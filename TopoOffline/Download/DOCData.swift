import Foundation

/// New Zealand Department of Conservation (DOC) open data: tracks, huts and campsites.
/// Licensed CC BY 4.0 ("You may use this work for commercial purposes"), Crown copyright.
enum DOC {
    static let attribution = "Department of Conservation (Crown copyright), CC BY 4.0"
    static let services = "https://services1.arcgis.com/3JjYDyG3oajxU6HO/ArcGIS/rest/services"
    static let tracksURL = URL(string: "\(services)/DOC_Tracks_Open_Data/FeatureServer/0/query")!
    static let hutsURL = URL(string: "\(services)/DOC_Huts_Open_Data/FeatureServer/0/query")!
    static let campsitesURL = URL(string: "\(services)/DOC_Campsites_Open_Data/FeatureServer/0/query")!
    static let freedomCampingURL = URL(string: "\(services)/DOC_FreedomCampingSites/FeatureServer/0/query")!

    /// DOC stores details as numbered name/value pairs (CharName2/CharValue2 = "USER_STATUS"/"OPEN").
    static func characteristics(_ a: [String: Any]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for i in 1...20 {
            guard let name = a["CharName\(i)"] as? String,
                  let value = (a["CharValue\(i)"] as? String)?.trimmingCharacters(in: .whitespaces),
                  !value.isEmpty, value != "None" else { continue }
            out[name, default: []].append(value)
        }
        return out
    }

