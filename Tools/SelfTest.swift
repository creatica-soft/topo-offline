import Foundation
import MapKit

let dataDir = URL(fileURLWithPath: CommandLine.arguments[1])
func check(_ ok: Bool, _ msg: String) { print(ok ? "PASS" : "FAIL", msg); if !ok { exit(1) } }

// 1. Tile math
let k = TileKey(z: 16, x: TileMath.tileX(lon: 150.31, z: 16), y: TileMath.tileY(lat: -33.71, z: 16))
let b = TileMath.bbox(of: k)
check(b.contains(.init(latitude: -33.71, longitude: 150.31)), "tile \(k) contains Katoomba point")
let big = BoundingBox(minLat: -34.0, minLon: 150.0, maxLat: -33.36, maxLon: 150.77)  // ~70 x 70 km
print("     70x70 km, zoom 9-16:", TileMath.tileCount(for: big, zooms: 9...16), "tiles")

// 1b. Which state map is chosen for well-known spots (state border is the tricky part)
let spots: [(String, Double, Double, String)] = [
    ("Mt Barney (QLD)", -28.28, 152.70, "qld-topo"), ("Lamington (QLD)", -28.23, 153.12, "qld-topo"),
    ("Girraween (QLD)", -28.83, 151.93, "qld-topo"), ("Brisbane", -27.47, 153.03, "qld-topo"),
    ("Carnarvon Gorge (QLD)", -25.07, 148.23, "qld-topo"), ("Mt Warning (NSW)", -28.40, 153.27, "nsw-topo"),
    ("Bald Rock (NSW)", -28.85, 152.06, "nsw-topo"), ("Mt Kaputar (NSW)", -30.27, 150.16, "nsw-topo"),
    ("Katoomba (NSW)", -33.71, 150.31, "nsw-topo"), ("Kosciuszko (NSW)", -36.46, 148.26, "nsw-topo"),
    ("Cradle Mtn (TAS)", -41.68, 145.95, "tas-topo"), ("Grampians (VIC)", -37.15, 142.45, "ga-topo"),
    ("Uluru (NT)", -25.34, 131.03, "ga-topo"),
]
for (name, lat, lon, want) in spots {
    let got = TileSources.best(for: .init(latitude: lat, longitude: lon)).id
    check(got == want, "\(name) -> \(got)")
}
// Sticking with the current map where both cover the spot, but leaving it when it doesn't
check(TileSources.best(for: .init(latitude: -28.28, longitude: 152.70), preferring: TileSources.nsw).id == "qld-topo",
      "NSW selected + Mt Barney -> switches to QLD")

// 2. Download small NSW + QLD areas through the real DownloadManager
let library = OfflineTileLibrary(directory: dataDir)
let store = RegionStore(library: library)
let dm = DownloadManager(store: store)

@MainActor func runDownload(_ name: String, _ area: BoundingBox, _ src: TileSource, _ z: ClosedRange<Int>) async -> OfflineRegion {
    let plan = DownloadManager.plan(name: name, area: area, source: src, zooms: z, includeOverview: true)!
    print("     \(name): \(DownloadManager.tileCount(of: plan)) tiles planned, est \(DownloadManager.estimatedBytes(of: plan)/1000) KB, layers: \(plan.layers.map { "\($0.sourceID) z\($0.minZoom)-\($0.maxZoom)" })")
    let t0 = Date()
    dm.start(plan)
    while dm.isRunning { try? await Task.sleep(nanoseconds: 200_000_000) }
    let p = dm.progress
    print("     done=\(p.done) failed=\(p.failed) bytes=\(p.bytes/1000) KB in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s, state=\(dm.state)")
    return store.regions.first { $0.id == plan.id }!
}

let katoomba = BoundingBox(minLat: -33.725, minLon: 150.30, maxLat: -33.705, maxLon: 150.32)
let r1 = await runDownload("Katoomba", katoomba, TileSources.nsw, 12...16)
check(r1.isComplete && r1.failedTiles == 0, "NSW region complete")
let barney = BoundingBox(minLat: -28.29, minLon: 152.69, maxLat: -28.28, maxLon: 152.70)
let r2 = await runDownload("Mt Barney", barney, TileSources.qld, 14...16)
check(r2.isComplete, "QLD region complete")

