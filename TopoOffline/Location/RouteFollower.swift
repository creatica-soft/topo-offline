import Foundation
import CoreLocation
import Observation
import UIKit
import UserNotifications

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
    /// Set when location access is off, so the app can explain how to turn it on.
    var permissionProblem = false

    var isFollowing: Bool { route != nil }

    @ObservationIgnored private var path: [CLLocationCoordinate2D] = []
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var session: CLBackgroundActivitySession?
    @ObservationIgnored private var startWhenAllowed = false
    private static let notificationID = "off-route"

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
        manager.distanceFilter = 10
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    func start(_ route: SavedRoute) {
        stop()
        self.route = route
        path = route.path
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Asks once; if notifications are turned off, the warning is a vibration in the app only.
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
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
        path = []
        progress = nil
        isOffRoute = false
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
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
              let p = RouteProgress.locate(location.coordinate, on: path, previous: progress?.done) else { return }
        progress = p
        if !isOffRoute, p.offBy > RouteProgress.offRouteMeters {
            isOffRoute = true
            warn(p, route: route)
        } else if isOffRoute, p.offBy < RouteProgress.backOnRouteMeters {
            isOffRoute = false
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
        }
    }

    private func warn(_ p: RouteProgress, route: SavedRoute) {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        let units = Units(UnitSetting(rawValue: UserDefaults.standard.string(forKey: "units") ?? "") ?? .automatic)
        let content = UNMutableNotificationContent()
        content.title = "Off route"
        content.body = "\(route.name) is \(units.distance(p.offBy)) to the \(p.directionToRoute)."
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: nil))
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

extension RouteFollower: UNUserNotificationCenterDelegate {
    /// With the app on screen the banner at the top already shows it: play the sound only.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.sound]
    }
}
