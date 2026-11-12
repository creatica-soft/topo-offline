import SwiftUI

/// Downloaded areas: open, resume, rename or delete.
struct RegionsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(RegionStore.self) private var store
    @Environment(DownloadManager.self) private var downloads

    let onSelect: (OfflineRegion) -> Void

    @State private var renaming: OfflineRegion?
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                if downloads.isRunning {
                    Section("Downloading") {
                        DownloadProgressCard()
                            .listRowInsets(EdgeInsets())
                    }
                }
                if case .failed(let message) = downloads.state {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }

                Section {
                    if store.regions.isEmpty {
                        ContentUnavailableView("No offline maps yet",
                                               systemImage: "map",
                                               description: Text("Move the map to where you're going and tap Download area."))
                    }
                    ForEach(store.regions) { region in
                        row(region)
                    }
                } footer: {
                    if !store.regions.isEmpty {
                        Text("Using \(ByteCountFormatter.string(fromByteCount: store.totalBytes, countStyle: .file)) on this iPhone.")
                    }
                }

                Section {
                    NavigationLink("About, privacy and map credits") { AboutView() }
                }
            }
            .navigationTitle("Offline maps")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Save") {
                    if let r = renaming, !newName.trimmingCharacters(in: .whitespaces).isEmpty {
                        store.rename(r, to: newName)
                    }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
        }
    }

    @ViewBuilder
    private func row(_ region: OfflineRegion) -> some View {
        let isActive = downloads.activeRegionID == region.id
        Button {
            onSelect(region)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(region.name).font(.headline).foregroundStyle(.primary)
                Text(details(region)).font(.caption).foregroundStyle(.secondary)
                if !region.isComplete && !isActive {
                    Text(region.failedTiles > 0 ? "\(region.failedTiles) tiles failed – tap Resume to retry" : "Incomplete – tap Resume to finish")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .swipeActions(edge: .trailing) {
            if !isActive {
                Button(role: .destructive) { store.delete(region) } label: { Label("Delete", systemImage: "trash") }
            }
            Button {
                newName = region.name
                renaming = region
            } label: { Label("Rename", systemImage: "pencil") }
        }
        .swipeActions(edge: .leading) {
            if !region.isComplete && !downloads.isRunning {
                Button { downloads.start(region) } label: { Label("Resume", systemImage: "arrow.down.circle") }
                    .tint(.blue)
            }
        }
    }

    private func details(_ region: OfflineRegion) -> String {
        let size = ByteCountFormatter.string(fromByteCount: store.bytes(of: region), countStyle: .file)
        let map = region.primarySource?.name ?? "Map"
        let zooms = region.layers.first.map { "zoom \($0.minZoom)–\($0.maxZoom)" } ?? ""
        return "\(map) · \(zooms) · \(size) · \(region.createdAt.formatted(date: .abbreviated, time: .omitted))"
    }
}