// 2b. Place-name search
let barneyCentre = CLLocationCoordinate2D(latitude: -28.28, longitude: 152.70)
check(Gazetteer.tokens(of: "Mt. Barney's") == ["mount", "barneys"], "query normalising: Mt. Barney's -> mount barneys")
let s1 = try await Gazetteer.search("mt barney", near: barneyCentre)
print("     'mt barney' top 3:", s1.prefix(3).map { "\($0.name) (\($0.feature), \(String(format: "%.1f", $0.distanceKm(from: barneyCentre))) km)" })
check(s1.first?.name == "Mount Barney" && s1.first!.distanceKm(from: barneyCentre) < 3, "'mt barney' near the mountain -> Mount Barney first")
let cradle = CLLocationCoordinate2D(latitude: -41.68, longitude: 145.95)
let s2 = try await Gazetteer.search("overland track", near: cradle)
check(s2.first?.name == "Overland Track", "'overland track' -> \(s2.first?.name ?? "nothing") (\(s2.first?.feature ?? ""))")
let s3 = try await Gazetteer.search("six foot", near: CLLocationCoordinate2D(latitude: -33.71, longitude: 150.31))
check(s3.prefix(3).contains { $0.name == "Six Foot Track" }, "'six foot' near Katoomba -> Six Foot Track in top 3")
let brisbane = CLLocationCoordinate2D(latitude: -27.40, longitude: 152.85)
for q in ["D'Aguilar", "d\u{2019}aguilar", "daguilar range", "daguilar", "aguilar"] {
    let r = try await Gazetteer.search(q, near: brisbane)
    check(r.first?.name.contains("D'Aguilar") == true, "'\(q)' -> \(r.first?.name ?? "nothing")")
}
let s5 = try await Gazetteer.search("oreillys", near: CLLocationCoordinate2D(latitude: -28.23, longitude: 153.13))
check(s5.contains { $0.name.hasPrefix("O'Reilly") }, "'oreillys' -> \(s5.first?.name ?? "nothing")")
let s4 = try await Gazetteer.search("barney's gap", near: nil)
check(s4.contains { $0.name == "Barneys Gap" }, "'barney\'s gap' -> Barneys Gap")
let areaNames = try await Gazetteer.names(in: BoundingBox(minLat: -28.37, minLon: 152.6, maxLat: -28.19, maxLon: 152.8))
check(areaNames.count > 20, "names in a 20 km area around Mt Barney: \(areaNames.count)")
check(r2.namesFileName != nil, "QLD download saved its place names")
let offlineHits = library.searchNames("barney", near: barneyCentre)
check(!offlineHits.isEmpty, "offline search 'barney' finds \(offlineHits.map(\.name))")

