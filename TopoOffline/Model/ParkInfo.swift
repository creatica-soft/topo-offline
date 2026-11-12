import Foundation
import CoreLocation

/// A closure as published by the Victorian Government. Many records are left marked "closed" long
/// after the reopening date, so whether a closure applies is always worked out from its dates.
struct ClosureInfo: Codable, Hashable, Sendable {
    var reason: String?       // "Fire", "Maintenance", "Seasonal closure", ...
    var details: String?      // free text from the agency
    var start: Date?
    var reopen: Date?
    var partial = false

    enum Status: Equatable { case current, upcoming(Date), none }

    /// Closures that start within this window are shown as "closing soon".
    static let upcomingWindow: TimeInterval = 60 * 24 * 3600

    func status(at now: Date = Date()) -> Status {
        if let reopen, reopen <= now { return .none }
        if let start, start > now {
            return start.timeIntervalSince(now) <= Self.upcomingWindow ? .upcoming(start) : .none
        }
        return .current
    }

    /// "Until 20 Dec 2026", "No reopening date", or "From 3 Jan 2027".
    func summary(at now: Date = Date()) -> String {
        switch status(at: now) {
        case .upcoming(let d): return "Closes \(d.formatted(date: .abbreviated, time: .omitted))"
        default:
            guard let reopen, Calendar.current.component(.year, from: reopen) < 2040 else { return "No reopening date" }
            return "Until \(reopen.formatted(date: .abbreviated, time: .omitted))"
        }
    }
}

/// A campsite, day area or hut in a Victorian state forest or reserve.
struct Campsite: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let kind: String          // "Campsite", "Day area", "Hut"
    var camping = false
    var picnic = false
    var fee = false
    var access: String?       // how to get there
    var closure: ClosureInfo?
    let lat: Double
    let lon: Double
    /// "NZ" for DOC sites; nil for Victoria (snapshots saved before NZ was added have none).
    var region: String? = nil
    /// Ready-made details line, e.g. "Serviced hut · 20 bunks · Heating, Cooking" (NZ).
    var detail: String? = nil
    /// Where it came from when not DEECA/DOC: see `CampSource`.
    var source: String? = nil
    /// Facilities as short phrases ("Toilets", "Free", "Tents OK").
    var amenities: [String]? = nil
    /// OpenStreetMap facilities attached to an official campground at the same spot.
    var communityAmenities: [String]? = nil
    var website: String? = nil

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
    var closureStatus: ClosureInfo.Status { closure?.status() ?? .none }
    var isCommunity: Bool { source == CampSource.osm }

    var credit: String {
        switch source {
        case CampSource.osm: return CampSource.osmCredit
        case CampSource.nswParks: return "NSW National Parks and Wildlife Service"
        case CampSource.vicmap: return "Vicmap Features of Interest © State of Victoria, CC BY 4.0"
        case CampSource.gazetteer: return "Composite Gazetteer of Australia © Geoscience Australia, CC BY 4.0"
        default: return region == "NZ" ? NZParkData.attribution : VicParkData.attribution
        }
    }
}

enum CampSource {
    static let osm = "osm"
    static let nswParks = "nsw-npws"
    static let vicmap = "vicmap"
    static let gazetteer = "ga"
    static let osmCredit = "© OpenStreetMap contributors (community data, ODbL)"
}

/// A New Zealand freedom-camping rule area from DOC (prohibited, or restricted with conditions).
struct CampingRule: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let prohibited: Bool
    let conditions: [String]
    let location: String?
    /// Outer rings as [lon0, lat0, lon1, lat1, ...]
    let rings: [[Double]]

    var bbox: BoundingBox {
        var b = BoundingBox(minLat: 90, minLon: 180, maxLat: -90, maxLon: -180)
        for ring in rings {
            for i in stride(from: 0, to: ring.count - 1, by: 2) {
                b.minLon = min(b.minLon, ring[i]); b.maxLon = max(b.maxLon, ring[i])
                b.minLat = min(b.minLat, ring[i + 1]); b.maxLat = max(b.maxLat, ring[i + 1])
            }
        }
        return b
    }

    func contains(_ c: CLLocationCoordinate2D) -> Bool {
        guard bbox.contains(c) else { return false }
        return rings.contains { ring in
            let pts = stride(from: 0, to: ring.count - 1, by: 2).map { LonLat(ring[$0], ring[$0 + 1]) }
            return LonLat.polygon(pts, contains: c)
        }
    }
}

/// A closed walking track or road/vehicle track (lines), Victoria.
struct ClosedLine: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case track, road }
    let id: String
    let name: String
    let kind: Kind
    let closure: ClosureInfo
    /// Each line as [lon0, lat0, lon1, lat1, ...]
    let lines: [[Double]]
    var region: String? = nil

    var credit: String { region == "NZ" ? NZParkData.attribution : VicParkData.attribution }

    var segments: [TrackSegment] {
        lines.map { TrackSegment(layer: "vic-closures", name: name, kind: kind.rawValue, state: "VIC", coords: $0) }
    }

    func distanceMeters(to c: CLLocationCoordinate2D) -> Double {
        segments.map { $0.distanceMeters(to: c) }.min() ?? .infinity
    }

    var bbox: BoundingBox {
        Track(segments: segments)?.bbox ?? BoundingBox(minLat: 0, minLon: 0, maxLat: 0, maxLon: 0)
    }
}

/// Everything the app knows about Victorian sites and closures, saved as one snapshot for offline use.
struct ParkSnapshot: Codable, Sendable {
    var updated: Date
    var sites: [Campsite]
    var closedLines: [ClosedLine]
    /// NZ freedom-camping rules (missing in snapshots saved before they were added).
    var campingRules: [CampingRule]? = nil
}
