import Foundation
import CoreLocation
import Observation
import UIKit

/// Following a route: progress along it, and a warning on straying more than 100 m from it.
/// GPS stays on while the phone is locked (iOS shows its location indicator), so the warning
/// still comes as a notification with sound when the phone is in a pocket. The notification is
/// made on the phone: nothing is sent anywhere, and it works with no signal.
@MainActor
@Observable
final class RouteFollower: NSObject {
    private(set) var route: SavedRoute?
    private(set) var progress: RouteProgress?
    /// Off route (with some slack before it counts as back on, so it doesn't flicker near 100 m).
    private(set) var isOffRoute = false
    /// Which way along the route the walker is going, once they've moved enough to tell.
    enum Direction { case unknown, forward, reverse }
    private(set) var direction = Direction.unknown
    /// Metres walked along the route since following started (back and forth both count).
    private(set) var walked = 0.0

    /// Warning distance, chosen in Settings or from the banner.
    static let warnKey = "offRouteMeters"
    static let warnChoices: [Double] = [50, 100, 200, 500]
    private var warnMeters: Double {
        let m = UserDefaults.standard.double(forKey: Self.warnKey)
        return m > 0 ? m : RouteProgress.offRouteMeters
    }
    /// Set when location access is off, so the app can explain how to turn it on.
    var permissionProblem = false

    var isFollowing: Bool { route != nil }
    /// What's being followed: a saved route's id, or a published track's `Track.id`.
    private(set) var followingID: String?

    @ObservationIgnored private var path: [CLLocationCoordinate2D] = []
    /// For a published track: all its pieces, so a side track that isn't part of the line being
    /// followed doesn't count as off route.
    @ObservationIgnored private var pieces: [TrackSegment] = []
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var session: CLBackgroundActivitySession?
    @ObservationIgnored private var startWhenAllowed = false
    /// Where along the route direction and distance walked were last updated.
    @ObservationIgnored private var directionMark: Double?
    @ObservationIgnored private var walkedMark: Double?

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
        manager.distanceFilter = 10
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    func start(_ route: SavedRoute) {
        start(route, id: route.id.uuidString, pieces: [])
    }

    /// Follows a published track. Its pieces are joined into one line (as for the elevation
    /// profile) for the distance done and to go.
    func start(_ track: Track) {
        let line = TrackPath.chain(track.segments.map(\.points)).path
        guard line.count >= 2 else { return }
        var route = SavedRoute(name: track.displayName, kind: .imported)
        route.legs = [SavedRoute.Leg(coords: SavedRoute.coords(line), followsTracks: true)]
        start(route, id: track.id, pieces: track.segments)
    }

    private func start(_ route: SavedRoute, id: String, pieces: [TrackSegment]) {
        stop()
        self.route = route
        followingID = id
        path = route.path
        self.pieces = pieces
        Notifications.shared.requestPermission()
        switch manager.authorizationStatus {
        case .notDetermined:
            startWhenAllowed = true
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            permissionProblem = true
            stop()
        default:
            startUpdates()
        }
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        session?.invalidate()
        session = nil
        startWhenAllowed = false
        route = nil
        followingID = nil
        path = []
        pieces = []
        progress = nil
        isOffRoute = false
        direction = .unknown
        walked = 0
        directionMark = nil
        walkedMark = nil
        Notifications.shared.remove(Notifications.offRoute)
    }

    private func startUpdates() {
        // Keeps location updates coming while locked, with "When In Use" permission only.
        session = CLBackgroundActivitySession()
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
    }

    private func update(_ location: CLLocation) {
        guard let route, location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 65,
              var p = RouteProgress.locate(location.coordinate, on: path, previous: progress?.done) else { return }
        if p.offBy > 20, !pieces.isEmpty {
            p.offBy = min(p.offBy, pieces.map { $0.distanceMeters(to: location.coordinate) }.min() ?? .infinity)
        }
        progress = p
        let warnAt = warnMeters
        if !isOffRoute, p.offBy > warnAt {
            isOffRoute = true
            warn(p, route: route)
        } else if isOffRoute, p.offBy < warnAt * 0.6 {
            isOffRoute = false
            Notifications.shared.remove(Notifications.offRoute)
        }
        if !isOffRoute { track(p.done) }
    }

    /// Works out which way the walker is going (50 m along the route one way or the other, so GPS
    /// wobble doesn't flip it) and adds up the distance walked (in steps of 20 m, for the same reason).
    private func track(_ done: Double) {
        let dm = directionMark ?? done, wm = walkedMark ?? done
        if done - dm > 50 { direction = .forward; directionMark = done } else if dm - done > 50 { direction = .reverse; directionMark = done } else { directionMark = dm }
        if abs(done - wm) >= 20 { walked += abs(done - wm); walkedMark = done } else { walkedMark = wm }
    }

    private func warn(_ p: RouteProgress, route: SavedRoute) {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        let units = Units(UnitSetting(rawValue: UserDefaults.standard.string(forKey: "units") ?? "") ?? .automatic)
        Notifications.shared.post(Notifications.offRoute, title: "Off route",
                                  body: "\(route.name) is \(units.distance(p.offBy)) to the \(p.directionToRoute).")
    }
}

extension RouteFollower: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            if let last = locations.last { update(last) }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            guard startWhenAllowed else { return }
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                startWhenAllowed = false
                startUpdates()
            case .denied, .restricted:
                permissionProblem = true
                stop()
            default: break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // No fix yet, or heavy cover: normal on a walk, keep going.
    }
}
