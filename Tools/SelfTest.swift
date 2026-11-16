import Foundation
import MapKit

setvbuf(stdout, nil, _IOLBF, 0)  // line by line, so a crash doesn't swallow the log
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
/// Geoscience Australia's gazetteer is sometimes very slow (tens of seconds): retry rather than
/// stop the whole test on one timeout.
func retrying<T>(_ what: String, _ work: () async throws -> T) async throws -> T {
    for attempt in 1...3 {
        do { return try await work() } catch where attempt < 3 {
            print("     \(what): \(error.localizedDescription), retrying")
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }
    fatalError("unreachable")
}
let barneyCentre = CLLocationCoordinate2D(latitude: -28.28, longitude: 152.70)
check(Gazetteer.tokens(of: "Mt. Barney's") == ["mount", "barneys"], "query normalising: Mt. Barney's -> mount barneys")
let s1 = try await retrying("gazetteer") { try await Gazetteer.search("mt barney", near: barneyCentre) }
print("     'mt barney' top 3:", s1.prefix(3).map { "\($0.name) (\($0.feature), \(String(format: "%.1f", $0.distanceKm(from: barneyCentre))) km)" })
check(s1.first?.name == "Mount Barney" && s1.first!.distanceKm(from: barneyCentre) < 3, "'mt barney' near the mountain -> Mount Barney first")
let cradle = CLLocationCoordinate2D(latitude: -41.68, longitude: 145.95)
let s2 = try await retrying("gazetteer") { try await Gazetteer.search("overland track", near: cradle) }
check(s2.first?.name == "Overland Track", "'overland track' -> \(s2.first?.name ?? "nothing") (\(s2.first?.feature ?? ""))")
let s3 = try await retrying("gazetteer") { try await Gazetteer.search("six foot", near: CLLocationCoordinate2D(latitude: -33.71, longitude: 150.31)) }
check(s3.prefix(3).contains { $0.name == "Six Foot Track" }, "'six foot' near Katoomba -> Six Foot Track in top 3")
let brisbane = CLLocationCoordinate2D(latitude: -27.40, longitude: 152.85)
for q in ["D'Aguilar", "d\u{2019}aguilar", "daguilar range", "daguilar", "aguilar"] {
    let r = try await retrying("gazetteer") { try await Gazetteer.search(q, near: brisbane) }
    check(r.first?.name.contains("D'Aguilar") == true, "'\(q)' -> \(r.first?.name ?? "nothing")")
}
let s5 = try await retrying("gazetteer") { try await Gazetteer.search("oreillys", near: CLLocationCoordinate2D(latitude: -28.23, longitude: 153.13)) }
check(s5.contains { $0.name.hasPrefix("O'Reilly") }, "'oreillys' -> \(s5.first?.name ?? "nothing")")
let s4 = try await retrying("gazetteer") { try await Gazetteer.search("barney's gap", near: nil) }
check(s4.contains { $0.name == "Barneys Gap" }, "'barney\'s gap' -> Barneys Gap")
let areaNames = try await retrying("gazetteer") { try await Gazetteer.names(in: BoundingBox(minLat: -28.37, minLon: 152.6, maxLat: -28.19, maxLon: 152.8)) }
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
check(DOC.cleanName("QCT - Torea to Kenepuru") == "Queen Charlotte Track: Torea to Kenepuru", "DOC: 'QCT - ' -> \(DOC.cleanName("QCT - Torea to Kenepuru") ?? "nil")")
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
    let nzKey = TileKey(z: 15, x: TileMath.tileX(lon: 175.65, z: 15), y: TileMath.tileY(lat: -39.13, z: 15))
    let (nzTile, _) = try await URLSession.shared.data(from: TileSources.nz.tileURL(nzKey))
    let nzImage = TileImage.decode(nzTile)
    check(TileSources.nz.storedFormat == "webp" && nzImage?.width == 256 && TileImage.overzoom(parent: nzTile, levels: 2, offsetX: 1, offsetY: 3) != nil,
          "NZ WebP tile decodes and enlarges (\(nzTile.count) bytes)")
}

// 2g. Campgrounds: official, community (bundled OpenStreetMap extract) and NZ freedom-camping rules
let extractURL = URL(fileURLWithPath: CommandLine.arguments[2])
let community = CommunityCampsites.load(from: extractURL)
check(community.sites.count > 10_000, "bundled OSM campsites: \(community.sites.count) (extract of \(community.generated ?? "?"))")
check(CommunityCampsites.amenities(["fee": "no", "toilets": "yes", "drinking_water": "no", "dog": "leashed", "backcountry": "yes"])
      == ["Free", "Toilets", "No drinking water", "Hike-in", "Dogs allowed"], "OSM tags -> amenities")