// 2c. Walking tracks
check(TrackSources.titleCase("LILA FALLS-LEURA FOREST WALKING TRACK") == "Lila Falls-Leura Forest Walking Track", "NSW name title-casing")
check(TrackSources.cleanQLDName("BB - Lower Bellbird circuit") == "Lower Bellbird circuit", "QLD prefix 'BB - ' removed")
check(TrackSources.cleanQLDName("BB Border Track (Great Walk)") == "Border Track (Great Walk)", "QLD prefix 'BB ' removed")
check(TrackSources.cleanQLDName("GM - DUA - Paths") == nil, "QLD generic 'Paths' treated as unnamed")
check(TrackSources.cleanQLDName("Ships Stern Circuit") == "Ships Stern Circuit", "QLD normal name unchanged")
check(TrackSources.capitalizeWords("Ships Stern circuit") == "Ships Stern Circuit", "capitalise: Ships Stern Circuit")
check(TrackSources.capitalizeWords("nixons creek to O'Reilly's") == "Nixons Creek to O'Reilly's", "capitalise keeps 'to' and O'Reilly's")
let katoombaC = CLLocationCoordinate2D(latitude: -33.71, longitude: 150.31)
for (q, c, want) in [("federal pass", katoombaC, "Federal Pass"),
                     ("ships stern", CLLocationCoordinate2D(latitude: -28.23, longitude: 153.13), "Ships Stern"),
                     ("face track", cradle, "Face Track")] {
    let found = try await TrackSources.search(q, near: c)
    let hit = found.first { $0.displayName.contains(want) }
    check(hit != nil && hit!.lengthKm > 0.3, "track search '\(q)' -> \(hit.map { "\($0.displayName), \($0.kind), \(String(format: "%.1f", $0.lengthKm)) km, \($0.segments.count) segments" } ?? "nothing")")
}
// Tap on a known track (online): the middle of Federal Pass
if let fp = try await TrackSources.search("federal pass", near: katoombaC).first {
    let mid = fp.segments[fp.segments.count / 2].points
    let tapped = await TrackLookup.track(at: mid[mid.count / 2], within: 30, library: OfflineTileLibrary(directory: dataDir.appendingPathComponent("empty")), offlineOnly: false)
    check(tapped?.name == fp.name, "tap on Federal Pass (online) -> \(tapped?.displayName ?? "nothing")")
}
// Downloaded areas saved their tracks; tap works offline
let r1now = store.regions.first { $0.id == r1.id }!
check(r1now.tracksFileName != nil, "Katoomba download saved its tracks")
let saved = try JSONDecoder().decode([TrackSegment].self, from: Data(contentsOf: library.fileURL(r1now.tracksFileName!)))
print("     Katoomba area tracks: \(saved.count) segments, named: \(Set(saved.compactMap(\.name)).sorted().prefix(6))")
if let seg = saved.first(where: { $0.name != nil }) ?? saved.first {
    let p = seg.points[seg.points.count / 2]
    let offlineTap = await TrackLookup.track(at: p, within: 20, library: library, offlineOnly: true)
    check(offlineTap != nil, "offline tap on a downloaded track -> \(offlineTap?.displayName ?? "nothing")")
}
check(await TrackLookup.track(at: CLLocationCoordinate2D(latitude: -25.0, longitude: 135.0), within: 20, library: library, offlineOnly: true) == nil,
      "offline tap in the middle of nowhere -> nothing")

// Somerset Trail (QLD): its pieces have different internal names; all share visitor_id "Somerset trail"
let somersetC = CLLocationCoordinate2D(latitude: -27.09, longitude: 152.69)
let somerset = try await TrackSources.search("somerset trail", near: somersetC).first { $0.displayName == "Somerset Trail" }
check(somerset != nil && somerset!.segments.count >= 6 && somerset!.lengthKm > 10,
      "QLD 'somerset trail' highlighted as a whole: \(somerset.map { "\($0.segments.count) pieces, \(String(format: "%.1f", $0.lengthKm)) km" } ?? "nothing")")
let bullBreak = CLLocationCoordinate2D(latitude: -27.0859, longitude: 152.6873)  // the "Bull Boundary Break" piece
let tappedSomerset = await TrackLookup.track(at: bullBreak, within: 25, library: OfflineTileLibrary(directory: dataDir.appendingPathComponent("empty3")), offlineOnly: false)
check(tappedSomerset?.displayName == "Somerset Trail" && tappedSomerset!.segments.count >= 6,
      "tap on a differently named piece -> whole Somerset Trail (\(tappedSomerset?.segments.count ?? 0) pieces)")

