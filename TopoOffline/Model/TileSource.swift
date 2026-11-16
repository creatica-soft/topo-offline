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
    /// Tile format as written to the MBTiles `format` metadata.
    var storedFormat: String {
        if storeAsJPEG { return "jpg" }
        return urlTemplate.contains(".webp") ? "webp" : "png"
    }
    /// Optional rough outlines (e.g. a state border) used to decide which map to show for a spot.
    /// Coverage rectangles of neighbouring states overlap a lot; the outlines settle which one applies.
    /// A country can have several (the US: lower 48, Alaska, Hawaii, Puerto Rico).
    var outlines: [[LonLat]] = []
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
        return outlines.isEmpty || outlines.contains { LonLat.polygon($0, contains: point) }
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
        // Attribution and licence as confirmed by DCS Spatial Services (request SD-17847, November 2026).
        attribution: "© State of New South Wales (DCS Spatial Services)",
        licenceName: "CC BY 4.0",
        licenceURL: URL(string: "https://www.nsw.gov.au/nsw-government/copyright")!,
        averageTileBytes: 30_000, storeAsJPEG: false,
        outlines: [StateOutlines.nsw])

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
        outlines: [StateOutlines.qld])

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
    /// WebP at LINZ's request (much cheaper for them to serve): ~20 KB a tile vs ~150 KB as PNG,
    /// visually the same, and stored as-is since it's already half the size of our JPEG re-encode.
    static let nz = TileSource(
        id: "nz-topo",
        name: "NZ Topo50",
        coverageName: "New Zealand",
        urlTemplate: "https://basemaps.linz.govt.nz/v1/tiles/topo-raster/WebMercatorQuad/{z}/{x}/{y}.webp?api={key}",
        minZoom: 5, maxZoom: 15, suggestedDownloadZooms: 9...15,
        coverage: BoundingBox(minLat: -47.4, minLon: 166.3, maxLat: -34.3, maxLon: 178.7),
        attribution: "© LINZ CC BY 4.0",  // the wording LINZ's Basemaps attribution example uses
        licenceName: "LINZ copyright",
        licenceURL: URL(string: "https://www.linz.govt.nz/copyright")!,
        averageTileBytes: 20_000, storeAsJPEG: false,
        usesNationalOverview: false,
        maxTilesPerMinute: Secrets.linzKeyIsDeveloperKey ? nil : 900)

    /// United States: USGS Topo from The National Map (US Topo / National Map data, public domain).
    /// Cached to zoom 16 (17 doesn't exist); the server allows tile export, so saving areas is expected.
    static let us = TileSource(
        id: "us-topo",
        name: "USGS Topo",
        coverageName: "United States",
        urlTemplate: "https://basemap.nationalmap.gov/arcgis/rest/services/USGSTopo/MapServer/tile/{z}/{y}/{x}",
        minZoom: 4, maxZoom: 16, suggestedDownloadZooms: 9...16,
        coverage: usCoverage,
        attribution: "USGS The National Map",
        licenceName: "Public domain (U.S. Government)",
        licenceURL: URL(string: "https://www.usgs.gov/information-policies-and-instructions/copyrights-and-credits")!,
        averageTileBytes: 25_000, storeAsJPEG: false,
        outlines: USOutlines.all,
        usesNationalOverview: false)

    /// All US states and territories the USGS map covers (the outlines narrow it down).
    static let usCoverage = BoundingBox(minLat: 17.5, minLon: -180, maxLat: 72, maxLon: -64.5)

    /// Elevation (not shown as a map): Terrain Tiles, terrarium-encoded PNGs. Zoom 13 is about
    /// 15 m per pixel here, finer than the 30 m SRTM data behind it in Australia (US data is 10 m 3DEP). Must stay
    /// lossless (no JPEG), since the colours *are* the elevations.
    static let terrain = TileSource(
        id: "terrain",
        name: "Elevation",
        coverageName: "Worldwide",
        urlTemplate: "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png",
        minZoom: 13, maxZoom: 13, suggestedDownloadZooms: 13...13,
        coverage: BoundingBox(minLat: -60.0, minLon: -180.0, maxLat: 72.0, maxLon: 180.0),
        attribution: Elevation.attribution,
        licenceName: "CC BY (Geoscience Australia, LINZ); public domain (USGS 3DEP, SRTM)",
        licenceURL: URL(string: "https://github.com/tilezen/joerd/blob/master/docs/attribution.md")!,
        averageTileBytes: 35_000, storeAsJPEG: false,
        usesNationalOverview: false)

    /// Shown underneath the detailed state maps so there is always something on screen.
    static let overview = australia

    /// Everything selectable; maps needing a key that isn't set are left out.
    static let all: [TileSource] = [nsw, qld, tas, nz, us, australia].filter(\.isAvailable)
    static let allIncludingUnavailable: [TileSource] = [nsw, qld, tas, nz, us, australia]

    static func source(id: String) -> TileSource? { (all + [terrain]).first { $0.id == id } }

    /// The map chosen on first launch: the phone's own country when the app has a map for it.
    static func defaultSource(for locale: Locale = .current) -> TileSource {
        switch locale.region?.identifier {
        case "US", "PR", "VI": return us
        case "NZ" where nz.isAvailable: return nz
        default: return nsw
        }
    }

    /// With "national map when zoomed out" on, state maps take over from this zoom
    /// (about a 10 km wide view on a phone), where their contours become useful.
    static let detailFromZoom = 13

    /// The detailed state maps, in the order they're tried.
    static let stateMaps: [TileSource] = [nsw, qld, tas, nz, us].filter(\.isAvailable)

    /// The best map for a spot: keep `current` if it covers the spot (coverage rectangles overlap
    /// along state borders, so this avoids flip-flopping there), otherwise the state map that
    /// covers it, otherwise (in Australia) the national map. Elsewhere `current` stays, and
    /// Apple's map shows where it has nothing.
    static func best(for point: CLLocationCoordinate2D, preferring current: TileSource? = nil) -> TileSource {
        if let current, current.covers(point) { return current }
        if let state = stateMaps.first(where: { $0.covers(point) }) { return state }
        if australia.covers(point) { return australia }
        return current ?? australia
    }

    /// Maps that have anything inside `area`, best match first.
    static func available(in area: BoundingBox, preferring current: TileSource? = nil) -> [TileSource] {
        let first = best(for: area.center, preferring: current)
        return [first] + all.filter { $0.id != first.id && $0.coverage.intersects(area) }
    }
}
