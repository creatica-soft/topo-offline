import SwiftUI
import CoreLocation

/// Search official place names: peaks, creeks, gaps, parks, towns and named walking tracks.
/// Online it asks Geoscience Australia's gazetteer; offline (or with no signal) it searches the
/// names saved with downloaded areas.
struct SearchView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(RegionStore.self) private var store

    let center: CLLocationCoordinate2D?
    let offlineOnly: Bool
    let onSelect: (PlaceName) -> Void
    let onSelectTrack: (Track) -> Void

    @State private var text = ""
    @State private var results: [PlaceName] = []
    @State private var tracksByID: [String: Track] = [:]
    @State private var searching = false
    @State private var onlineFailed = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            List {
                if results.isEmpty {
                    emptyState
                } else {
                    Section {
                        ForEach(results) { place in
                            Button {
                                if let track = tracksByID[place.id] {
                                    onSelectTrack(track)
                                } else {
                                    onSelect(place)
                                }
                                dismiss()
                            } label: {
                                ResultRow(place: place, center: center)
                            }
                        }
                    } footer: {
                        if onlineFailed && !offlineOnly {
                            Text("No connection: showing names from your downloaded areas only.")
                        }
                    }
                }
                Section {
                } footer: {
                    Text(Gazetteer.attribution)
                }
            }
            .safeAreaInset(edge: .top) { searchField }
            .navigationTitle("Search")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task(id: text) { await runSearch() }
            .onAppear { focused = true }
        }
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Peak, creek, track, park or town", text: $text)
                .focused($focused)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if searching {
                ProgressView()
            } else if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .accessibilityLabel("Clear")
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var emptyState: some View {
        let typed = Gazetteer.tokens(of: text).joined().count
        if typed < 3 {
            Text(offlineOnly
                 ? "Offline: searching names in your downloaded areas."
                 : "Type at least 3 letters, e.g. \"barney\", \"six foot\" or \"wollangambe\".")
                .foregroundStyle(.secondary)
        } else if !searching {
            Text(offlineOnly && !store.library.hasOfflineNames
                 ? "No place names saved yet. Download an area while online to search it offline."
                 : "Nothing found.")
                .foregroundStyle(.secondary)
        }
    }

    private func runSearch() async {
        let query = text
        guard Gazetteer.tokens(of: query).joined().count >= 3 else {
            results = []
            searching = false
            return
        }
        // Instant offline results, then (if allowed) online results after a short typing pause.
        let localPlaces = store.library.searchNames(query, near: center)
        let localTracks = store.library.searchTracks(query)
        show(places: localPlaces, tracks: localTracks, query: query)
        onlineFailed = false
        guard !offlineOnly else { return }

        try? await Task.sleep(nanoseconds: 350_000_000)
        guard !Task.isCancelled else { return }
        searching = true
        defer { searching = false }
        let near = center
        async let tracksOnline: [Track] = Self.onlineTracks(query, near: near)
        do {
            let placesOnline = try await Gazetteer.search(query, near: center)
            let tracks = await tracksOnline
            guard !Task.isCancelled else { return }
            show(places: placesOnline + localPlaces, tracks: tracks + localTracks, query: query)
        } catch {
            _ = await tracksOnline
            if !Task.isCancelled { onlineFailed = true }
        }
    }

    private static func onlineTracks(_ query: String, near: CLLocationCoordinate2D?) async -> [Track] {
        guard let near else { return [] }
        return (try? await TrackSources.search(query, near: near)) ?? []
    }

    /// Merges place names and tracks. A track from the state data replaces the gazetteer's point for
    /// the same track, because it can be highlighted along its whole length.
    private func show(places: [PlaceName], tracks: [Track], query: String) {
        var byID: [String: Track] = [:]
        for t in tracks where (byID[t.id]?.segments.count ?? 0) < t.segments.count { byID[t.id] = t }
        let trackNames = Set(byID.values.compactMap { $0.name.map(Gazetteer.normalize) })
        let places = places.filter { !($0.category == "TRAIL" && trackNames.contains(Gazetteer.normalize($0.name))) }
        tracksByID = byID
        results = Array(Gazetteer.rank(places + byID.values.map(\.asPlace), for: query, near: center).prefix(50))
    }
}

private struct ResultRow: View {
    let place: PlaceName
    let center: CLLocationCoordinate2D?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name).foregroundStyle(.primary)
                Text(place.kind).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let center {
                Text(distance(place.distanceKm(from: center)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var icon: String {
        switch place.category {
        case "TRAIL": return "figure.hiking"
        case "LANDFORM": return "mountain.2"
        case "WATERWAY", "WATERBODY", "WATER POINT": return "drop"
        case "PROTECTED AREA": return "tree"
        case "POPULATED PLACE", "ADMINISTRATIVE AREA": return "house"
        default: return "mappin"
        }
    }

    private func distance(_ km: Double) -> String {
        km < 10 ? String(format: "%.1f km", km) : String(format: "%.0f km", km)
    }
}