// 2d. Victoria: tracks from Vicmap (WFS), drawn on the map when zoomed in
let hallsGap = CLLocationCoordinate2D(latitude: -37.14, longitude: 142.52)
let gpt = try await TrackSources.search("peaks trail", near: hallsGap)
let gptHit = gpt.first { $0.displayName == "Grampians Peaks Trail" }
check(gptHit != nil, "VIC search 'peaks trail' -> \(gptHit.map { "\($0.displayName), \(String(format: "%.0f", $0.lengthKm)) km, \($0.segments.count) segments" } ?? "nothing")")
let grampiansBox = BoundingBox(minLat: -37.30, minLon: 142.40, maxLat: -37.10, maxLon: 142.60)
let vicSegs = try await TrackSources.segments(in: grampiansBox, layers: [TrackSources.vicTrails])
check(vicSegs.count > 100 && vicSegs.allSatisfy { $0.state == "VIC" }, "VIC trails in a 20 km Grampians area: \(vicSegs.count)")
if let mf = vicSegs.first(where: { $0.name == "Mackenzie Falls Lookout Walk" }) {
    let p = mf.points[mf.points.count / 2]
    let tapped = await TrackLookup.track(at: p, within: 25, library: OfflineTileLibrary(directory: dataDir.appendingPathComponent("empty2")), offlineOnly: false)
    check(tapped?.name == "Mackenzie Falls Lookout Walk", "VIC tap (online) -> \(tapped?.displayName ?? "nothing")")
}
let visible = VisibleTracks()
let smallGrampians = BoundingBox(minLat: -37.17, minLon: 142.48, maxLat: -37.11, maxLon: 142.56)
visible.update(area: smallGrampians, zoom: 13, offlineOnly: false, library: library)
await visible.settle()
check(visible.segments.count > 20, "drawn tracks, Grampians at zoom 13 (online): \(visible.segments.count)")
visible.update(area: smallGrampians, zoom: 10, offlineOnly: false, library: library)
check(visible.segments.isEmpty, "no drawn tracks when zoomed out (zoom 10)")
visible.update(area: katoomba, zoom: 14, offlineOnly: false, library: library)
await visible.settle()
check(visible.segments.isEmpty, "no drawn tracks in NSW (the topo map already shows them)")
// Offline in Victoria: download a small area (national map + names + tracks), then draw from it
let vicArea = BoundingBox(minLat: -37.16, minLon: 142.50, maxLat: -37.13, maxLon: 142.54)
let r3 = await runDownload("Halls Gap", vicArea, TileSources.australia, 10...12)
check(r3.tracksFileName != nil && r3.isComplete, "VIC download saved tracks")
visible.update(area: vicArea, zoom: 14, offlineOnly: true, library: library)
check(!visible.segments.isEmpty, "drawn tracks offline from the download: \(visible.segments.count)")

// 2e. Victorian campsites and closures
let day: TimeInterval = 86_400
let t0 = Date(timeIntervalSince1970: 1_800_000_000)
check(ClosureInfo(start: t0 - 10 * day, reopen: t0 + 10 * day).status(at: t0) == .current, "closure in force -> current")
check(ClosureInfo(start: t0 - 10 * day, reopen: t0 - 1 * day).status(at: t0) == .none, "reopening date passed -> not shown")
check(ClosureInfo(start: t0 + 20 * day, reopen: t0 + 30 * day).status(at: t0) == .upcoming(t0 + 20 * day), "starts in 20 days -> upcoming")
check(ClosureInfo(start: t0 + 90 * day, reopen: nil).status(at: t0) == .none, "starts in 90 days -> not shown yet")
check(ClosureInfo(start: nil, reopen: nil).status(at: t0) == .current, "no dates -> current")
check(VicParkData.expandRoadName("Joes Trk") == "Joes Track", "road name 'Joes Trk' -> 'Joes Track'")
check(VicParkData.tidy("FIRE\t") == "Fire" && VicParkData.tidy("NOT RELEVANT") == nil, "reason tidy-up")
check(VicParkData.tidy("SEASONCLOSUREUPD") == "Seasonal closure" && VicParkData.expandRoadName("Lay Flne") == "Lay Fireline", "odd labels cleaned")
let parkInfo = ParkInfoStore(directory: dataDir)
await parkInfo.refreshIfStale(offlineOnly: false)
let snap = parkInfo.snapshot
check(snap != nil, "Victorian park data fetched")
if let snap {
    let closedSites = snap.sites.filter { $0.closureStatus != .none }
    let staleSites = snap.sites.filter { $0.closure != nil && $0.closureStatus == .none }
    print("     sites: \(snap.sites.count) (\(snap.sites.filter { $0.kind == "Hut" }.count) huts), closed or closing soon: \(closedSites.count), stale closures ignored: \(staleSites.count)")
    for site in closedSites.prefix(4) { print("       \(site.name): \(site.closure?.reason ?? "-"), \(site.closure!.summary())") }
    let tracksClosed = snap.closedLines.filter { $0.kind == .track }, roadsClosed = snap.closedLines.filter { $0.kind == .road }
    print("     closed tracks: \(tracksClosed.count), closed roads (joined per road): \(roadsClosed.count)")
    for line in (tracksClosed.prefix(3) + roadsClosed.prefix(3)) { print("       \(line.kind): \(line.name): \(line.closure.reason ?? "-"), \(line.closure.summary())") }
    check(snap.sites.count > 400, "sites > 400")
    check(snap.closedLines.allSatisfy { $0.closure.status() != .none }, "no stale closed lines kept")
    if let line = tracksClosed.first, let p = line.segments.first?.points.first {
        check(parkInfo.closure(near: p, within: 30)?.id == line.id, "tap on a closed track finds it")
    }
    let reloaded = ParkInfoStore(directory: dataDir)
    check(reloaded.snapshot?.sites.count == snap.sites.count, "snapshot saved for offline use")
}

