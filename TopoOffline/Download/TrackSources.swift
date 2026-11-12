import Foundation
import CoreLocation

/// A government track dataset. NSW, QLD and TAS serve ArcGIS REST; Victoria serves OGC WFS (GeoServer).
struct TrackLayer: Sendable {
    enum Backend: Sendable {
        case arcGIS
        case wfs(typeName: String, geometryField: String, sortField: String)
    }
    let id: String
    let state: String
    let queryURL: URL
    var backend: Backend = .arcGIS
    /// Always-applied filter (e.g. "only open walking tracks"): SQL for ArcGIS, CQL for WFS.
    let baseWhere: String
    /// Fields that make up the name, searched with LIKE.
    let nameFields: [String]
    let outFields: String
    let orderField: String
    let coverage: BoundingBox
    let attribution: String
    /// Turns raw attributes into a (name, kind); nil skips the feature.
    let describe: @Sendable ([String: Any]) -> (name: String?, kind: String)?
}

/// Walking tracks from NSW Spatial Services, Queensland Parks and Tasmania's LIST.
enum TrackSources {
    static let nswPaths = TrackLayer(
        id: "nsw-paths", state: "NSW",
        queryURL: URL(string: "https://portal.spatial.nsw.gov.au/server/rest/services/NSW_Transport_Theme/FeatureServer/5/query")!,
        // Paths (walking tracks), plus named vehicle tracks (fire trails walkers use). Operational only.
        baseWhere: "operationalstatus=1 AND (functionhierarchy=9 OR (functionhierarchy=8 AND roadnamebase IS NOT NULL))",
        nameFields: ["roadnamebase", "roadnametype"],
        outFields: "roadnamebase,roadnametype,functionhierarchy",
        orderField: "objectid",
        coverage: TileSources.nsw.coverage,
        attribution: "Tracks: © State of New South Wales (Spatial Services, DCS)",
        describe: { a in
            let parts = [a["roadnamebase"] as? String, a["roadnametype"] as? String]
                .compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let name = parts.isEmpty ? nil : titleCase(parts.joined(separator: " "))
            guard (a["functionhierarchy"] as? Int) == 9 else { return (name, "Fire trail or vehicle track") }
            // NSW "paths" also include town footpaths ("Boomerang Street"): only call it a walking
            // track when it's unnamed bush path or the name says so.
            let bushWords = ["track", "walk", "trail", "pass", "circuit", "lookout", "loop", "route", "steps", "stairs"]
            let lower = name?.lowercased() ?? ""
            let isWalk = name == nil || bushWords.contains { lower.contains($0) }
            return (name, isWalk ? "Walking track" : "Path")
        })

    private static func qldLayer(_ n: Int, id: String, kind: String) -> TrackLayer {
        TrackLayer(
            id: id, state: "QLD",
            queryURL: URL(string: "https://spatial-gis.information.qld.gov.au/arcgis/rest/services/Environment/ParksTerrestrialProtectedAreas/MapServer/\(n)/query")!,
            baseWhere: "1=1",
            nameFields: ["name", "visitor_id"],
            outFields: "name,visitor_id,class,status",
            orderField: "objectid",
            coverage: TileSources.qld.coverage,
            attribution: "Tracks: © State of Queensland (Department of Environment and Science), CC BY 4.0",
            describe: { a in
                // `name` is the park's internal name for each piece ("Somerset Walking Track",
                // "Bull Boundary Break"); `visitor_id` is the public track it belongs to ("Somerset trail").
                let name = qldTrackName(visitorID: a["visitor_id"] as? String, name: a["name"] as? String)
                if let status = a["status"] as? String, status.lowercased().contains("closed") {
                    return (name, "\(kind) (closed)")
                }
                return (name, kind)
            })
    }
    static let qldWalking = qldLayer(5, id: "qld-walking", kind: "Walking track")
    static let qldGreatWalk = qldLayer(6, id: "qld-greatwalk", kind: "Great Walk")

