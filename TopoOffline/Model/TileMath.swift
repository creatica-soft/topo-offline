import Foundation
import CoreLocation

/// A latitude/longitude rectangle (WGS84 degrees).
struct BoundingBox: Codable, Hashable, Sendable {
    var minLat: Double
    var minLon: Double
    var maxLat: Double
    var maxLon: Double

    var center: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
    }

    func intersects(_ other: BoundingBox) -> Bool {
        minLat < other.maxLat && maxLat > other.minLat && minLon < other.maxLon && maxLon > other.minLon
    }

    func intersection(_ other: BoundingBox) -> BoundingBox? {
        guard intersects(other) else { return nil }
        return BoundingBox(minLat: max(minLat, other.minLat), minLon: max(minLon, other.minLon),
                           maxLat: min(maxLat, other.maxLat), maxLon: min(maxLon, other.maxLon))
    }

    func contains(_ c: CLLocationCoordinate2D) -> Bool {
        c.latitude >= minLat && c.latitude <= maxLat && c.longitude >= minLon && c.longitude <= maxLon
    }

    /// Approximate east–west size in kilometres.
    var widthKm: Double { (maxLon - minLon) * 111.32 * cos(center.latitude * .pi / 180) }
    /// Approximate north–south size in kilometres.
    var heightKm: Double { (maxLat - minLat) * 110.57 }
}

/// A Web Mercator ("XYZ" / Google scheme) tile address.
struct TileKey: Hashable, Sendable, CustomStringConvertible {
    let z: Int
    let x: Int
    let y: Int

    var description: String { "\(z)/\(x)/\(y)" }
}

enum TileMath {
    static let maxLatitude = 85.05112878

    static func tileX(lon: Double, z: Int) -> Int {
        let n = Double(1 << z)
        let x = Int(floor((lon + 180) / 360 * n))
        return min(max(x, 0), (1 << z) - 1)
    }

    static func tileY(lat: Double, z: Int) -> Int {
        let rad = min(max(lat, -maxLatitude), maxLatitude) * .pi / 180
        let n = Double(1 << z)
        let y = Int(floor((1 - log(tan(rad) + 1 / cos(rad)) / .pi) / 2 * n))
        return min(max(y, 0), (1 << z) - 1)
    }

    static func bbox(of key: TileKey) -> BoundingBox {
        let n = Double(1 << key.z)
        func lon(_ x: Int) -> Double { Double(x) / n * 360 - 180 }
        func lat(_ y: Int) -> Double { atan(sinh(.pi * (1 - 2 * Double(y) / n))) * 180 / .pi }
        return BoundingBox(minLat: lat(key.y + 1), minLon: lon(key.x), maxLat: lat(key.y), maxLon: lon(key.x + 1))
    }

    static func ranges(for bbox: BoundingBox, z: Int) -> (x: ClosedRange<Int>, y: ClosedRange<Int>) {
        let x0 = tileX(lon: bbox.minLon, z: z), x1 = tileX(lon: bbox.maxLon, z: z)
        let y0 = tileY(lat: bbox.maxLat, z: z), y1 = tileY(lat: bbox.minLat, z: z)
        return (x0...x1, y0...y1)
    }

    static func tileCount(for bbox: BoundingBox, zooms: ClosedRange<Int>) -> Int {
        zooms.reduce(0) { total, z in
            let r = ranges(for: bbox, z: z)
            return total + r.x.count * r.y.count
        }
    }

    /// All tiles covering `bbox`, lowest zoom first (so the overview arrives before the detail).
    static func tiles(for bbox: BoundingBox, zooms: ClosedRange<Int>) -> [TileKey] {
        var keys: [TileKey] = []
        keys.reserveCapacity(tileCount(for: bbox, zooms: zooms))
        for z in zooms {
            let r = ranges(for: bbox, z: z)
            for y in r.y { for x in r.x { keys.append(TileKey(z: z, x: x, y: y)) } }
        }
        return keys
    }
}