// 2f. New Zealand
check(DOC.cleanName("Oturere Hut to Emerald Lakes Track (TNC)") == "Oturere Hut to Emerald Lakes Track", "DOC: code '(TNC)' removed")
check(DOC.cleanName("Upper Tama Lakes Tk") == "Upper Tama Lakes Track", "DOC: 'Tk' -> 'Track'")
check(DOC.cleanName("T3: Kahikanui Track") == "Kahikanui Track", "DOC: 'T3: ' code removed")
check(DOC.cleanName("TAC Soda Springs Jn-Red Crater") == "Tongariro Alpine Crossing: Soda Springs Junction-Red Crater",
      "DOC: TAC -> \(DOC.cleanName("TAC Soda Springs Jn-Red Crater") ?? "nil")")
check(DOC.cleanName("T3 Whangaehu Hut (RTMT) (NZAC)") == "Whangaehu Hut", "DOC: 'T3 ... (RTMT) (NZAC)' -> \(DOC.cleanName("T3 Whangaehu Hut (RTMT) (NZAC)") ?? "nil")")
let tongariro = CLLocationCoordinate2D(latitude: -39.13, longitude: 175.65)
let tama = try await TrackSources.search("tama lakes", near: tongariro)
check(tama.contains { $0.displayName == "Upper Tama Lakes Track" }, "DOC track search 'tama lakes' -> \(tama.map { "\($0.displayName) (\($0.kind), \(String(format: "%.1f", $0.lengthKm)) km)" }.prefix(3))")
let tongariroTracks = try await TrackSources.segments(in: BoundingBox(minLat: -39.3, minLon: 175.5, maxLat: -39.0, maxLon: 175.8), layers: [TrackSources.nzTracks])
check(tongariroTracks.count > 20 && tongariroTracks.allSatisfy { $0.state == "NZ" }, "DOC tracks around Tongariro: \(tongariroTracks.count)")
let nzPark = try await NZParkData.fetch()
let huts = nzPark.sites.filter { $0.kind == "Hut" }, camps = nzPark.sites.filter { $0.kind == "Campsite" }
print("     DOC: \(huts.count) huts (\(huts.filter { $0.closureStatus != .none }.count) closed), \(camps.count) campsites (\(camps.filter { $0.closureStatus != .none }.count) closed), \(nzPark.closed.count) closed tracks")
for site in huts.filter({ $0.name.contains("Mangatepopo") || $0.name.contains("Waihohonu") }).prefix(2) { print("       \(site.name): \(site.detail ?? "")") }
for line in nzPark.closed.prefix(3) { print("       closed: \(line.name)") }
check(huts.count > 800 && camps.count > 250 && nzPark.closed.count > 30, "DOC huts, campsites and closed tracks loaded")
check(huts.allSatisfy { $0.region == "NZ" } && huts.contains { ($0.detail ?? "").contains("bunks") }, "hut details include bunks")
let tNames = Date()
let nzNames = try await NZPlaceNames.fetchAll()
print("     NZ place names: \(nzNames.count) in \(String(format: "%.1f", Date().timeIntervalSince(tNames))) s")
check(nzNames.count > 50_000, "NZ Gazetteer downloaded")
library.setNationalNames(nzNames)
let tSearch = Date()
let ngau = library.searchNames("ngauruhoe", near: tongariro)
let searchMs = Date().timeIntervalSince(tSearch) * 1000
check(ngau.first?.name == "Mount Ngauruhoe", "NZ search 'ngauruhoe' -> \(ngau.first?.name ?? "nothing") (\(Int(searchMs)) ms, on-device)")
let cook = library.searchNames("mt cook", near: CLLocationCoordinate2D(latitude: -43.7, longitude: 170.1))
check(cook.prefix(3).contains { $0.name == "Aoraki/Mount Cook" }, "NZ search 'mt cook' -> \(cook.prefix(3).map(\.name))")
check(OfflineTileLibrary(directory: dataDir).nationalNamesCount == nzNames.count, "NZ names saved for offline use")
check(TileSources.nz.isAvailable == !Secrets.linzAPIKey.isEmpty, "NZ topo available only with a LINZ key (key set: \(!Secrets.linzAPIKey.isEmpty))")
if TileSources.nz.isAvailable {
    var have: [Int] = []
    for z in 5...18 {
        let key = TileKey(z: z, x: TileMath.tileX(lon: 175.65, z: z), y: TileMath.tileY(lat: -39.13, z: z))
        let (data, resp) = try await URLSession.shared.data(from: TileSources.nz.tileURL(key))
        if (resp as? HTTPURLResponse)?.statusCode == 200, TileImage.isImage(data) { have.append(z) }
    }
    print("     LINZ topo-raster zooms with tiles at Tongariro: \(have) (TileSource.nz.maxZoom = \(TileSources.nz.maxZoom))")
}

