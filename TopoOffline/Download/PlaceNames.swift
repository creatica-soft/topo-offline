import Foundation
import CoreLocation

/// United States place names from the USGS Geographic Names Information System (GNIS), served by
/// The National Map. Public domain. Searches go only to this government server.
enum USPlaceNames {
    static let attribution = "Place names: USGS Geographic Names Information System (public domain)"
    private static let base = "https://carto.nationalmap.gov/arcgis/rest/services/geonames/MapServer"
    /// Populated places, landforms (summits, gaps, ridges…), streams, and other water features
    /// (lakes, falls, springs…). Census areas and bridges are left out.
    static let layers = [3, 5, 6, 7]

    /// Names matching `text`: everything near the map (about 200 km), plus nationwide names that
    /// start with the text, ranked like the Australian search.
    static func search(_ text: String, near center: CLLocationCoordinate2D?) async throws -> [PlaceName] {
        let parts = Gazetteer.serverTokens(of: text)
        let significant = parts.count > 1 ? parts.filter { $0.count > 1 } : parts
        guard !significant.isEmpty, Gazetteer.tokens(of: text).joined().count >= 3 else { return [] }
        let contains = significant.map { "UPPER(gaz_name) LIKE '%\($0.uppercased())%'" }.joined(separator: " AND ")
        let prefix = "UPPER(gaz_name) LIKE '\(parts.joined(separator: "%").uppercased())%'"
        var jobs: [@Sendable () async -> [PlaceName]?] = []
        for layer in layers {
            jobs.append { try? await query(layer, where: prefix, box: nil, count: 50, timeout: 10) }
            if let c = center {
                let box = BoundingBox(minLat: c.latitude - 2, minLon: c.longitude - 2,
                                      maxLat: c.latitude + 2, maxLon: c.longitude + 2)
                jobs.append { try? await query(layer, where: contains, box: box, count: 200, timeout: 10) }
            }
        }
        let found = try await Gazetteer.firstAnswers(jobs)
        return Gazetteer.rank(found, for: text, near: center)
    }

    /// Every name inside `box` (for a downloaded area), paged.
    static func names(in box: BoundingBox) async throws -> [PlaceName] {
        var all: [PlaceName] = []
        for layer in layers {
            var offset = 0
            let page = 2000
            while true {
                let part = try await query(layer, where: "1=1", box: box, count: page, offset: offset,
                                           session: TileNetwork.download)
                all += part
                offset += part.count
                if part.count < page || all.count >= 50_000 { break }
            }
        }
        return all
    }

    // MARK: - Feature classes

    /// GNIS feature class -> the categories the ranking understands.
    static func category(for featureClass: String, layer: Int) -> String {
        switch layer {
        case 3: return "POPULATED PLACE"
        case 5: return "LANDFORM"
        case 6: return "WATERWAY"
        default: return ["Falls", "Rapids"].contains(featureClass) ? "WATERWAY" : "WATERBODY"
        }
    }

    // MARK: - HTTP

    private struct Response: Decodable {
        struct Feature: Decodable {
            struct Attributes: Decodable {
                let gaz_id: Int?
                let gaz_name: String?
                let gaz_featureclass: String?
                let state_alpha: String?
            }
            struct Geometry: Decodable {
                let points: [[Double]]?
                let x: Double?
                let y: Double?
            }
            let attributes: Attributes
            let geometry: Geometry?
        }
        struct ServerError: Decodable { let message: String? }
        let features: [Feature]?
        let error: ServerError?
    }