    /// "Oturere Hut to Emerald Lakes Track (TNC)" -> "Oturere Hut to Emerald Lakes Track"
    /// "TAC Soda Springs Jn-Red Crater" -> "Tongariro Alpine Crossing: Soda Springs Junction-Red Crater"
    /// "T3 Whangaehu Hut (RTMT) (NZAC)" -> "Whangaehu Hut", "Upper Tama Lakes Tk" -> "Upper Tama Lakes Track"
    static func cleanName(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        // Internal codes in brackets: (TNC), (RTMT), (NZAC)...
        s = s.replacingOccurrences(of: #"\s*\([A-Z0-9]{2,6}\)"#, with: "", options: .regularExpression)
        // Leading codes: "TAC ", "QCT - ", "T3: ", "RTMT "... Known track codes become a readable
        // prefix ("Queen Charlotte Track: Torea to Kenepuru"); others are dropped.
        var prefix = ""
        if let m = s.range(of: #"^(?:[A-Z]{2,4}|[A-Z]\d)(?:\s*[-:–]\s*|\s+)(?=[A-Z])"#, options: .regularExpression) {
            let code = s[m].trimmingCharacters(in: CharacterSet(charactersIn: " -:–"))
            s.removeSubrange(m)
            if let full = trackCodes[code] { prefix = "\(full): " }
        }
        let words = ["Tk": "Track", "Jn": "Junction", "Jnc": "Junction", "Rd": "Road", "Rte": "Route", "Mt": "Mt"]
        s = s.split(separator: " ").map { w in
            let core = w.trimmingCharacters(in: CharacterSet(charactersIn: "-,"))
            return words[core].map { w.replacingOccurrences(of: core, with: $0) } ?? String(w)
        }.joined(separator: " ")
        // "Jn-Red Crater": also expand abbreviations joined by a hyphen.
        s = s.replacingOccurrences(of: #"\bJn-"#, with: "Junction-", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : prefix + s
    }

    /// DOC's codes for well-known tracks, as used at the start of section names.
    static let trackCodes = [
        "TAC": "Tongariro Alpine Crossing",
        "TNC": "Tongariro Northern Circuit",
        "QCT": "Queen Charlotte Track",
        "RTMT": "Round the Mountain Track",
    ]

    /// "Tramping Track" -> "Tramping track", "Great Walk" stays.
    static func kindName(_ subtype: String?) -> String? {
        guard let t = subtype?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        if t.lowercased().hasPrefix("great walk") { return "Great Walk" }
        return t.prefix(1).uppercased() + t.dropFirst().lowercased()
    }

    /// Statuses that mean the asset isn't in public use (initial, removed).
    static func isRetired(_ chars: [String: [String]]) -> Bool {
        let status = chars["USER_STATUS"]?.first ?? "OPEN"
        return status == "INIT" || status == "REMD" || chars["PUBLIC_USE"]?.first == "No"
    }

    static func isClosed(_ chars: [String: [String]]) -> Bool { chars["USER_STATUS"]?.first == "CLSD" }

    static let closedNote = "DOC lists this as closed. Check doc.govt.nz for alerts and when it will reopen."
}

/// DOC huts and campsites (as pins) and closed DOC tracks, for the park info snapshot.
enum NZParkData {
    static let attribution = "Huts, campsites and closures: \(DOC.attribution)"

    static func fetch(session: URLSession = TileNetwork.browse) async throws -> (sites: [Campsite], closed: [ClosedLine], rules: [CampingRule]) {
        async let rules = campingRules(session: session)
        async let huts = points(DOC.hutsURL, session: session)
        async let camps = points(DOC.campsitesURL, session: session)
        async let closedTracks = closedTrackLines(session: session)

        let hutSites: [Campsite] = try await huts.compactMap { item in
            let (a, lon, lat) = item
            let chars = DOC.characteristics(a)
            guard !DOC.isRetired(chars), let name = DOC.cleanName(a["TechObjectName"] as? String) else { return nil }
            var detail: [String] = []
            if let kind = DOC.kindName(a["SubObjectType"] as? String) {
                detail.append(kind.lowercased().contains("hut") ? kind : "\(kind) hut")  // "Great Walk hut"
            }
            if let bunks = chars["WEB_HUT_BUNKS"]?.first?.split(separator: " ").first, Int(bunks) != nil {
                detail.append("\(bunks) bunks")
            }
            if let facilities = chars["WEB_FACILITIES_HUT"], !facilities.isEmpty {
                detail.append(facilities.joined(separator: ", "))
            }
            return Campsite(id: "nz-hut-\(a["OBJECTID"] ?? name)", name: name, kind: "Hut",
                            closure: DOC.isClosed(chars) ? ClosureInfo(details: DOC.closedNote) : nil,
                            lat: lat, lon: lon, region: "NZ", detail: detail.joined(separator: " · "))
        }
        let campSites: [Campsite] = try await camps.compactMap { item in
            let (a, lon, lat) = item
            let chars = DOC.characteristics(a)
            guard !DOC.isRetired(chars), let name = DOC.cleanName(a["TechObjectName"] as? String) else { return nil }
            var detail: [String] = []
            if let kind = DOC.kindName(a["SubObjectType"] as? String) { detail.append("\(kind) campsite") }
            let sites = ["WEB_NUM_SITES_NON_POWER", "WEB_NUM_SITES_POWER"]
                .compactMap { chars[$0]?.first.flatMap(Int.init) }.reduce(0, +)
            if sites > 0 { detail.append("\(sites) sites") }
            if let facilities = chars["WEB_FACILITIES_CAMP"], !facilities.isEmpty {
                detail.append(facilities.joined(separator: ", "))
            }
            let access = chars["WEB_ACCESS_CAMP"].map { "Access: " + $0.joined(separator: ", ") }
            let dogs = chars["WEB_DOGS_ALLOWED"]?.first
            return Campsite(id: "nz-camp-\(a["OBJECTID"] ?? name)", name: name, kind: "Campsite",
                            camping: true,
                            access: [access, dogs].compactMap { $0 }.joined(separator: ". ").nilIfEmpty,
                            closure: DOC.isClosed(chars) ? ClosureInfo(details: DOC.closedNote) : nil,
                            lat: lat, lon: lon, region: "NZ", detail: detail.joined(separator: " · "))
        }
        return (hutSites + campSites, try await closedTracks, (try? await rules) ?? [])
    }

    /// Where freedom camping is prohibited, or restricted with conditions, on DOC land.
    private static func campingRules(session: URLSession) async throws -> [CampingRule] {
        var comps = URLComponents(url: DOC.freedomCampingURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "where", value: "Status='Current'"),
            URLQueryItem(name: "outFields", value: "OBJECTID,Name,Site_Category_Type,Condition_1,Condition_2,Condition_3,Condition_4,Location"),
            URLQueryItem(name: "returnGeometry", value: "true"),
            URLQueryItem(name: "outSR", value: "4326"),
            URLQueryItem(name: "geometryPrecision", value: "5"),
            URLQueryItem(name: "maxAllowableOffset", value: "0.00002"),
            URLQueryItem(name: "resultRecordCount", value: "2000"),
            URLQueryItem(name: "f", value: "json"),
        ]
        let (data, response) = try await session.data(from: comps.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = json["features"] as? [[String: Any]] else { throw URLError(.badServerResponse) }
        return features.compactMap { f in
            guard let a = f["attributes"] as? [String: Any], let g = f["geometry"] as? [String: Any],
                  let rings = g["rings"] as? [[[Double]]], let name = a["Name"] as? String else { return nil }
            let conditions = (1...4).compactMap { (a["Condition_\($0)"] as? String)?.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return CampingRule(id: "nz-rule-\(a["OBJECTID"] ?? name)", name: name,
                               prohibited: (a["Site_Category_Type"] as? String) == "Prohibited",
                               conditions: conditions,
                               location: (a["Location"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                               rings: rings.map { ring in ring.flatMap { $0.count >= 2 ? [$0[0], $0[1]] : [] } })
        }
    }

    /// DOC tracks marked closed, with their lines (USER_STATUS is always CharName2/CharValue2).
    private static func closedTrackLines(session: URLSession) async throws -> [ClosedLine] {
        let segments = try await TrackSources.segments(in: TrackSources.nzTracks.coverage,
                                                       layers: [TrackSources.nzClosedTracks], session: session)
        var byName: [String: [TrackSegment]] = [:]
        for s in segments { byName[s.name ?? "Unnamed track", default: []].append(s) }
        return byName.map { name, segs in
            ClosedLine(id: "nz-track-\(name)", name: name, kind: .track,
                       closure: ClosureInfo(details: DOC.closedNote), lines: segs.map(\.coords), region: "NZ")
        }
    }

    /// All points of a DOC layer (one page: huts ~960, campsites ~330, limit 2,000).
    private static func points(_ url: URL, session: URLSession) async throws -> [([String: Any], Double, Double)] {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "where", value: "1=1"),
            URLQueryItem(name: "outFields", value: "*"),
            URLQueryItem(name: "returnGeometry", value: "true"),
            URLQueryItem(name: "outSR", value: "4326"),
            URLQueryItem(name: "resultRecordCount", value: "2000"),
            URLQueryItem(name: "f", value: "json"),
        ]
        let (data, response) = try await session.data(from: comps.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = json["features"] as? [[String: Any]] else { throw URLError(.badServerResponse) }
        return features.compactMap { f in
            guard let a = f["attributes"] as? [String: Any], let g = f["geometry"] as? [String: Any],
                  let x = g["x"] as? Double, let y = g["y"] as? Double else { return nil }
            return (a, x, y)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
