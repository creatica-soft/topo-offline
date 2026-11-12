import SwiftUI
import MapKit

struct ContentView: View {
    @Environment(RegionStore.self) private var store
    @Environment(DownloadManager.self) private var downloads

    @State private var controller = MapController()
    @AppStorage("sourceID") private var sourceID = TileSources.nsw.id
    @AppStorage("offlineOnly") private var offlineOnly = false
    @AppStorage("nationalWhenZoomedOut") private var nationalWhenZoomedOut = true
    @State private var showDownload = false
    @State private var showRegions = false
    @State private var switchNotice: String?
    @State private var showSearch = false
    @State private var pin: PlaceName?
    @State private var card: MapCard?
    /// Card whose full details are open in a sheet.
    @State private var details: MapCard?
    @State private var trackLookup: Task<Void, Never>?
    @State private var visibleTracks = VisibleTracks()
    @State private var parkInfo = ParkInfoStore()
    @State private var nzNamesLoading = false
    @State private var campgrounds = CampgroundStore()
    @State private var trackProfile: ProfileState?
    @State private var profileMarker: CLLocationCoordinate2D?

    /// Changes whenever a different track is selected (or offline mode flips), to recompute the profile.
    private var profileTaskID: String {
        guard case .track(let t) = card else { return "" }
        return "\(t.id)|\(t.segments.count)|\(offlineOnly)"
    }

    /// What the card at the bottom shows (one thing at a time).
    enum MapCard: Equatable {
        case track(Track)
        case site(Campsite)
        case closure(ClosedLine)
        case rule(CampingRule)
    }

    /// Track drawn highlighted on the map: the selected track, or the selected closed track/road.
    private var highlighted: Track? {
        switch card {
        case .track(let t): return t
        case .closure(let c): return Track(segments: c.segments)
        default: return nil
        }
    }

    private var selectedSiteID: String? {
        if case .site(let s) = card { return s.id }
        return nil
    }

    /// Campsites, huts and day areas from about a 30 km wide view (all sources, merged);
    /// closures from further out.
    private var visibleSites: [Campsite] {
        guard let area = controller.visibleArea, controller.zoomLevel >= 10 else { return [] }
        return campgrounds.sites(in: area, rich: parkInfo.sites(in: area))
    }
    private var visibleRules: [CampingRule] {
        guard let area = controller.visibleArea, controller.zoomLevel >= 10 else { return [] }
        return parkInfo.campingRules(in: area)
    }
    private var visibleClosures: [ClosedLine] {
        guard let area = controller.visibleArea, controller.zoomLevel >= 9 else { return [] }
        return parkInfo.closedLines(in: area)
    }

    private var source: TileSource { TileSources.source(id: sourceID) ?? TileSources.nsw }
    private var mapView: MKMapView? { controller.isMapReady ? controller.mapView : nil }

