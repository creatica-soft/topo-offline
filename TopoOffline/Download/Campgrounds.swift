import Foundation

/// Official campground locations that carry little more than a name: NSW National Parks camping
/// areas, Vicmap "camp ground" features (including Parks Victoria parks), and "camp ground" entries
/// in the national place-name gazetteer (TAS, SA, WA, NT, ACT). Small, so fetched in one go.
enum OfficialCampgrounds {
    static func fetch(session: URLSession = TileNetwork.browse) async -> [String: [Campsite]] {
        async let nsw = try? nswParks(session: session)
        async let vic = try? vicmap(session: session)
        async let ga = try? gazetteer(session: session)
        var out: [String: [Campsite]] = [:]
        if let v = await nsw { out[CampSource.nswParks] = v }
        if let v = await vic { out[CampSource.vicmap] = v }
        if let v = await ga { out[CampSource.gazetteer] = v }
        return out
    }

    private static func nswParks(session: URLSession) async throws -> [Campsite] {
        let url = URL(string: "https://mapprod2.environment.nsw.gov.au/arcgis/rest/services/Assets/AMS_Assets/FeatureServer/24/query")!
        let features = try await arcgis(url, where: "SubtypeCD=5001", fields: "OBJECTID,AssetName", session: session)
        return features.compactMap { item in
            let (a, lon, lat) = item
            guard let raw = a["AssetName"] as? String, !raw.isEmpty else { return nil }
            return Campsite(id: "nsw-camp-\(a["OBJECTID"] ?? raw)", name: TrackSources.capitalizeWords(raw), kind: "Campsite",
                            camping: true, lat: lat, lon: lon, source: CampSource.nswParks)
        }
    }

    private static func gazetteer(session: URLSession) async throws -> [Campsite] {
        let url = URL(string: "https://services.ga.gov.au/gis/rest/services/Composite_Gazetteer_of_Australia/MapServer/0/query")!
        // Victoria is covered better by Vicmap (the gazetteer's Victorian entries include cabins and
        // school camps), and NSW by National Parks, so the gazetteer is used for the other states.
        let features = try await arcgis(url, where: "feature='CAMP GROUND' AND authority NOT IN ('VIC','NSW')",
                                        fields: "id,name,latitude,longitude", session: session)
        return features.compactMap { item in
            let a = item.0
            guard let name = a["name"] as? String, let lat = a["latitude"] as? Double, let lon = a["longitude"] as? Double else { return nil }
            return Campsite(id: "ga-camp-\(a["id"] ?? name)", name: TrackSources.capitalizeWords(name.lowercased().capitalized),
                            kind: "Campsite", camping: true, lat: lat, lon: lon, source: CampSource.gazetteer)
        }
    }