    private static func query(_ layer: Int, where clause: String, box: BoundingBox?, count: Int, offset: Int = 0,
                              timeout: TimeInterval = 30, session: URLSession = TileNetwork.browse) async throws -> [PlaceName] {
        var comps = URLComponents(string: "\(base)/\(layer)/query")!
        var items = [
            URLQueryItem(name: "where", value: clause),
            URLQueryItem(name: "outFields", value: "gaz_id,gaz_name,gaz_featureclass,state_alpha"),
            URLQueryItem(name: "returnGeometry", value: "true"),
            URLQueryItem(name: "outSR", value: "4326"),
            URLQueryItem(name: "orderByFields", value: "OBJECTID"),
            URLQueryItem(name: "resultOffset", value: String(offset)),
            URLQueryItem(name: "resultRecordCount", value: String(count)),
            URLQueryItem(name: "f", value: "json"),
        ]
        if let box {
            items += [
                URLQueryItem(name: "geometry", value: "\(box.minLon),\(box.minLat),\(box.maxLon),\(box.maxLat)"),
                URLQueryItem(name: "geometryType", value: "esriGeometryEnvelope"),
                URLQueryItem(name: "inSR", value: "4326"),
                URLQueryItem(name: "spatialRel", value: "esriSpatialRelIntersects"),
            ]
        }
        comps.queryItems = items
        var request = URLRequest(url: comps.url!)
        request.timeoutInterval = timeout
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        if let message = decoded.error?.message {
            throw NSError(domain: "USPlaceNames", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return (decoded.features ?? []).compactMap { f in
            let a = f.attributes
            let point = f.geometry?.points?.first ?? f.geometry.flatMap { g in g.x.flatMap { x in g.y.map { [x, $0] } } }
            guard let id = a.gaz_id, let name = a.gaz_name, let p = point, p.count >= 2 else { return nil }
            let featureClass = a.gaz_featureclass ?? ""
            return PlaceName(id: "US_\(id)", name: name, feature: featureClass.uppercased(),
                             category: category(for: featureClass, layer: layer),
                             state: a.state_alpha ?? "US", lat: p[1], lon: p[0])
        }
    }
}

// MARK: - Canada

/// Canadian place names from the Canadian Geographical Names Database (NRCan), under the Open
/// Government Licence – Canada.
enum CANames {
    static let attribution = "Place names: Canadian Geographical Names Database, Natural Resources Canada (Open Government Licence – Canada)"
    private static let base = "https://geogratis.gc.ca/services/geoname/en/geonames.json"

    /// Names near the map (about 200 km) plus nationwide matches. Each word is a prefix ("assinib").
    static func search(_ text: String, near center: CLLocationCoordinate2D?) async throws -> [PlaceName] {
        let words = Gazetteer.serverTokens(of: text).filter { $0.count > 1 }
        guard !words.isEmpty, words.joined().count >= 3 else { return [] }
        let q = words.map { "\($0)*" }.joined(separator: " ")
        var jobs: [@Sendable () async -> [PlaceName]?] = [
            { try? await query(["q": q, "num": "100"]) },
        ]
        if let c = center {
            jobs.append { try? await query(["q": q, "num": "200", "lat": String(c.latitude), "lon": String(c.longitude),
                                            "radius": "200"]) }
        }
        return Gazetteer.rank(try await Gazetteer.firstAnswers(jobs), for: text, near: center)
    }

    /// Every name inside `box` (for a downloaded area), paged.
    static func names(in box: BoundingBox) async throws -> [PlaceName] {
        var all: [PlaceName] = []
        let page = 1000
        while true {
            let part = try await query(["bbox": "\(box.minLon),\(box.minLat),\(box.maxLon),\(box.maxLat)",
                                        "num": String(page), "skip": String(all.count)],
                                       session: TileNetwork.download, timeout: 60)
            all += part
            if part.count < page || all.count >= 50_000 { break }
        }
        return all
    }

    /// Generic codes -> (feature text, ranking category).
    private static let concise: [String: (String, String)] = [
        "MTN": ("MOUNTAIN", "LANDFORM"), "VALL": ("VALLEY", "LANDFORM"), "CLF": ("CLIFF", "LANDFORM"),
        "CAPE": ("CAPE", "LANDFORM"), "ISL": ("ISLAND", "LANDFORM"), "CAVE": ("CAVE", "LANDFORM"),
        "CRAT": ("CRATER", "LANDFORM"), "PLN": ("PLAIN", "LANDFORM"), "BCH": ("BEACH", "LANDFORM"),
        "GLAC": ("GLACIER", "WATERBODY"), "LAKE": ("LAKE", "WATERBODY"), "SPRG": ("SPRING", "WATERBODY"),
        "BAY": ("BAY", "WATERBODY"), "RIV": ("RIVER", "WATERWAY"), "RIVF": ("RIVER FEATURE", "WATERWAY"),
        "FALL": ("FALLS", "WATERWAY"), "RAP": ("RAPIDS", "WATERWAY"), "CHAN": ("CHANNEL", "WATERWAY"),
        "CITY": ("CITY", "POPULATED PLACE"), "TOWN": ("TOWN", "POPULATED PLACE"),
        "VILG": ("VILLAGE", "POPULATED PLACE"), "HAM": ("HAMLET", "POPULATED PLACE"),
        "UNP": ("PLACE", "POPULATED PLACE"), "PARK": ("PARK", "PROTECTED AREA"),
        "RECR": ("RECREATION SITE", "RECREATION"), "CAMP": ("CAMPSITE", "RECREATION"), "FOR": ("FOREST", "VEGETATION"),
    ]
    private static let provinces = [
        "10": "NL", "11": "PE", "12": "NS", "13": "NB", "24": "QC", "35": "ON", "46": "MB", "47": "SK",
        "48": "AB", "59": "BC", "60": "YT", "61": "NT", "62": "NU",
    ]

    private struct Response: Decodable {
        struct Code: Decodable { let code: String? }
        struct Item: Decodable {
            let id: String?
            let name: String?
            let latitude: Double?
            let longitude: Double?
            let concise: Code?
            let province: Code?
        }
        let items: [Item]?
    }

    private static func query(_ params: [String: String], session: URLSession = TileNetwork.browse,
                              timeout: TimeInterval = 10) async throws -> [PlaceName] {
        var comps = URLComponents(string: base)!
        comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: comps.url!)
        request.timeoutInterval = timeout
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return (try JSONDecoder().decode(Response.self, from: data).items ?? []).compactMap { i in
            guard let id = i.id, let name = i.name, let lat = i.latitude, let lon = i.longitude else { return nil }
            let code = i.concise?.code ?? ""
            let (feature, category) = concise[code] ?? (code, "")
            return PlaceName(id: "CA_\(id)", name: name, feature: feature, category: category,
                             state: provinces[i.province?.code ?? ""] ?? "CA", lat: lat, lon: lon)
        }
    }
}

// MARK: - Switzerland

/// Swiss place names from swisstopo's search service (swissNAMES3D). There's no way to list the
/// names in an area, so downloaded Swiss areas have no offline names.
enum CHNames {
    static let attribution = "Place names © swisstopo (swissNAMES3D)"

