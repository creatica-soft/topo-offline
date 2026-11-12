import Foundation
import CoreLocation

/// One piece of a track as published by a state agency (tracks come in many short segments).
struct TrackSegment: Codable, Hashable, Sendable {
    /// `TrackLayer.id` it came from, e.g. "nsw-paths".
    let layer: String
    /// Cleaned-up name ("Federal Pass Walking Track"), nil if unnamed.
    let name: String?
    /// "Walking track", "Great Walk", "Fire trail or vehicle track", ...
    let kind: String
    /// "NSW", "QLD", "TAS"
    let state: String
    /// Longitude/latitude pairs: [lon0, lat0, lon1, lat1, ...]
    let coords: [Double]

    var points: [CLLocationCoordinate2D] {
        stride(from: 0, to: coords.count - 1, by: 2).map {
            CLLocationCoordinate2D(latitude: coords[$0 + 1], longitude: coords[$0])
        }
    }

    var bbox: BoundingBox {
        var b = BoundingBox(minLat: 90, minLon: 180, maxLat: -90, maxLon: -180)
        for i in stride(from: 0, to: coords.count - 1, by: 2) {
            b.minLon = min(b.minLon, coords[i]); b.maxLon = max(b.maxLon, coords[i])
            b.minLat = min(b.minLat, coords[i + 1]); b.maxLat = max(b.maxLat, coords[i + 1])
        }
        return b
    }

    var lengthMeters: Double {
        let p = points
        guard p.count > 1 else { return 0 }
        return zip(p, p.dropFirst()).reduce(0) { sum, pair in
            sum + CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
                .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
        }
    }

    /// Shortest distance in metres from `c` to this line (flat-earth approximation, fine at track scale).
    func distanceMeters(to c: CLLocationCoordinate2D) -> Double {
        let kx = 111_320 * cos(c.latitude * .pi / 180), ky = 110_540.0
        func xy(_ i: Int) -> (Double, Double) { ((coords[i] - c.longitude) * kx, (coords[i + 1] - c.latitude) * ky) }
        guard coords.count >= 2 else { return .infinity }
        if coords.count < 4 { let (x, y) = xy(0); return (x * x + y * y).squareRoot() }
        var best = Double.infinity
        for i in stride(from: 0, to: coords.count - 3, by: 2) {
            let (x1, y1) = xy(i), (x2, y2) = xy(i + 2)
            let dx = x2 - x1, dy = y2 - y1
            let len2 = dx * dx + dy * dy
            let t = len2 == 0 ? 0 : max(0, min(1, -(x1 * dx + y1 * dy) / len2))
            let px = x1 + t * dx, py = y1 + t * dy
            best = min(best, (px * px + py * py).squareRoot())
        }
        return best
    }
}

/// A whole named track (all its segments), or a single unnamed segment.
struct Track: Identifiable, Equatable, Sendable {
    let id: String
    let name: String?
    let kind: String
    let state: String
    let segments: [TrackSegment]
    let lengthKm: Double
    let bbox: BoundingBox

    init?(segments: [TrackSegment]) {
        guard let first = segments.first else { return nil }
        self.segments = segments
        name = first.name
        // A track mixing kinds (e.g. a Great Walk using ordinary walking tracks) shows the most specific.
        kind = segments.first(where: { $0.kind.hasPrefix("Great Walk") })?.kind ?? first.kind
        state = first.state
        id = first.name.map { Track.id(state: first.state, name: $0) }
            ?? "segment|\(first.state)|\(first.coords.prefix(2).map { String($0) }.joined(separator: ","))"
        lengthKm = segments.reduce(0) { $0 + $1.lengthMeters } / 1000
        bbox = segments.dropFirst().reduce(first.bbox) { b, s in
            let o = s.bbox
            return BoundingBox(minLat: min(b.minLat, o.minLat), minLon: min(b.minLon, o.minLon),
                               maxLat: max(b.maxLat, o.maxLat), maxLon: max(b.maxLon, o.maxLon))
        }
    }

    static func id(state: String, name: String) -> String { "track|\(state)|\(Gazetteer.normalize(name))" }

    var displayName: String { name ?? "Unnamed \(kind.lowercased())" }

    /// For listing alongside place names in search results.
    var asPlace: PlaceName {
        let mid = segments[segments.count / 2].points
        let p = mid[mid.count / 2]
        return PlaceName(id: id, name: displayName, feature: kind.uppercased(), category: "TRAIL",
                         state: state, lat: p.latitude, lon: p.longitude)
    }

    static func == (a: Track, b: Track) -> Bool { a.id == b.id && a.segments.count == b.segments.count }
}