// 2g. Campgrounds: official, community (bundled OpenStreetMap extract) and NZ freedom-camping rules
let extractURL = URL(fileURLWithPath: CommandLine.arguments[2])
let community = CommunityCampsites.load(from: extractURL)
check(community.sites.count > 10_000, "bundled OSM campsites: \(community.sites.count) (extract of \(community.generated ?? "?"))")
check(CommunityCampsites.amenities(["fee": "no", "toilets": "yes", "drinking_water": "no", "dog": "leashed", "backcountry": "yes"])
      == ["Free", "Toilets", "No drinking water", "Hike-in", "Dogs allowed"], "OSM tags -> amenities")
let officialSites = await OfficialCampgrounds.fetch()
print("     official campgrounds: " + officialSites.map { "\($0.key) \($0.value.count)" }.sorted().joined(separator: ", "))
check((officialSites[CampSource.nswParks]?.count ?? 0) > 500 && (officialSites[CampSource.vicmap]?.count ?? 0) > 1000
      && (officialSites[CampSource.gazetteer]?.count ?? 0) > 300, "official campgrounds from NSW parks, Vicmap and gazetteer")
// Merge rules
func site(_ id: String, _ lat: Double, _ lon: Double, source: String?, amenities: [String]? = nil, detail: String? = nil) -> Campsite {
    Campsite(id: id, name: id, kind: "Campsite", camping: true, lat: lat, lon: lon, detail: detail, source: source, amenities: amenities)
}
let merged = CampgroundStore.merge(
    rich: [site("rich", -37.0, 145.0, source: nil, detail: "DEECA site")],
    official: [site("dupOfRich", -37.0009, 145.0, source: CampSource.vicmap),       // ~100 m away -> dropped
               site("official", -37.1, 145.0, source: CampSource.vicmap)],
    community: [site("osmNearOfficial", -37.1008, 145.0, source: CampSource.osm, amenities: ["Toilets"]),  // -> attached
                site("osmAlone", -37.3, 145.0, source: CampSource.osm, amenities: ["Free"])])
