import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// Downloads one region at a time into MBTiles files, with limited concurrency, retries and resume.
@MainActor
@Observable
final class DownloadManager {
    enum State: Equatable {
        case idle
        case running
        case finished
        case cancelled
        case failed(String)
    }

    struct Progress: Equatable {
        var total = 0
        var done = 0       // stored, already present, or not on the server
        var failed = 0
        var bytes: Int64 = 0
        var fraction: Double { total == 0 ? 0 : Double(done + failed) / Double(total) }
    }

    private(set) var state: State = .idle
    private(set) var progress = Progress()
    private(set) var activeRegionID: UUID?
    private(set) var activeRegionName: String?

    @ObservationIgnored private let store: RegionStore
    @ObservationIgnored private var task: Task<Void, Never>?
    #if canImport(UIKit)
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    init(store: RegionStore) {
        self.store = store
    }

    var isRunning: Bool { state == .running }

    /// Builds the layers for a new download: the chosen map, plus the national overview underneath it.
    nonisolated static func plan(name: String, area: BoundingBox, source: TileSource, zooms: ClosedRange<Int>,
                     includeOverview: Bool) -> OfflineRegion? {
        let id = UUID()
        var layers: [OfflineRegion.Layer] = []
        if let box = area.intersection(source.coverage) {
            layers.append(.init(sourceID: source.id, bbox: box, minZoom: zooms.lowerBound, maxZoom: zooms.upperBound,
                                fileName: "\(id.uuidString)-\(source.id).mbtiles"))
        }
        let overview = TileSources.overview
        if includeOverview, overview.id != source.id, let box = area.intersection(overview.coverage) {
            let top = min(overview.maxZoom, zooms.upperBound)
            let bottom = min(overview.suggestedDownloadZooms.lowerBound, top)
            layers.append(.init(sourceID: overview.id, bbox: box, minZoom: bottom, maxZoom: top,
                                fileName: "\(id.uuidString)-\(overview.id).mbtiles"))
        }
        // Elevation for track profiles: one zoom level, about 1 MB for a 20 × 20 km area.
        let terrain = TileSources.terrain
        if !layers.isEmpty, let box = area.intersection(terrain.coverage) {
            layers.append(.init(sourceID: terrain.id, bbox: box, minZoom: terrain.maxZoom, maxZoom: terrain.maxZoom,
                                fileName: "\(id.uuidString)-\(terrain.id).mbtiles"))
        }
        guard !layers.isEmpty else { return nil }
        return OfflineRegion(id: id, name: name, bbox: area, layers: layers, createdAt: Date(), isComplete: false)
    }

    nonisolated static func tileCount(of region: OfflineRegion) -> Int {
        region.layers.reduce(0) { $0 + TileMath.tileCount(for: $1.bbox, zooms: $1.zooms) }
    }

    nonisolated static func estimatedBytes(of region: OfflineRegion) -> Int64 {
        region.layers.reduce(Int64(0)) { total, layer in
            let avg = TileSources.source(id: layer.sourceID)?.averageTileBytes ?? 30_000
            return total + Int64(TileMath.tileCount(for: layer.bbox, zooms: layer.zooms) * avg)
        }
    }

    /// Starts (or resumes) downloading a region. Tiles already in the file are skipped.
    func start(_ region: OfflineRegion) {
        guard !isRunning else { return }
        var region = region
        region.isComplete = false
        store.upsert(region)

        activeRegionID = region.id
        activeRegionName = region.name
        progress = Progress(total: Self.tileCount(of: region))
        state = .running
        setKeepAwake(true)

        task = Task { [weak self] in
            await self?.run(region)
        }
    }

    func cancel() {
        task?.cancel()
    }

