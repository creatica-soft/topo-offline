import Foundation
import MapKit
import Observation

/// Lets SwiftUI views read where the map is looking and move it.
@MainActor
@Observable
final class MapController {
    private(set) var visibleArea: BoundingBox?
    private(set) var zoomLevel: Double = 0
    /// Ground distance per screen point at the centre of the map (for the scale bar).
    private(set) var metersPerPoint: Double = 0
    /// Becomes true once the MKMapView exists, so the scale bar and compass can attach to it.
    private(set) var isMapReady = false

    @ObservationIgnored weak var mapView: MKMapView?
    @ObservationIgnored private let locationManager = CLLocationManager()
    /// Called with each position MapKit reports for the blue dot (while the app is on screen).
    @ObservationIgnored var onUserLocation: ((CLLocation) -> Void)?

    static let australia = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: -28, longitude: 134),
        span: MKCoordinateSpan(latitudeDelta: 34, longitudeDelta: 40))
    static let newZealand = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: -41, longitude: 173),
        span: MKCoordinateSpan(latitudeDelta: 14, longitudeDelta: 14))
    static let lower48 = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 39, longitude: -98),
        span: MKCoordinateSpan(latitudeDelta: 28, longitudeDelta: 60))

    /// Where the map opens: the phone's own country when the app has maps for it.
    static func startRegion(for locale: Locale = .current) -> MKCoordinateRegion {
        switch locale.region?.identifier {
        case "US", "PR", "VI": return lower48
        case "NZ": return newZealand
        default: return australia
        }
    }

    func attach(_ map: MKMapView) {
        mapView = map
        isMapReady = true
    }

    func requestLocationPermission() {
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
    }

    func show(_ box: BoundingBox, animated: Bool = true) {
        // At least ~600 m across, so a short track or single point doesn't zoom in absurdly far.
        let span = MKCoordinateSpan(latitudeDelta: max((box.maxLat - box.minLat) * 1.25, 0.006),
                                    longitudeDelta: max((box.maxLon - box.minLon) * 1.25, 0.006))
        mapView?.setRegion(MKCoordinateRegion(center: box.center, span: span), animated: animated)
    }

    /// Centres the map on a point, showing about `km` across.
    func show(_ point: CLLocationCoordinate2D, km: Double = 4, animated: Bool = true) {
        let region = MKCoordinateRegion(center: point, latitudinalMeters: km * 1000, longitudinalMeters: km * 1000)
        mapView?.setRegion(region, animated: animated)
    }

    var center: CLLocationCoordinate2D? { visibleArea?.center }
    var userLocation: CLLocation? { mapView?.userLocation.location }

    func followUser() {
        requestLocationPermission()
        mapView?.setUserTrackingMode(.follow, animated: true)
    }

    func mapDidMove(_ map: MKMapView) {
        let r = map.region
        visibleArea = BoundingBox(minLat: r.center.latitude - r.span.latitudeDelta / 2,
                                  minLon: r.center.longitude - r.span.longitudeDelta / 2,
                                  maxLat: r.center.latitude + r.span.latitudeDelta / 2,
                                  maxLon: r.center.longitude + r.span.longitudeDelta / 2)
        let width = max(Double(map.bounds.width), 1)
        zoomLevel = log2(360 * width / 256 / max(r.span.longitudeDelta, 1e-9))
        mapIsMoving(map)
    }

    /// Called continuously while the map moves (pinch zooms included), so the scale bar keeps up.
    func mapIsMoving(_ map: MKMapView) {
        let width = Double(map.bounds.width)
        guard width > 0 else { return }
        let m = MKMetersPerMapPointAtLatitude(map.centerCoordinate.latitude) * map.visibleMapRect.size.width / width
        // Small changes don't move the bar visibly; skipping them saves redraws while panning.
        if abs(m - metersPerPoint) > metersPerPoint * 0.005 { metersPerPoint = m }
    }
}