    static let tasTracks = TrackLayer(
        id: "tas-tracks", state: "TAS",
        queryURL: URL(string: "https://services.thelist.tas.gov.au/arcgis/rest/services/Public/OpenDataWFS/MapServer/42/query")!,
        baseWhere: "TRANS_TYPE='Track' AND USER_TYPE<>'Private'",
        nameFields: ["PRI_NAME"],
        outFields: "PRI_NAME,USER_TYPE",
        orderField: "OBJECTID",
        coverage: TileSources.tas.coverage,
        attribution: "Tracks: © State of Tasmania (the LIST), CC BY 3.0 AU",
        describe: { a in
            let name = (a["PRI_NAME"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let restricted = (a["USER_TYPE"] as? String) == "Restricted"
            return (name, restricted ? "Track (restricted access)" : "Track")
        })

    /// Victoria has no free topo map, so its tracks are also drawn on the map (see `VisibleTracks`).
    static let victoria = BoundingBox(minLat: -39.2, minLon: 140.95, maxLat: -33.98, maxLon: 150.0)

    static let vicTrails = TrackLayer(
        id: "vic-trails", state: "VIC",
        queryURL: URL(string: "https://opendata.maps.vic.gov.au/geoserver/wfs")!,
        backend: .wfs(typeName: "open-data-platform:tr_road", geometryField: "geom", sortField: "ufi"),
        // Vicmap Transport "trail" features: walking tracks, paths and similar (not roads).
        baseWhere: "feature_type_code='trail'",
        nameFields: ["ezi_road_name_label"],
        outFields: "ezi_road_name_label,road_type",
        orderField: "ufi",
        coverage: victoria,
        attribution: "Tracks: © State of Victoria (Vicmap), CC BY 4.0",
        describe: { a in
            let raw = (a["ezi_road_name_label"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let name = (raw.isEmpty || raw.lowercased() == "unnamed") ? nil : raw
            let kind = (name?.lowercased().contains("cycle") ?? false) ? "Shared path" : "Walking track"
            return (name, kind)
        })

    private static func docTrackLayer(id: String, where clause: String) -> TrackLayer {
        TrackLayer(
            id: id, state: "NZ",
            queryURL: DOC.tracksURL,
            baseWhere: clause,
            nameFields: ["TechObjectName"],
            outFields: "*",  // details live in numbered CharName/CharValue pairs
            orderField: "OBJECTID",
            coverage: TileSources.nz.coverage,
            attribution: "Tracks: \(DOC.attribution)",
            describe: { a in
                let chars = DOC.characteristics(a)
                guard !DOC.isRetired(chars) else { return nil }
                var kind = DOC.kindName(a["SubObjectType"] as? String) ?? "Track"
                if let duration = chars["WEB_WALKING_DURATION"]?.first { kind += ", \(duration.lowercased())" }
                if DOC.isClosed(chars) { kind += " (closed)" }
                return (DOC.cleanName(a["TechObjectName"] as? String), kind)
            })
    }
    /// New Zealand DOC tracks (the Topo50 map already shows them, so they're tappable/searchable, not drawn).
    static let nzTracks = docTrackLayer(id: "nz-doc", where: "1=1")
    /// Only DOC tracks marked closed (for the closures snapshot).
    static let nzClosedTracks = docTrackLayer(id: "nz-doc-closed", where: "CharName2='USER_STATUS' AND CharValue2='CLSD'")

    static let all = [nswPaths, qldWalking, qldGreatWalk, tasTracks, vicTrails, nzTracks]

    static func layers(for state: String) -> [TrackLayer] { all.filter { $0.state == state } }

    static func attribution(for state: String) -> String? { layers(for: state).first?.attribution }

    // MARK: - Queries

    /// All track segments inside `box`, from every state that overlaps it.
    static func segments(in box: BoundingBox, layers only: [TrackLayer]? = nil,
                         session: URLSession = TileNetwork.browse) async throws -> [TrackSegment] {
        let layers = (only ?? all).filter { $0.coverage.intersects(box) }
        return try await withThrowingTaskGroup(of: [TrackSegment].self) { group in
            for layer in layers {
                group.addTask { try await fetch(layer, where: layer.baseWhere, box: box, limit: 30_000, session: session) }
            }
            var result: [TrackSegment] = []
            for try await part in group { result += part }
            return result
        }
    }

    /// Named tracks matching `text` within about 100 km of `center`.
    static func search(_ text: String, near center: CLLocationCoordinate2D) async throws -> [Track] {
        let tokens = Gazetteer.serverTokens(of: text).filter { $0.count > 1 }
        guard !tokens.isEmpty, tokens.joined().count >= 3 else { return [] }
        let box = BoundingBox(minLat: center.latitude - 1, minLon: center.longitude - 1,
                              maxLat: center.latitude + 1, maxLon: center.longitude + 1)
        let layers = all.filter { $0.coverage.intersects(box) }
        let segments = try await withThrowingTaskGroup(of: [TrackSegment].self) { group in
            for layer in layers {
                group.addTask {
                    try await fetch(layer, where: "\(layer.baseWhere) AND \(nameClause(layer, tokens))",
                                    box: box, limit: 4000, session: TileNetwork.browse)
                }
            }
            var result: [TrackSegment] = []
            for try await part in group { result += part }
            return result
        }
        let matchTokens = Gazetteer.tokens(of: text)
        return group(segments.filter { s in
            s.name.map { n in matchTokens.allSatisfy { Gazetteer.normalize(n).contains($0) } } ?? false
        })
    }

    /// Every segment of the named track near `center` (tracks can be long, so the window is wide).
    static func segments(named name: String, state: String, near center: CLLocationCoordinate2D) async throws -> [TrackSegment] {
        let tokens = Gazetteer.serverTokens(of: name).filter { $0.count > 1 }
        guard !tokens.isEmpty else { return [] }
        let box = BoundingBox(minLat: center.latitude - 1.5, minLon: center.longitude - 1.5,
                              maxLat: center.latitude + 1.5, maxLon: center.longitude + 1.5)
        var result: [TrackSegment] = []
        for layer in layers(for: state) {
            result += try await fetch(layer, where: "\(layer.baseWhere) AND \(nameClause(layer, tokens))",
                                      box: box, limit: 10_000, session: TileNetwork.browse)
        }
        let wanted = Gazetteer.normalize(name)
        return result.filter { $0.name.map(Gazetteer.normalize) == wanted }
    }

    /// Groups segments into tracks by state + name (unnamed segments are left out).
    static func group(_ segments: [TrackSegment]) -> [Track] {
        var byID: [String: [TrackSegment]] = [:]
        for s in segments {
            guard let name = s.name else { continue }
            byID[Track.id(state: s.state, name: name), default: []].append(s)
        }
        return byID.values.compactMap { Track(segments: $0) }
    }

    // MARK: - Helpers

    private static func nameClause(_ layer: TrackLayer, _ tokens: [String]) -> String {
        tokens.map { t in
            "(" + layer.nameFields.map { field in
                switch layer.backend {
                case .arcGIS: return "UPPER(\(field)) LIKE '%\(t.uppercased())%'"
                case .wfs: return "\(field) ILIKE '%\(t)%'"
                }
            }.joined(separator: " OR ") + ")"
        }.joined(separator: " AND ")
    }

    /// The public track name if the piece belongs to one, otherwise the piece's own name.
    static func qldTrackName(visitorID: String?, name: String?) -> String? {
        if let v = cleanQLDName(visitorID) {
            return capitalizeWords(v)  // "Ships Stern circuit" -> "Ships Stern Circuit"
        }
        return cleanQLDName(name)
    }

    /// Queensland names carry internal prefixes: "BB - Lower Bellbird circuit", "GM - DUA - Paths".
    static func cleanQLDName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = raw.replacingOccurrences(of: #"^(?:[A-Z]{2,4}\s*-\s*|[A-Z]{2}\s+)+"#, with: "",
                                               options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let generic: Set<String> = ["", "path", "paths", "track", "tracks", "walking track", "walk", "access"]
        return generic.contains(cleaned.lowercased()) ? nil : cleaned
    }

    /// Capitalises the first letter of each word, keeping existing capitals ("O'Reilly's walk" ->
    /// "O'Reilly's Walk") and small joining words in lower case.
    static func capitalizeWords(_ s: String) -> String {
        let small: Set<String> = ["to", "and", "of", "the", "via", "on", "at"]
        return s.split(separator: " ", omittingEmptySubsequences: false).enumerated().map { i, word in
            guard let first = word.first, i == 0 || !small.contains(word.lowercased()) else { return String(word) }
            return first.uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }

    /// "LILA FALLS-LEURA FOREST WALKING TRACK" -> "Lila Falls-Leura Forest Walking Track"
    static func titleCase(_ s: String) -> String {
        var out = ""
        var capitalizeNext = true
        for ch in s.lowercased() {
            out.append(capitalizeNext ? Character(ch.uppercased()) : ch)
            capitalizeNext = ch == " " || ch == "-" || ch == "(" || ch == "/"
        }
        return out
    }

    private static func fetch(_ layer: TrackLayer, where clause: String, box: BoundingBox,
                              limit: Int, session: URLSession) async throws -> [TrackSegment] {
        switch layer.backend {
        case .arcGIS:
            return try await fetchArcGIS(layer, where: clause, box: box, limit: limit, session: session)
        case let .wfs(typeName, geometryField, sortField):
            return try await fetchWFS(layer, typeName: typeName, geometryField: geometryField, sortField: sortField,
                                      filter: clause, box: box, limit: limit, session: session)
        }
    }

    /// OGC WFS 2.0 GetFeature as GeoJSON, filtered with CQL (GeoServer).
    private static func fetchWFS(_ layer: TrackLayer, typeName: String, geometryField: String, sortField: String,
                                 filter: String, box: BoundingBox, limit: Int,
                                 session: URLSession) async throws -> [TrackSegment] {
        var result: [TrackSegment] = []
        var start = 0
        let page = 2000
        let bbox = "BBOX(\(geometryField),\(box.minLon),\(box.minLat),\(box.maxLon),\(box.maxLat),'EPSG:4326')"
        while start < limit {
            var comps = URLComponents(url: layer.queryURL, resolvingAgainstBaseURL: false)!
            comps.queryItems = [
                URLQueryItem(name: "service", value: "WFS"),
                URLQueryItem(name: "version", value: "2.0.0"),
                URLQueryItem(name: "request", value: "GetFeature"),
                URLQueryItem(name: "typeNames", value: typeName),
                URLQueryItem(name: "outputFormat", value: "application/json"),
                URLQueryItem(name: "srsName", value: "EPSG:4326"),
                URLQueryItem(name: "propertyName", value: "\(layer.outFields),\(geometryField)"),
                URLQueryItem(name: "cql_filter", value: "\(filter) AND \(bbox)"),
                URLQueryItem(name: "sortBy", value: sortField),
                URLQueryItem(name: "count", value: String(page)),
                URLQueryItem(name: "startIndex", value: String(start)),
            ]
            let (data, response) = try await session.data(from: comps.url!)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw URLError(.badServerResponse)  // GeoServer reports errors as XML
            }
            let features = json["features"] as? [[String: Any]] ?? []
            for f in features {
                guard let props = f["properties"] as? [String: Any],
                      let described = layer.describe(props),
                      let geometry = f["geometry"] as? [String: Any] else { continue }
                let lines: [[[Double]]]
                switch geometry["type"] as? String {
                case "LineString": lines = [(geometry["coordinates"] as? [[Double]]) ?? []]
                case "MultiLineString": lines = (geometry["coordinates"] as? [[[Double]]]) ?? []
                default: lines = []
                }
                for line in lines where line.count >= 2 {
                    // 5 decimals ≈ 1 m, plenty for walking and keeps saved files small.
                    let coords = line.flatMap { $0.count >= 2 ? [round5($0[0]), round5($0[1])] : [] }
                    result.append(TrackSegment(layer: layer.id, name: described.name, kind: described.kind,
                                               state: layer.state, coords: coords))
                }
            }
            if features.count < page { break }
            start += features.count
        }
        return result
    }

    private static func round5(_ v: Double) -> Double { (v * 100_000).rounded() / 100_000 }

    private static func fetchArcGIS(_ layer: TrackLayer, where clause: String, box: BoundingBox,
                                    limit: Int, session: URLSession) async throws -> [TrackSegment] {
        var result: [TrackSegment] = []
        var offset = 0
        let page = 2000
        while offset < limit {
            var comps = URLComponents(url: layer.queryURL, resolvingAgainstBaseURL: false)!
            comps.queryItems = [
                URLQueryItem(name: "where", value: clause),
                URLQueryItem(name: "geometry", value: "\(box.minLon),\(box.minLat),\(box.maxLon),\(box.maxLat)"),
                URLQueryItem(name: "geometryType", value: "esriGeometryEnvelope"),
                URLQueryItem(name: "inSR", value: "4326"),
                URLQueryItem(name: "outSR", value: "4326"),
                URLQueryItem(name: "spatialRel", value: "esriSpatialRelIntersects"),
                URLQueryItem(name: "outFields", value: layer.outFields),
                URLQueryItem(name: "returnGeometry", value: "true"),
                URLQueryItem(name: "geometryPrecision", value: "5"),
                URLQueryItem(name: "maxAllowableOffset", value: "0.00002"),  // ≈2 m simplification
                URLQueryItem(name: "orderByFields", value: layer.orderField),
                URLQueryItem(name: "resultOffset", value: String(offset)),
                URLQueryItem(name: "resultRecordCount", value: String(page)),
                URLQueryItem(name: "f", value: "json"),
            ]
            let (data, response) = try await session.data(from: comps.url!)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw URLError(.badServerResponse)
            }
            if let error = json["error"] as? [String: Any] {
                throw NSError(domain: "Tracks", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: error["message"] as? String ?? "Track query failed"])
            }
            let features = json["features"] as? [[String: Any]] ?? []
            for f in features {
                guard let attrs = f["attributes"] as? [String: Any],
                      let described = layer.describe(attrs),
                      let geometry = f["geometry"] as? [String: Any],
                      let paths = geometry["paths"] as? [[[Double]]] else { continue }
                for path in paths where path.count >= 2 {
                    let coords = path.flatMap { $0.count >= 2 ? [$0[0], $0[1]] : [] }
                    result.append(TrackSegment(layer: layer.id, name: described.name, kind: described.kind,
                                               state: layer.state, coords: coords))
                }
            }
            let more = (json["exceededTransferLimit"] as? Bool) == true || features.count == page
            if !more { break }
            offset += features.count
        }
        return result
    }
}