    private func run(_ initial: OfflineRegion) async {
        var region = initial
        do {
            for layer in region.layers {
                guard let source = TileSources.source(id: layer.sourceID) else { continue }
                let db = try MBTiles(url: store.library.fileURL(layer.fileName), create: true)
                try db.setMetadata([
                    "name": region.name,
                    "format": source.storeAsJPEG ? "jpg" : "png",
                    "type": "baselayer",
                    "version": "1",
                    "attribution": source.attribution,
                    "bounds": "\(layer.bbox.minLon),\(layer.bbox.minLat),\(layer.bbox.maxLon),\(layer.bbox.maxLat)",
                    "minzoom": String(layer.minZoom),
                    "maxzoom": String(layer.maxZoom),
                ])
                store.upsert(region)  // make the file visible to the map while it fills in
                await download(TileMath.tiles(for: layer.bbox, zooms: layer.zooms), from: source, into: db)
                db.checkpoint()
                if Task.isCancelled { break }
            }
            let namesOK = Task.isCancelled ? false : await saveNames(for: &region)
            let tracksOK = Task.isCancelled ? false : await saveTracks(for: &region)
            let terrainOK = Task.isCancelled ? false : await ensureTerrain(for: &region) != .failed
            region.failedTiles = progress.failed
            region.isComplete = !Task.isCancelled && progress.failed == 0 && namesOK && tracksOK && terrainOK
            store.upsert(region)
            state = Task.isCancelled ? .cancelled : .finished
        } catch {
            store.upsert(region)
            state = .failed(error.localizedDescription)
        }
        activeRegionID = nil
        setKeepAwake(false)
    }

    /// Areas downloaded before search and tracks existed lack place names and track lines:
    /// fetch them quietly (a few small requests per area). Failures are retried next launch.
    func addMissingNames(offlineOnly: Bool) async {
        guard !offlineOnly else { return }  // Offline mode means no network requests at all
        for var region in store.regions
        where region.isComplete && (region.namesFileName == nil || !Self.isCurrentTracksFile(region.tracksFileName)) {
            guard !isRunning else { return }
            let names = await saveNames(for: &region)
            let tracks = await saveTracks(for: &region)
            if names || tracks { store.upsert(region) }
        }
        // Elevation for older areas, and for tracks that run past an area's edge.
        for var region in store.regions where region.isComplete {
            guard !isRunning else { return }
            if await ensureTerrain(for: &region) == .updated { store.upsert(region) }
        }
    }

    enum TerrainResult { case unchanged, updated, failed }

    /// Makes sure elevation is saved for the area and for wherever its saved tracks go (up to
    /// ~10 km beyond the area), so profiles work offline for tracks that run past the edge.
    /// Only missing tiles are fetched; it's a few dozen small tiles for a typical area.
    func ensureTerrain(for region: inout OfflineRegion) async -> TerrainResult {
        let terrain = TileSources.terrain
        var wanted = region.bbox
        if let file = region.tracksFileName,
           let data = try? Data(contentsOf: store.library.fileURL(file)),
           let segments = try? JSONDecoder().decode([TrackSegment].self, from: data) {
            for s in segments { wanted = wanted.union(s.bbox) }
        }
        guard let box = wanted.intersection(region.bbox.expanded(by: 0.1))?.intersection(terrain.coverage) else {
            return .unchanged  // outside the elevation data's coverage
        }
        let existing = region.layers.firstIndex { $0.sourceID == terrain.id }
        if let i = existing, region.layers[i].bbox.contains(box) { return .unchanged }

        let fileName = existing.map { region.layers[$0].fileName } ?? "\(region.id.uuidString)-\(terrain.id).mbtiles"
        let keys = TileMath.tiles(for: box, zooms: terrain.maxZoom...terrain.maxZoom)
        guard keys.count <= 1500,
              let db = try? MBTiles(url: store.library.fileURL(fileName), create: true) else { return .failed }
        for key in keys where !db.contains(key) {
            guard let (data, response) = try? await TileNetwork.download.data(from: terrain.tileURL(key)),
                  (response as? HTTPURLResponse)?.statusCode == 200, TileImage.isImage(data) else { return .failed }
            try? db.insert(key, data: data)
        }
        db.checkpoint()
        let layer = OfflineRegion.Layer(sourceID: terrain.id, bbox: box, minZoom: terrain.maxZoom,
                                        maxZoom: terrain.maxZoom, fileName: fileName)
        if let i = existing { region.layers[i] = layer } else { region.layers.append(layer) }
        return .updated
    }

    /// Bump when the way tracks are named or grouped changes; older saved files are then refreshed.
    /// v2: Queensland tracks grouped by their public name (visitor_id).
    private static let tracksFormat = "tracks-v2"

    private static func isCurrentTracksFile(_ file: String?) -> Bool {
        file?.hasSuffix("-\(tracksFormat).json") == true
    }

