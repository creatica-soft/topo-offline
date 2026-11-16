import Foundation
import CoreLocation
import Observation

/// Campgrounds from all sources, merged for display:
///  1. "rich" sites with facilities/closures (Victorian state forests, NZ DOC) from `ParkInfoStore`,
///  2. official campgrounds (NSW parks, Vicmap, gazetteer; US Forest Service once the map has shown
///     the US), saved and refreshed fortnightly,
///  3. community campsites from the bundled OpenStreetMap extract.
/// The same campground often appears in several sources, so nearby duplicates are folded together.
@MainActor
@Observable
final class CampgroundStore {
    private(set) var official: [Campsite] = []
    private(set) var community: [Campsite] = []
    private(set) var communityDate: String?

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var lastUSAttempt: Date?
    static let maxAge: TimeInterval = 14 * 24 * 3600

    init(directory: URL = OfflineTileLibrary.defaultDirectory,
         bundledExtract: URL? = Bundle.main.url(forResource: "osm-campsites", withExtension: "json")) {
        fileURL = directory.appendingPathComponent("official-campgrounds.json")
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([String: [Campsite]].self, from: data) {
            official = saved.values.flatMap { $0 }
        }
        let loaded = CommunityCampsites.load(from: bundledExtract)
        community = loaded.sites
        communityDate = loaded.generated
    }

    var hasUSSites: Bool { official.contains { $0.source == CampSource.usfs } }

    /// Refreshes the saved campgrounds when they're over a fortnight old. US sites are fetched only
    /// once the map has shown the US (`area`), so people elsewhere never download them.
    func refreshIfStale(offlineOnly: Bool, area: BoundingBox? = nil) async {
        guard !offlineOnly, !refreshing else { return }
        let hasUS = hasUSSites
        let wantsUS = hasUS || (area?.intersects(TileSources.usCoverage) ?? false)
        let modified = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let fresh = (modified.map { Date().timeIntervalSince($0) < Self.maxAge } ?? false) && !official.isEmpty
        let missingUS = wantsUS && !hasUS
        if fresh && !missingUS { return }
        // Don't retry a failed US fetch on every map move.
        if fresh, let last = lastUSAttempt, Date().timeIntervalSince(last) < 600 { return }
        refreshing = true
        defer { refreshing = false }
        if missingUS { lastUSAttempt = Date() }
        let fetched: [String: [Campsite]]
        if fresh {
            fetched = (try? await OfficialCampgrounds.usfs()).map { [CampSource.usfs: $0] } ?? [:]
        } else {
            fetched = await OfficialCampgrounds.fetch(includeUS: wantsUS)
        }
        guard !fetched.isEmpty else { return }
        // Keep the previous data for any source that failed this time.
        var bySource = Dictionary(grouping: official, by: { $0.source ?? "" })
        for (source, sites) in fetched { bySource[source] = sites }
        official = bySource.values.flatMap { $0 }
        if let data = try? JSONEncoder().encode(bySource) { try? data.write(to: fileURL, options: .atomic) }
    }

    /// Everything to show in `box`, de-duplicated, richest version first.
    func sites(in box: BoundingBox, rich: [Campsite]) -> [Campsite] {
        Self.merge(rich: rich,
                   official: official.filter { box.contains($0.coordinate) }.sorted { Self.rank($0) < Self.rank($1) },
                   community: community.filter { box.contains($0.coordinate) })
    }

    /// Folds duplicates: an official names-only site near a rich one is dropped; a community site
    /// near an official one lends it its facilities instead of getting its own pin.
    nonisolated static func merge(rich: [Campsite], official: [Campsite], community: [Campsite]) -> [Campsite] {
        var result = rich
        for o in official where !result.contains(where: { near($0, o, meters: 250) }) {
            result.append(o)
        }
        for c in community {
            if let i = result.firstIndex(where: { !$0.isCommunity && near($0, c, meters: 250) }) {
                if result[i].amenities == nil && result[i].detail == nil, let a = c.amenities, !a.isEmpty,
                   result[i].communityAmenities == nil {
                    result[i].communityAmenities = a
                    if result[i].website == nil { result[i].website = c.website }
                }
            } else if !result.contains(where: { $0.isCommunity && near($0, c, meters: 40) }) {
                result.append(c)
            }
        }
        return result
    }

    /// State sources first, so they win when two official sources list the same campground.
    nonisolated private static func rank(_ s: Campsite) -> Int {
        switch s.source {
        case CampSource.nswParks, CampSource.vicmap: return 0
        default: return 1
        }
    }

    nonisolated private static func near(_ a: Campsite, _ b: Campsite, meters: Double) -> Bool {
        let dLat = (a.lat - b.lat) * 110_540
        let dLon = (a.lon - b.lon) * 111_320 * cos(a.lat * .pi / 180)
        return dLat * dLat + dLon * dLon <= meters * meters
    }
}