var officialSites = await OfficialCampgrounds.fetch()
for _ in 0..<2 where officialSites[CampSource.gazetteer] == nil {  // the gazetteer server is sometimes very slow
    print("     gazetteer campgrounds didn't arrive, retrying")
    officialSites.merge(await OfficialCampgrounds.fetch()) { old, _ in old }
}
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
// Pieces 3 km apart (a track following a road between walking sections) are bridged, and flagged
let far = [Array(line[0...10]), (0...10).map { CLLocationCoordinate2D(latitude: -33.7, longitude: 150.36 + Double($0) * 0.001) }]
let bridged = TrackPath.chain(far)
check(bridged.usedAll && bridged.bridged, "pieces with a 3 km gap are bridged and flagged")
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
// Every track saved with the area gets an offline profile, even where it runs past the edge
let savedTracks = TrackSources.group(saved).filter { $0.lengthKm > 0.3 }
var withProfile = 0
for t in savedTracks where await Elevation.profile(for: t, library: library, offlineOnly: true) != nil { withProfile += 1 }
check(withProfile == savedTracks.count, "offline profiles for tracks leaving the downloaded area: \(withProfile)/\(savedTracks.count)")
check(await Elevation.profile(for: Track(segments: [TrackSegment(layer: "x", name: "x", kind: "x", state: "NSW", coords: [140.5, -30.0, 140.51, -30.0])])!,
                              library: noDownloads, offlineOnly: true) == nil, "no profile offline without downloaded elevation")

