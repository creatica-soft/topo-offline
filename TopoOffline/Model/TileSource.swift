import Foundation
import CoreLocation

/// A raster topo map served as 256 px Web Mercator tiles.
struct TileSource: Identifiable, Hashable, Sendable {
    let id: String
    /// Name shown in the map picker.
    let name: String
    /// Area the map covers, e.g. "New South Wales".
    let coverageName: String
    /// URL with `{z}`, `{x}` and `{y}` placeholders (ArcGIS caches use `/tile/{z}/{y}/{x}`),
    /// and `{key}` for an API key from `Secrets`.
    let urlTemplate: String
    /// Lowest zoom worth requesting.
    let minZoom: Int
    /// Highest zoom the server actually has (verified by sampling tiles). Above this, tiles are scaled up.
    let maxZoom: Int
    /// Default zoom range offered when downloading an area.
    let suggestedDownloadZooms: ClosedRange<Int>
    /// Rough rectangle the map covers.
    let coverage: BoundingBox
    /// Credit line shown on the map (required by the licence).
    let attribution: String
    let licenceName: String
    let licenceURL: URL
    /// Used to estimate download size.
    let averageTileBytes: Int
    /// Large PNG tiles are re-encoded to JPEG when stored offline (≈3× smaller).
    let storeAsJPEG: Bool
    /// Optional rough outline (e.g. a state border) used to decide which map to show for a spot.
    /// Coverage rectangles of neighbouring states overlap a lot; the outline settles which one applies.
    var outline: [LonLat] = []
    /// Australian state maps sit on top of the national map (shown when zoomed out); a map with
    /// its own small-scale levels, like NZ's Topo250, doesn't need it.
    var usesNationalOverview = true
    /// Provider rate limit for downloads (nil = none we need to respect).
    var maxTilesPerMinute: Int? = nil

    /// False when the map needs an API key that hasn't been set (see `Secrets`).
    var isAvailable: Bool {
        !urlTemplate.contains("{key}") || !Secrets.linzAPIKey.isEmpty
    }

    /// Whether this map has data at `point`.
    func covers(_ point: CLLocationCoordinate2D) -> Bool {
        guard coverage.contains(point) else { return false }
        return outline.isEmpty || LonLat.polygon(outline, contains: point)
    }

    func tileURL(_ key: TileKey) -> URL {
        let s = urlTemplate
            .replacingOccurrences(of: "{z}", with: String(key.z))
            .replacingOccurrences(of: "{x}", with: String(key.x))
            .replacingOccurrences(of: "{y}", with: String(key.y))
            .replacingOccurrences(of: "{key}", with: Secrets.linzAPIKey)
        return URL(string: s)!
    }
}

enum TileSources {
    // Zoom ranges and tile sizes were measured against the live servers in November 2026.

    static let nsw = TileSource(
        id: "nsw-topo",
        name: "NSW Topo",
        coverageName: "New South Wales",
        urlTemplate: "https://maps.six.nsw.gov.au/arcgis/rest/services/public/NSW_Topo_Map/MapServer/tile/{z}/{y}/{x}",
        minZoom: 6, maxZoom: 16, suggestedDownloadZooms: 9...16,
        coverage: BoundingBox(minLat: -37.6, minLon: 140.9, maxLat: -28.1, maxLon: 153.7),
        attribution: "© State of New South Wales (Spatial Services, DCS)",
        licenceName: "CC BY 4.0 (per Spatial Services web services terms)",
        licenceURL: URL(string: "https://www.spatial.nsw.gov.au/products_and_services/web_services/terms_and_conditions")!,
        averageTileBytes: 30_000, storeAsJPEG: false,
        outline: StateOutlines.nsw)

    static let qld = TileSource(
        id: "qld-topo",
        name: "Queensland Topo",
        coverageName: "Queensland",
        urlTemplate: "https://spatial-gis.information.qld.gov.au/arcgis/rest/services/Basemaps/QldMap_Topo/MapServer/tile/{z}/{y}/{x}",
        minZoom: 5, maxZoom: 17, suggestedDownloadZooms: 9...16,
        coverage: BoundingBox(minLat: -29.2, minLon: 137.9, maxLat: -9.0, maxLon: 153.6),
        attribution: "© State of Queensland, CC BY 4.0",
        licenceName: "CC BY 4.0",
        licenceURL: URL(string: "https://creativecommons.org/licenses/by/4.0/")!,
        averageTileBytes: 45_000, storeAsJPEG: true,
        outline: StateOutlines.qld)

    static let tas = TileSource(
        id: "tas-topo",
        name: "Tasmania Topo",
        coverageName: "Tasmania",
        urlTemplate: "https://services.thelist.tas.gov.au/arcgis/rest/services/Basemaps/Topographic/MapServer/tile/{z}/{y}/{x}",
        minZoom: 5, maxZoom: 17, suggestedDownloadZooms: 9...16,
        coverage: BoundingBox(minLat: -43.8, minLon: 143.5, maxLat: -39.2, maxLon: 148.6),
        attribution: "© State of Tasmania (the LIST), CC BY 3.0 AU",
        licenceName: "CC BY 3.0 AU",
        licenceURL: URL(string: "https://creativecommons.org/licenses/by/3.0/au/")!,
        averageTileBytes: 25_000, storeAsJPEG: true)

