import Foundation
import CoreLocation

/// Place-name search against Geoscience Australia's Composite Gazetteer of Australia
/// (≈290,000 approved names: peaks, creeks, gaps, parks, towns, walking tracks…), CC BY 4.0.
/// Searches go only to this government server; nothing else is sent anywhere.
enum Gazetteer {
    static let attribution = "Place names: Composite Gazetteer of Australia © Geoscience Australia, CC BY 4.0"
    private static let queryURL = URL(string: "https://services.ga.gov.au/gis/rest/services/Composite_Gazetteer_of_Australia/MapServer/0/query")!
    private static let fields = "id,name,feature,category,authority,latitude,longitude"

    // MARK: - Online search

    /// Runs a few queries in parallel (starts-with, anywhere, and anywhere-near-the-map) because
    /// the server can't rank by relevance; results are merged and ranked locally.
    static func search(_ text: String, near center: CLLocationCoordinate2D?) async throws -> [PlaceName] {
        guard tokens(of: text).joined().count >= 3 else { return [] }
        // Official names sometimes keep an apostrophe ("D'Aguilar") and sometimes not ("Barneys Gap"),
        // so the server is asked for the pieces around it; ranking below ignores apostrophes.
        let parts = serverTokens(of: text)
        let significant = parts.count > 1 ? parts.filter { $0.count > 1 } : parts
        guard !significant.isEmpty else { return [] }
        let contains = significant.map { "UPPER(name) LIKE '%\($0.uppercased())%'" }.joined(separator: " AND ")
        // The D'/O' spelling variants double the work, so they're only added to the query limited to
        // the area around the map, where it stays cheap.
        let containsWithVariants = significant.map(likeClause).joined(separator: " AND ")
        let prefix = "UPPER(name) LIKE '\(parts.joined(separator: "%").uppercased())%'"

        var queries: [[String: String]] = [
            ["where": prefix, "resultRecordCount": "100"],
            ["where": contains, "resultRecordCount": "200"],
        ]
        if let c = center {
            queries.append(["where": containsWithVariants, "resultRecordCount": "200",
                            "geometry": "\(c.longitude - 1),\(c.latitude - 1),\(c.longitude + 1),\(c.latitude + 1)",
                            "geometryType": "esriGeometryEnvelope", "inSR": "4326",
                            "spatialRel": "esriSpatialRelIntersects"])
        }
        // The server is sometimes slow on broad queries ("track" matches thousands of names). Use
        // what has arrived 2 s after the first answer (or 10 s at most), and only fail if nothing did.
        enum Part { case result([PlaceName]?), deadline }
        let parts2: [[PlaceName]?] = await withTaskGroup(of: Part.self) { group in
            for q in queries {
                group.addTask { .result(try? await query(q, session: TileNetwork.browse, timeout: 10)) }
            }
            var all: [[PlaceName]?] = []
            var waitingFor = queries.count
            var deadlineSet = false
            for await part in group {
                switch part {
                case .result(let r):
                    all.append(r)
                    waitingFor -= 1
                    if waitingFor == 0 { return all }
                    if r != nil && !deadlineSet {
                        deadlineSet = true
                        group.addTask {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            return .deadline
                        }
                    }
                case .deadline:
                    group.cancelAll()  // stop waiting for the slow query
                    return all
                }
            }
            return all
        }
        let answered = parts2.compactMap { $0 }
        guard !answered.isEmpty else { throw URLError(.timedOut) }
        return rank(answered.flatMap { $0 }, for: text, near: center)
    }

    // MARK: - Names for an offline area

    /// Every name inside `box` (paged, as the server returns at most 2,000 per request).
    static func names(in box: BoundingBox) async throws -> [PlaceName] {
        var all: [PlaceName] = []
        let page = 2000
        while true {
            let part = try await query([
                "where": "1=1",
                "geometry": "\(box.minLon),\(box.minLat),\(box.maxLon),\(box.maxLat)",
                "geometryType": "esriGeometryEnvelope", "inSR": "4326",
                "spatialRel": "esriSpatialRelIntersects",
                "orderByFields": "objectid",
                "resultOffset": String(all.count), "resultRecordCount": String(page),
            ], session: TileNetwork.download)
            all += part
            if part.count < page || all.count >= 50_000 { break }
        }
        return all
    }

    // MARK: - Matching and ranking (shared by online and offline search)

