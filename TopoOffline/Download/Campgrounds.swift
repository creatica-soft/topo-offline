import Foundation

/// Official campground locations: NSW National Parks camping areas, Vicmap "camp ground" features
/// (including Parks Victoria parks), and "camp ground" entries in the national place-name gazetteer
/// (TAS, SA, WA, NT, ACT), which carry little more than a name; and US Forest Service campgrounds
/// (with open/closed status, season and booking page). Small enough to fetch in one go.
enum OfficialCampgrounds {
    /// Groups of sources, fetched only once the map has shown the region (so people in Australia
    /// never download Canadian campgrounds, and the reverse).
    enum Region: String, CaseIterable, Sendable {
        case australia, us, canada

        var sources: [String] {
            switch self {
            case .australia: return [CampSource.nswParks, CampSource.vicmap, CampSource.gazetteer]
            case .us: return [CampSource.usfs]
            case .canada: return [CampSource.parksCanada, CampSource.bcRecSites]
            }
        }

        /// Whether the map showing `area` means this region's campgrounds are wanted.
        func isShown(by area: BoundingBox) -> Bool {
            switch self {
            case .australia: return area.intersects(TileSources.australia.coverage)
            case .us: return TileSources.us.touches(area)
            case .canada: return TileSources.ca.touches(area)
            }
        }
    }

    /// The sources of `regions`, by source. A source that fails is left out (the caller keeps its old data).
    static func fetch(regions: Set<Region> = [.australia], session: URLSession = TileNetwork.browse) async -> [String: [Campsite]] {
        await withTaskGroup(of: (String, [Campsite]?).self) { group in
            for region in regions {
                for source in region.sources {
                    group.addTask { (source, try? await fetch(source: source, session: session)) }
                }
            }
            var out: [String: [Campsite]] = [:]
            for await (source, sites) in group { if let sites { out[source] = sites } }
            return out
        }
    }

    private static func fetch(source: String, session: URLSession) async throws -> [Campsite] {
        switch source {
        case CampSource.nswParks: return try await nswParks(session: session)
        case CampSource.vicmap: return try await vicmap(session: session)
        case CampSource.gazetteer: return try await gazetteer(session: session)
        case CampSource.usfs: return try await usfs(session: session)
        case CampSource.parksCanada: return try await parksCanada(session: session)
        case CampSource.bcRecSites: return try await bcRecSites(session: session)
        default: return []
        }
    }