    private static func vicmap(session: URLSession) async throws -> [Campsite] {
        var comps = URLComponents(string: "https://opendata.maps.vic.gov.au/geoserver/wfs")!
        comps.queryItems = [
            URLQueryItem(name: "service", value: "WFS"), URLQueryItem(name: "version", value: "2.0.0"),
            URLQueryItem(name: "request", value: "GetFeature"),
            URLQueryItem(name: "typeNames", value: "open-data-platform:foi_point"),
            URLQueryItem(name: "outputFormat", value: "application/json"),
            URLQueryItem(name: "srsName", value: "EPSG:4326"),
            URLQueryItem(name: "propertyName", value: "ufi,name,name_label,parent_name,geom"),
            URLQueryItem(name: "cql_filter", value: "feature_subtype='camp ground'"),
            URLQueryItem(name: "count", value: "10000"),
        ]
        let (data, response) = try await session.data(from: comps.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = json["features"] as? [[String: Any]] else { throw URLError(.badServerResponse) }
        return features.compactMap { f in
            // Vicmap stores these as MultiPoint ([[lon, lat]]); accept a plain Point too.
            guard let p = f["properties"] as? [String: Any], let g = f["geometry"] as? [String: Any],
                  let c = (g["coordinates"] as? [Double]) ?? (g["coordinates"] as? [[Double]])?.first,
                  c.count >= 2 else { return nil }
            let name = [p["name_label"], p["name"]].compactMap { $0 as? String }.first { !$0.isEmpty }
                ?? (p["parent_name"] as? String).map { "Campground (\($0))" } ?? "Campground"
            return Campsite(id: "vicmap-camp-\(p["ufi"] ?? name)", name: name, kind: "Campsite",
                            camping: true, lat: c[1], lon: c[0], source: CampSource.vicmap)
        }
    }

    private static func arcgis(_ url: URL, where clause: String, fields: String,
                               session: URLSession) async throws -> [([String: Any], Double, Double)] {
        var out: [([String: Any], Double, Double)] = []
        var offset = 0
        while true {
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            comps.queryItems = [
                URLQueryItem(name: "where", value: clause), URLQueryItem(name: "outFields", value: fields),
                URLQueryItem(name: "returnGeometry", value: "true"), URLQueryItem(name: "outSR", value: "4326"),
                URLQueryItem(name: "resultOffset", value: String(offset)),
                URLQueryItem(name: "resultRecordCount", value: "1000"), URLQueryItem(name: "f", value: "json"),
            ]
            let (data, response) = try await session.data(from: comps.url!)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let features = json["features"] as? [[String: Any]] else { throw URLError(.badServerResponse) }
            for f in features {
                guard let a = f["attributes"] as? [String: Any] else { continue }
                let g = f["geometry"] as? [String: Any]
                out.append((a, g?["x"] as? Double ?? 0, g?["y"] as? Double ?? 0))
            }
            if features.count < 1000 { break }
            offset += features.count
        }
        return out
    }
}

/// The OpenStreetMap campsite extract bundled with the app (see Tools/update-osm-campsites.py).
enum CommunityCampsites {
    /// Where the extract is published (the ODbL requires making it available).
    static let publishedExtractURL = URL(string: "https://github.com/creatica-soft/topo-offline/blob/main/TopoOffline/Resources/osm-campsites.json")!

    private struct Extract: Decodable {
        struct Site: Decodable {
            let i: String
            let n: String?
            let t: String
            let a: Double
            let o: Double
            let f: [String: String]?
        }
        let generated: String
        let sites: [Site]
    }

    /// Loads and converts the bundled file. Returns the sites and the extract date.
    static func load(from url: URL?) -> (sites: [Campsite], generated: String?) {
        guard let url, let data = try? Data(contentsOf: url),
              let extract = try? JSONDecoder().decode(Extract.self, from: data) else { return ([], nil) }
        let sites = extract.sites.map { s -> Campsite in
            let caravan = s.t == "v"
            let tags = s.f ?? [:]
            return Campsite(id: "osm-\(s.i)", name: s.n ?? (caravan ? "Caravan park" : "Campsite"),
                            kind: caravan ? "Caravan park" : "Campsite", camping: true,
                            fee: tags["fee"] == "yes",
                            access: tags["description"],
                            lat: s.a, lon: s.o, source: CampSource.osm,
                            amenities: amenities(tags), website: tags["website"])
        }
        return (sites, extract.generated)
    }

    /// OpenStreetMap tags as short phrases a camper cares about.
    static func amenities(_ t: [String: String]) -> [String] {
        func yes(_ k: String) -> Bool { ["yes", "designated", "hot", "permissive"].contains(t[k] ?? "") }
        var out: [String] = []
        if t["fee"] == "no" { out.append("Free") } else if t["fee"] == "yes" { out.append("Fees apply") }
        if yes("toilets") { out.append("Toilets") } else if t["toilets"] == "no" { out.append("No toilets") }
        if yes("drinking_water") { out.append("Drinking water") } else if t["drinking_water"] == "no" { out.append("No drinking water") }
        if yes("shower") || yes("showers") { out.append("Showers") }
        if yes("power_supply") { out.append("Powered sites") }
        if yes("tents") { out.append("Tents") }
        if yes("caravans") { out.append("Caravans") }
        if yes("motorhome") { out.append("Motorhomes") }
        if yes("backcountry") { out.append("Hike-in") }
        if yes("sanitary_dump_station") { out.append("Dump point") }
        if yes("bbq") { out.append("BBQ") }
        if yes("openfire") { out.append("Campfires allowed") } else if t["openfire"] == "no" { out.append("No campfires") }
        switch t["dog"] {
        case "yes", "leashed": out.append("Dogs allowed")
        case "no": out.append("No dogs")
        default: break
        }
        if t["reservation"] == "required" { out.append("Booking required") }
        if yes("group_only") { out.append("Groups only") }
        if let cap = t["capacity"], Int(cap) != nil { out.append("\(cap) sites") }
        return out
    }
}
