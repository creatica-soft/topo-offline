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
    /// `{key}` for an API key from `Secrets`, or `{bbox}` and `{size}` for a WMS GetMap request
    /// (Web Mercator bounds in metres, minX,minY,maxX,maxY, and the image width/height in pixels).
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
        if storeAsJPEG || urlTemplate.contains(".jpeg") || urlTemplate.contains(".jpg") { return "jpg" }
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
    /// Whether areas of this map may be saved for offline use. Off where the provider's terms
    /// need permission for copying that hasn't been given yet; the map still works online.
    var allowsOffline = true
    /// For a WMS that draws every request from scratch (slow, but the time hardly depends on the
    /// image size): fetch blocks of `metaTiles` × `metaTiles` tiles as one image and cut it up.
    var metaTiles = 1

    /// The country this map covers ("AU" for the Australian maps); search follows it.
    var country: String {
        switch id {
        case "nz-topo": return "NZ"
        case "us-topo": return "US"
        case "ca-topo": return "CA"
        case "ch-topo": return "CH"
        case "no-topo": return "NO"
        default: return "AU"
        }
    }

    /// False when the map needs an API key that hasn't been set (see `Secrets`).
    var isAvailable: Bool {
        !urlTemplate.contains("{key}") || !Secrets.linzAPIKey.isEmpty
    }

    /// Whether this map has data at `point`.
    func covers(_ point: CLLocationCoordinate2D) -> Bool {
        guard coverage.contains(point) else { return false }
        return outlines.isEmpty || outlines.contains { LonLat.polygon($0, contains: point) }
    }

    /// Whether this map has data anywhere in `box` (checks the centre, corners and edge midpoints
    /// against the outlines, so a box just over a border doesn't count).
    func touches(_ box: BoundingBox) -> Bool {
        guard coverage.intersects(box) else { return false }
        guard !outlines.isEmpty else { return true }
        let lats = [box.minLat, box.center.latitude, box.maxLat], lons = [box.minLon, box.center.longitude, box.maxLon]
        return lats.contains { lat in lons.contains { lon in covers(CLLocationCoordinate2D(latitude: lat, longitude: lon)) } }
    }

    func tileURL(_ key: TileKey) -> URL {
        let s = urlTemplate
            .replacingOccurrences(of: "{z}", with: String(key.z))
            .replacingOccurrences(of: "{x}", with: String(key.x))
            .replacingOccurrences(of: "{y}", with: String(key.y))
            .replacingOccurrences(of: "{key}", with: Secrets.linzAPIKey)
            .replacingOccurrences(of: "{bbox}", with: TileMath.mercatorBBox(of: key))
            .replacingOccurrences(of: "{size}", with: "256")
        return URL(string: s)!
    }

    /// The block of tiles containing `key`, fetched together (see `metaTiles`): its top-left tile
    /// and its size in tiles (smaller than `metaTiles` only at the lowest zooms).
    func block(containing key: TileKey) -> (origin: TileKey, span: Int) {
        let span = min(metaTiles, 1 << key.z)
        return (TileKey(z: key.z, x: key.x / span * span, y: key.y / span * span), span)
    }

    /// One WMS image covering a block of tiles.
    func blockURL(_ origin: TileKey, span: Int) -> URL {
        let s = urlTemplate
            .replacingOccurrences(of: "{bbox}", with: TileMath.mercatorBBox(of: origin, span: span))
            .replacingOccurrences(of: "{size}", with: String(256 * span))
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

    /// Canada: NRCan's Toporama (CanVec at 1:50k), drawn by a WMS rather than cached tiles, so each
    /// request takes a few seconds; tiles are fetched in 4 × 4 blocks. Detail stops adding much
    /// beyond zoom 15.
    static let ca = TileSource(
        id: "ca-topo",
        name: "Canada Toporama",
        coverageName: "Canada",
        urlTemplate: "https://maps.geogratis.gc.ca/wms/toporama_en?service=WMS&version=1.3.0&request=GetMap&layers=WMS-Toporama&styles=&crs=EPSG:3857&bbox={bbox}&width={size}&height={size}&format=image/png",
        minZoom: 4, maxZoom: 15, suggestedDownloadZooms: 9...15,
        coverage: BoundingBox(minLat: 41.6, minLon: -141.1, maxLat: 84, maxLon: -52),
        attribution: "© Natural Resources Canada · Open Government Licence – Canada",
        licenceName: "Open Government Licence – Canada",
        licenceURL: URL(string: "https://open.canada.ca/en/open-government-licence-canada")!,
        averageTileBytes: 25_000, storeAsJPEG: true,
        outlines: [CountryOutlines.canada],
        usesNationalOverview: false,
        maxTilesPerMinute: 60,  // requests (each a 4 × 4 block): a slow WMS, so be gentle
        metaTiles: 4)  // a 1,024 px image takes ~6 s against ~2.5 s for one 256 px tile

    /// Switzerland: swisstopo's national map. Zoom 18 exists (the 1:10,000 map) but 17 (1:25,000
    /// style) is plenty for walking and a quarter of the tiles.
    /// Offline saving within the terms' fair-use limits was agreed by the geo.admin.ch helpdesk
    /// (Nov 2026). They asked for a Referer header (see `TileNetwork.headers`). The cap below keeps
    /// downloads moderate; the terms give no number.
    static let ch = TileSource(
        id: "ch-topo",
        name: "swisstopo",
        coverageName: "Switzerland",
        urlTemplate: "https://wmts.geo.admin.ch/1.0.0/ch.swisstopo.pixelkarte-farbe/default/current/3857/{z}/{x}/{y}.jpeg",
        minZoom: 7, maxZoom: 17, suggestedDownloadZooms: 10...17,
        coverage: BoundingBox(minLat: 45.8, minLon: 5.9, maxLat: 47.85, maxLon: 10.55),
        attribution: "© swisstopo",
        licenceName: "swisstopo terms of use (free geodata)",
        licenceURL: URL(string: "https://www.swisstopo.admin.ch/en/terms-of-use-free-geodata-and-geoservices")!,
        averageTileBytes: 25_000, storeAsJPEG: false,
        outlines: [CountryOutlines.switzerland],
        usesNationalOverview: false,
        maxTilesPerMinute: 600)

    /// Norway: Kartverket's topographic map (CC BY 4.0).
    /// Offline saving waits on Kartverket: at zoom 12+ the map includes Geovekst data whose copying
    /// needs the rightsholders' permission, which has been asked for.
    static let no = TileSource(
        id: "no-topo",
        name: "Norway Topo",
        coverageName: "Norway",
        urlTemplate: "https://cache.kartverket.no/v1/wmts/1.0.0/topo/default/webmercator/{z}/{y}/{x}.png",
        minZoom: 5, maxZoom: 17, suggestedDownloadZooms: 9...17,
        coverage: BoundingBox(minLat: 57.7, minLon: 4.3, maxLat: 71.6, maxLon: 31.5),
        attribution: "© Kartverket",
        licenceName: "CC BY 4.0 (Kartverket)",
        licenceURL: URL(string: "https://kartverket.no/api-og-data/vilkar-for-bruk")!,
        averageTileBytes: 30_000, storeAsJPEG: true,
        outlines: [CountryOutlines.norway],
        usesNationalOverview: false,
        allowsOffline: false)

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
    static let all: [TileSource] = [nsw, qld, tas, nz, us, ca, ch, no, australia].filter(\.isAvailable)
    static let allIncludingUnavailable: [TileSource] = [nsw, qld, tas, nz, us, ca, ch, no, australia]

    static func source(id: String) -> TileSource? { (all + [terrain]).first { $0.id == id } }

    /// The map chosen on first launch: the phone's own country when the app has a map for it.
    static func defaultSource(for locale: Locale = .current) -> TileSource {
        switch locale.region?.identifier {
        case "US", "PR", "VI": return us
        case "CA": return ca
        case "CH", "LI": return ch
        case "NO": return no
        case "NZ" where nz.isAvailable: return nz
        default: return nsw
        }
    }

    /// With "national map when zoomed out" on, state maps take over from this zoom
    /// (about a 10 km wide view on a phone), where their contours become useful.
    static let detailFromZoom = 13

    /// The detailed state maps, in the order they're tried.
    /// US before Canada: the US outline settles the shared border.
    static let stateMaps: [TileSource] = [nsw, qld, tas, nz, us, ca, ch, no].filter(\.isAvailable)

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