    /// Lower-cases, drops apostrophes, and expands "mt" to "mount" (the gazetteer spells it out).
    static func normalize(_ s: String) -> String {
        let cleaned = s.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "‘", with: "")
            .replacingOccurrences(of: ".", with: " ")
        return cleaned.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "-" })
            .map { $0 == "mt" ? "mount" : String($0) }
            .joined(separator: " ")
    }

    /// Search words, safe to put inside a SQL LIKE pattern.
    static func tokens(of text: String) -> [String] {
        normalize(text).split(separator: " ").map { word in
            String(word.filter { $0.isLetter || $0.isNumber })
        }.filter { !$0.isEmpty }
    }

    /// "daguilar" should also find "D'Aguilar" (and "oreillys" find "O'Reillys").
    private static func likeClause(_ token: String) -> String {
        let up = token.uppercased()
        let plain = "UPPER(name) LIKE '%\(up)%'"
        guard up.count >= 4, let first = up.first, first == "D" || first == "O" else { return plain }
        return "(\(plain) OR UPPER(name) LIKE '%\(first)''\(up.dropFirst())%')"
    }

    /// Words for the server query: like `tokens(of:)`, but apostrophes split words instead of
    /// joining them ("d'aguilar" -> "d", "aguilar"). Safe to put inside a SQL LIKE pattern.
    static func serverTokens(of text: String) -> [String] {
        let spaced = text.replacingOccurrences(of: "'", with: " ")
            .replacingOccurrences(of: "’", with: " ")
            .replacingOccurrences(of: "‘", with: " ")
        return tokens(of: spaced)
    }

    static func matches(_ place: PlaceName, tokens: [String]) -> Bool {
        let name = normalize(place.name)
        return tokens.allSatisfy { name.contains($0) }
    }

    /// Best first: exact/starts-with matches, outdoor features, then closeness to the map centre.
    static func rank(_ places: [PlaceName], for text: String, near center: CLLocationCoordinate2D?) -> [PlaceName] {
        let query = tokens(of: text).joined(separator: " ")
        let words = query.split(separator: " ").map(String.init)
        var seen = Set<String>()
        let unique = places.filter { p in
            guard matches(p, tokens: words) else { return false }
            // The same name is often listed by two authorities a few hundred metres apart.
            let key = "\(normalize(p.name))|\(p.feature)|\((p.lat * 100).rounded())|\((p.lon * 100).rounded())"
            return seen.insert(p.id).inserted && seen.insert(key).inserted
        }
        func matchScore(_ name: String) -> Double {
            let nameWords = name.split(separator: " ")
            if name == query { return 0 }
            if name.hasPrefix(query) { return 1 }
            if words.allSatisfy({ w in nameWords.contains { $0.hasPrefix(w) } }) { return 2 }
            return 3
        }
        func score(_ p: PlaceName) -> Double {
            // Dual names ("Aoraki/Mount Cook") match on either part as well as the whole.
            var names = [normalize(p.name)]
            if p.name.contains("/") { names += p.name.split(separator: "/").map { normalize(String($0)) } }
            var s = names.map(matchScore).min() ?? 3
            s += categoryWeight(p)
            if let c = center { s += log10(1 + p.distanceKm(from: c) / 10) }
            return s
        }
        return unique.map { ($0, score($0)) }.sorted { $0.1 < $1.1 }.map(\.0)
    }

    private static let outdoorCategories: Set<String> = [
        "LANDFORM", "TRAIL", "PROTECTED AREA", "POPULATED PLACE", "RECREATION", "WATERWAY",
        "WATERBODY", "WATER POINT", "VEGETATION", "ICE FEATURE",
    ]
    private static let indoorCategories: Set<String> = [
        "EDUCATION", "BUSINESS", "CARE", "LEGAL", "HEALTH", "PLACE OF WORSHIP", "INDUSTRY",
        "COMMUNICATION", "WASTE", "PROCESSING", "DEFENCE", "UNDERSEA", "COMMUNITY LIVING",
    ]

    private static func categoryWeight(_ p: PlaceName) -> Double {
        if p.category == "TRAIL" || p.feature.contains("TRACK") || p.feature.contains("TRAIL") { return -0.7 }
        if ["MOUNTAIN", "PEAK", "HILL", "RANGE", "GORGE", "FALLS", "WATERFALL", "LOOKOUT"].contains(p.feature) { return -0.6 }
        if outdoorCategories.contains(p.category) { return -0.3 }
        if indoorCategories.contains(p.category) { return 1 }
        return 0
    }

    // MARK: - HTTP

    private struct Response: Decodable {
        struct Feature: Decodable { let attributes: Attributes }
        struct Attributes: Decodable {
            let id: String?
            let name: String?
            let feature: String?
            let category: String?
            let authority: String?
            let latitude: Double?
            let longitude: Double?
        }
        struct ServerError: Decodable { let message: String? }
        let features: [Feature]?
        let error: ServerError?
    }

    private static func query(_ params: [String: String], session: URLSession,
                              timeout: TimeInterval = 30) async throws -> [PlaceName] {
        var comps = URLComponents(url: queryURL, resolvingAgainstBaseURL: false)!
        var items = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        items += [URLQueryItem(name: "outFields", value: fields),
                  URLQueryItem(name: "returnGeometry", value: "false"),
                  URLQueryItem(name: "f", value: "json")]
        comps.queryItems = items
        var request = URLRequest(url: comps.url!)
        request.timeoutInterval = timeout
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        if let message = decoded.error?.message { throw NSError(domain: "Gazetteer", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        return (decoded.features ?? []).compactMap { f in
            let a = f.attributes
            guard let id = a.id, let name = a.name, let lat = a.latitude, let lon = a.longitude else { return nil }
            return PlaceName(id: id, name: name, feature: a.feature ?? "", category: a.category ?? "",
                             state: a.authority ?? "", lat: lat, lon: lon)
        }
    }
}
