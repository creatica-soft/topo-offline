import Foundation
import CoreLocation

/// Where the user is along a route they're following.
struct RouteProgress: Equatable, Sendable {
    /// Metres along the route to the closest point on it, and metres left after that.
    var done: Double
    var remaining: Double
    /// Metres from the route.
    var offBy: Double

    static let offRouteMeters = 100.0
    var isOffRoute: Bool { offBy > Self.offRouteMeters }

    /// Projects `c` onto `path`. Where the route passes close by twice (an out-and-back, or a loop
    /// near its start), the candidate nearest `previous` progress wins, so it doesn't jump ahead.
    static func locate(_ c: CLLocationCoordinate2D, on path: [CLLocationCoordinate2D], previous: Double? = nil) -> RouteProgress? {
        guard path.count >= 2 else { return nil }
        let kx = 111_320 * cos(c.latitude * .pi / 180), ky = 110_540.0
        func xy(_ p: CLLocationCoordinate2D) -> (Double, Double) {
            ((p.longitude - c.longitude) * kx, (p.latitude - c.latitude) * ky)
        }
        var candidates: [(dist: Double, along: Double)] = []
        var along = 0.0
        for i in 0..<(path.count - 1) {
            let (x1, y1) = xy(path[i]), (x2, y2) = xy(path[i + 1])
            let dx = x2 - x1, dy = y2 - y1
            let len2 = dx * dx + dy * dy
            let len = len2.squareRoot()
            let t = len2 == 0 ? 0 : max(0, min(1, -(x1 * dx + y1 * dy) / len2))
            let px = x1 + t * dx, py = y1 + t * dy
            candidates.append(((px * px + py * py).squareRoot(), along + t * len))
            along += len
        }
        let total = along
        guard let best = candidates.min(by: { $0.dist < $1.dist }) else { return nil }
        var pick = best
        if let previous {
            // Any spot almost as close as the best counts as "here"; take the one nearest where we were.
            let near = candidates.filter { $0.dist <= best.dist + 25 }
            pick = near.min { abs($0.along - previous) < abs($1.along - previous) } ?? best
        }
        return RouteProgress(done: pick.along, remaining: max(0, total - pick.along), offBy: pick.dist)
    }
}

/// One GPS position, as recorded.
struct GPSFix: Equatable, Sendable {
    var coordinate: CLLocationCoordinate2D
    var time: Double
    /// Metres; negative means invalid (Core Location's convention).
    var horizontalAccuracy: Double
    var altitude: Double?

    static func == (a: GPSFix, b: GPSFix) -> Bool {
        a.coordinate.latitude == b.coordinate.latitude && a.coordinate.longitude == b.coordinate.longitude
            && a.time == b.time
    }
}

/// Which GPS positions go into a recording: drops invalid and vague fixes, and jumps that would
/// need faster than 30 km/h (a bad fix under cliffs or trees), unless the last good fix is old.
enum RecordingFilter {
    static let maxSpeed = 30 / 3.6
    static func accept(_ fix: GPSFix, after last: GPSFix?, maxAccuracy: Double) -> Bool {
        guard fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= maxAccuracy else { return false }
        guard let last else { return true }
        let dt = fix.time - last.time
        guard dt > 0 else { return false }
        let d = TrackPath.meters(last.coordinate, fix.coordinate)
        if d > 50, d / dt > maxSpeed, dt < 120 { return false }
        return true
    }

    /// Climb and descent from GPS altitudes, smoothed (GPS altitude wanders by several metres).
    static func climb(_ altitudes: [Double?]) -> (up: Double, down: Double) {
        let known = altitudes.compactMap { $0 }
        guard known.count > 2 else { return (0, 0) }
        let (up, down) = Elevation.climb(Elevation.movingAverage(known, window: 5), threshold: 5)
        return (up, down)
    }
}
