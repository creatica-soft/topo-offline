import Foundation

/// Campsites, huts and current closures from the Victorian Government's open data
/// (DEECA recreation sites and tracks, and the road closures register). Statewide data is small,
/// so it's fetched in one go and saved as a snapshot for offline use.
enum VicParkData {
    static let attribution = "Sites and closures: © State of Victoria (DEECA), CC BY 4.0"
    private static let wfs = URL(string: "https://opendata.maps.vic.gov.au/geoserver/wfs")!

    static func fetch(now: Date = Date(), session: URLSession = TileNetwork.browse) async throws -> ParkSnapshot {
        async let sites = fetchSites(session: session)
        async let huts = fetchHuts(session: session)
        async let tracks = fetchClosedTracks(now: now, session: session)
        async let roads = fetchClosedRoads(now: now, session: session)
        let lines = try await tracks + roads
        return ParkSnapshot(updated: now, sites: try await sites + huts,
                            closedLines: lines.filter { $0.closure.status(at: now) != .none })
    }

    // MARK: - Layers

    private static func fetchSites(session: URLSession) async throws -> [Campsite] {
        let features = try await query("recweb_site",
            fields: "serial_no,name,camping,picnicing,fee,access_dsc,clos_stat,clos_reas,clos_desc,clos_start,clos_open,geom",
            filter: nil, session: session)
        return features.compactMap { item in
            let (p, geometry) = item
            guard let pt = point(geometry), let name = string(p["name"]) else { return nil }
            let (lon, lat) = pt
            let camping = flag(p["camping"])
            let picnic = flag(p["picnicing"])
            var closure: ClosureInfo?
            if (string(p["clos_stat"]) ?? "").uppercased().contains("CLOS") {
                closure = ClosureInfo(reason: tidy(p["clos_reas"]), details: string(p["clos_desc"]),
                                      start: date(p["clos_start"]), reopen: date(p["clos_open"]))
            }
            return Campsite(id: "site-\(string(p["serial_no"]) ?? name)", name: name,
                            kind: camping ? "Campsite" : (picnic ? "Day area" : "Site"),
                            camping: camping, picnic: picnic, fee: flag(p["fee"]),
                            access: string(p["access_dsc"]), closure: closure, lat: lat, lon: lon)
        }
    }

    private static func fetchHuts(session: URLSession) async throws -> [Campsite] {
        let features = try await query("recweb_hut", fields: "serial_no,name,geom", filter: nil, session: session)
        return features.compactMap { item in
            let (p, geometry) = item
            guard let pt = point(geometry), let name = string(p["name"]) else { return nil }
            let (lon, lat) = pt
            return Campsite(id: "hut-\(string(p["serial_no"]) ?? name)", name: name, kind: "Hut", lat: lat, lon: lon)
        }
    }

    private static func fetchClosedTracks(now: Date, session: URLSession) async throws -> [ClosedLine] {
        let features = try await query("recweb_tracks",
            fields: "serial_no,name,clos_stat,clos_reas,clos_desc,clos_start,clos_open,geom",
            filter: "clos_stat='FULL CLOSURE' AND (clos_open IS NULL OR clos_open > \(cql(now)))",
            session: session)
        return features.compactMap { item in
            let (p, geometry) = item
            guard let name = string(p["name"]), let lines = lines(geometry) else { return nil }
            let closure = ClosureInfo(reason: tidy(p["clos_reas"]), details: string(p["clos_desc"]),
                                      start: date(p["clos_start"]), reopen: date(p["clos_open"]))
            return ClosedLine(id: "track-\(string(p["serial_no"]) ?? name)", name: name, kind: .track,
                              closure: closure, lines: lines)
        }
    }

    /// The road closures register goes back to 2011 and most records were never cleared, so only
    /// closures with a future reopening date, or open-ended ones from the last two years, are used.
    private static func fetchClosedRoads(now: Date, session: URLSession) async throws -> [ClosedLine] {
        let twoYearsAgo = now.addingTimeInterval(-2 * 365 * 24 * 3600)
        let features = try await query("paim_vm_tr_road_closures",
            fields: "vdpid,ezi_road_name_label,status,reason,statusnote,closure_date,reopen_date,geom",
            filter: "status LIKE 'Closed%' AND (reopen_date > \(cql(now)) OR (reopen_date IS NULL AND closure_date > \(cql(twoYearsAgo))))",
            session: session)
        // The register stores each road in many short pieces: join them per road and closure.
        var grouped: [String: (name: String, closure: ClosureInfo, lines: [[Double]])] = [:]
        for (p, geometry) in features {
            guard let name = string(p["ezi_road_name_label"]), let lines = lines(geometry) else { continue }
            // "Other" says nothing; the status note often has the real reason ("Seasonal closure").
            var reason = tidy(p["reason"])
            var note = tidy(p["statusnote"])
            if reason == nil || reason == "Other", let n = note { reason = n; note = nil }
            let closure = ClosureInfo(reason: reason, details: note == reason ? nil : note,
                                      start: date(p["closure_date"]), reopen: date(p["reopen_date"]),
                                      partial: (string(p["status"]) ?? "").contains("Partial"))
            let key = "\(name)|\(closure.reopen?.timeIntervalSince1970 ?? 0)|\(closure.partial)"
            grouped[key, default: (name, closure, [])].lines += lines
        }
        return grouped.map { key, value in
            ClosedLine(id: "road-\(key)", name: expandRoadName(value.name), kind: .road,
                       closure: value.closure, lines: value.lines)
        }
    }

