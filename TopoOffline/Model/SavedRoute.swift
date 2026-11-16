import Foundation
import CoreLocation

/// A route the user planned or imported, or a walk they recorded. Kept on the phone only.
/// ("Track" in this app means an agency's published walking track, so these are "routes".)
struct SavedRoute: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case planned, recorded, imported
    }

    /// The line between two waypoints of a planned route (or one piece of an imported/recorded line).
    struct Leg: Codable, Hashable, Sendable {
        /// Longitude/latitude pairs, both ends included: [lon0, lat0, lon1, lat1, ...]
        var coords: [Double]
        /// True when the leg follows the walking-track network, false for a straight line.
        var followsTracks: Bool

        var points: [CLLocationCoordinate2D] { SavedRoute.points(coords) }
    }

    var id = UUID()
    var name: String
    var kind: Kind
    var created = Date()
    var modified = Date()
    /// Planned routes: the points the user placed (lon/lat pairs); there's one leg between each pair.
    var waypoints: [Double] = []
    var legs: [Leg] = []
    /// Recorded walks (and imported tracks that have them): per point of the line, the time
    /// (seconds since 1970) and GPS altitude in metres (nil where unknown). Empty otherwise.
    var times: [Double] = []
    var altitudes: [Double?] = []
    /// A recording that hasn't been stopped yet (e.g. the app was closed while recording).
    var inProgress = false

    /// The whole line, legs joined (a leg's first point repeats the previous leg's last, so it's dropped).
    var coords: [Double] {
        var out: [Double] = []
        for leg in legs {
            let c = leg.coords
            if out.count >= 2, c.count >= 2, out[out.count - 2] == c[0], out[out.count - 1] == c[1] {
                out += c.dropFirst(2)
            } else {
                out += c
            }
        }
        return out
    }

    var path: [CLLocationCoordinate2D] { Self.points(coords) }
    var waypointPoints: [CLLocationCoordinate2D] { Self.points(waypoints) }

    var lengthMeters: Double { TrackPath.length(path) }

    /// Time from the first to the last recorded point.
    var duration: TimeInterval? {
        guard let first = times.first, let last = times.last, last > first else { return nil }
        return last - first
    }

    var kindName: String {
        switch kind {
        case .planned: return "Route"
        case .recorded: return "Recorded walk"
        case .imported: return "Imported route"
        }
    }

    var symbol: String {
        switch kind {
        case .planned: return "point.topleft.down.to.point.bottomright.curvepath"
        case .recorded: return "figure.walk"
        case .imported: return "square.and.arrow.down"
        }
    }

    /// As a `Track`, so the track card, highlight and elevation profile work for it unchanged.
    /// The id includes the modification time, so an edited route gets a fresh profile.
    var asTrack: Track {
        let segment = TrackSegment(layer: "user", name: name, kind: kindName, state: "", coords: coords)
        return Track(id: "route|\(id.uuidString)|\(modified.timeIntervalSince1970)", name: name,
                     kind: kindName, state: "", segments: [segment])
    }

    /// Shortest distance in metres from `c` to the route's line.
    func distanceMeters(to c: CLLocationCoordinate2D) -> Double {
        TrackSegment(layer: "user", name: nil, kind: "", state: "", coords: coords).distanceMeters(to: c)
    }

    var bbox: BoundingBox { asTrack.bbox }

    static func points(_ coords: [Double]) -> [CLLocationCoordinate2D] {
        stride(from: 0, to: coords.count - 1, by: 2).map {
            CLLocationCoordinate2D(latitude: coords[$0 + 1], longitude: coords[$0])
        }
    }

    static func coords(_ points: [CLLocationCoordinate2D]) -> [Double] {
        points.flatMap { [$0.longitude, $0.latitude] }
    }

    /// "Walk 16 Nov 2026, 9:12 am"
    static func recordingName(at date: Date = Date()) -> String {
        "Walk \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}
