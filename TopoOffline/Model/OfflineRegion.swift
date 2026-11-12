import Foundation

/// An area the user downloaded. Each layer (map source) is stored in its own MBTiles file.
struct OfflineRegion: Identifiable, Codable, Hashable, Sendable {
    struct Layer: Codable, Hashable, Sendable {
        var sourceID: String
        var bbox: BoundingBox
        var minZoom: Int
        var maxZoom: Int
        var fileName: String
        var zooms: ClosedRange<Int> { minZoom...maxZoom }
    }

    var id: UUID
    var name: String
    var bbox: BoundingBox
    var layers: [Layer]
    var createdAt: Date
    var isComplete: Bool
    /// Tiles that failed after retries on the last run (0 when complete).
    var failedTiles: Int = 0
    /// Place names inside the area (JSON array of `PlaceName`), for searching offline.
    var namesFileName: String?
    /// Walking tracks inside the area (JSON array of `TrackSegment`), for tapping and searching offline.
    var tracksFileName: String?

    /// The detailed map the user chose (the overview layer, if any, comes after it).
    var primarySource: TileSource? { layers.first.flatMap { TileSources.source(id: $0.sourceID) } }
}