    // MARK: - WFS + parsing helpers

    private static func query(_ layer: String, fields: String, filter: String?,
                              session: URLSession) async throws -> [([String: Any], [String: Any])] {
        var comps = URLComponents(url: wfs, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "service", value: "WFS"),
            URLQueryItem(name: "version", value: "2.0.0"),
            URLQueryItem(name: "request", value: "GetFeature"),
            URLQueryItem(name: "typeNames", value: "open-data-platform:\(layer)"),
            URLQueryItem(name: "outputFormat", value: "application/json"),
            URLQueryItem(name: "srsName", value: "EPSG:4326"),
            URLQueryItem(name: "propertyName", value: fields),
            URLQueryItem(name: "count", value: "10000"),
        ] + (filter.map { [URLQueryItem(name: "cql_filter", value: $0)] } ?? [])
        let (data, response) = try await session.data(from: comps.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = json["features"] as? [[String: Any]] else {
            throw URLError(.badServerResponse)
        }
        return features.compactMap { f in
            guard let p = f["properties"] as? [String: Any], let g = f["geometry"] as? [String: Any] else { return nil }
            return (p, g)
        }
    }

    private static func point(_ g: [String: Any]) -> (Double, Double)? {
        guard g["type"] as? String == "Point", let c = g["coordinates"] as? [Double], c.count >= 2 else { return nil }
        return (c[0], c[1])
    }

    private static func lines(_ g: [String: Any]) -> [[Double]]? {
        let raw: [[[Double]]]
        switch g["type"] as? String {
        case "LineString": raw = [(g["coordinates"] as? [[Double]]) ?? []]
        case "MultiLineString": raw = (g["coordinates"] as? [[[Double]]]) ?? []
        default: return nil
        }
        let out = raw.filter { $0.count >= 2 }.map { line in
            line.flatMap { $0.count >= 2 ? [($0[0] * 1e5).rounded() / 1e5, ($0[1] * 1e5).rounded() / 1e5] : [] }
        }
        return out.isEmpty ? nil : out
    }

    private static func string(_ v: Any?) -> String? {
        let s: String
        switch v {
        case let x as String: s = x
        case let x as NSNumber: s = x.stringValue
        default: return nil
        }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// "FIRE\t" -> "Fire", "MAINTENANCE WORKS" -> "Maintenance works", "NOT RELEVANT" -> nil
    static func tidy(_ v: Any?) -> String? {
        guard let s = string(v), s.uppercased() != "NOT RELEVANT" else { return nil }
        let lower = s.lowercased()
        if lower.hasPrefix("season") { return "Seasonal closure" }  // also "SEASONCLOSUREUPD"
        return lower.prefix(1).uppercased() + lower.dropFirst()
    }

    private static func flag(_ v: Any?) -> Bool {
        guard let s = string(v)?.uppercased() else { return false }
        return s == "Y" || s == "YES" || s == "TRUE" || s == "1"
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(_ v: Any?) -> Date? {
        guard let s = string(v) else { return nil }
        return isoFormatter.date(from: s) ?? isoFormatter.date(from: String(s.prefix(19)) + "Z")
    }

    private static func cql(_ d: Date) -> String { isoFormatter.string(from: d) }

    /// The road register abbreviates: "Joes Trk" -> "Joes Track".
    static func expandRoadName(_ s: String) -> String {
        if s.lowercased() == "unnamed" { return "Unnamed road or track" }
        let map = ["Trk": "Track", "Rd": "Road", "Fwy": "Freeway", "Hwy": "Highway", "Spr": "Spur",
                   "Tr": "Trail", "Flne": "Fireline", "Fl": "Fireline", "Ck": "Creek", "Mt": "Mount"]
        return s.split(separator: " ").map { map[String($0)] ?? String($0) }.joined(separator: " ")
    }
}