    static func search(_ text: String, near center: CLLocationCoordinate2D?) async throws -> [PlaceName] {
        guard Gazetteer.tokens(of: text).joined().count >= 3 else { return [] }
        var comps = URLComponents(string: "https://api3.geo.admin.ch/rest/services/api/SearchServer")!
        comps.queryItems = [
            URLQueryItem(name: "searchText", value: text), URLQueryItem(name: "type", value: "locations"),
            URLQueryItem(name: "origins", value: "gazetteer"), URLQueryItem(name: "limit", value: "50"),
            URLQueryItem(name: "sr", value: "4326"), URLQueryItem(name: "lang", value: "en"),
        ]
        var request = URLRequest(url: comps.url!)
        request.timeoutInterval = 10
        let (data, response) = try await TileNetwork.browse.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        struct Response: Decodable {
            struct Result: Decodable {
                struct Attrs: Decodable { let label: String?; let lat: Double?; let lon: Double? }
                let id: Int?
                let attrs: Attrs
            }
            let results: [Result]?
        }
        let places = (try JSONDecoder().decode(Response.self, from: data).results ?? []).compactMap { r -> PlaceName? in
            guard let label = r.attrs.label, let lat = r.attrs.lat, let lon = r.attrs.lon,
                  let parsed = parse(label) else { return nil }
            return PlaceName(id: "CH_\(r.id ?? 0)_\(parsed.name)", name: parsed.name, feature: feature(for: parsed.kind),
                             category: category(for: parsed.kind), state: parsed.canton ?? "CH", lat: lat, lon: lon)
        }
        return Gazetteer.rank(places, for: text, near: center)
    }