    /// Parks Canada campgrounds: the open data lists every campsite (about 12,000), so sites with the
    /// same name within about 2 km are folded into one campground pin.
    static func parksCanada(session: URLSession = TileNetwork.browse) async throws -> [Campsite] {
        let url = URL(string: "https://services2.arcgis.com/wCOMu5IS7YdSyPNx/ArcGIS/rest/services/vw_Accommodation_Hebergement_V2_FGP/FeatureServer/0/query")!
        let points = try await arcgis(url, where: "1=1", fields: "OBJECTID,Name_e,URL_e,Accommodation_Type", session: session)
        struct Group { var name: String; var lat = 0.0, lon = 0.0, count = 0; var types = Set<String>(); var url: String? }
        var groups: [String: Group] = [:]
        for (a, lon, lat) in points {
            guard let name = (a["Name_e"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  lat != 0 || lon != 0 else { continue }
            // "Cabin//Chalet" -> "Cabin"
            let type = ((a["Accommodation_Type"] as? String) ?? "").components(separatedBy: "//").first ?? ""
            guard !["Mooring", "None", ""].contains(type) else { continue }
            let key = "\(name)|\((lat / 0.02).rounded())|\((lon / 0.02).rounded())"
            var g = groups[key] ?? Group(name: name)
            g.lat += lat; g.lon += lon; g.count += 1
            g.types.insert(type)
            if g.url == nil, let u = a["URL_e"] as? String, u.hasPrefix("http") { g.url = u }
            groups[key] = g
        }
        return groups.map { key, g in
            let roofedOnly = g.types.isSubset(of: ["Backcountry accommodation", "Cabin", "Historic stay", "MicrOcube", "Oasis", "Tipi", "Yurt", "oTENTik"])
            var detail = ["\(g.count) \(g.count == 1 ? "site" : "sites")"]
            let extras = g.types.subtracting(["Camping"]).sorted()
            if !extras.isEmpty { detail.append(extras.joined(separator: ", ")) }
            detail.append("Parks Canada")
            return Campsite(id: "pc-\(key)", name: g.name, kind: roofedOnly ? "Hut" : "Campsite", camping: !roofedOnly,
                            lat: g.lat / Double(g.count), lon: g.lon / Double(g.count),
                            detail: detail.joined(separator: " · "), source: CampSource.parksCanada, website: g.url)
        }
    }

    /// British Columbia recreation sites with campsites. Only the fields needed are requested:
    /// the dataset also names site operators, which the app never fetches.
    static func bcRecSites(session: URLSession = TileNetwork.browse) async throws -> [Campsite] {
        let structures = (1...10).map { "STRUCTURE_DESC\($0)" }
        let fields = ["FOREST_FILE_ID", "PROJECT_NAME", "NUM_CAMP_SITES", "MAINTAIN_STD_DESC", "SUB_ACCESS_DESC1", "GEOMETRY"] + structures
        var comps = URLComponents(string: "https://openmaps.gov.bc.ca/geo/pub/wfs")!
        comps.queryItems = [
            URLQueryItem(name: "service", value: "WFS"), URLQueryItem(name: "version", value: "2.0.0"),
            URLQueryItem(name: "request", value: "GetFeature"),
            URLQueryItem(name: "typeNames", value: "pub:WHSE_FOREST_TENURE.FTEN_REC_SITE_POINTS_SVW"),
            URLQueryItem(name: "outputFormat", value: "application/json"), URLQueryItem(name: "srsName", value: "EPSG:4326"),
            URLQueryItem(name: "propertyName", value: fields.joined(separator: ",")),
            URLQueryItem(name: "cql_filter", value: "NUM_CAMP_SITES > 0"),
            URLQueryItem(name: "count", value: "10000"),
        ]
        let (data, response) = try await session.data(from: comps.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = json["features"] as? [[String: Any]] else { throw URLError(.badServerResponse) }
        return features.compactMap { f in
            guard let p = f["properties"] as? [String: Any], let g = f["geometry"] as? [String: Any],
                  let c = (g["coordinates"] as? [Double]) ?? (g["coordinates"] as? [[Double]])?.first, c.count >= 2,
                  let raw = (p["PROJECT_NAME"] as? String)?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
            let name = raw == raw.uppercased() ? TrackSources.titleCase(raw) : raw
            let built = structures.compactMap { (p[$0] as? String)?.lowercased() }
            var amenities: [String] = []
            if built.contains(where: { $0.contains("toilet") }) { amenities.append("Toilets") }
            if built.contains(where: { $0.contains("table") }) { amenities.append("Tables") }
            if built.contains(where: { $0.contains("fire ring") }) { amenities.append("Fire rings") }
            if built.contains(where: { $0.contains("boat launch") }) { amenities.append("Boat launch") }
            if let access = p["SUB_ACCESS_DESC1"] as? String, !access.isEmpty { amenities.append("Access: \(access)") }
            let sites = (p["NUM_CAMP_SITES"] as? Int) ?? 0
            var detail = ["\(sites) campsite\(sites == 1 ? "" : "s")"]
            if let standard = p["MAINTAIN_STD_DESC"] as? String, !standard.isEmpty { detail.append(standard) }
            let file = (p["FOREST_FILE_ID"] as? String) ?? ""
            return Campsite(id: "bc-rec-\(file.isEmpty ? name : file)", name: name, kind: "Campsite", camping: true,
                            lat: c[1], lon: c[0], detail: detail.joined(separator: " · "), source: CampSource.bcRecSites,
                            amenities: amenities.isEmpty ? nil : amenities,
                            website: file.isEmpty ? nil : "https://www.sitesandtrailsbc.ca/resource/\(file)")
        }
    }

    /// US Forest Service campgrounds (about 3,500).
    static func usfs(session: URLSession = TileNetwork.browse) async throws -> [Campsite] {
        let url = URL(string: "https://apps.fs.usda.gov/arcx/rest/services/EDW/EDW_RecreationOpportunities_01/MapServer/0/query")!
        let features = try await arcgis(url, where: "markeractivity='Campground Camping'",
                                        fields: "recareaid,recareaname,forestname,openstatus,feedescription,recareaurl,open_season_start,open_season_end",
                                        session: session)
        var seen = Set<String>()
        return features.compactMap { item in
            let (a, lon, lat) = item
            guard let name = (a["recareaname"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  lat != 0 || lon != 0 else { return nil }
            let id = "usfs-camp-\(a["recareaid"] ?? name)"
            guard seen.insert(id).inserted else { return nil }
            var detail = [a["forestname"] as? String].compactMap { $0 }
            if let season = usfsSeason(start: a["open_season_start"] as? String, end: a["open_season_end"] as? String) {
                detail.append(season)
            }
            let status = (a["openstatus"] as? String)?.lowercased() ?? ""
            let closure: ClosureInfo? = switch status {
            case "closed": ClosureInfo(reason: "Closed", details: usfsClosedNote)
            case "temporarily closed": ClosureInfo(reason: "Temporarily closed", details: usfsClosedNote)
            default: nil
            }
            let fees = (a["feedescription"] as? String) ?? ""
            return Campsite(id: id, name: name, kind: "Campsite", camping: true, fee: fees.contains("$"),
                            closure: closure, lat: lat, lon: lon,
                            detail: detail.isEmpty ? nil : detail.joined(separator: " · "),
                            source: CampSource.usfs, website: a["recareaurl"] as? String)
        }
    }

    static let usfsClosedNote = "The Forest Service lists this campground as closed (often for the season). Check its Forest Service page for opening dates."

    /// "Open May – Oct. 31", "Open year round"; nil when the season isn't given.
    static func usfsSeason(start: String?, end: String?) -> String? {
        let s = start?.trimmingCharacters(in: .whitespaces) ?? "", e = end?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !s.isEmpty, s.count <= 25, e.count <= 25 else { return nil }
        if s.lowercased().hasPrefix("year") { return "Open year round" }
        return e.isEmpty ? "Open from \(s)" : "Open \(s) – \(e)"
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
    /// Where the extracts are published (the ODbL requires making them available).
    static let publishedExtractURL = URL(string: "https://github.com/creatica-soft/topo-offline/tree/main/TopoOffline/Resources")!

    /// Extracts beyond Australia and New Zealand, with the area each covers (loaded when shown).
    static var bundledRegions: [(area: BoundingBox, url: URL)] {
        [("osm-campsites-na", BoundingBox(minLat: 17.5, minLon: -180, maxLat: 84, maxLon: -52)),
         ("osm-campsites-europe", BoundingBox(minLat: 45.8, minLon: 4.3, maxLat: 71.6, maxLon: 31.5))]
            .compactMap { name, area in Bundle.main.url(forResource: name, withExtension: "json").map { (area, $0) } }
    }

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
            let caravan = s.t == "v", hut = s.t == "h"
            let tags = s.f ?? [:]
            let kind = hut ? "Hut" : (caravan ? "Caravan park" : "Campsite")
            return Campsite(id: "osm-\(s.i)", name: s.n ?? kind,
                            kind: kind, camping: !hut || tags["tents"] == "yes",
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
