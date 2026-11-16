import Foundation
import CoreLocation
import Observation

/// A route being drawn: tap to add points, or tap the line to insert one; tap a point to select it,
/// then tap the map to move it there (or, for the start or end, to extend the route from it). Each leg between two points
/// follows the walking tracks where it can (see `TrackRouter`), or is a straight line.
@MainActor
@Observable
final class RoutePlanner {
    var name: String
    /// The saved route being edited (nil for a new one).
    let editing: SavedRoute?
    /// How new legs are drawn.
    var followTracks = true
    private(set) var waypoints: [CLLocationCoordinate2D] = []
    private(set) var legs: [SavedRoute.Leg] = []
    /// Routing in progress (legs can take a moment while track data loads).
    private(set) var isBusy = false
    /// Set when a leg was too long to route along tracks and was drawn straight.
    private(set) var notice: String?
    /// Changes on every edit (for redrawing and recomputing the elevation profile).
    private(set) var version = 0
    /// The point selected on the map, if any.
    private(set) var selected: Int?
    /// With the start or end selected: map taps add points beyond it instead of moving it.
    var extendsFromSelected = false

    @ObservationIgnored private var history: [([CLLocationCoordinate2D], [SavedRoute.Leg])] = []
    @ObservationIgnored private var queue: Task<Void, Never>?
    @ObservationIgnored private let library: OfflineTileLibrary
    @ObservationIgnored var offlineOnly: Bool

    init(library: OfflineTileLibrary, offlineOnly: Bool, editing: SavedRoute? = nil) {
        self.library = library
        self.offlineOnly = offlineOnly
        self.editing = editing
        name = editing?.name ?? "Route \(Date().formatted(date: .abbreviated, time: .omitted))"
        if let editing {
            waypoints = editing.waypointPoints
            legs = editing.legs
            followTracks = editing.legs.last?.followsTracks ?? true
        }
    }

    var canUndo: Bool { !history.isEmpty }
    var lengthMeters: Double { TrackPath.length(SavedRoute.points(route.coords)) }

    /// The route as it stands (keeps the id and creation date of a route being edited).
    var route: SavedRoute {
        var r = editing ?? SavedRoute(name: name, kind: .planned)
        r.name = name
        r.kind = .planned
        r.waypoints = SavedRoute.coords(waypoints)
        r.legs = legs
        r.modified = Date()
        if waypoints.count == 1 {  // a single point: a zero-length leg so it still draws and saves
            r.legs = [SavedRoute.Leg(coords: SavedRoute.coords([waypoints[0], waypoints[0]]), followsTracks: false)]
        }
        return r
    }

    /// Wait for routing to finish (used by the self-test).
    func settle() async { await queue?.value }

    /// True for the first and last points (a route can be extended from these).
    func isEnd(_ index: Int) -> Bool { index == 0 || index == waypoints.count - 1 }

    /// Tapping a point selects it; tapping the selected point again deselects it.
    func select(_ index: Int?) {
        selected = index == selected ? nil : index
        extendsFromSelected = false
    }

    /// A tap on the map: inserts a point if it's on the route's line, adds one at the end if not,
    /// or acts on the selected point.
    func tap(_ c: CLLocationCoordinate2D, tolerance: Double) {
        guard let i = selected, waypoints.indices.contains(i) else {
            selected = nil
            enqueue { [self] in
                if let hit = routeHit(near: c, within: tolerance) {
                    insert(hit)
                } else {
                    await appendPoint(c, tolerance: tolerance, selectNew: false)
                }
            }
            return
        }
        if extendsFromSelected, isEnd(i) {
            if i == 0, waypoints.count > 1 {
                prepend(c, tolerance: tolerance)  // the new point becomes the selected start
            } else {
                add(c, tolerance: tolerance, selectNew: true)
            }
        } else {
            selected = nil
            move(i, to: c, tolerance: tolerance)
        }
    }

    /// Adds a point after the end.
    func add(_ c: CLLocationCoordinate2D, tolerance: Double, selectNew: Bool = false) {
        enqueue { [self] in await appendPoint(c, tolerance: tolerance, selectNew: selectNew) }
    }

