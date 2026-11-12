import Foundation
import CoreLocation

struct LonLat: Hashable, Sendable {
    let lon: Double
    let lat: Double
    init(_ lon: Double, _ lat: Double) { self.lon = lon; self.lat = lat }

    /// Even–odd ray casting. Fine for these small, non-wrapping polygons.
    static func polygon(_ ring: [LonLat], contains p: CLLocationCoordinate2D) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in ring.indices {
            let a = ring[i], b = ring[j]
            if (a.lat > p.latitude) != (b.lat > p.latitude),
               p.longitude < (b.lon - a.lon) * (p.latitude - a.lat) / (b.lat - a.lat) + a.lon {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}

/// Rough state outlines (within a few km) used only to choose which map to show.
/// The sea side is drawn generously; only the land borders matter.
enum StateOutlines {
    /// NSW / Queensland land border, west to east: 29°S, then the Macintyre and Dumaresq rivers,
    /// then the Great Dividing Range and McPherson Range to Point Danger.
    private static let qldNswBorder: [LonLat] = [
        LonLat(141.00, -29.00), LonLat(148.95, -29.00), LonLat(149.60, -28.60), LonLat(150.30, -28.55),
        LonLat(150.90, -28.70), LonLat(151.17, -28.85), LonLat(151.55, -28.95), LonLat(151.93, -28.95),
        LonLat(152.05, -28.55), LonLat(152.50, -28.37), LonLat(152.90, -28.33), LonLat(153.20, -28.25),
        LonLat(153.55, -28.16),
    ]

    static let nsw: [LonLat] = qldNswBorder + [
        LonLat(154.20, -28.16), LonLat(154.20, -37.60),
        // Victorian border: Cape Howe, straight line to the Murray's source, then down the Murray.
        LonLat(149.98, -37.55), LonLat(148.20, -36.80), LonLat(147.90, -36.10), LonLat(146.90, -36.05),
        LonLat(144.75, -36.10), LonLat(143.55, -35.30), LonLat(142.20, -34.15), LonLat(141.00, -34.00),
    ]

    static let qld: [LonLat] = [
        LonLat(138.00, -9.00), LonLat(154.20, -9.00), LonLat(154.20, -28.16),
    ] + qldNswBorder.reversed() + [
        LonLat(141.00, -26.00), LonLat(138.00, -26.00),
    ]
}
