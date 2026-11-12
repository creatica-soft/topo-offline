import Foundation

/// New Zealand Gazetteer (LINZ, ~55,000 names), CC BY 4.0. The server's name search is too slow
/// for type-ahead (10+ s), but the whole list is only a few MB, so it's downloaded once and
/// searched on the phone: instant, and offline anywhere in New Zealand.
enum NZPlaceNames {
    static let attribution = "NZ place names: Toitū Te Whenua LINZ (NZ Gazetteer), CC BY 4.0"
    static let fileName = "nz-placenames.json"
    private static let url = URL(string: "https://services.arcgis.com/xdsHIIxuCWByZiCB/ArcGIS/rest/services/LINZ_NZ_Place_Names/FeatureServer/0/query")!
    /// Refresh the saved list after this long.
    static let maxAge: TimeInterval = 30 * 24 * 3600

    static func fetchAll(session: URLSession = TileNetwork.download) async throws -> [PlaceName] {
        let total = try await count(session: session)
        let page = 2000
        let offsets = Array(stride(from: 0, to: total, by: page))
        var all: [PlaceName] = []
        // A few pages at a time: quick, without hammering the server.
        for chunk in stride(from: 0, to: offsets.count, by: 4).map({ Array(offsets[$0..<min($0 + 4, offsets.count)]) }) {
            try await withThrowingTaskGroup(of: [PlaceName].self) { group in
                for offset in chunk { group.addTask { try await self.page(offset: offset, size: page, session: session) } }
                for try await part in group { all += part }
            }
        }
        var seen = Set<String>()
        return all.filter { seen.insert($0.id).inserted }
    }

    private static func count(session: URLSession) async throws -> Int {
        let json = try await get(["where": "1=1", "returnCountOnly": "true"], session: session)
        guard let n = json["count"] as? Int else { throw URLError(.badServerResponse) }
        return n
    }

    private static func page(offset: Int, size: Int, session: URLSession) async throws -> [PlaceName] {
        let json = try await get([
            "where": "1=1",
            "outFields": "name_id,name,feat_type,crd_latitude,crd_longitude",
            "returnGeometry": "false",
            "orderByFields": "OBJECTID",
            "resultOffset": String(offset),
            "resultRecordCount": String(size),
        ], session: session)
        let features = json["features"] as? [[String: Any]] ?? []
        return features.compactMap { f in
            guard let a = f["attributes"] as? [String: Any],
                  let name = a["name"] as? String, !name.isEmpty,
                  let lat = a["crd_latitude"] as? Double, let lon = a["crd_longitude"] as? Double else { return nil }
            let type = (a["feat_type"] as? String) ?? ""
            let id = (a["name_id"] as? Int).map(String.init) ?? "\(name)|\(lat)|\(lon)"
            return PlaceName(id: "NZ_\(id)", name: name, feature: type.uppercased(),
                             category: category(for: type), state: "NZ", lat: lat, lon: lon)
        }
    }

    /// Map NZ feature types onto the categories used for ranking search results.
    static func category(for type: String) -> String {
        switch type.lowercased() {
        case "hill", "range", "ridge", "pass", "valley", "cliff", "flat", "rock", "point", "saddle",
             "spur", "gorge", "mountain", "peak", "crater", "basin", "plateau", "slope", "cave":
            return "LANDFORM"
        case "stream", "river", "waterfall", "rapid", "channel": return "WATERWAY"
        case "lake", "pond", "lagoon", "tarn", "swamp", "spring", "bay": return "WATERBODY"
        case "glacier", "ice feature", "snowfield": return "ICE FEATURE"
        case "locality", "suburb", "town", "city", "village", "place": return "POPULATED PLACE"
        case "national park", "scenic reserve", "recreation reserve", "conservation area",
             "forest park", "nature reserve", "historic reserve", "wildlife management area": return "PROTECTED AREA"
        case "track", "walkway": return "TRAIL"
        default: return ""
        }
    }

    private static func get(_ params: [String: String], session: URLSession) async throws -> [String: Any] {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) } + [URLQueryItem(name: "f", value: "json")]
        let (data, response) = try await session.data(from: comps.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.badServerResponse)
        }
        return json
    }
}
