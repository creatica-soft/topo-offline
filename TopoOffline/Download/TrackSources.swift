import Foundation
import CoreLocation

/// A government track dataset. NSW, QLD, TAS, NZ and the US serve ArcGIS REST; Victoria serves
/// OGC WFS (GeoServer, GeoJSON); Switzerland the geo.admin.ch identify service; Norway a WFS that
/// only speaks GML.
struct TrackLayer: Sendable {
    enum Backend: Sendable {
        case arcGIS
        case wfs(typeName: String, geometryField: String, sortField: String)
        case geoAdmin(layer: String)
        case gmlWFS(typeName: String, namespace: String)
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
        attribution: "Tracks: © State of New South Wales (DCS Spatial Services)",
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

    /// United States: USGS National Digital Trails (NPS, Forest Service, BLM, state and local
    /// trails), public domain. Land trails open to walkers (or with no rule recorded).
    static let usTrails = TrackLayer(
        id: "us-trails", state: "US",
        queryURL: URL(string: "https://carto.nationalmap.gov/arcgis/rest/services/transportation/MapServer/37/query")!,
        baseWhere: "trailtype='Terra Trail' AND (hikerpedestrian IS NULL OR hikerpedestrian NOT IN ('N','No'))",
        nameFields: ["name"],
        outFields: "name,primarytrailmaintainer",
        orderField: "objectid",
        coverage: TileSources.usCoverage,
        attribution: "Trails: USGS National Digital Trails (public domain)",
        describe: { a in
            let raw = (a["name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let name = raw.isEmpty ? nil : raw
            let maintainers = ["NPS": "NPS", "FS": "Forest Service", "BLM": "BLM", "FWS": "Fish & Wildlife",
                               "State": "State", "USACE": "Army Corps"]
            let by = (a["primarytrailmaintainer"] as? String).flatMap { maintainers[$0] }
            return (name, by.map { "Trail · \($0)" } ?? "Trail")
        })

    /// Switzerland: the signposted hiking trail network (swissTLM3D Wanderwege). Pieces have no
    /// names, so they can be tapped and routed along but not searched.
    static let chTrails = TrackLayer(
        id: "ch-trails", state: "CH",
        queryURL: URL(string: "https://api3.geo.admin.ch/rest/services/api/MapServer/identify")!,
        backend: .geoAdmin(layer: "ch.swisstopo.swisstlm3d-wanderwege"),
        baseWhere: "", nameFields: [], outFields: "", orderField: "",
        coverage: TileSources.ch.coverage,
        attribution: "Hiking trails © swisstopo",
        describe: { a in
            switch a["hikingtype"] as? String {
            case "Bergwanderweg": return (nil, "Mountain hiking trail")
            case "Alpinwanderweg": return (nil, "Alpine route")
            default: return (nil, "Hiking trail")
            }
        })

    /// Norway: walking routes from Kartverket's Turrutebasen (CC BY 4.0). A piece can belong to
    /// several routes; it's named after the first one with a name ("Gjendesheim-Bessheim").
    /// The service can't filter on names, so name search filters the routes around the map.
    static let noTrails = TrackLayer(
        id: "no-trails", state: "NO",
        queryURL: URL(string: "https://wfs.geonorge.no/skwms1/wfs.turogfriluftsruter")!,
        backend: .gmlWFS(typeName: "app:Fotrute",
                         namespace: "http://skjema.geonorge.no/SOSI/produktspesifikasjon/TurOgFriluftsruter/20171210"),
        baseWhere: "", nameFields: ["rutenavn"], outFields: "", orderField: "",
        coverage: TileSources.no.coverage,
        attribution: "Trails: Turruter © Kartverket, CC BY 4.0",
        describe: { a in
            func values(_ key: String) -> [String] { (a[key] as? [String]) ?? [] }
            let name = values("rutenavn").first { !$0.isEmpty && $0 != "Ukjent" }
            var kind = values("merking").first == "JA" ? "Marked trail" : "Trail"
            // DNT's grades: green, blue, red, black.
            let grades = ["G": "easy", "B": "moderate", "R": "demanding", "S": "expert"]
            if let grade = values("gradering").compactMap({ grades[$0] }).first { kind += " (\(grade))" }
            if let by = values("vedlikeholdsansvarlig").first?.components(separatedBy: " | ").first, !by.isEmpty {
                kind += " · \(by)"
            }
            return (name, kind)
        })

    /// Switzerland: SchweizMobil's named hiking routes ("Wanderland": Via Alpina stages, Eiger
    /// Trail…), published by the Federal Roads Office as Opendata BY. They run along the trail
    /// network above, and give its trails names for tapping and searching.
    static let chRoutes = TrackLayer(
        id: "ch-routes", state: "CH",
        queryURL: URL(string: "https://api3.geo.admin.ch/rest/services/api/MapServer/identify")!,
        backend: .geoAdmin(layer: "ch.astra.wanderland"),
        baseWhere: "", nameFields: ["chmobil_title"], outFields: "", orderField: "",
        coverage: TileSources.ch.coverage,
        attribution: "Hiking routes: Wanderland Schweiz (SchweizMobil), FEDRO and cantons",
        describe: { a in
            let raw = ((a["chmobil_title"] as? String) ?? (a["label"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { return nil }
            let kind: String
            switch a["chmobil_route_number"] as? Int {
            case let n? where n < 10: kind = "National hiking route \(n)"
            case let n? where n < 100: kind = "Regional hiking route \(n)"
            case let n?: kind = "Local hiking route \(n)"
            case nil: kind = "Hiking route"
            }
            return (raw, kind)
        })

    /// Canada: official trails in national parks, historic sites and marine conservation areas
    /// (Parks Canada "Trails APCA", Open Government Licence – Canada). There's no national dataset
    /// for trails outside federal parks.
    static let caTrails = TrackLayer(
        id: "ca-parks", state: "CA",
        queryURL: URL(string: "https://services2.arcgis.com/wCOMu5IS7YdSyPNx/ArcGIS/rest/services/vw_Trails_Sentiers_APCA_V2_FGP/FeatureServer/0/query")!,
        baseWhere: "Official_Officiel=1",
        nameFields: ["Name_Official_e"],
        outFields: "Name_Official_e,Restr_Sum_Ete_Interd",
        orderField: "OBJECTID",
        coverage: TileSources.ca.coverage,
        attribution: "Trails: Parks Canada, Open Government Licence – Canada",
        describe: { a in
            let raw = (a["Name_Official_e"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            // Closed to summer use: a ski or snowshoe trail.
            let winterOnly = (a["Restr_Sum_Ete_Interd"] as? Int) == 1
            return (raw.isEmpty ? nil : raw, winterOnly ? "Winter trail · Parks Canada" : "Trail · Parks Canada")
        })

    /// British Columbia: Recreation Sites and Trails BC trails (Open Government Licence – BC).
    static let bcTrails = TrackLayer(
        id: "bc-trails", state: "CA",
        queryURL: URL(string: "https://openmaps.gov.bc.ca/geo/pub/wfs")!,
        backend: .wfs(typeName: "pub:WHSE_FOREST_TENURE.FTEN_RECREATION_LINES_SVW", geometryField: "GEOMETRY", sortField: "OBJECTID"),
        baseWhere: "LIFE_CYCLE_STATUS_CODE='ACTIVE'",
        nameFields: ["PROJECT_NAME"],
        outFields: "PROJECT_NAME",
        orderField: "OBJECTID",
        coverage: BoundingBox(minLat: 48.2, minLon: -139.1, maxLat: 60.0, maxLon: -114.0),
        attribution: "Trails: Recreation Sites and Trails BC, Open Government Licence – British Columbia",
        describe: { a in
            let raw = (a["PROJECT_NAME"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            // Names are often in capitals ("DEEKS LAKE TRAIL").
            let name = raw.isEmpty ? nil : (raw == raw.uppercased() ? titleCase(raw) : raw)
            return (name, "Trail · BC Recreation Sites and Trails")
        })

    /// Ontario: the Ontario Trail Network (Open Government Licence – Ontario), walking trails only.
    static let onTrails = TrackLayer(
        id: "on-trails", state: "CA",
        queryURL: URL(string: "https://ws.lioservices.lrc.gov.on.ca/arcgis1071a/rest/services/LIO_OPEN_DATA/LIO_Open04/MapServer/19/query")!,
        baseWhere: "(PERMITTED_USES LIKE '%Hiking%' OR PERMITTED_USES LIKE '%Walking%')",
        nameFields: ["TRAIL_NAME"],
        outFields: "TRAIL_NAME,TRAIL_ASSOCIATION",
        orderField: "OBJECTID",
        coverage: BoundingBox(minLat: 41.6, minLon: -95.2, maxLat: 56.9, maxLon: -74.3),
        attribution: "Trails: Ontario Trail Network, Open Government Licence – Ontario",
        describe: { a in
            let raw = (a["TRAIL_NAME"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let by = (a["TRAIL_ASSOCIATION"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            return (raw.isEmpty ? nil : raw, by.isEmpty ? "Trail" : "Trail · \(by)")
        })

    static let all = [nswPaths, qldWalking, qldGreatWalk, tasTracks, vicTrails, nzTracks, usTrails,
                      chTrails, chRoutes, noTrails, caTrails, bcTrails, onTrails]

    static func layers(for state: String) -> [TrackLayer] { all.filter { $0.state == state } }

    static func attribution(for state: String) -> String? { layers(for: state).first?.attribution }

    /// Every credit for a country (several layers can cover one: Parks Canada, BC, Ontario).
    static func attributions(for state: String) -> [String] { layers(for: state).map(\.attribution) }

    /// The credit for a track: from the data layer its pieces came from (falls back to the state).
    static func attribution(for track: Track) -> String? {
        let ids = Set(track.segments.map(\.layer))
        let credits = all.filter { ids.contains($0.id) }.map(\.attribution)
        return credits.isEmpty ? attribution(for: track.state) : credits.joined(separator: " · ")
    }

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
    /// Named tracks matching `text` within about 100 km of `center`.
    static func search(_ text: String, near center: CLLocationCoordinate2D) async throws -> [Track] {
        let tokens = Gazetteer.serverTokens(of: text).filter { $0.count > 1 }
        guard !tokens.isEmpty, tokens.joined().count >= 3 else { return [] }
        let box = BoundingBox(minLat: center.latitude - 1, minLon: center.longitude - 1,
                              maxLat: center.latitude + 1, maxLon: center.longitude + 1)
        let layers = all.filter { !$0.nameFields.isEmpty && $0.coverage.intersects(box) }
        let segments = try await withThrowingTaskGroup(of: [TrackSegment].self) { group in
            for layer in layers {
                group.addTask {
                    try await named(layer, text: tokens.joined(separator: " "), exact: false, tokens: tokens,
                                    near: center, box: box, limit: 4000)
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
        for layer in layers(for: state) where !layer.nameFields.isEmpty {
            result += try await named(layer, text: name, exact: true, tokens: tokens, near: center, box: box, limit: 10_000)
        }
        let wanted = Gazetteer.normalize(name)
        return result.filter { $0.name.map(Gazetteer.normalize) == wanted }
    }

    /// The tapped segment among (segment, distance) candidates: the nearest, unless a named one is
    /// nearly as close. Named routes often run along unnamed network pieces (Switzerland), and
    /// the name is what the user wants to see.
    static func preferNamed(_ candidates: [(TrackSegment, Double)]) -> TrackSegment? {
        guard let nearest = candidates.min(by: { $0.1 < $1.1 }) else { return nil }
        if nearest.0.name != nil { return nearest.0 }
        let named = candidates.filter { $0.0.name != nil }.min(by: { $0.1 < $1.1 })
        if let named, named.1 <= nearest.1 + 15 { return named.0 }
        return nearest.0
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

    /// Segments whose name matches, by whatever means the layer's service offers: a name filter
    /// for ArcGIS and GeoServer, geo.admin's `find`, or (Norway, whose service can't filter on
    /// names) every route around the map, filtered by the caller.
    private static func named(_ layer: TrackLayer, text: String, exact: Bool, tokens: [String],
                              near center: CLLocationCoordinate2D, box: BoundingBox, limit: Int) async throws -> [TrackSegment] {
        switch layer.backend {
        case .arcGIS, .wfs:
            return try await fetch(layer, where: "\(layer.baseWhere) AND \(nameClause(layer, tokens))",
                                   box: box, limit: limit, session: TileNetwork.browse)
        case let .geoAdmin(name):
            return try await findGeoAdmin(layer, name: name, text: text, exact: exact)
        case .gmlWFS:
            let near = BoundingBox(minLat: center.latitude - 0.25, minLon: center.longitude - 0.5,
                                   maxLat: center.latitude + 0.25, maxLon: center.longitude + 0.5)
            return try await fetch(layer, where: "", box: near, limit: 5000, session: TileNetwork.browse)
        }
    }

    /// geo.admin.ch `find`: features of `name` whose name field contains (or equals) `text`.
    private static func findGeoAdmin(_ layer: TrackLayer, name: String, text: String, exact: Bool) async throws -> [TrackSegment] {
        guard let field = layer.nameFields.first else { return [] }
        var comps = URLComponents(string: "https://api3.geo.admin.ch/rest/services/api/MapServer/find")!
        comps.queryItems = [
            URLQueryItem(name: "layer", value: name), URLQueryItem(name: "searchText", value: text),
            URLQueryItem(name: "searchField", value: field), URLQueryItem(name: "contains", value: exact ? "false" : "true"),
            URLQueryItem(name: "returnGeometry", value: "true"), URLQueryItem(name: "geometryFormat", value: "geojson"),
            URLQueryItem(name: "sr", value: "4326"),
        ]
        let (data, response) = try await TileNetwork.browse.data(from: comps.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw URLError(.badServerResponse) }
        return geoAdminSegments(layer, json["results"] as? [[String: Any]] ?? [])
    }

    private static func geoAdminSegments(_ layer: TrackLayer, _ features: [[String: Any]]) -> [TrackSegment] {
        var result: [TrackSegment] = []
        for f in features {
            guard let described = layer.describe(f["properties"] as? [String: Any] ?? f["attributes"] as? [String: Any] ?? [:]),
                  let geometry = f["geometry"] as? [String: Any] else { continue }
            for line in geoJSONLines(geometry) where line.count >= 2 {
                let coords = line.flatMap { $0.count >= 2 ? [round5($0[0]), round5($0[1])] : [] }
                result.append(TrackSegment(layer: layer.id, name: described.name, kind: described.kind,
                                           state: layer.state, coords: coords))
            }
        }
        return result
    }

    // MARK: - Helpers

    private static func nameClause(_ layer: TrackLayer, _ tokens: [String]) -> String {
        tokens.map { t in
            "(" + layer.nameFields.map { field in
                switch layer.backend {
                case .arcGIS: return "UPPER(\(field)) LIKE '%\(t.uppercased())%'"
                case .wfs: return "\(field) ILIKE '%\(t)%'"
                case .geoAdmin, .gmlWFS: return "1=1"  // these layers have no names to search
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
        case let .geoAdmin(name):
            return try await fetchGeoAdmin(layer, name: name, box: box, limit: limit, session: session)
        case let .gmlWFS(typeName, namespace):
            return try await fetchGML(layer, typeName: typeName, namespace: namespace, box: box, limit: limit, session: session)
        }
    }

    /// geo.admin.ch identify over the box, as GeoJSON (at most 200 features a page).
    private static func fetchGeoAdmin(_ layer: TrackLayer, name: String, box: BoundingBox,
                                      limit: Int, session: URLSession) async throws -> [TrackSegment] {
        var result: [TrackSegment] = []
        var offset = 0
        let page = 200
        let extent = "\(box.minLon),\(box.minLat),\(box.maxLon),\(box.maxLat)"
        while offset < limit {
            var comps = URLComponents(url: layer.queryURL, resolvingAgainstBaseURL: false)!
            comps.queryItems = [
                URLQueryItem(name: "geometryType", value: "esriGeometryEnvelope"),
                URLQueryItem(name: "geometry", value: extent),
                URLQueryItem(name: "mapExtent", value: extent),
                URLQueryItem(name: "imageDisplay", value: "1000,1000,96"),
                URLQueryItem(name: "tolerance", value: "0"),
                URLQueryItem(name: "layers", value: "all:\(name)"),
                URLQueryItem(name: "sr", value: "4326"),
                URLQueryItem(name: "geometryFormat", value: "geojson"),
                URLQueryItem(name: "returnGeometry", value: "true"),
                URLQueryItem(name: "limit", value: String(page)),
                URLQueryItem(name: "offset", value: String(offset)),
            ]
            let (data, response) = try await session.data(from: comps.url!)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw URLError(.badServerResponse)
            }
            let features = json["results"] as? [[String: Any]] ?? []
            result += geoAdminSegments(layer, features)
            if features.count < page { break }
            offset += features.count
        }
        return result
    }

    private static func geoJSONLines(_ geometry: [String: Any]) -> [[[Double]]] {
        switch geometry["type"] as? String {
        case "LineString": return [(geometry["coordinates"] as? [[Double]]) ?? []]
        case "MultiLineString": return (geometry["coordinates"] as? [[[Double]]]) ?? []
        default: return []
        }
    }

    /// OGC WFS 2.0 GetFeature as GML 3.2, in EPSG:4326 (latitude first), paged.
    private static func fetchGML(_ layer: TrackLayer, typeName: String, namespace: String, box: BoundingBox,
                                 limit: Int, session: URLSession) async throws -> [TrackSegment] {
        var result: [TrackSegment] = []
        var start = 0
        let page = 1000
        let prefix = typeName.split(separator: ":").first.map(String.init) ?? "app"
        while start < limit {
            var comps = URLComponents(url: layer.queryURL, resolvingAgainstBaseURL: false)!
            comps.queryItems = [
                URLQueryItem(name: "service", value: "WFS"), URLQueryItem(name: "version", value: "2.0.0"),
                URLQueryItem(name: "request", value: "GetFeature"), URLQueryItem(name: "typeNames", value: typeName),
                URLQueryItem(name: "namespaces", value: "xmlns(\(prefix),\(namespace))"),
                URLQueryItem(name: "srsName", value: "urn:ogc:def:crs:EPSG::4326"),
                URLQueryItem(name: "bbox", value: "\(box.minLat),\(box.minLon),\(box.maxLat),\(box.maxLon),urn:ogc:def:crs:EPSG::4326"),
                URLQueryItem(name: "count", value: String(page)), URLQueryItem(name: "startIndex", value: String(start)),
            ]
            let (data, response) = try await session.data(from: comps.url!)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let reader = GMLLineReader(featureElement: String(typeName.split(separator: ":").last ?? ""))
            let parser = XMLParser(data: data)
            parser.delegate = reader
            guard parser.parse() else { throw URLError(.cannotParseResponse) }
            for f in reader.features {
                guard let described = layer.describe(f.attributes) else { continue }
                for line in f.lines where line.count >= 4 {
                    // posList is "lat lon lat lon …"; segments store lon, lat.
                    var coords: [Double] = []
                    coords.reserveCapacity(line.count)
                    for i in stride(from: 0, to: line.count - 1, by: 2) { coords += [round5(line[i + 1]), round5(line[i])] }
                    result.append(TrackSegment(layer: layer.id, name: described.name, kind: described.kind,
                                               state: layer.state, coords: coords))
                }
            }
            if reader.features.count < page { break }
            start += reader.features.count
        }
        return result
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

/// Reads features from a GML 3.2 feature collection: each feature's `posList` lines, plus its
/// simple text properties by local name, as lists ("rutenavn" can appear once per route).
private final class GMLLineReader: NSObject, XMLParserDelegate {
    struct Feature {
        var lines: [[Double]] = []
        var attributes: [String: Any] = [:]
    }
    let featureElement: String
    private(set) var features: [Feature] = []
    private var current: Feature?
    private var text = ""

    init(featureElement: String) { self.featureElement = featureElement }

    private func local(_ name: String) -> String { String(name.split(separator: ":").last ?? Substring(name)) }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        if local(name) == featureElement { current = Feature() }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let element = local(name)
        if element == featureElement {
            if let f = current { features.append(f) }
            current = nil
        } else if current != nil {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if element == "posList" {
                current?.lines.append(value.split(whereSeparator: { $0 == " " || $0 == "\n" }).compactMap { Double($0) })
            } else if !value.isEmpty {
                let previous = (current?.attributes[element] as? [String]) ?? []
                current?.attributes[element] = previous + [value]
            }
        }
        text = ""
    }
}
