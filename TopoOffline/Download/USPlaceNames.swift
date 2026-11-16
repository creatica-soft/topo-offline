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

/// Chooses the place-name service for where the map is.
enum PlaceSearch {
    static func isUS(_ c: CLLocationCoordinate2D?) -> Bool {
        c.map { TileSources.usCoverage.contains($0) } ?? false
    }

    static func search(_ text: String, near center: CLLocationCoordinate2D?) async throws -> [PlaceName] {
        isUS(center) ? try await USPlaceNames.search(text, near: center) : try await Gazetteer.search(text, near: center)
    }

    static func attribution(near center: CLLocationCoordinate2D?) -> String {
        isUS(center) ? USPlaceNames.attribution : Gazetteer.attribution
    }

    /// Names for a downloaded area, from whichever services cover it.
    static func names(in box: BoundingBox) async throws -> [PlaceName] {
        var all: [PlaceName] = []
        if box.intersects(TileSources.australia.coverage) { all += try await Gazetteer.names(in: box) }
        if box.intersects(TileSources.usCoverage) { all += try await USPlaceNames.names(in: box) }
        return all
    }
}