    static let australia = TileSource(
        id: "ga-topo",
        name: "Australia (1:250k)",
        coverageName: "Australia",
        urlTemplate: "https://services.ga.gov.au/gis/rest/services/Topographic_Base_Map/MapServer/tile/{z}/{y}/{x}",
        minZoom: 3, maxZoom: 12, suggestedDownloadZooms: 5...12,
        coverage: BoundingBox(minLat: -44.0, minLon: 112.0, maxLat: -9.0, maxLon: 154.0),
        attribution: "© Commonwealth of Australia (Geoscience Australia), CC BY 4.0",
        licenceName: "CC BY 4.0",
        licenceURL: URL(string: "https://creativecommons.org/licenses/by/4.0/")!,
        averageTileBytes: 15_000, storeAsJPEG: false)

    /// New Zealand: LINZ Topo50 (and Topo250 when zoomed out). Needs a LINZ Basemaps key.
    /// LINZ serves tiles to zoom 18, but Topo50's real detail ends at 15 (16+ are enlargements),
    /// so 15 is the top: downloads are 4× smaller and the app enlarges beyond it itself.
    static let nz = TileSource(
        id: "nz-topo",
        name: "NZ Topo50",
        coverageName: "New Zealand",
        urlTemplate: "https://basemaps.linz.govt.nz/v1/tiles/topo-raster/WebMercatorQuad/{z}/{x}/{y}.png?api={key}",
        minZoom: 5, maxZoom: 15, suggestedDownloadZooms: 9...15,
        coverage: BoundingBox(minLat: -47.4, minLon: 166.3, maxLat: -34.3, maxLon: 178.7),
        attribution: "© Toitū Te Whenua LINZ, CC BY 4.0",
        licenceName: "CC BY 4.0 (LINZ Basemaps terms of use)",
        licenceURL: URL(string: "https://www.linz.govt.nz/guidance/data-service/linz-basemaps-guide/linz-basemaps-terms-use")!,
        averageTileBytes: 50_000, storeAsJPEG: true,  // PNG tiles are ~160 KB
        usesNationalOverview: false,
        maxTilesPerMinute: Secrets.linzKeyIsDeveloperKey ? nil : 900)

    /// Elevation (not shown as a map): Terrain Tiles, terrarium-encoded PNGs. Zoom 13 is about
    /// 15 m per pixel here, finer than the 30 m SRTM data behind it in Australia. Must stay
    /// lossless (no JPEG), since the colours *are* the elevations.
    static let terrain = TileSource(
        id: "terrain",
        name: "Elevation",
        coverageName: "Australia and New Zealand",
        urlTemplate: "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png",
        minZoom: 13, maxZoom: 13, suggestedDownloadZooms: 13...13,
        coverage: BoundingBox(minLat: -48.0, minLon: 112.0, maxLat: -9.0, maxLon: 179.0),
        attribution: Elevation.attribution,
        licenceName: "CC BY (Geoscience Australia, LINZ); public domain (USGS)",
        licenceURL: URL(string: "https://github.com/tilezen/joerd/blob/master/docs/attribution.md")!,
        averageTileBytes: 35_000, storeAsJPEG: false,
        usesNationalOverview: false)

    /// Shown underneath the detailed state maps so there is always something on screen.
    static let overview = australia

    /// Everything selectable; maps needing a key that isn't set are left out.
    static let all: [TileSource] = [nsw, qld, tas, nz, australia].filter(\.isAvailable)
    static let allIncludingUnavailable: [TileSource] = [nsw, qld, tas, nz, australia]

    static func source(id: String) -> TileSource? { (all + [terrain]).first { $0.id == id } }

    /// With "national map when zoomed out" on, state maps take over from this zoom
    /// (about a 10 km wide view on a phone), where their contours become useful.
    static let detailFromZoom = 13

    /// The detailed state maps, in the order they're tried.
    static let stateMaps: [TileSource] = [nsw, qld, tas, nz].filter(\.isAvailable)

    /// The best map for a spot: keep `current` if it covers the spot (coverage rectangles overlap
    /// along state borders, so this avoids flip-flopping there), otherwise the state map that
    /// covers it, otherwise the national map.
    static func best(for point: CLLocationCoordinate2D, preferring current: TileSource? = nil) -> TileSource {
        if let current, current.covers(point) { return current }
        return stateMaps.first { $0.covers(point) } ?? australia
    }

    /// Maps that have anything inside `area`, best match first.
    static func available(in area: BoundingBox, preferring current: TileSource? = nil) -> [TileSource] {
        let first = best(for: area.center, preferring: current)
        return [first] + all.filter { $0.id != first.id && $0.coverage.intersects(area) }
    }
}
