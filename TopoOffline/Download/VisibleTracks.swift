import Foundation
import Observation

/// Keeps the tracks for the visible part of Victoria loaded, so they can be drawn on the map.
/// (Victoria has no free topo map, so without this its walking tracks wouldn't be visible.)
/// Works in 0.1° cells (about 10 km) that are cached, so panning doesn't refetch.
@MainActor
@Observable
final class VisibleTracks {
    /// Tracks to draw. `version` changes whenever this does (cheap change detection for MapKit).
    private(set) var segments: [TrackSegment] = []
    private(set) var version = 0

    /// Tracks are drawn from this zoom (roughly a 30 km wide view on a phone).
    static let minZoom = 12.0
    nonisolated private static let cell = 0.1
    private static let maxCells = 40

    @ObservationIgnored private var cache: [String: [TrackSegment]] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Call when the map stops moving. Loads missing cells (online), or reads downloaded areas (offline).
    func update(area: BoundingBox?, zoom: Double, offlineOnly: Bool, library: OfflineTileLibrary) {
        task?.cancel()
        guard let area, zoom >= Self.minZoom, let visible = area.intersection(TrackSources.victoria) else {
            set([])
            return
        }
        if offlineOnly {
            set(library.trackSegments(in: visible, state: "VIC"))
            return
        }
        let keys = Self.cells(covering: visible)
        guard keys.count <= Self.maxCells else { return }
        set(Self.unique(keys.compactMap { cache[$0] }.flatMap { $0 }))
        let missing = keys.filter { cache[$0] == nil }
        guard !missing.isEmpty else { return }
        task = Task {
            await withTaskGroup(of: (String, [TrackSegment]?).self) { group in
                for key in missing {
                    group.addTask {
                        let box = Self.box(for: key)
                        let segs = try? await TrackSources.segments(in: box, layers: [TrackSources.vicTrails])
                        return (key, segs)
                    }
                }
                for await (key, segs) in group {
                    if let segs { cache[key] = segs }
                }
            }
            guard !Task.isCancelled else { return }
            // Downloaded areas fill in any cell that failed to load (e.g. patchy signal).
            var all = keys.compactMap { cache[$0] }.flatMap { $0 }
            if keys.contains(where: { cache[$0] == nil }) {
                all += library.trackSegments(in: visible, state: "VIC")
            }
            set(Self.unique(all))
        }
    }

    /// Waits for the current load (used by the self-test).
    func settle() async { await task?.value }

    private func set(_ new: [TrackSegment]) {
        guard new.count != segments.count || new.first?.coords != segments.first?.coords else { return }
        segments = new
        version += 1
    }

    private static func cells(covering box: BoundingBox) -> [String] {
        let x0 = Int(floor(box.minLon / cell)), x1 = Int(floor(box.maxLon / cell))
        let y0 = Int(floor(box.minLat / cell)), y1 = Int(floor(box.maxLat / cell))
        guard x1 >= x0, y1 >= y0, (x1 - x0 + 1) * (y1 - y0 + 1) <= maxCells else {
            return Array(repeating: "", count: maxCells + 1)  // too many: caller skips
        }
        return (y0...y1).flatMap { y in (x0...x1).map { x in "\(x),\(y)" } }
    }

    nonisolated private static func box(for key: String) -> BoundingBox {
        let p = key.split(separator: ",").compactMap { Int($0) }
        return BoundingBox(minLat: Double(p[1]) * cell, minLon: Double(p[0]) * cell,
                           maxLat: Double(p[1] + 1) * cell, maxLon: Double(p[0] + 1) * cell)
    }

    /// A segment crossing a cell edge comes back for both cells.
    private static func unique(_ segs: [TrackSegment]) -> [TrackSegment] {
        var seen = Set<[Double]>()
        return segs.filter { seen.insert($0.coords).inserted }
    }
}
