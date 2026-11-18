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

    /// The default warning distance (it can be changed in Settings).
    static let offRouteMeters = 100.0
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

/// Speed and stops along a recorded walk, from the GPS times of its points (stops: `StopFinder`).
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

    static let window = 100.0

    /// For a saved walk: pauses (gaps between its pieces) count as stopped.
    init?(route: SavedRoute, rule: StopFinder.Rule = .current) {
        var breaks: Set<Int> = [], count = 0
        for leg in route.legs where !leg.coords.isEmpty {
            if count > 0 { breaks.insert(count - 1) }
            count += leg.coords.count / 2
        }
        self.init(path: route.path, times: route.times, breaks: breaks, rule: rule)
    }

    /// Nil unless every point has a time (recorded walks, and GPX tracks that include times).
    /// `breaks`: segments (point i → i+1) that are a pause, not walking.
    init?(path: [CLLocationCoordinate2D], times: [Double], breaks: Set<Int> = [], rule: StopFinder.Rule = .current) {
        let n = path.count
        guard n >= 3, times.count == n, let first = times.first, let last = times.last, last > first else { return nil }
        var along = [0.0]
        along.reserveCapacity(n)
        for i in 1..<n { along.append(along[i - 1] + TrackPath.meters(path[i - 1], path[i])) }

        var stopped = StopFinder.stoppedSegments(path, times, rule: rule)  // per segment i → i+1
        for b in breaks where b < n - 1 { stopped[b] = true }

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
/// need faster than 80 km/h (a bad fix under cliffs or trees: real ones jump hundreds of metres
/// in seconds), unless the last good fix is old. 80 km/h leaves room for cycling downhill.
enum RecordingFilter {
    static let maxSpeed = 80 / 3.6
    static func accept(_ fix: GPSFix, after last: GPSFix?, maxAccuracy: Double) -> Bool {
        guard fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= maxAccuracy else { return false }
        guard let last else { return true }
        let dt = fix.time - last.time
        guard dt > 0 else { return false }
        let d = TrackPath.meters(last.coordinate, fix.coordinate)
        if d > 50, d / dt > maxSpeed, dt < 120 { return false }
        return true
    }

    /// Climb and descent of a recording, piece by piece (no climb is counted across a pause).
    static func climb(_ walk: SavedRoute) -> (up: Double, down: Double) {
        var up = 0.0, down = 0.0, start = 0
        for leg in walk.legs {
            let n = leg.coords.count / 2
            let end = min(start + n, walk.altitudes.count)
            if end > start {
                let c = climb(Array(walk.altitudes[start..<end]))
                up += c.up; down += c.down
            }
            start += n
        }
        return (up, down)
    }

    /// Climb and descent from GPS altitudes, smoothed (GPS altitude wanders by several metres).
    static func climb(_ altitudes: [Double?]) -> (up: Double, down: Double) {
        let known = altitudes.compactMap { $0 }
        guard known.count > 2 else { return (0, 0) }
        let (up, down) = Elevation.climb(Elevation.movingAverage(known, window: 5), threshold: 5)
        return (up, down)
    }
}

/// Finds where a recording stood still. A point is only recorded after 5–50 m of movement, so
/// standing still shows up in the points as
///  - a long gap between two nearby points (no movement recorded at all),
///  - points within 20 m of each other (GPS drift outdoors), or
///  - points wandering around one spot (indoors, where GPS drifts by tens of metres and each
///    wobble is recorded: a shop, a hut),
/// lasting at least the rule's time. The rule (Settings › Recording) trades catching stops where
/// you potter about (lunch, camp) against counting very slow walking as stopped.
enum StopFinder {
    struct Rule: Equatable, Sendable {
        /// Staying within this of one spot…
        var radius: Double
        /// …for this long counts as a stop.
        var duration: TimeInterval

        static let standard = Rule(radius: 50, duration: 300)
        static let radiusChoices: [Double] = [20, 50, 100]
        static let durationChoices: [TimeInterval] = [120, 300, 600, 900]
        static let radiusKey = "stopRadius"
        static let durationKey = "stopDuration"

        /// From Settings.
        static var current: Rule {
            let d = UserDefaults.standard
            let r = d.double(forKey: radiusKey), t = d.double(forKey: durationKey)
            return Rule(radius: r > 0 ? r : standard.radius, duration: t > 0 ? t : standard.duration)
        }

        /// Moving slower than this, on average over `duration`, can count as stopped.
        var slowestMoving: Double { radius * 1.2 / duration }
    }

    /// GPS drift outdoors stays within this.
    static let tight = 20.0

    /// Per segment (point i → i+1): true where it's part of a stop.
    static func stoppedSegments(_ path: [CLLocationCoordinate2D], _ times: [Double], rule: Rule = .current) -> [Bool] {
        let n = min(path.count, times.count)
        guard n >= 2 else { return [] }
        var stopped = [Bool](repeating: false, count: n - 1)
        for range in stops(path, times, rule: rule) {
            for k in range.lowerBound..<range.upperBound { stopped[k] = true }
        }
        return stopped
    }

    /// Each stop as a point range (first point...last point).
    static func stops(_ path: [CLLocationCoordinate2D], _ times: [Double], rule: Rule = .current) -> [ClosedRange<Int>] {
        let n = min(path.count, times.count)
        guard n >= 2 else { return [] }
        let radius = max(tight, rule.radius), duration = rule.duration
        var marked = [Bool](repeating: false, count: n - 1)
        // Staying within `tight` of a point.
        var i = 0
        while i < n - 1 {
            var j = i
            while j + 1 < n, TrackPath.meters(path[i], path[j + 1]) <= min(tight, radius) { j += 1 }
            if j > i, times[j] - times[i] >= duration {
                for k in i..<j { marked[k] = true }
                i = j
            } else {
                i += 1
            }
        }
        // One long gap with hardly any movement (GPS silent indoors, then a jump when it's back).
        for k in 0..<(n - 1) {
            let dt = times[k + 1] - times[k], d = TrackPath.meters(path[k], path[k + 1])
            if dt >= duration, d <= radius || d / dt < rule.slowestMoving { marked[k] = true }
        }
        // Wandering around one spot for `duration` (a silence after the last point counts): start
        // and end close together, and 90% of the points within `radius` of their middle.
        var drift = [Bool](repeating: false, count: n - 1)
        for i in 0..<n {
            var j = i
            while j + 1 < n, times[j + 1] - times[i] <= duration { j += 1 }
            guard j > i else { continue }
            let covered = j + 1 < n ? min(times[j + 1], times[i] + duration) - times[i] : times[j] - times[i]
            guard covered >= duration * 0.8, TrackPath.meters(path[i], path[j]) <= radius * 1.2 else { continue }
            let mid = center(path[i...j])
            let spread = path[i...j].map { TrackPath.meters(mid, $0) }.sorted()
            guard spread[Int(0.9 * Double(spread.count - 1))] <= radius else { continue }
            for k in i..<j { drift[k] = true }
        }
        // A window can start or end on the way in or out: trim each drifting stretch back to the
        // points near its middle, so walking up to the stop isn't counted as stopped.
        for r in runs(drift) {
            let mid = center(path[r])
            var a = r.lowerBound, b = r.upperBound
            while a < b, TrackPath.meters(path[a], mid) > radius / 2 { a += 1 }
            while b > a, TrackPath.meters(path[b], mid) > radius / 2 { b -= 1 }
            for m in a..<b { marked[m] = true }
        }
        // Stops at the same spot with a short break between (a wobble that didn't fit) are one stop.
        var out: [ClosedRange<Int>] = []
        for r in runs(marked) {
            if let last = out.last, times[r.lowerBound] - times[last.upperBound] <= duration / 2,
               TrackPath.meters(center(path[last]), center(path[r])) <= radius {
                out[out.count - 1] = last.lowerBound...r.upperBound
            } else {
                out.append(r)
            }
        }
        return out
    }

    /// Runs of true segments as point ranges.
    private static func runs(_ segments: [Bool]) -> [ClosedRange<Int>] {
        var out: [ClosedRange<Int>] = []
        var k = 0
        while k < segments.count {
            guard segments[k] else { k += 1; continue }
            var j = k
            while j < segments.count, segments[j] { j += 1 }
            out.append(k...j)
            k = j
        }
        return out
    }

    /// Median latitude and longitude (outliers don't drag it).
    private static func center(_ points: ArraySlice<CLLocationCoordinate2D>) -> CLLocationCoordinate2D {
        let lats = points.map(\.latitude).sorted(), lons = points.map(\.longitude).sorted()
        return CLLocationCoordinate2D(latitude: lats[lats.count / 2], longitude: lons[lons.count / 2])
    }
}