    /// "<i>Alpiner Gipfel</i> <b>Eiger</b> (BE) - Grindelwald" -> ("Eiger", "Alpiner Gipfel", "BE").
    static func parse(_ label: String) -> (name: String, kind: String, canton: String?)? {
        func between(_ open: String, _ close: String) -> String? {
            guard let a = label.range(of: open), let b = label.range(of: close, range: a.upperBound..<label.endIndex) else { return nil }
            return String(label[a.upperBound..<b.lowerBound])
        }
        guard let name = between("<b>", "</b>")?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        let kind = (between("<i>", "</i>") ?? "").trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{a0}")))
        let canton = between("(", ")").flatMap { $0.count == 2 ? $0 : nil }
        return (name, kind, canton)
    }

    /// The search answers in English ("Alpin peak", "Lake", "Water course", "Populated Place").
    /// Peaks of every kind become PEAK, so they rank (and read) as peaks.
    private static func feature(for kind: String) -> String {
        let k = kind.lowercased()
        if k.contains("peak") || k.contains("summit") { return "PEAK" }
        return kind.uppercased()
    }

    private static func category(for kind: String) -> String {
        let k = kind.lowercased()
        if ["peak", "summit", "hill", "pass", "ridge", "valley", "rock", "massif", "territory"].contains(where: k.contains) { return "LANDFORM" }
        if ["lake", "pond", "glacier"].contains(where: k.contains) { return "WATERBODY" }
        if ["water course", "river", "stream", "waterfall"].contains(where: k.contains) { return "WATERWAY" }
        if k.contains("populated place") { return "POPULATED PLACE" }
        if ["building", "road", "transport", "plant", "heliport", "run"].contains(where: k.contains) { return "BUSINESS" }
        return ""
    }
}

// MARK: - Norway

/// Norwegian place names from Kartverket's Sentralt stedsnavnregister, CC BY 4.0.
enum NONames {
    static let attribution = "Place names: Stedsnavn © Kartverket, CC BY 4.0"
    private static let base = "https://ws.geonorge.no/stedsnavn/v1"

    static func search(_ text: String, near center: CLLocationCoordinate2D?) async throws -> [PlaceName] {
        let words = text.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard Gazetteer.tokens(of: text).joined().count >= 3, !words.isEmpty else { return [] }
        let found = try await query("navn", ["sok": words.joined(separator: " ") + "*", "treffPerSide": "100"])
        return Gazetteer.rank(found, for: text, near: center)
    }

    /// Every name inside `box`: the service lists names within 5 km of a point, so the box is
    /// covered with overlapping circles 7 km apart.
    static func names(in box: BoundingBox) async throws -> [PlaceName] {
        let stepLat = 7_000 / 110_540.0, stepLon = 7_000 / (111_320 * cos(box.center.latitude * .pi / 180))
        var seen = Set<String>()
        var all: [PlaceName] = []
        var lat = box.minLat + stepLat / 2
        repeat {
            var lon = box.minLon + stepLon / 2
            repeat {
                var page = 1
                while page <= 20 {
                    let part = try await query("punkt", ["nord": String(lat), "ost": String(lon), "koordsys": "4326",
                                                         "radius": "5000", "treffPerSide": "500", "side": String(page)],
                                               session: TileNetwork.download, timeout: 60)
                    all += part.filter { box.contains($0.coordinate) && seen.insert($0.id).inserted }
                    if part.count < 500 { break }
                    page += 1
                }
                lon += stepLon
            } while lon - stepLon / 2 < box.maxLon
            lat += stepLat
        } while lat - stepLat / 2 < box.maxLat
        return all
    }