    var body: some View {
        TopoMapView(source: source, offlineOnly: offlineOnly, nationalWhenZoomedOut: nationalWhenZoomedOut,
                    library: store.library,
                    regions: store.regions, pin: pin, track: highlighted,
                    areaTracks: visibleTracks.segments, areaTracksVersion: visibleTracks.version,
                    sites: visibleSites, closedLines: visibleClosures, campingRules: visibleRules,
                    profileMarker: profileMarker,
                    selectedSiteID: selectedSiteID,
                    onSelectSite: { site in card = .site(site) },
                    controller: controller,
                    onTap: { coordinate, meters in lookUpTrack(at: coordinate, within: meters) })
            .ignoresSafeArea()
            .overlay(alignment: .top) {
                VStack(spacing: 8) {
                    topBar
                    if let pin {
                        pinChip(pin)
                    }
                    if nzNeedsKey {
                        Text("The New Zealand topo map needs a LINZ key (see README). Tracks, huts and search work.")
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                            .padding(.horizontal)
                    }
                    if let switchNotice {
                        Text(switchNotice)
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule())
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut, value: switchNotice)
            }
            .overlay(alignment: .bottom) { bottomBar }
            .onChange(of: controller.visibleArea) {
                followStateMaps()
                refreshVisibleTracks()
                if let area = controller.visibleArea, ParkInfoStore.covers(area) {
                    Task { await parkInfo.refreshIfStale(offlineOnly: offlineOnly) }
                }
                loadNZNamesIfNeeded()
            }
            .onChange(of: offlineOnly) {
                refreshVisibleTracks()
                // Back online: top up older areas (names, tracks, elevation) now, not only at launch.
                if !offlineOnly { Task { await downloads.addMissingNames(offlineOnly: false) } }
            }
            .sheet(isPresented: $showDownload) {
                DownloadSheet(current: source, visibleArea: controller.visibleArea ?? source.coverage,
                              nationalWhenZoomedOut: nationalWhenZoomedOut)
            }
            .sheet(isPresented: $showSearch) {
                SearchView(center: controller.center, offlineOnly: offlineOnly,
                           onSelect: { place in
                               card = nil
                               pin = place
                               controller.show(place.coordinate)
                           },
                           onSelectTrack: { t in
                               pin = nil
                               card = .track(t)
                               controller.show(t.bbox)
                           })
            }
            .sheet(isPresented: Binding(get: { details != nil }, set: { if !$0 { details = nil } })) {
                switch details {
                case .site(let site): SiteDetailView(site: site, updated: parkInfo.updatedText)
                case .closure(let closure): ClosureDetailView(closure: closure, updated: parkInfo.updatedText)
                case .rule(let rule): RuleDetailView(rule: rule)
                case .track(let track):
                    if case .ready(let profile) = trackProfile {
                        TrackDetailView(track: track, profile: profile, onScrub: { profileMarker = $0 })
                    }
                default: EmptyView()
                }
            }
            .task { await downloads.addMissingNames(offlineOnly: offlineOnly) }
            .task { await parkInfo.refreshIfStale(offlineOnly: offlineOnly) }
            .task { await campgrounds.refreshIfStale(offlineOnly: offlineOnly) }
            .task(id: profileTaskID) {
                profileMarker = nil
                guard case .track(let t) = card else {
                    trackProfile = nil
                    return
                }
                trackProfile = .loading
                let profile = await Elevation.profile(for: t, library: store.library, offlineOnly: offlineOnly)
                guard !Task.isCancelled else { return }
                trackProfile = profile.map { .ready($0) } ?? .unavailable
            }
            .sheet(isPresented: $showRegions) {
                RegionsView { region in
                    if let id = region.primarySource?.id { sourceID = id }
                    controller.show(region.bbox)
                }
            }
            .onAppear { controller.requestLocationPermission() }
    }