check(merged.map(\.id) == ["rich", "official", "osmAlone"], "merge keeps one pin per campground: \(merged.map(\.id))")
check(merged.first { $0.id == "official" }?.communityAmenities == ["Toilets"], "community facilities attached to the official pin")
// A real area: around Halls Gap (Grampians)
let campStore = CampgroundStore(directory: dataDir, bundledExtract: extractURL)
await campStore.refreshIfStale(offlineOnly: false)
let gramp = BoundingBox(minLat: -37.35, minLon: 142.3, maxLat: -37.0, maxLon: 142.7)
let grampSites = campStore.sites(in: gramp, rich: parkInfo.sites(in: gramp))
print("     Grampians: \(grampSites.count) pins (\(grampSites.filter(\.isCommunity).count) community, \(grampSites.filter { $0.communityAmenities != nil }.count) official with community facilities)")
for s in grampSites.prefix(5) { print("       \(s.name) [\(s.source ?? s.region ?? "vic")] \((s.amenities ?? s.communityAmenities ?? []).prefix(4).joined(separator: ", "))") }
check(!grampSites.isEmpty, "Grampians campgrounds shown")
check(CampgroundStore(directory: dataDir, bundledExtract: nil).official.count == campStore.official.count, "official campgrounds saved for offline use")
// NZ freedom-camping rules
let nzRules = try await NZParkData.fetch().rules
check(nzRules.count > 200, "NZ freedom-camping rule areas: \(nzRules.count) (\(nzRules.filter(\.prohibited).count) prohibited)")
let square = CampingRule(id: "t", name: "t", prohibited: true, conditions: [], location: nil,
                         rings: [[170.0, -44.0, 170.1, -44.0, 170.1, -43.9, 170.0, -43.9, 170.0, -44.0]])
check(square.contains(CLLocationCoordinate2D(latitude: -43.95, longitude: 170.05)) &&
      !square.contains(CLLocationCoordinate2D(latitude: -43.85, longitude: 170.05)), "tap inside/outside a rule area")

// 2h. Elevation profiles
let noDownloads = OfflineTileLibrary(directory: dataDir.appendingPathComponent("empty-elev"))
let kosci = await Elevation.elevation(at: CLLocationCoordinate2D(latitude: -36.45578, longitude: 148.26326), library: noDownloads, offlineOnly: false)
check(kosci.map { abs($0 - 2228) < 20 } == true, "Kosciuszko summit elevation: \(kosci.map { String(format: "%.0f", $0) } ?? "nil") m (official 2228)")
// Ngauruhoe is a steep cone, so take the highest point within ~400 m of the listed summit position.
var ngauruhoe = -Double.infinity
for dy in stride(from: -0.004, through: 0.004, by: 0.0004) {
    for dx in stride(from: -0.005, through: 0.005, by: 0.0005) {
        if let e = await Elevation.elevation(at: CLLocationCoordinate2D(latitude: -39.1569 + dy, longitude: 175.6322 + dx),
                                             library: noDownloads, offlineOnly: false) { ngauruhoe = max(ngauruhoe, e) }
    }
}
check(abs(ngauruhoe - 2291) < 40, "Ngauruhoe summit (highest nearby): \(String(format: "%.0f", ngauruhoe)) m (official 2291)")
// Chaining: pieces shuffled and some reversed still make one line
let line = (0...30).map { CLLocationCoordinate2D(latitude: -33.7, longitude: 150.3 + Double($0) * 0.001) }
let pieces = [Array(line[10...20]), Array(line[0...10].reversed()), Array(line[20...30])]
let chained = TrackPath.chain(pieces)
check(chained.usedAll && abs(TrackPath.length(chained.path) - TrackPath.length(line)) < 1, "pieces joined into one line (\(Int(TrackPath.length(chained.path))) m)")
check(Elevation.climb([100, 101, 104, 103, 110, 90], threshold: 3) == (10, 20), "climb adds up rises/falls over the threshold")
for (q, c) in [("federal pass", katoombaC), ("ships stern", CLLocationCoordinate2D(latitude: -28.23, longitude: 153.13))] {
    if let t = try await TrackSources.search(q, near: c).first,
       let p = await Elevation.profile(for: t, library: noDownloads, offlineOnly: false) {
        print("     \(t.displayName): \(String(format: "%.1f", p.lengthKm)) km, up \(Int(p.ascent)) m, down \(Int(p.descent)) m, \(Int(p.lowest))–\(Int(p.highest)) m, \(p.distances.count) samples, whole track: \(p.coversWholeTrack)")
        check(p.distances.count > 50 && p.highest > p.lowest + 50, "profile for \(t.displayName)")
    } else { check(false, "profile for '\(q)'") }
}
// Offline: the Katoomba download included elevation tiles
check(store.regions.first { $0.id == r1.id }?.layers.contains { $0.sourceID == "terrain" } == true, "area downloads include elevation tiles")
let offlineTrack = TrackSources.group(saved).first { $0.name != nil }
if let offlineTrack {
    let p = await Elevation.profile(for: offlineTrack, library: library, offlineOnly: true)
    check(p != nil, "profile offline from downloaded elevation: \(offlineTrack.displayName) \(p.map { "up \(Int($0.ascent)) m" } ?? "none")")
}
check(await Elevation.profile(for: Track(segments: [TrackSegment(layer: "x", name: "x", kind: "x", state: "NSW", coords: [140.5, -30.0, 140.51, -30.0])])!,
                              library: noDownloads, offlineOnly: true) == nil, "no profile offline without downloaded elevation")

