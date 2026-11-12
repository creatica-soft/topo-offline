import Foundation
import CoreLocation

/// Finds the track the user tapped: downloaded tracks first, then (if allowed) the state servers.
enum TrackLookup {
    static func track(at c: CLLocationCoordinate2D, within meters: Double,
                      library: OfflineTileLibrary, offlineOnly: Bool) async -> Track? {
        if let segment = library.nearestTrackSegment(to: c, within: meters) {
            let all = segment.name.map { library.trackSegments(named: $0, state: segment.state) } ?? [segment]
            // A long track may run outside the downloaded area; complete it from the server if we can.
            if !offlineOnly, let name = segment.name,
               let full = try? await TrackSources.segments(named: name, state: segment.state, near: c),
               full.count > all.count {
                return Track(segments: full)
            }
            return Track(segments: all.isEmpty ? [segment] : all)
        }
        guard !offlineOnly else { return nil }

        let dLat = meters / 110_540, dLon = meters / (111_320 * cos(c.latitude * .pi / 180))
        let probe = BoundingBox(minLat: c.latitude - dLat, minLon: c.longitude - dLon,
                                maxLat: c.latitude + dLat, maxLon: c.longitude + dLon)
        guard let nearby = try? await TrackSources.segments(in: probe),
              let segment = nearby.min(by: { $0.distanceMeters(to: c) < $1.distanceMeters(to: c) }),
              segment.distanceMeters(to: c) <= meters else { return nil }
        guard let name = segment.name,
              let full = try? await TrackSources.segments(named: name, state: segment.state, near: c),
              !full.isEmpty else {
            return Track(segments: [segment])
        }
        return Track(segments: full)
    }
}