    /// When the map moves out of the selected state's map into another state, switch to that
    /// state's map. (The national map is left alone if the user picked it.)
    private func followStateMaps() {
        guard let area = controller.visibleArea, controller.zoomLevel >= 7,
              source.id != TileSources.overview.id else { return }
        let best = TileSources.best(for: area.center, preferring: source)
        guard best.id != source.id, best.id != TileSources.overview.id else { return }
        sourceID = best.id
        // Only announce it when the state map is actually on screen.
        if !nationalWhenZoomedOut || controller.zoomLevel >= Double(TileSources.detailFromZoom) {
            switchNotice = "Showing \(best.name)"
        }
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if switchNotice == "Showing \(best.name)" { switchNotice = nil }
        }
    }

    /// The first time the map is in New Zealand (online), fetch the NZ place-name list for search.
    private func loadNZNamesIfNeeded() {
        guard !offlineOnly, !nzNamesLoading, let area = controller.visibleArea,
              area.intersects(TileSources.nz.coverage), store.library.nationalNamesNeedRefresh else { return }
        nzNamesLoading = true
        Task {
            if let names = try? await NZPlaceNames.fetchAll() { store.library.setNationalNames(names) }
            nzNamesLoading = false
        }
    }

    /// In New Zealand without a LINZ key there's no topo map: say so instead of a blank map.
    private var nzNeedsKey: Bool {
        guard !TileSources.nz.isAvailable, let area = controller.visibleArea, controller.zoomLevel >= 6 else { return false }
        return TileSources.nz.coverage.contains(area.center)
    }

    private func refreshVisibleTracks() {
        visibleTracks.update(area: controller.visibleArea, zoom: controller.zoomLevel,
                             offlineOnly: offlineOnly, library: store.library)
    }

    /// Tap on the map: a closure under the finger first, then a track; tapping empty map clears the card.
    private func lookUpTrack(at c: CLLocationCoordinate2D, within meters: Double) {
        trackLookup?.cancel()
        if controller.zoomLevel >= 9, let closure = parkInfo.closure(near: c, within: meters) {
            card = .closure(closure)
            return
        }
        guard controller.zoomLevel >= 12 else {  // tracks aren't visible further out
            card = nil
            return
        }
        trackLookup = Task {
            let found = await TrackLookup.track(at: c, within: meters, library: store.library, offlineOnly: offlineOnly)
            guard !Task.isCancelled else { return }
            if let found {
                card = .track(found)
            } else if let rule = parkInfo.campingRule(at: c) {
                card = .rule(rule)  // inside a freedom-camping rule area (NZ)
            } else {
                card = nil
            }
        }
    }

    private func pinChip(_ place: PlaceName) -> some View {
        HStack(spacing: 0) {
            Button {
                controller.show(place.coordinate)
            } label: {
                Label(place.name, systemImage: "mappin.and.ellipse")
                    .lineLimit(1)
                    .padding(.leading, 14)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            Button {
                pin = nil
            } label: {
                // 44 × 44 pt tap area (Apple's minimum) around a visibly larger icon.
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Remove pin")
        }
        .font(.subheadline.weight(.medium))
        .background(.regularMaterial, in: Capsule())
    }

    private var topBar: some View {
        HStack {
            Menu {
                Picker("Map", selection: $sourceID) {
                    ForEach(TileSources.all) { s in
                        Text(s.name).tag(s.id)
                    }
                }
                Divider()
                Toggle(isOn: $nationalWhenZoomedOut) {
                    Text("National map when zoomed out")
                    Text("State topo appears from about 10 km across")
                }
            } label: {
                Label(source.name, systemImage: "map")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
            }
            Button {
                showSearch = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 38, height: 38)
                    .background(.regularMaterial, in: Circle())
            }
            .accessibilityLabel("Search places")
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                Button {
                    offlineOnly.toggle()
                } label: {
                    Label(offlineOnly ? "Offline" : "Online", systemImage: offlineOnly ? "wifi.slash" : "wifi")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(offlineOnly ? AnyShapeStyle(Color.orange.opacity(0.9)) : AnyShapeStyle(.regularMaterial),
                                    in: Capsule())
                }
                .accessibilityHint("When offline, only downloaded and recently viewed maps are shown")
                CompassButton(mapView: mapView)
                    .frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal)
        .padding(.top, 4)
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if downloads.isRunning {
                DownloadProgressCard()
            }
            switch card {
            case .track(let track):
                TrackCard(track: track, profile: trackProfile,
                          onOpen: { if case .ready = trackProfile { details = .track(track) } },
                          onZoom: { controller.show(track.bbox) },
                          onClose: { card = nil })
            case .site(let site):
                SiteCard(site: site, updated: parkInfo.updatedText,
                         onOpen: { details = .site(site) }, onClose: { card = nil })
            case .rule(let rule):
                RuleCard(rule: rule, onOpen: { details = .rule(rule) }, onClose: { card = nil })
            case .closure(let closure):
                ClosureCard(closure: closure, updated: parkInfo.updatedText,
                            onOpen: { details = .closure(closure) },
                            onZoom: { controller.show(closure.bbox) },
                            onClose: { card = nil })
            case nil:
                EmptyView()
            }
            HStack {
                ScaleBar(mapView: mapView)
                    .frame(width: 170, height: 26, alignment: .leading)
                    .allowsHitTesting(false)
                Spacer()
            }
            HStack(spacing: 12) {
                RoundButton(systemImage: "location.fill", label: "My location") { controller.followUser() }
                Button {
                    showDownload = true
                } label: {
                    Label("Download area", systemImage: "arrow.down.circle.fill")
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .background(.tint, in: Capsule())
                        .foregroundStyle(.white)
                }
                .disabled(downloads.isRunning || offlineOnly)  // downloading needs the network
                .accessibilityHint(offlineOnly ? "Switch to Online to download" : "")
                RoundButton(systemImage: "square.stack.3d.down.right", label: "Offline maps") { showRegions = true }
            }
            Text(attribution)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(.horizontal)
        .padding(.bottom, 6)
    }

    private var attribution: String {
        source.id == TileSources.overview.id
            ? source.attribution
            : "\(source.attribution) · \(TileSources.overview.attribution)"
    }
}

private struct RoundButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 48, height: 48)
                .background(.regularMaterial, in: Circle())
        }
        .accessibilityLabel(label)
    }
}

struct DownloadProgressCard: View {
    @Environment(DownloadManager.self) private var downloads

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Downloading \(downloads.activeRegionName ?? "")")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Button("Cancel", role: .cancel) { downloads.cancel() }
                    .font(.subheadline)
            }
            ProgressView(value: downloads.progress.fraction)
            Text("\(downloads.progress.done + downloads.progress.failed) of \(downloads.progress.total) tiles · \(ByteCountFormatter.string(fromByteCount: downloads.progress.bytes, countStyle: .file))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
