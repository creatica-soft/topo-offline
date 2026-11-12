import Foundation
import CoreLocation

/// Thread-safe lookup of downloaded tiles across all offline regions.
/// MapKit asks for tiles on background threads, so this class is not tied to the main actor.
final class OfflineTileLibrary: @unchecked Sendable {
    private struct Entry {
        let sourceID: String
        let bbox: BoundingBox
        let zooms: ClosedRange<Int>
        let db: MBTiles
    }

    let directory: URL
    private let lock = NSLock()
    private var entries: [Entry] = []
    private var handles: [String: MBTiles] = [:]  // keyed by file name
    private var names: [String: [PlaceName]] = [:]  // place names per names file, for offline search
    private var tracks: [String: [TrackSegment]] = [:]  // track segments per tracks file
    /// Country-wide name lists searched on the phone (New Zealand), with names pre-normalised.
    private var nationalNames: [(place: PlaceName, normalized: String)] = []

    init(directory: URL = OfflineTileLibrary.defaultDirectory) {
        self.directory = directory
        Self.prepare(directory)
        if let data = try? Data(contentsOf: fileURL(NZPlaceNames.fileName)),
           let names = try? JSONDecoder().decode([PlaceName].self, from: data) {
            nationalNames = names.map { ($0, Gazetteer.normalize($0.name)) }
        }
    }