    /// Saves the area's walking tracks so tapping and searching them works offline.
    private func saveTracks(for region: inout OfflineRegion) async -> Bool {
        if let file = region.tracksFileName, Self.isCurrentTracksFile(file),
           FileManager.default.fileExists(atPath: store.library.fileURL(file).path) {
            return true
        }
        do {
            let segments = try await TrackSources.segments(in: region.bbox, session: TileNetwork.download)
            let file = "\(region.id.uuidString)-\(Self.tracksFormat).json"
            try JSONEncoder().encode(segments).write(to: store.library.fileURL(file), options: .atomic)
            if let old = region.tracksFileName, old != file {
                try? FileManager.default.removeItem(at: store.library.fileURL(old))
            }
            region.tracksFileName = file
            return true
        } catch {
            return false  // the region stays "incomplete" so Resume can retry
        }
    }

    /// Saves the area's place names so search works offline. Skipped if already saved (resume).
    private func saveNames(for region: inout OfflineRegion) async -> Bool {
        if let file = region.namesFileName,
           FileManager.default.fileExists(atPath: store.library.fileURL(file).path) {
            return true
        }
        do {
            let names = try await Gazetteer.names(in: region.bbox)
            let file = "\(region.id.uuidString)-names.json"
            try JSONEncoder().encode(names).write(to: store.library.fileURL(file), options: .atomic)
            region.namesFileName = file
            return true
        } catch {
            return false  // the region stays "incomplete" so Resume can retry
        }
    }

    private func download(_ keys: [TileKey], from source: TileSource, into db: MBTiles) async {
        let session = TileNetwork.download
        await withTaskGroup(of: TileResult.self) { group in
            var iterator = keys.makeIterator()
            for _ in 0..<DownloadLimits.maxConcurrentRequests {
                guard let key = iterator.next() else { break }
                group.addTask { await Self.fetch(key, source: source, session: session, db: db) }
            }
            for await result in group {
                switch result {
                case .stored(let bytes):
                    progress.done += 1
                    progress.bytes += Int64(bytes)
                case .skipped:
                    progress.done += 1
                case .failed:
                    progress.failed += 1
                case .cancelled:
                    break
                }
                if Task.isCancelled {
                    group.cancelAll()
                    continue
                }
                if let key = iterator.next() {
                    if let perMinute = source.maxTilesPerMinute, case .stored = result {
                        // Stay under the provider's limit (only real downloads count, not skips).
                        try? await Task.sleep(nanoseconds: UInt64(60_000_000_000 / perMinute))
                    }
                    group.addTask { await Self.fetch(key, source: source, session: session, db: db) }
                }
            }
        }
    }

    private enum TileResult: Sendable {
        case stored(Int)
        case skipped   // already downloaded, or the server has no tile there
        case failed
        case cancelled
    }

    nonisolated private static func fetch(_ key: TileKey, source: TileSource, session: URLSession, db: MBTiles) async -> TileResult {
        if db.contains(key) { return .skipped }
        for attempt in 0..<DownloadLimits.retries {
            if Task.isCancelled { return .cancelled }
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000)
            }
            do {
                let (data, response) = try await session.data(from: source.tileURL(key))
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                switch status {
                case 200 where TileImage.isImage(data):
                    let stored = source.storeAsJPEG ? (TileImage.jpeg(from: data) ?? data) : data
                    try db.insert(key, data: stored)
                    return .stored(stored.count)
                case 404, 204:
                    return .skipped  // outside the map's coverage
                case 429, 500...599:
                    continue  // busy or temporary error: back off and retry
                default:
                    return .failed
                }
            } catch {
                if Task.isCancelled { return .cancelled }
            }
        }
        return .failed
    }

    /// Stop the screen locking (which would pause the download) and ask iOS for a little extra
    /// time if the user switches away.
    private func setKeepAwake(_ on: Bool) {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = on
        if on {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Map download") { [weak self] in
                // Out of background time: stop cleanly. The region can be resumed later.
                MainActor.assumeIsolated {
                    self?.cancel()
                    self?.endBackgroundTask()
                }
            }
        } else {
            endBackgroundTask()
        }
        #endif
    }

    #if canImport(UIKit)
    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
    #endif
}