    private func appendPoint(_ c: CLLocationCoordinate2D, tolerance: Double, selectNew: Bool) async {
        remember()
        waypoints.append(c)
        let n = waypoints.count
        if n == 1 {
            // Put the first point on a track if there's one under the finger.
            if followTracks, let snapped = await snapPoint(c, tolerance: tolerance) { waypoints[0] = snapped }
        } else {
            legs.append(await routeLeg(n - 2, follow: followTracks, tolerance: tolerance,
                                       snap: n == 2 ? [0, 1] : [n - 1]))
        }
        if selectNew { selected = n - 1 }
    }

    /// Where a tap lands on the route's line: leg, line piece within it, and the closest point.
    private struct RouteHit {
        var leg: Int
        var piece: Int
        var point: CLLocationCoordinate2D
    }

    /// The closest point on the route within `meters` of `c`, unless that's the start or the end
    /// (a tap just past either end adds a point rather than inserting one).
    private func routeHit(near c: CLLocationCoordinate2D, within meters: Double) -> RouteHit? {
        let kx = 111_320 * cos(c.latitude * .pi / 180), ky = 110_540.0
        var best: (hit: RouteHit, dist: Double)?
        for (l, leg) in legs.enumerated() {
            let pts = leg.points
            guard pts.count >= 2 else { continue }
            for k in 0..<(pts.count - 1) {
                // Flat metres around the tap.
                let ax = (pts[k].longitude - c.longitude) * kx, ay = (pts[k].latitude - c.latitude) * ky
                let bx = (pts[k + 1].longitude - c.longitude) * kx, by = (pts[k + 1].latitude - c.latitude) * ky
                let dx = bx - ax, dy = by - ay, len2 = dx * dx + dy * dy
                let t = len2 == 0 ? 0 : max(0, min(1, -(ax * dx + ay * dy) / len2))
                let px = ax + t * dx, py = ay + t * dy
                let d = (px * px + py * py).squareRoot()
                if d <= meters, d < (best?.dist ?? .infinity) {
                    let p = CLLocationCoordinate2D(latitude: c.latitude + py / ky, longitude: c.longitude + px / kx)
                    best = (RouteHit(leg: l, piece: k, point: p), d)
                }
            }
        }
        guard let hit = best?.hit, let first = waypoints.first, let last = waypoints.last,
              TrackPath.meters(hit.point, first) > 1, TrackPath.meters(hit.point, last) > 1 else { return nil }
        return hit
    }

    /// Splits a leg at the tapped point, keeping its shape, and selects the new point (so the next
    /// tap can move it). On an existing point, just selects that point.
    private func insert(_ hit: RouteHit) {
        if let existing = [hit.leg, hit.leg + 1].first(where: { TrackPath.meters(waypoints[$0], hit.point) < 1 }) {
            selected = existing
            return
        }
        remember()
        let pts = legs[hit.leg].points
        var before = Array(pts[0...hit.piece])
        var after = Array(pts[(hit.piece + 1)...])
        if TrackPath.meters(before[before.count - 1], hit.point) > 0.1 { before.append(hit.point) }
        if TrackPath.meters(after[0], hit.point) > 0.1 { after.insert(hit.point, at: 0) }
        let follows = legs[hit.leg].followsTracks
        legs[hit.leg] = SavedRoute.Leg(coords: SavedRoute.coords(before), followsTracks: follows)
        legs.insert(SavedRoute.Leg(coords: SavedRoute.coords(after), followsTracks: follows), at: hit.leg + 1)
        waypoints.insert(hit.point, at: hit.leg + 1)
        selected = hit.leg + 1
    }