// 2h. Routes: track routing, GPX, progress along a route, GPS fix filtering, saving
do {
    // Two lines meeting in a T with an 8 m gap (as in published data): routing joins them
    let base = CLLocationCoordinate2D(latitude: -33.7, longitude: 150.3)
    func off(_ e: Double, _ n: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: base.latitude + n / 110_540, longitude: base.longitude + e / (111_320 * cos(base.latitude * .pi / 180)))
    }
    let main = [off(0, 0), off(500, 0), off(1000, 0)]
    let branch = [off(700, 8), off(700, 600)]
    let r = TrackRouter.route(from: off(10, 5), to: off(705, 590), along: [main, branch], snap: 30)
    let rLen = r.map(TrackPath.length) ?? 0
    check(r != nil && abs(rLen - (690 + 8 + 592)) < 20, "router follows a T junction with a gap (\(Int(rLen)) m)")
    check(TrackRouter.route(from: off(10, 5), to: off(705, 900), along: [main, branch], snap: 30) == nil, "router: point off the network -> no route")

    // Online: two points on Federal Pass Walking Track
    if let fp = try await TrackSources.search("federal pass", near: katoombaC).first {
        let line = TrackPath.chain(fp.segments.map(\.points)).path
        let s = TrackPath.sample(line, maxSamples: 100, minStep: 10)
        let i = s.points.count / 5, j = s.points.count * 3 / 5
        let along = s.distances[j] - s.distances[i]
        let leg = await TrackRouter.leg(from: s.points[i], to: s.points[j], followTracks: true, snap: 40, library: noDownloads, offlineOnly: false)
        let len = TrackPath.length(leg.points), direct = TrackPath.meters(s.points[i], s.points[j])
        check(leg.followsTracks && len > direct * 1.02 && len < along * 1.15,
              "route along Federal Pass: \(Int(len)) m (along track \(Int(along)) m, straight \(Int(direct)) m)")
    } else { check(false, "Federal Pass for routing") }
    let outback = await TrackRouter.leg(from: .init(latitude: -32.0, longitude: 142.0), to: .init(latitude: -32.01, longitude: 142.01),
                                        followTracks: true, snap: 40, library: noDownloads, offlineOnly: false)
    check(!outback.followsTracks && outback.points.count == 2, "no tracks nearby -> straight leg")
    // Offline, from the downloaded Katoomba area only
    if let t = TrackSources.group(saved).filter({ $0.lengthKm > 0.8 }).max(by: { $0.lengthKm < $1.lengthKm }) {
        let line = TrackPath.chain(t.segments.map(\.points)).path
        let s = TrackPath.sample(line, maxSamples: 50, minStep: 10)
        let leg = await TrackRouter.leg(from: s.points[2], to: s.points[s.points.count - 3], followTracks: true, snap: 40,
                                        library: library, offlineOnly: true)
        check(leg.followsTracks, "offline route along \(t.displayName) from downloaded tracks (\(Int(TrackPath.length(leg.points))) m)")
    }

    // Planner: three taps, undo, delete a point
    let planner = RoutePlanner(library: noDownloads, offlineOnly: true)
    planner.followTracks = false
    planner.add(off(0, 0), tolerance: 30); planner.add(off(1000, 0), tolerance: 30); planner.add(off(1000, 1000), tolerance: 30)
    await planner.settle()
    check(planner.waypoints.count == 3 && abs(planner.lengthMeters - 2000) < 5, "planner: 3 points, \(Int(planner.lengthMeters)) m")
    planner.remove(1); await planner.settle()
    check(planner.legs.count == 1 && abs(planner.lengthMeters - 1414) < 5, "planner: middle point removed")
    planner.undo(); await planner.settle()
    check(planner.legs.count == 2, "planner: undo")
    // Select a point, then tap the map: it moves there and the selection clears.
    planner.select(1)
    planner.tap(off(1000, -500), tolerance: 30); await planner.settle()
    check(planner.waypoints.count == 3 && planner.selected == nil && abs(planner.lengthMeters - 2618) < 5,
          "planner: tap moves the selected point (\(Int(planner.lengthMeters)) m)")
    // Start selected, "Add before start": each tap adds a new start, which stays selected.
    planner.select(0); planner.extendsFromSelected = true
    planner.tap(off(-1000, 0), tolerance: 30); planner.tap(off(-1000, -1000), tolerance: 30); await planner.settle()
    check(planner.waypoints.count == 5 && planner.selected == 0 && planner.legs.count == 4
          && TrackPath.meters(planner.waypoints[0], off(-1000, -1000)) < 1 && abs(planner.lengthMeters - 4618) < 5,
          "planner: extend from the start (\(Int(planner.lengthMeters)) m)")
    // End selected, "Add after end": the new point becomes the selected end.
    planner.select(4); planner.extendsFromSelected = true
    planner.tap(off(2000, 1000), tolerance: 30); await planner.settle()
    check(planner.waypoints.count == 6 && planner.selected == 5 && abs(planner.lengthMeters - 5618) < 5,
          "planner: extend from the end")
    planner.select(5)
    check(planner.selected == nil, "planner: tapping the selected point deselects it")
    // Tapping the line inserts a point there (shape unchanged) and selects it; the next tap moves it.
    let inserting = RoutePlanner(library: noDownloads, offlineOnly: true)
    inserting.followTracks = false
    inserting.add(off(0, 0), tolerance: 30); inserting.add(off(1000, 0), tolerance: 30); inserting.add(off(1000, 1000), tolerance: 30)
    inserting.tap(off(500, 12), tolerance: 30); await inserting.settle()
    check(inserting.waypoints.count == 4 && inserting.legs.count == 3 && inserting.selected == 1
          && TrackPath.meters(inserting.waypoints[1], off(500, 0)) < 1 && abs(inserting.lengthMeters - 2000) < 5,
          "planner: tap on the line inserts a point")
    inserting.tap(off(500, 300), tolerance: 30); await inserting.settle()
    check(inserting.waypoints.count == 4 && inserting.selected == nil && abs(inserting.lengthMeters - 2166) < 5,
          "planner: the inserted point moves (\(Int(inserting.lengthMeters)) m)")
    inserting.tap(off(1000, 1020), tolerance: 30); await inserting.settle()
    check(inserting.waypoints.count == 5 && inserting.selected == nil, "planner: a tap just past the end adds a point")

    // GPX: write and read back a recorded walk; read a file with a route and a 2-piece track
    var walk = SavedRoute(name: "Walk & <test>", kind: .recorded)
    let pts = [off(0, 0), off(30, 10), off(60, 25)]
    walk.legs = [SavedRoute.Leg(coords: SavedRoute.coords(pts), followsTracks: false)]
    walk.times = [1_763_000_000, 1_763_000_020, 1_763_000_045]
    walk.altitudes = [900, nil, 912.5]
    let back = GPX.routes(from: GPX.data(for: walk), fallbackName: "x")
    check(back.count == 1 && back[0].name == walk.name && back[0].times == walk.times && back[0].altitudes == walk.altitudes
          && zip(back[0].path, pts).allSatisfy { TrackPath.meters($0, $1) < 0.2 }, "GPX round trip (name, points, times, elevations)")
    let other = """
    <?xml version="1.0"?><gpx xmlns="http://www.topografix.com/GPX/1/1"><metadata><name>Trip</name></metadata>
    <wpt lat="-33.7" lon="150.3"><name>Camp</name></wpt>
    <rte><name>Day 1</name><rtept lat="-33.70" lon="150.30"/><rtept lat="-33.71" lon="150.31"/><rtept lat="-33.72" lon="150.30"/></rte>
    <trk><trkseg><trkpt lat="-33.7" lon="150.3"/><trkpt lat="-33.7" lon="150.31"/></trkseg><trkseg><trkpt lat="-33.71" lon="150.31"/><trkpt lat="-33.71" lon="150.32"/></trkseg></trk></gpx>
    """
    let parsed = GPX.routes(from: Data(other.utf8), fallbackName: "file")
    check(parsed.map(\.name) == ["Day 1", "Trip 2"] && parsed[0].path.count == 3 && parsed[1].legs.count == 2 && parsed[1].path.count == 4,
          "GPX import: route and two-piece track (\(parsed.map(\.name)))")

    // Progress along a route: halfway along, and off route
    let route = [off(0, 0), off(1000, 0), off(1000, 1000)]
    let half = RouteProgress.locate(off(1000, 0), on: route)
    check(half.map { abs($0.done - 1000) < 2 && abs($0.remaining - 1000) < 2 && !$0.isOffRoute } == true, "progress: halfway")
    check(RouteProgress.locate(off(500, 150), on: route)?.isOffRoute == true, "progress: 150 m away is off route")
    let outBack = [off(0, 0), off(1000, 0), off(0, 0)]
    check(RouteProgress.locate(off(200, 0), on: outBack, previous: 1700).map { abs($0.done - 1800) < 2 } == true,
          "progress: out-and-back keeps to the return leg")

    // GPS fixes: a bad-accuracy fix and a 1 km jump are dropped
    let f0 = GPSFix(coordinate: off(0, 0), time: 0, horizontalAccuracy: 8, altitude: 900)
    check(RecordingFilter.accept(GPSFix(coordinate: off(15, 0), time: 10, horizontalAccuracy: 10), after: f0, maxAccuracy: 50),
          "GPS: normal walking fix kept")
    check(!RecordingFilter.accept(GPSFix(coordinate: off(15, 0), time: 10, horizontalAccuracy: 200), after: f0, maxAccuracy: 50),
          "GPS: ±200 m fix dropped")
    check(!RecordingFilter.accept(GPSFix(coordinate: off(1000, 0), time: 10, horizontalAccuracy: 10), after: f0, maxAccuracy: 50),
          "GPS: 1 km jump in 10 s dropped")

    // Saving
    let routesDir = dataDir.appendingPathComponent("Routes")
    let rs = RouteStore(directory: routesDir, shownKey: "selftest-shown")
    rs.save(walk); rs.setShown(walk.id, true)
    let imported = rs.importGPX(Data(other.utf8), fileName: "Trip.gpx")
    let rs2 = RouteStore(directory: routesDir, shownKey: "selftest-shown")
    check(rs2.routes.count == 3 && rs2.route(id: walk.id) == walk && rs2.shownIDs.count == 3, "routes saved and reloaded (\(rs2.routes.count))")
    rs2.delete(walk); imported.forEach(rs2.delete)
    check(RouteStore(directory: routesDir, shownKey: "selftest-shown").routes.isEmpty, "routes deleted")
}

