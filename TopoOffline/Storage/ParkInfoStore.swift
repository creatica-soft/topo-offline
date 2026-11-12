import Foundation
import CoreLocation
import Observation

/// Victorian campsites, huts and current closures. Loaded from the last saved snapshot at launch,
/// refreshed from the server when online and older than a few hours, so it also works offline.
@MainActor
@Observable
final class ParkInfoStore {
    private(set) var snapshot: ParkSnapshot?
    private(set) var refreshing = false

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var lastAttempt: Date?

    static let maxAge: TimeInterval = 3 * 3600

    init(directory: URL = OfflineTileLibrary.defaultDirectory) {
        fileURL = directory.appendingPathComponent("vic-park-info.json")
        if let data = try? Data(contentsOf: fileURL) {
            snapshot = try? JSONDecoder().decode(ParkSnapshot.self, from: data)
        }
    }

    /// Fetches a fresh snapshot if online and the saved one is old (or missing).
    func refreshIfStale(offlineOnly: Bool, force: Bool = false) async {
        let now = Date()
        guard !offlineOnly, !refreshing else { return }
        if !force, let s = snapshot, now.timeIntervalSince(s.updated) < Self.maxAge { return }
        if !force, let last = lastAttempt, now.timeIntervalSince(last) < 600 { return }  // don't retry too often
        lastAttempt = now
        refreshing = true
        defer { refreshing = false }
        async let vic = try? VicParkData.fetch(now: now)
        async let nz = try? NZParkData.fetch()
        let (v, n) = await (vic, nz)
        guard v != nil || n != nil else { return }
        let old = snapshot
        let vicSites = v?.sites ?? old?.sites.filter { $0.region != "NZ" } ?? []
        let vicLines = v?.closedLines ?? old?.closedLines.filter { $0.region != "NZ" } ?? []
        let nzSites = n?.sites ?? old?.sites.filter { $0.region == "NZ" } ?? []
        let nzLines = n?.closed ?? old?.closedLines.filter { $0.region == "NZ" } ?? []
        let rules = n?.rules ?? old?.campingRules ?? []
        let fresh = ParkSnapshot(updated: now, sites: vicSites + nzSites, closedLines: vicLines + nzLines,
                                 campingRules: rules)
        snapshot = fresh
        if let data = try? JSONEncoder().encode(fresh) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// NZ freedom-camping rule areas overlapping `box`.
    func campingRules(in box: BoundingBox) -> [CampingRule] {
        snapshot?.campingRules?.filter { $0.bbox.intersects(box) } ?? []
    }

    func campingRule(at c: CLLocationCoordinate2D) -> CampingRule? {
        snapshot?.campingRules?.first { $0.contains(c) }
    }

    func sites(in box: BoundingBox) -> [Campsite] {
        snapshot?.sites.filter { box.contains($0.coordinate) } ?? []
    }

    /// Closures in force now (or starting soon), worked out from their dates every time.
    func closedLines(in box: BoundingBox, at now: Date = Date()) -> [ClosedLine] {
        snapshot?.closedLines.filter { $0.closure.status(at: now) != .none && $0.bbox.intersects(box) } ?? []
    }

    func closure(near c: CLLocationCoordinate2D, within meters: Double, at now: Date = Date()) -> ClosedLine? {
        let dLat = meters / 110_540, dLon = meters / (111_320 * cos(c.latitude * .pi / 180))
        let probe = BoundingBox(minLat: c.latitude - dLat, minLon: c.longitude - dLon,
                                maxLat: c.latitude + dLat, maxLon: c.longitude + dLon)
        return closedLines(in: probe, at: now)
            .map { ($0, $0.distanceMeters(to: c)) }
            .filter { $0.1 <= meters }
            .min { $0.1 < $1.1 }?.0
    }

    /// Where park info exists: Victoria (DEECA) and New Zealand (DOC).
    static func covers(_ area: BoundingBox) -> Bool {
        area.intersects(TrackSources.victoria) || area.intersects(TileSources.nz.coverage)
    }

    /// "Updated 2 hours ago"
    var updatedText: String? {
        snapshot.map { "Updated \($0.updated.formatted(.relative(presentation: .named)))" }
    }
}
