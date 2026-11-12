import Foundation
import CoreLocation

/// An official place name from the Composite Gazetteer of Australia.
struct PlaceName: Codable, Hashable, Identifiable, Sendable {
    let id: String         // gazetteer id, e.g. "QLD_1682"
    let name: String       // "Mount Barney"
    let feature: String    // "MOUNTAIN", "WALKING TRACK", "WATERCOURSE", ...
    let category: String   // "LANDFORM", "TRAIL", "WATERWAY", ...
    let state: String      // naming authority: "NSW", "QLD", "AHO", ...
    let lat: Double
    let lon: Double

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }

    /// "Mountain · QLD"
    var kind: String {
        let f = feature.lowercased()
        let pretty = f.prefix(1).uppercased() + f.dropFirst()
        return state.count <= 3 ? "\(pretty) · \(state)" : pretty
    }

    func distanceKm(from c: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: lat, longitude: lon)
            .distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude)) / 1000
    }
}