// 2i. United States: USGS topo, trails, GNIS place names, Forest Service campgrounds; units
do {
    let yosemite = CLLocationCoordinate2D(latitude: 37.73, longitude: -119.57)
    func usTile(_ z: Int) -> TileKey {
        TileKey(z: z, x: TileMath.tileX(lon: yosemite.longitude, z: z), y: TileMath.tileY(lat: yosemite.latitude, z: z))
    }
    let (z16, _) = try await URLSession.shared.data(from: TileSources.us.tileURL(usTile(16)))
    check(TileImage.isImage(z16) && TileImage.decode(z16)?.width == 256, "USGS topo tile at z16 decodes (\(z16.count) bytes)")
    let (_, r17) = try await URLSession.shared.data(from: TileSources.us.tileURL(usTile(17)))
    check((r17 as? HTTPURLResponse)?.statusCode == 404, "USGS topo has nothing at z17 (maxZoom 16 is right)")

    for (name, lat, lon, want) in [("Yosemite", 37.73, -119.57, "us-topo"), ("Seattle", 47.6, -122.3, "us-topo"),
                                   ("Detroit", 42.33, -83.05, "us-topo"), ("El Paso", 31.76, -106.49, "us-topo"), ("Denali", 63.07, -151.0, "us-topo"),
                                   ("Mauna Kea", 19.82, -155.47, "us-topo"), ("Katoomba", -33.71, 150.31, "nsw-topo"),
                                   ("Uluru", -25.34, 131.03, "ga-topo")] {
        let got = TileSources.best(for: .init(latitude: lat, longitude: lon)).id
        check(got == want, "\(name) -> \(got)")
    }
    for (name, lat, lon) in [("Vancouver", 49.25, -123.1), ("Toronto", 43.65, -79.38), ("Montreal", 45.5, -73.57),
                             ("Windsor", 42.28, -83.0), ("Tijuana", 32.5, -117.0), ("Ciudad Juárez", 31.69, -106.42), ("Whitehorse", 60.72, -135.05)] {
        check(!TileSources.us.covers(.init(latitude: lat, longitude: lon)), "\(name) is outside the US outline")
    }

    let mist = try await TrackSources.search("mist trail", near: yosemite)
    if let t = mist.first(where: { $0.name == "Mist Trail" }) {
        check(t.state == "US" && t.kind.hasPrefix("Trail"), "US trail found: \(t.displayName), \(t.kind), \(t.segments.count) pieces")
        if let p = await Elevation.profile(for: t, library: noDownloads, offlineOnly: false) {
            print("     Mist Trail: \(String(format: "%.1f", p.lengthKm)) km, up \(Int(p.ascent)) m, \(Int(p.lowest))–\(Int(p.highest)) m")
            check(p.highest > p.lowest + 200, "Mist Trail elevation profile (climbs past Vernal Fall)")
        } else { check(false, "Mist Trail elevation profile") }
        let line = TrackPath.chain(t.segments.map(\.points)).path
        let s = TrackPath.sample(line, maxSamples: 60, minStep: 10)
        let leg = await TrackRouter.leg(from: s.points[1], to: s.points[s.points.count - 2], followTracks: true, snap: 40,
                                        library: noDownloads, offlineOnly: false)
        check(leg.followsTracks, "route along the Mist Trail (\(Int(TrackPath.length(leg.points))) m)")
    } else { check(false, "Mist Trail in USGS trails (found: \(mist.map(\.displayName)))") }

    let halfDome = try await PlaceSearch.search("half dome", near: yosemite)
    check(halfDome.first.map { $0.name == "Half Dome" && $0.state == "CA" && $0.feature == "SUMMIT" } == true,
          "GNIS: Half Dome near Yosemite -> \(halfDome.first.map { "\($0.name), \($0.kind)" } ?? "nothing")")
    let box = BoundingBox(minLat: 37.72, minLon: -119.56, maxLat: 37.77, maxLon: -119.50)
    let boxNames = try await PlaceSearch.names(in: box)
    check(boxNames.contains { $0.name == "Half Dome" }, "GNIS names for a small Yosemite area (\(boxNames.count))")
    check(PlaceSearch.attribution(near: yosemite) == USPlaceNames.attribution
          && PlaceSearch.attribution(near: katoombaC) == Gazetteer.attribution, "place-name credit follows the map")

    // A small area around Vernal Fall, downloaded: map, names, trails and elevation all work offline
    let vernal = BoundingBox(minLat: 37.722, minLon: -119.555, maxLat: 37.735, maxLon: -119.535)
    let ry = await runDownload("Vernal Fall", vernal, TileSources.us, 14...16)
    check(ry.isComplete && ry.failedTiles == 0 && !ry.layers.contains { $0.sourceID == TileSources.overview.id }
          && ry.layers.contains { $0.sourceID == "terrain" }, "US area downloaded (USGS topo + elevation, no Australian overview)")
    let yTile = TileKey(z: 16, x: TileMath.tileX(lon: vernal.center.longitude, z: 16), y: TileMath.tileY(lat: vernal.center.latitude, z: 16))
    check(library.tile(sourceID: "us-topo", key: yTile).map(TileImage.isImage) == true, "USGS tile readable offline")
    check(library.searchNames("vernal fall", near: yosemite).contains { $0.name == "Vernal Fall" }, "offline search finds Vernal Fall")
    let offlineMist = library.searchTracks("mist trail").first { $0.name == "Mist Trail" }
    check(offlineMist != nil, "Mist Trail saved with the area")
    if let offlineMist {
        let p = await Elevation.profile(for: offlineMist, library: library, offlineOnly: true)
        check(p != nil, "Mist Trail profile offline (\(p.map { "up \(Int($0.ascent)) m" } ?? "none"))")
        let pts = TrackPath.chain(offlineMist.segments.map(\.points)).path
        let s = TrackPath.sample(pts, maxSamples: 40, minStep: 10)
        let leg = await TrackRouter.leg(from: s.points[1], to: s.points[s.points.count / 2], followTracks: true, snap: 40,
                                        library: library, offlineOnly: true)
        check(leg.followsTracks, "offline route along the Mist Trail")
    }
    store.delete(ry)

    let usfs = try await OfficialCampgrounds.usfs()
    let closed = usfs.filter { $0.closure != nil }.count
    check(usfs.count > 3000 && closed > 0 && usfs.contains { $0.website?.hasPrefix("https://www.fs.usda.gov") == true },
          "Forest Service campgrounds: \(usfs.count), \(closed) closed")
    check(OfficialCampgrounds.usfsSeason(start: "May", end: "Oct. 31") == "Open May – Oct. 31"
          && OfficialCampgrounds.usfsSeason(start: "Year Round", end: nil) == "Open year round", "campground season text")
}