    /// True when the NZ name list is missing or due for a refresh.
    var nationalNamesNeedRefresh: Bool {
        let url = fileURL(NZPlaceNames.fileName)
        guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return true }
        return Date().timeIntervalSince(date) > NZPlaceNames.maxAge
    }

    var nationalNamesCount: Int {
        lock.lock(); defer { lock.unlock() }
        return nationalNames.count
    }

    func setNationalNames(_ names: [PlaceName]) {
        if let data = try? JSONEncoder().encode(names) {
            try? data.write(to: fileURL(NZPlaceNames.fileName), options: .atomic)
        }
        let prepared = names.map { ($0, Gazetteer.normalize($0.name)) }
        lock.lock()
        nationalNames = prepared
        lock.unlock()
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OfflineMaps", isDirectory: true)
    }

    func fileURL(_ fileName: String) -> URL { directory.appendingPathComponent(fileName) }

    /// Rebuilds the lookup table. Called whenever regions are added, finished or deleted.
    func reload(regions: [OfflineRegion]) {
        lock.lock(); defer { lock.unlock() }
        var newEntries: [Entry] = []
        var newHandles: [String: MBTiles] = [:]
        for region in regions {
            for layer in region.layers {
                let url = fileURL(layer.fileName)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                guard let db = handles[layer.fileName] ?? (try? MBTiles(url: url)) else { continue }
                newHandles[layer.fileName] = db
                newEntries.append(Entry(sourceID: layer.sourceID, bbox: layer.bbox, zooms: layer.zooms, db: db))
            }
        }
        entries = newEntries
        handles = newHandles

        var newNames: [String: [PlaceName]] = [:]
        for region in regions {
            guard let file = region.namesFileName else { continue }
            if let cached = names[file] {
                newNames[file] = cached
            } else if let data = try? Data(contentsOf: fileURL(file)),
                      let decoded = try? JSONDecoder().decode([PlaceName].self, from: data) {
                newNames[file] = decoded
            }
        }
        names = newNames

        var newTracks: [String: [TrackSegment]] = [:]
        for region in regions {
            guard let file = region.tracksFileName else { continue }
            if let cached = tracks[file] {
                newTracks[file] = cached
            } else if let data = try? Data(contentsOf: fileURL(file)),
                      let decoded = try? JSONDecoder().decode([TrackSegment].self, from: data) {
                newTracks[file] = decoded
            }
        }
        tracks = newTracks
    }

    // MARK: - Offline tracks

    private var allTrackSegments: [TrackSegment] {
        lock.lock(); defer { lock.unlock() }
        return Array(tracks.values.joined())
    }

    /// The downloaded track segment closest to `c`, if within `meters`.
    func nearestTrackSegment(to c: CLLocationCoordinate2D, within meters: Double) -> TrackSegment? {
        let dLat = meters / 110_540, dLon = meters / (111_320 * cos(c.latitude * .pi / 180))
        let probe = BoundingBox(minLat: c.latitude - dLat, minLon: c.longitude - dLon,
                                maxLat: c.latitude + dLat, maxLon: c.longitude + dLon)
        var best: (TrackSegment, Double)?
        for s in allTrackSegments where s.bbox.intersects(probe) {
            let d = s.distanceMeters(to: c)
            if d <= meters, d < (best?.1 ?? .infinity) { best = (s, d) }
        }
        return best?.0
    }

    /// Downloaded segments of one state inside `box` (de-duplicated across overlapping areas).
    func trackSegments(in box: BoundingBox, state: String) -> [TrackSegment] {
        var seen = Set<[Double]>()
        return allTrackSegments.filter {
            $0.state == state && $0.bbox.intersects(box) && seen.insert($0.coords).inserted
        }
    }

    /// Every downloaded segment of a named track (de-duplicated across overlapping areas).
    func trackSegments(named name: String, state: String) -> [TrackSegment] {
        let wanted = Gazetteer.normalize(name)
        var seen = Set<[Double]>()
        return allTrackSegments.filter {
            $0.state == state && $0.name.map(Gazetteer.normalize) == wanted && seen.insert($0.coords).inserted
        }
    }

    func searchTracks(_ text: String) -> [Track] {
        let tokens = Gazetteer.tokens(of: text)
        guard !tokens.isEmpty else { return [] }
        var seen = Set<[Double]>()
        let hits = allTrackSegments.filter { s in
            guard let n = s.name else { return false }
            let normalized = Gazetteer.normalize(n)
            return tokens.allSatisfy { normalized.contains($0) } && seen.insert(s.coords).inserted
        }
        return TrackSources.group(hits)
    }

    /// Searches the place names saved with downloaded areas (works with no signal).
    func searchNames(_ text: String, near center: CLLocationCoordinate2D?) -> [PlaceName] {
        let tokens = Gazetteer.tokens(of: text)
        guard !tokens.isEmpty else { return [] }
        lock.lock()
        let all = names.values.joined()
        var hits = all.filter { Gazetteer.matches($0, tokens: tokens) }
        let national = nationalNames
        lock.unlock()
        hits += national.filter { entry in tokens.allSatisfy { entry.normalized.contains($0) } }.map(\.place)
        return Gazetteer.rank(hits, for: text, near: center)
    }

    var hasOfflineNames: Bool {
        lock.lock(); defer { lock.unlock() }
        return !nationalNames.isEmpty || names.values.contains { !$0.isEmpty }
    }

    func tile(sourceID: String, key: TileKey) -> Data? {
        let tileBox = TileMath.bbox(of: key)
        lock.lock()
        let candidates = entries.filter {
            $0.sourceID == sourceID && $0.zooms.contains(key.z) && $0.bbox.intersects(tileBox)
        }
        lock.unlock()
        for entry in candidates {
            if let data = entry.db.tile(key) { return data }
        }
        return nil
    }

    func deleteFiles(for region: OfflineRegion) {
        lock.lock()
        for layer in region.layers { handles[layer.fileName] = nil }
        for file in [region.namesFileName, region.tracksFileName].compactMap({ $0 }) {
            names[file] = nil
            tracks[file] = nil
            try? FileManager.default.removeItem(at: fileURL(file))
        }
        entries.removeAll { entry in region.layers.contains { $0.fileName == entry.db.url.lastPathComponent } }
        lock.unlock()
        for layer in region.layers {
            let base = fileURL(layer.fileName).path
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: base + suffix)
            }
        }
    }

    func bytesOnDisk(for region: OfflineRegion) -> Int64 {
        let namesBytes = [region.namesFileName, region.tracksFileName].compactMap { $0 }.reduce(0) { sum, file in
            sum + ((try? fileURL(file).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return Int64(namesBytes) + region.layers.reduce(0) { total, layer in
            let base = fileURL(layer.fileName)
            return total + ["", "-wal"].reduce(Int64(0)) { sum, suffix in
                let url = URL(fileURLWithPath: base.path + suffix)
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return sum + Int64(size)
            }
        }
    }

    /// Map tiles can be downloaded again, so Apple's guidelines require keeping them out of iCloud backups.
    private static func prepare(_ directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var dir = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
    }
}