    private static let categories: [String: String] = [
        "Fjell": "LANDFORM", "Topp": "LANDFORM", "Høyde": "LANDFORM", "Ås": "LANDFORM", "Skar": "LANDFORM",
        "Dal": "LANDFORM", "Bre": "WATERBODY", "Vann": "WATERBODY", "Innsjø": "WATERBODY", "Tjern": "WATERBODY",
        "Elv": "WATERWAY", "Bekk": "WATERWAY", "Foss": "WATERWAY", "By": "POPULATED PLACE", "Tettsted": "POPULATED PLACE",
        "Bygdelag (bygd)": "POPULATED PLACE", "Turisthytte": "RECREATION", "Hytte": "RECREATION",
    ]

    private struct Response: Decodable {
        struct Point: Decodable {
            let nord: Double?
            let øst: Double?
        }
        struct Spelling: Decodable { let skrivemåte: String? }
        struct Municipality: Decodable { let kommunenavn: String? }
        struct Name: Decodable {
            let skrivemåte: String?
            let stedsnavn: [Spelling]?
            let navneobjekttype: String?
            let representasjonspunkt: Point?
            let stedsnummer: Int?
            let kommuner: [Municipality]?
        }
        let navn: [Name]?
    }

    private static func query(_ path: String, _ params: [String: String], session: URLSession = TileNetwork.browse,
                              timeout: TimeInterval = 10) async throws -> [PlaceName] {
        var comps = URLComponents(string: "\(base)/\(path)")!
        comps.queryItems = (params.merging(["utkoordsys": "4326"]) { a, _ in a }).map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: comps.url!)
        request.timeoutInterval = timeout
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return (try JSONDecoder().decode(Response.self, from: data).navn ?? []).compactMap { n in
            guard let id = n.stedsnummer, let name = n.skrivemåte ?? n.stedsnavn?.first?.skrivemåte,
                  let lat = n.representasjonspunkt?.nord, let lon = n.representasjonspunkt?.øst else { return nil }
            let type = n.navneobjekttype ?? ""
            // Shown as "Fjell · Lom" (the municipality is more useful than the county here).
            let place = n.kommuner?.first?.kommunenavn ?? "NO"
            return PlaceName(id: "NO_\(id)", name: name, feature: type.uppercased(), category: categories[type] ?? "",
                             state: place, lat: lat, lon: lon)
        }
    }
}

// MARK: - Choosing a service

/// Chooses the place-name service for where the map is.
enum PlaceSearch {
    enum Country { case us, ca, ch, no, other }

    static func country(at c: CLLocationCoordinate2D?) -> Country {
        guard let c else { return .other }
        if TileSources.us.covers(c) { return .us }
        if TileSources.ca.covers(c) { return .ca }
        if TileSources.ch.covers(c) { return .ch }
        if TileSources.no.covers(c) { return .no }
        // Just offshore or across a border: the nearest country's service still makes sense.
        if TileSources.usCoverage.contains(c) && !TileSources.ca.coverage.contains(c) { return .us }
        return .other
    }

    static func isUS(_ c: CLLocationCoordinate2D?) -> Bool { country(at: c) == .us }

    static func search(_ text: String, near center: CLLocationCoordinate2D?) async throws -> [PlaceName] {
        switch country(at: center) {
        case .us: return try await USPlaceNames.search(text, near: center)
        case .ca: return try await CANames.search(text, near: center)
        case .ch: return try await CHNames.search(text, near: center)
        case .no: return try await NONames.search(text, near: center)
        case .other: return try await Gazetteer.search(text, near: center)
        }
    }

    static func attribution(near center: CLLocationCoordinate2D?) -> String {
        switch country(at: center) {
        case .us: return USPlaceNames.attribution
        case .ca: return CANames.attribution
        case .ch: return CHNames.attribution
        case .no: return NONames.attribution
        case .other: return Gazetteer.attribution
        }
    }

    /// Names for a downloaded area, from whichever services cover it.
    static func names(in box: BoundingBox) async throws -> [PlaceName] {
        var all: [PlaceName] = []
        if box.intersects(TileSources.australia.coverage) { all += try await Gazetteer.names(in: box) }
        if TileSources.us.touches(box) { all += try await USPlaceNames.names(in: box) }
        if TileSources.ca.touches(box) { all += try await CANames.names(in: box) }
        if TileSources.no.touches(box) { all += try await NONames.names(in: box) }
        return all
    }
}