// Units
do {
    let mi = Units.usCustomary, km = Units.metric
    check(mi.distance(1609.344) == "1.0 mi" && mi.distance(30) == "100 ft" && mi.distance(200_000) == "124 mi",
          "imperial distances: \(mi.distance(1609.344)), \(mi.distance(30)), \(mi.distance(200_000))")
    check(km.distance(850) == "850 m" && km.distance(1234) == "1.2 km" && km.distance(150_000) == "150 km",
          "metric distances: \(km.distance(850)), \(km.distance(1234)), \(km.distance(150_000))")
    check(mi.height(1000) == "3,281 ft" || mi.height(1000) == "3 281 ft" || mi.height(1000) == "3281 ft", "height in feet: \(mi.height(1000))")
    check(km.climb(up: 120, down: 80) == "↑ 120 m ↓ 80 m", "climb text")
    check(mi.roundDistance(TrackRouter.maxDistance) == "12 mi" && km.roundDistance(TrackRouter.maxDistance) == "20 km", "round distances")
    // Scale bar: 10 m per point, 110 pt max -> 1 km (100 pt) / ½ mi (80 pt); 3 m per point -> 1000 ft
    let mBar = km.scaleBar(metersPerPoint: 10, maxPoints: 110), fBar = mi.scaleBar(metersPerPoint: 10, maxPoints: 110)
    check(mBar?.label == "1 km" && abs((mBar?.points ?? 0) - 100) < 0.01, "metric scale bar: \(mBar?.label ?? "-")")
    check(fBar?.label == "½ mi", "imperial scale bar: \(fBar?.label ?? "-")")
    check(mi.scaleBar(metersPerPoint: 3, maxPoints: 110)?.label == "1000 ft", "imperial scale bar in feet")
    check(mi.scaleBar(metersPerPoint: 30, maxPoints: 110)?.label == "2 mi", "imperial scale bar in miles")
    check(Units(.automatic, locale: Locale(identifier: "en_US")).imperial && !Units(.automatic, locale: Locale(identifier: "en_AU")).imperial,
          "automatic units follow the region")
}