    /// Adds a point before the start.
    func prepend(_ c: CLLocationCoordinate2D, tolerance: Double) {
        enqueue { [self] in
            remember()
            waypoints.insert(c, at: 0)
            if waypoints.count == 1 {
                if followTracks, let snapped = await snapPoint(c, tolerance: tolerance) { waypoints[0] = snapped }
            } else {
                legs.insert(await routeLeg(0, follow: followTracks, tolerance: tolerance,
                                           snap: waypoints.count == 2 ? [0, 1] : [0]), at: 0)
            }
            selected = 0
        }
    }

    func move(_ index: Int, to c: CLLocationCoordinate2D, tolerance: Double) {
        enqueue { [self] in
            guard waypoints.indices.contains(index) else { return }
            remember()
            waypoints[index] = c
            if waypoints.count == 1 {
                if followTracks, let snapped = await snapPoint(c, tolerance: tolerance) { waypoints[0] = snapped }
            }
            // Only the moved point may slide onto a track: its neighbours stay where they are.
            if index > 0 {
                legs[index - 1] = await routeLeg(index - 1, follow: followTracks, tolerance: tolerance, snap: [index])
            }
            if index < legs.count {
                legs[index] = await routeLeg(index, follow: followTracks, tolerance: tolerance, snap: [index])
            }
        }
    }

    func remove(_ index: Int) {
        selected = nil
        enqueue { [self] in
            guard waypoints.indices.contains(index) else { return }
            remember()
            if index == 0 {
                waypoints.removeFirst()
                if !legs.isEmpty { legs.removeFirst() }
            } else if index == waypoints.count - 1 {
                waypoints.removeLast()
                legs.removeLast()
            } else {
                let follow = legs[index - 1].followsTracks && legs[index].followsTracks
                waypoints.remove(at: index)
                legs.remove(at: index)
                legs[index - 1] = await routeLeg(index - 1, follow: follow, tolerance: 30, snap: [])
            }
        }
    }

    func undo() {
        selected = nil
        enqueue { [self] in
            guard let (w, l) = history.popLast() else { return }
            waypoints = w
            legs = l
        }
    }

    private func remember() {
        history.append((waypoints, legs))
        if history.count > 100 { history.removeFirst() }
    }

    /// Runs edits one at a time, in order, so quick taps don't race each other.
    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = queue
        queue = Task { @MainActor in
            await previous?.value
            isBusy = true
            await work()
            version += 1
            isBusy = false
        }
    }

    /// Routes leg `i` (waypoint i to i+1). A routed leg starts and ends on the track: the waypoints
    /// listed in `snap` move onto it; the others keep their place, joined to the track by a short
    /// straight bit (so a neighbouring leg isn't left with a gap).
    private func routeLeg(_ i: Int, follow: Bool, tolerance: Double, snap: Set<Int>) async -> SavedRoute.Leg {
        let a = waypoints[i], b = waypoints[i + 1]
        if follow, TrackPath.meters(a, b) > TrackRouter.maxDistance {
            notice = "Points over 20 km apart are joined in a straight line. Add points in between to follow tracks."
        } else {
            notice = nil
        }
        let leg = await TrackRouter.leg(from: a, to: b, followTracks: follow, snap: min(tolerance, 150),
                                        library: library, offlineOnly: offlineOnly)
        if leg.followsTracks, let first = leg.points.first, let last = leg.points.last {
            if snap.contains(i) { waypoints[i] = first }
            if snap.contains(i + 1) { waypoints[i + 1] = last }
        }
        var points = leg.points
        if TrackPath.meters(points[0], waypoints[i]) > 0.5 { points.insert(waypoints[i], at: 0) }
        if TrackPath.meters(points[points.count - 1], waypoints[i + 1]) > 0.5 { points.append(waypoints[i + 1]) }
        return SavedRoute.Leg(coords: SavedRoute.coords(points), followsTracks: leg.followsTracks)
    }

    private func snapPoint(_ c: CLLocationCoordinate2D, tolerance: Double) async -> CLLocationCoordinate2D? {
        let lines = await TrackRouter.trackLines(around: [c], padding: 300, library: library, offlineOnly: offlineOnly)
        return TrackRouter.route(from: c, to: c, along: lines, snap: max(30, min(tolerance, 150)))?.first
    }
}
