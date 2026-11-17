import Foundation
import CoreLocation

/// Where the user is along a route they're following.
struct RouteProgress: Equatable, Sendable {
    /// Metres along the route to the closest point on it, and metres left after that.
    var done: Double
    var remaining: Double
    /// Metres from the route.
    var offBy: Double
    /// Compass bearing (degrees) from the walker to the closest point of the route.
    var bearingToRoute: Double = 0

    static let offRouteMeters = 100.0
    /// Back on route once this close again (lower than `offRouteMeters`, so a walker near 100 m
    /// isn't warned again and again).
    static let backOnRouteMeters = 60.0
    var isOffRoute: Bool { offBy > Self.offRouteMeters }

    /// "north-east"
    var directionToRoute: String { Self.compassName(bearingToRoute) }
    /// "NE"
    var directionToRouteShort: String { Self.compassAbbreviation(bearingToRoute) }

    static func compassName(_ degrees: Double) -> String {
        ["north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west"][octant(degrees)]
    }

    static func compassAbbreviation(_ degrees: Double) -> String {
        ["N", "NE", "E", "SE", "S", "SW", "W", "NW"][octant(degrees)]
    }

    private static func octant(_ degrees: Double) -> Int {
        let d = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return Int((d + 22.5) / 45) % 8
    }

    /// Projects `c` onto `path`. Where the route passes close by twice (an out-and-back, or a loop
    /// near its start), the candidate nearest `previous` progress wins, so it doesn't jump ahead.
    static func locate(_ c: CLLocationCoordinate2D, on path: [CLLocationCoordinate2D], previous: Double? = nil) -> RouteProgress? {
        guard path.count >= 2 else { return nil }
        let kx = 111_320 * cos(c.latitude * .pi / 180), ky = 110_540.0
        func xy(_ p: CLLocationCoordinate2D) -> (Double, Double) {
            ((p.longitude - c.longitude) * kx, (p.latitude - c.latitude) * ky)
        }
        var candidates: [(dist: Double, along: Double, x: Double, y: Double)] = []
        var along = 0.0
        for i in 0..<(path.count - 1) {
            let (x1, y1) = xy(path[i]), (x2, y2) = xy(path[i + 1])
            let dx = x2 - x1, dy = y2 - y1
            let len2 = dx * dx + dy * dy
            let len = len2.squareRoot()
            let t = len2 == 0 ? 0 : max(0, min(1, -(x1 * dx + y1 * dy) / len2))
            let px = x1 + t * dx, py = y1 + t * dy
            candidates.append(((px * px + py * py).squareRoot(), along + t * len, px, py))
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
        let bearing = (atan2(pick.x, pick.y) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        return RouteProgress(done: pick.along, remaining: max(0, total - pick.along), offBy: pick.dist,
                             bearingToRoute: bearing)
    }
}

/// Speed and stops along a recorded walk, from the GPS times of its points.
///
/// Recording has no pause button and doesn't need one: a point is only recorded after 5–50 m of
/// movement, so standing still adds a long gap between two nearby points, or a few points
/// wandering in a small circle (GPS drift). A stretch that stays within `stopRadius` for at least
/// `minStop` counts as a stop. Everything else is moving.
struct WalkSpeed: Equatable, Sendable {
    /// For the chart: metres along the walk, and the moving speed there (m/s), averaged over
    /// about `window` either side.
    var distances: [Double]
    var speeds: [Double]
    var totalTime: TimeInterval
    var movingTime: TimeInterval
    var movingDistance: Double
    /// Metres from start to end.
    var length: Double

    var stoppedTime: TimeInterval { max(0, totalTime - movingTime) }
    var averageMoving: Double { movingTime > 0 ? movingDistance / movingTime : 0 }

    static let stopRadius = 20.0
    static let minStop: TimeInterval = 120
    static let window = 100.0

    /// Nil unless every point has a time (recorded walks, and GPX tracks that include times).
    init?(path: [CLLocationCoordinate2D], times: [Double]) {
        let n = path.count
        guard n >= 3, times.count == n, let first = times.first, let last = times.last, last > first else { return nil }
        var along = [0.0]
        along.reserveCapacity(n)
        for i in 1..<n { along.append(along[i - 1] + TrackPath.meters(path[i - 1], path[i])) }

        // Stops: from each point, how long the walk stays within `stopRadius` of it.
        var stopped = [Bool](repeating: false, count: n - 1)  // per segment i → i+1
        var i = 0
        while i < n - 1 {
            var j = i
            while j + 1 < n, TrackPath.meters(path[i], path[j + 1]) <= Self.stopRadius { j += 1 }
            if j > i, times[j] - times[i] >= Self.minStop {
                for k in i..<j { stopped[k] = true }
                i = j
            } else {
                i += 1
            }
        }

        var movingTime = 0.0, movingDistance = 0.0
        for k in 0..<(n - 1) where !stopped[k] {
            let dt = times[k + 1] - times[k]
            guard dt > 0 else { continue }
            movingTime += dt
            movingDistance += along[k + 1] - along[k]
        }

        // Chart: moving speed over the segments within `window` of each point (at most ~400 points).
        let step = max(1, n / 400)
        var ds: [Double] = [], vs: [Double] = []
        for p in stride(from: 0, to: n, by: step) {
            var d = 0.0, t = 0.0
            var k = p - 1
            while k >= 0, along[p] - along[k + 1] <= Self.window {
                if !stopped[k], times[k + 1] > times[k] { d += along[k + 1] - along[k]; t += times[k + 1] - times[k] }
                k -= 1
            }
            k = p
            while k < n - 1, along[k] - along[p] <= Self.window {
                if !stopped[k], times[k + 1] > times[k] { d += along[k + 1] - along[k]; t += times[k + 1] - times[k] }
                k += 1
            }
            guard t > 0 else { continue }
            ds.append(along[p])
            vs.append(d / t)
        }
        guard !ds.isEmpty else { return nil }
        distances = ds
        speeds = vs
        totalTime = last - first
        self.movingTime = movingTime
        self.movingDistance = movingDistance
        length = along[n - 1]
    }

    /// The same walk the other way round (for the profile's Reverse button).
    func reversed() -> WalkSpeed {
        var r = self
        let total = length
        r.distances = distances.reversed().map { total - $0 }
        r.speeds = speeds.reversed()
        return r
    }

    /// Speed at `meters` along the walk (the nearest chart point).
    func speed(atDistance meters: Double) -> Double? {
        guard let i = distances.firstIndex(where: { $0 >= meters }) else { return speeds.last }
        return speeds[i]
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
