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
    /// Regions whose campgrounds are wanted (the map has shown them); Australia always.
    @ObservationIgnored private var regions: Set<OfficialCampgrounds.Region>
    @ObservationIgnored private var lastAttempt: [OfficialCampgrounds.Region: Date] = [:]
    @ObservationIgnored private let regionsKey: String
    static let maxAge: TimeInterval = 14 * 24 * 3600

    /// Community (OpenStreetMap) extracts beyond Australia and New Zealand, loaded the first time
    /// the map shows their area.
    @ObservationIgnored private var pendingExtracts: [(area: BoundingBox, url: URL)]

    init(directory: URL = OfflineTileLibrary.defaultDirectory,
         bundledExtract: URL? = Bundle.main.url(forResource: "osm-campsites", withExtension: "json"),
         moreExtracts: [(area: BoundingBox, url: URL)] = CommunityCampsites.bundledRegions,
         regionsKey: String = "campgroundRegions") {
        fileURL = directory.appendingPathComponent("official-campgrounds.json")
        self.regionsKey = regionsKey
        var saved: [Campsite] = []
        if let data = try? Data(contentsOf: fileURL),
           let bySource = try? JSONDecoder().decode([String: [Campsite]].self, from: data) {
            saved = bySource.values.flatMap { $0 }
        }
        var regions: Set<OfficialCampgrounds.Region> = [.australia]
        for raw in UserDefaults.standard.stringArray(forKey: regionsKey) ?? [] {
            if let r = OfficialCampgrounds.Region(rawValue: raw) { regions.insert(r) }
        }
        // Campgrounds saved before regions were remembered.
        for r in OfficialCampgrounds.Region.allCases where saved.contains(where: { r.sources.contains($0.source ?? "") }) {
            regions.insert(r)
        }
        self.regions = regions
        official = saved
        let loaded = CommunityCampsites.load(from: bundledExtract)
        community = loaded.sites
        communityDate = loaded.generated
        pendingExtracts = moreExtracts
    }

    /// Loads any community extract covering `area` that isn't loaded yet (off the main thread).
    func loadCommunity(for area: BoundingBox) async {
        let due = pendingExtracts.filter { $0.area.intersects(area) }
        guard !due.isEmpty else { return }
        pendingExtracts.removeAll { e in due.contains { $0.url == e.url } }
        for extract in due {
            let url = extract.url
            let loaded = await Task.detached(priority: .utility) { CommunityCampsites.load(from: url) }.value
            community += loaded.sites
        }
    }

    func wants(_ region: OfficialCampgrounds.Region) -> Bool { regions.contains(region) }

    /// Refreshes the saved campgrounds when they're over a fortnight old. A region's sources are
    /// fetched only once the map has shown it (`area`), so people elsewhere never download them.
    /// Cheap to call on every map move.
    func refreshIfStale(offlineOnly: Bool, area: BoundingBox? = nil) async {
        if let area { await loadCommunity(for: area) }
        guard !offlineOnly, !refreshing else { return }
        if let area {
            let shown = OfficialCampgrounds.Region.allCases.filter { !regions.contains($0) && $0.isShown(by: area) }
            if !shown.isEmpty {
                regions.formUnion(shown)
                UserDefaults.standard.set(regions.map(\.rawValue), forKey: regionsKey)
            }
        }
        let have = Set(official.compactMap(\.source))
        let missing = regions.filter { !$0.sources.contains(where: have.contains) }
        let modified = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let fresh = (modified.map { Date().timeIntervalSince($0) < Self.maxAge } ?? false) && !official.isEmpty
        // Don't retry a failing region on every map move.
        let due = (fresh ? missing : regions).filter { lastAttempt[$0].map { Date().timeIntervalSince($0) > 600 } ?? true }
        guard !due.isEmpty else { return }
        refreshing = true
        defer { refreshing = false }
        for r in due { lastAttempt[r] = Date() }
        let fetched = await OfficialCampgrounds.fetch(regions: due)
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
        case CampSource.nswParks, CampSource.vicmap, CampSource.parksCanada, CampSource.bcRecSites, CampSource.usfs: return 0
        default: return 1
        }
    }

    nonisolated private static func near(_ a: Campsite, _ b: Campsite, meters: Double) -> Bool {
        let dLat = (a.lat - b.lat) * 110_540
        let dLon = (a.lon - b.lon) * 111_320 * cos(a.lat * .pi / 180)
        return dLat * dLat + dLon * dLon <= meters * meters
    }
}