// 2j. Canada, Switzerland, Norway
do {
    func tile(_ src: TileSource, _ lat: Double, _ lon: Double, _ z: Int) -> TileKey {
        TileKey(z: z, x: TileMath.tileX(lon: lon, z: z), y: TileMath.tileY(lat: lat, z: z))
    }
    // WMS tile bounds: tile 0/0/0 is the whole Web Mercator square
    check(TileMath.mercatorBBox(of: TileKey(z: 0, x: 0, y: 0)) == "-20037508.34,-20037508.34,20037508.34,20037508.34",
          "WMS bbox for the world tile")
    check(TileSources.ca.tileURL(TileKey(z: 1, x: 1, y: 0)).absoluteString.contains("bbox=0.00,0.00,20037508.34,20037508.34&width=256"),
          "WMS bbox in the Toporama URL")
    // Toporama in 4 × 4 blocks: one 1,024 px request serves 16 tiles
    let b = TileSources.ca.block(containing: TileKey(z: 15, x: 5483, y: 11339))
    check(b.origin == TileKey(z: 15, x: 5480, y: 11336) && b.span == 4
          && TileSources.ca.blockURL(b.origin, span: b.span).absoluteString.contains("width=1024&height=1024"), "Toporama block of 4 × 4 tiles")
    check(TileSources.ca.block(containing: TileKey(z: 1, x: 1, y: 1)).span == 2, "block shrinks at the lowest zooms")
    let t0 = Date()
    let blockTiles = await withTaskGroup(of: Data?.self) { group in
        for dy in 0..<4 { for dx in 0..<4 {
            group.addTask { await BlockTiles.shared.tile(TileKey(z: 15, x: 5480 + dx, y: 11336 + dy), source: TileSources.ca,
                                                         session: URLSession.shared, offlineOnly: false) }
        } }
        var out: [Data?] = []
        for await d in group { out.append(d) }
        return out
    }
    let blockSeconds = Date().timeIntervalSince(t0)
    check(blockTiles.count == 16 && blockTiles.allSatisfy { $0.flatMap(TileImage.decode)?.width == 256 } && blockSeconds < 15,
          "16 Toporama tiles from one block request in \(String(format: "%.1f", blockSeconds)) s")
    for (src, lat, lon, z) in [(TileSources.ca, 51.18, -115.57, 15), (TileSources.ch, 46.62, 8.04, 17), (TileSources.no, 61.64, 8.31, 17)] {
        let (data, _) = try await URLSession.shared.data(from: src.tileURL(tile(src, lat, lon, z)))
        check(TileImage.decode(data)?.width == 256, "\(src.name) tile at z\(z) decodes (\(data.count) bytes)")
    }

    for (name, lat, lon, want) in [("Banff", 51.18, -115.57, "ca-topo"), ("Vancouver", 49.25, -123.1, "ca-topo"),
                                   ("Toronto", 43.65, -79.38, "ca-topo"), ("Montreal", 45.5, -73.57, "ca-topo"),
                                   ("Whitehorse", 60.72, -135.05, "ca-topo"), ("Iqaluit", 63.75, -68.52, "ca-topo"),
                                   ("Seattle", 47.6, -122.3, "us-topo"), ("Detroit", 42.33, -83.05, "us-topo"),
                                   ("Anchorage", 61.22, -149.9, "us-topo"), ("Grindelwald", 46.62, 8.04, "ch-topo"),
                                   ("Zermatt", 46.02, 7.75, "ch-topo"), ("Vaduz", 47.14, 9.52, "ch-topo"),
                                   ("Oslo", 59.91, 10.75, "no-topo"), ("Tromsø", 69.65, 18.96, "no-topo"),
                                   ("Galdhøpiggen", 61.64, 8.31, "no-topo"), ("Katoomba", -33.71, 150.31, "nsw-topo")] {
        let got = TileSources.best(for: .init(latitude: lat, longitude: lon)).id
        check(got == want, "\(name) -> \(got)")
    }
    for (name, lat, lon) in [("Stockholm", 59.33, 18.07), ("Kiruna", 67.85, 20.22), ("Milan", 45.46, 9.19),
                             ("Munich", 48.14, 11.58), ("Annecy", 45.9, 6.13), ("Nuuk", 64.18, -51.7)] {
        let c = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        check(![TileSources.ca, TileSources.ch, TileSources.no, TileSources.us].contains { $0.covers(c) }, "\(name) is outside all the outlines")
    }

    // Place names
    let banffC = CLLocationCoordinate2D(latitude: 51.0, longitude: -115.6)
    let assiniboine = try await PlaceSearch.search("mount assiniboine", near: banffC)
    check(assiniboine.first.map { $0.name == "Mount Assiniboine" && $0.feature == "MOUNTAIN" } == true,
          "Canada: Mount Assiniboine -> \(assiniboine.first.map { "\($0.name), \($0.kind)" } ?? "nothing")")
    let grindelwald = CLLocationCoordinate2D(latitude: 46.62, longitude: 8.04)
    let eiger = try await PlaceSearch.search("eiger", near: grindelwald)
    check(eiger.first.map { $0.name == "Eiger" && $0.feature == "PEAK" } == true, "Switzerland: Eiger summit first (\(eiger.prefix(3).map { "\($0.name), \($0.kind)" }))")
    check(CHNames.parse("<i>Alpiner Gipfel</i> <b>Eiger</b> (BE) - Grindelwald").map { "\($0.name)|\($0.kind)|\($0.canton ?? "")" }
          == "Eiger|Alpiner Gipfel|BE", "Swiss label parsed")
    let jotunheimen = CLLocationCoordinate2D(latitude: 61.6, longitude: 8.4)
    let galdh = try await PlaceSearch.search("galdhøpiggen", near: jotunheimen)
    check(galdh.first.map { $0.name == "Galdhøpiggen" && $0.state == "Lom" } == true,
          "Norway: Galdhøpiggen -> \(galdh.first.map { "\($0.name), \($0.kind)" } ?? "nothing")")
    check(Gazetteer.matches(PlaceName(id: "x", name: "Galdhøpiggen", feature: "", category: "", state: "", lat: 0, lon: 0),
                            tokens: ["galdhopiggen"]), "typing without ø still matches")
    let caBox = BoundingBox(minLat: 50.84, minLon: -115.70, maxLat: 50.90, maxLon: -115.60)
    let caNames = try await PlaceSearch.names(in: caBox)
    check(caNames.contains { $0.name == "Mount Assiniboine" } && !caNames.contains { $0.id.hasPrefix("US_") },
          "Canadian names for a small area, no US ones (\(caNames.count))")
    let noBox = BoundingBox(minLat: 61.62, minLon: 8.27, maxLat: 61.66, maxLon: 8.35)
    let noNames = try await PlaceSearch.names(in: noBox)
    check(noNames.contains { $0.name == "Galdhøpiggen" }, "Norwegian names for a small area (\(noNames.count))")
    check(PlaceSearch.attribution(near: grindelwald) == CHNames.attribution && PlaceSearch.attribution(near: banffC) == CANames.attribution
          && PlaceSearch.attribution(near: jotunheimen) == NONames.attribution, "place-name credit follows the map")

    // Trails
    let chBox = BoundingBox(minLat: 46.60, minLon: 8.00, maxLat: 46.64, maxLon: 8.06)
    let chSegs = try await TrackSources.segments(in: chBox, layers: [TrackSources.chTrails])
    check(chSegs.count > 50 && chSegs.allSatisfy { $0.state == "CH" && $0.points.count >= 2 },
          "Swiss hiking trails near Grindelwald: \(chSegs.count) (\(Set(chSegs.map(\.kind)).sorted()))")
    let noSegs = try await TrackSources.segments(in: BoundingBox(minLat: 61.48, minLon: 8.75, maxLat: 61.54, maxLon: 8.85),
                                                 layers: [TrackSources.noTrails])
    check(noSegs.count > 3 && noSegs.allSatisfy { $0.points.count >= 2 && abs($0.points[0].latitude - 61.5) < 0.2 },
          "Norwegian trails near Gjendesheim: \(noSegs.count) (\(Set(noSegs.map(\.kind)).sorted()))")
    if let longest = chSegs.max(by: { $0.points.count < $1.points.count }), longest.points.count >= 6 {
        let pts = longest.points
        let leg = await TrackRouter.leg(from: pts[1], to: pts[pts.count - 2], followTracks: true, snap: 40,
                                        library: noDownloads, offlineOnly: false)
        check(leg.followsTracks, "route along a Swiss hiking trail (\(Int(TrackPath.length(leg.points))) m)")
    }

    let lakeAgnes = try await TrackSources.search("lake agnes", near: CLLocationCoordinate2D(latitude: 51.41, longitude: -116.22))
    if let t = lakeAgnes.first(where: { $0.name == "Lake Agnes" }) {
        let p = await Elevation.profile(for: t, library: noDownloads, offlineOnly: false)
        check(t.state == "CA" && (p?.ascent ?? 0) > 200, "Parks Canada trail: Lake Agnes, \(t.kind), climb \(Int(p?.ascent ?? 0)) m")
    } else { check(false, "Lake Agnes in Parks Canada trails (found \(lakeAgnes.map(\.displayName)))") }

    // Downloads: Canada allowed, Switzerland and Norway not (yet)
    check(DownloadManager.plan(name: "x", area: chBox, source: TileSources.ch, zooms: 14...15, includeOverview: true) == nil
          && DownloadManager.plan(name: "x", area: noBox, source: TileSources.no, zooms: 14...15, includeOverview: true) == nil,
          "Swiss and Norwegian maps can't be saved offline yet")
    let lakeLouise = BoundingBox(minLat: 51.410, minLon: -116.225, maxLat: 51.420, maxLon: -116.205)
    let rc = await runDownload("Lake Louise", lakeLouise, TileSources.ca, 13...15)
    let caTile = TileKey(z: 15, x: TileMath.tileX(lon: lakeLouise.center.longitude, z: 15), y: TileMath.tileY(lat: lakeLouise.center.latitude, z: 15))
    check(rc.isComplete && rc.failedTiles == 0 && library.tile(sourceID: "ca-topo", key: caTile).map(TileImage.isImage) == true,
          "Canadian area downloaded and readable offline")
    check(library.searchNames("louise", near: lakeLouise.center).contains { $0.name.contains("Louise") }, "Canadian names saved with the area")
    store.delete(rc)

    // Named trails to search: BC, Ontario, Swiss routes, Norwegian routes
    for (q, lat, lon, want) in [("deeks lake", 49.5, -123.2, "Deeks Lake Trail"), ("bruce trail", 44.5, -80.2, "Bruce Trail"),
                                ("eiger trail", 46.6, 8.0, "Eiger Trail"), ("gjendesheim", 61.49, 8.81, "Gjendesheim-Bessheim")] {
        let found = try await TrackSources.search(q, near: CLLocationCoordinate2D(latitude: lat, longitude: lon))
        check(found.contains { ($0.name ?? "").hasPrefix(want) }, "trail search '\(q)' -> \(found.prefix(3).map { "\($0.displayName) (\($0.kind))" })")
    }
    // Search follows the selected map's country, and finds trails when the map is zoomed out
    let noFar = try await TrackSources.search("bessheim", near: CLLocationCoordinate2D(latitude: 59.9, longitude: 10.7), country: "NO")
    check(noFar.contains { $0.name == "Gjendesheim-Bessheim" }, "Norwegian route found from Oslo (nationwide): \(noFar.map(\.displayName))")
    let caFar = try await TrackSources.search("lake agnes", near: CLLocationCoordinate2D(latitude: 55, longitude: -100), country: "CA")
    check(caFar.contains { $0.name == "Lake Agnes" } && caFar.allSatisfy { $0.state == "CA" },
          "Canadian trail found with the map zoomed out, Canadian sources only")
    check(try await PlaceSearch.search("eiger", near: CLLocationCoordinate2D(latitude: -33.7, longitude: 150.3), country: "CH").first?.name == "Eiger",
          "place search uses the selected map's country, not the map centre")
    // A tap on the Eiger Trail gives the named route rather than an unnamed network piece
    if let eigerTrail = try await TrackSources.search("eiger trail", near: grindelwald).first,
       let mid = eigerTrail.segments.first?.points.dropFirst(5).first {
        let tapped = await TrackLookup.track(at: mid, within: 25, library: OfflineTileLibrary(directory: dataDir.appendingPathComponent("empty-ch")), offlineOnly: false)
        check(tapped?.name?.hasPrefix("Eiger Trail") == true, "tap on the Eiger Trail -> \(tapped?.displayName ?? "nothing")")
    }

    // Campgrounds: Parks Canada (one pin per campground) and BC recreation sites
    let pc = try await OfficialCampgrounds.parksCanada()
    check(pc.count > 100 && pc.contains { $0.name == "Tunnel Mountain Village I" }, "Parks Canada campgrounds: \(pc.count)")
    let bc = try await OfficialCampgrounds.bcRecSites()
    check(bc.count > 1000 && bc.contains { $0.amenities?.contains("Toilets") == true }
          && bc.allSatisfy { $0.website?.hasPrefix("https://www.sitesandtrailsbc.ca/resource/REC") == true },
          "BC recreation sites with campsites: \(bc.count)")
    let bcJSON = String(decoding: try JSONEncoder().encode(bc), as: UTF8.self)
    check(!bcJSON.contains("OPERATOR"), "no operator names in BC data")

    // Regions: Canadian campgrounds are fetched only once the map has shown Canada
    UserDefaults.standard.removeObject(forKey: "selftest-regions")
    let regionDir = dataDir.appendingPathComponent("regions-test")
    try? FileManager.default.createDirectory(at: regionDir, withIntermediateDirectories: true)
    let gated = CampgroundStore(directory: regionDir, bundledExtract: nil, moreExtracts: [], regionsKey: "selftest-regions")
    await gated.refreshIfStale(offlineOnly: false)
    check(!gated.official.contains { $0.source == CampSource.parksCanada } && !gated.wants(.canada), "no Canadian campgrounds before the map shows Canada")
    await gated.refreshIfStale(offlineOnly: false, area: BoundingBox(minLat: 51.0, minLon: -115.8, maxLat: 51.3, maxLon: -115.4))
    check(gated.official.contains { $0.source == CampSource.parksCanada } && gated.wants(.canada), "Canadian campgrounds after showing Banff")

    // Huts from the per-region OpenStreetMap extracts, loaded when the map shows the region
    let resources = extractURL.deletingLastPathComponent()
    let regional = CampgroundStore(directory: regionDir, bundledExtract: nil,
                                   moreExtracts: [(BoundingBox(minLat: 45.8, minLon: 4.3, maxLat: 71.6, maxLon: 31.5), resources.appendingPathComponent("osm-campsites-europe.json")),
                                                  (BoundingBox(minLat: 17.5, minLon: -180, maxLat: 84, maxLon: -52), resources.appendingPathComponent("osm-campsites-na.json"))],
                                   regionsKey: "selftest-regions")
    check(regional.community.isEmpty, "regional extracts aren't loaded up front")
    await regional.loadCommunity(for: BoundingBox(minLat: 46.5, minLon: 7.9, maxLat: 46.7, maxLon: 8.2))
    let huts = regional.community.filter { $0.kind == "Hut" }
    check(huts.contains { $0.name.contains("Gleckstein") } && huts.contains { $0.name.contains("Gjendebu") },
          "Swiss and Norwegian huts from OpenStreetMap (\(huts.count) huts, \(regional.community.count) places)")
    await regional.loadCommunity(for: BoundingBox(minLat: 51.0, minLon: -115.8, maxLat: 51.3, maxLon: -115.4))
    check(regional.community.count > 50_000, "North American extract loaded when the map shows Canada (\(regional.community.count) places)")
}

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
check(TileSources.all.allSatisfy { TopoTileOverlay(source: $0, library: library, offlineOnly: true).maximumZ >= 21 },
      "every map layer covers zoom 21 (no white screen when fully zoomed in)")
let deep = await loadQ(TileKey(z: 21, x: (qk.x << 5) + 3, y: (qk.y << 5) + 3))
check(deep.flatMap(TileImage.decode)?.width == 256, "QLD offline z21 enlarged from downloaded z16")

// 6. Delete cleans up files
store.delete(r2)
let left = try FileManager.default.contentsOfDirectory(atPath: dataDir.path).filter { $0.contains(r2.id.uuidString) }
check(left.isEmpty, "delete removes region files")
print("     regions.json:", (try? String(contentsOf: dataDir.appendingPathComponent("regions.json"), encoding: .utf8))?.count ?? 0, "chars; total on disk:", store.totalBytes / 1000, "KB")
print("ALL CHECKS PASSED")