// 3. Read back via the library (as the map does)
let nswTile = library.tile(sourceID: "nsw-topo", key: k)
check(nswTile != nil && TileImage.isImage(nswTile!), "NSW z16 tile readable offline (\(nswTile?.count ?? 0) bytes)")
let gaKey = TileKey(z: 12, x: TileMath.tileX(lon: 150.31, z: 12), y: TileMath.tileY(lat: -33.71, z: 12))
check(library.tile(sourceID: "ga-topo", key: gaKey) != nil, "GA overview z12 tile readable offline")
let qk = TileKey(z: 16, x: TileMath.tileX(lon: 152.695, z: 16), y: TileMath.tileY(lat: -28.285, z: 16))
let qt = library.tile(sourceID: "qld-topo", key: qk)
check(qt != nil && qt!.prefix(2) == Data([0xFF, 0xD8]), "QLD tile stored re-encoded as JPEG (\(qt?.count ?? 0) bytes vs ~80-120 KB PNG)")
check(library.tile(sourceID: "nsw-topo", key: TileKey(z: 16, x: 0, y: 0)) == nil, "tile outside region -> nil")

// 4. Resume: restarting a complete region skips everything
dm.start(r1)
while dm.isRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
check(dm.progress.bytes == 0 && dm.progress.failed == 0, "resume re-uses existing tiles (0 bytes downloaded)")

// 5. Overlay in offline-only mode, including over-zoom past z16
let overlay = TopoTileOverlay(source: TileSources.nsw, library: library, offlineOnly: true)
func load(_ z: Int, _ x: Int, _ y: Int) async -> Data? {
    await withCheckedContinuation { c in
        overlay.loadTile(at: MKTileOverlayPath(x: x, y: y, z: z, contentScaleFactor: 2)) { d, _ in c.resume(returning: d) }
    }
}
check(await load(16, k.x, k.y) != nil, "overlay serves z16 offline")
let z18 = await load(18, k.x * 4 + 1, k.y * 4 + 2)
let img = z18.flatMap(TileImage.decode)
check(img?.width == 256 && img?.height == 256, "overlay over-zooms z18 from z16 (256x256)")
if let z18 { try? z18.write(to: dataDir.appendingPathComponent("overzoom-z18.png")) }

// 5b. QLD server goes to z17 but the download stopped at z16: offline z17/z18 must enlarge z16, not go blank
let qOverlay = TopoTileOverlay(source: TileSources.qld, library: library, offlineOnly: true)
func loadQ(_ key: TileKey) async -> Data? {
    await withCheckedContinuation { c in
        qOverlay.loadTile(at: MKTileOverlayPath(x: key.x, y: key.y, z: key.z, contentScaleFactor: 2)) { d, _ in c.resume(returning: d) }
    }
}
for z in [17, 18, 20] {
    let d = z - 16
    let img = (await loadQ(TileKey(z: z, x: (qk.x << d) + 1, y: (qk.y << d) + 1))).flatMap(TileImage.decode)
    check(img?.width == 256, "QLD offline z\(z) enlarged from downloaded z16")
}
check(await loadQ(TileKey(z: 17, x: 0, y: 0)) == nil, "QLD offline outside download -> nil (national map shows instead)")

// 6. Delete cleans up files
store.delete(r2)
let left = try FileManager.default.contentsOfDirectory(atPath: dataDir.path).filter { $0.contains(r2.id.uuidString) }
check(left.isEmpty, "delete removes region files")
print("     regions.json:", (try? String(contentsOf: dataDir.appendingPathComponent("regions.json"), encoding: .utf8))?.count ?? 0, "chars; total on disk:", store.totalBytes / 1000, "KB")
print("ALL CHECKS PASSED")
