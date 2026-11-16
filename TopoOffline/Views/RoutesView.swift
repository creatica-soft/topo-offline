import SwiftUI
import UniformTypeIdentifiers
import CoreTransferable

extension UTType {
    static let gpx = UTType(importedAs: "com.topografix.gpx", conformingTo: .xml)
}

/// A route as a .gpx file, for the share sheet.
struct GPXFile: Transferable {
    let route: SavedRoute

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .gpx) { file in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(GPX.fileName(for: file.route))
            try GPX.data(for: file.route).write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}

/// Saved routes and recorded walks, plus the recording settings.
struct RoutesView: View {
    @Environment(RouteStore.self) private var routes
    @Environment(\.dismiss) private var dismiss
    @AppStorage("recordingEnabled") private var recordingEnabled = false
    @Environment(\.units) private var units
    @AppStorage("recordingDetail") private var recordingDetail = WalkRecorder.Detail.standard.rawValue

    let onSelect: (SavedRoute) -> Void
    let onNewRoute: () -> Void
    let onEdit: (SavedRoute) -> Void

    @State private var importing = false
    @State private var importMessage: String?
    @State private var renaming: SavedRoute?
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        dismiss()
                        onNewRoute()
                    } label: {
                        Label("New route", systemImage: "plus.circle.fill")
                    }
                    Button {
                        importing = true
                    } label: {
                        Label("Import GPX file", systemImage: "square.and.arrow.down")
                    }
                } footer: {
                    Text("Tap the map to add points. Where there are walking tracks the route follows them; elsewhere it goes in a straight line.")
                }

                Section("Saved") {
                    if routes.routes.filter({ !$0.inProgress }).isEmpty {
                        Text("No routes yet").foregroundStyle(.secondary)
                    }
                    ForEach(routes.routes.filter { !$0.inProgress }) { route in
                        row(route)
                    }
                }

                Section {
                    Toggle("Record walks", isOn: $recordingEnabled)
                    if recordingEnabled {
                        Picker("Detail", selection: $recordingDetail) {
                            ForEach(WalkRecorder.Detail.allCases) { d in
                                Text(d.title).tag(d.rawValue)
                            }
                        }
                    }
                } header: {
                    Text("Recording")
                } footer: {
                    Text(recordingEnabled
                         ? "\(WalkRecorder.Detail(rawValue: recordingDetail)?.explanation ?? "") A record button appears on the map. Recording keeps GPS on while the phone is locked, which uses a lot more battery: carry a power bank on long walks. Your walks stay on your iPhone."
                         : "Off to save battery. When on, a record button appears on the map.")
                }
            }
            .navigationTitle("Routes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.gpx, .xml], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                let added = urls.flatMap { routes.importGPX(at: $0) }
                importMessage = added.isEmpty
                    ? "No routes or tracks found in that file."
                    : "Imported \(added.count == 1 ? "“\(added[0].name)”" : "\(added.count) routes")."
            }
            .alert(importMessage ?? "", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
                Button("OK", role: .cancel) {}
            }
            .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Save") { if let r = renaming { routes.rename(r, to: newName) } }
            }
        }
    }

    private func row(_ route: SavedRoute) -> some View {
        let shown = routes.shownIDs.contains(route.id)
        return HStack(spacing: 12) {
            Button {
                dismiss()
                onSelect(route)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: route.symbol)
                        .foregroundStyle(route.kind == .recorded ? .orange : .blue)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(route.name).foregroundStyle(.primary).lineLimit(2)
                        Text(RouteFormat.summary(route, units: units)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                routes.setShown(route.id, !shown)
            } label: {
                Image(systemName: shown ? "eye" : "eye.slash")
                    .foregroundStyle(shown ? Color.accentColor : .secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(shown ? "Hide on map" : "Show on map")
        }
        .swipeActions {
            Button(role: .destructive) { routes.delete(route) } label: { Label("Delete", systemImage: "trash") }
            Button { newName = route.name; renaming = route } label: { Label("Rename", systemImage: "pencil") }
        }
        .contextMenu {
            ShareLink(item: GPXFile(route: route), preview: SharePreview(GPX.fileName(for: route))) {
                Label("Share GPX", systemImage: "square.and.arrow.up")
            }
            if route.kind == .planned {
                Button { dismiss(); onEdit(route) } label: { Label("Edit", systemImage: "pencil.and.outline") }
            }
            Button { newName = route.name; renaming = route } label: { Label("Rename", systemImage: "pencil") }
            Button(role: .destructive) { routes.delete(route) } label: { Label("Delete", systemImage: "trash") }
        }
    }
}

/// Short descriptions of routes and times.
enum RouteFormat {
    static func duration(_ t: TimeInterval) -> String {
        let minutes = Int(t / 60)
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }

    static func summary(_ route: SavedRoute, units: Units) -> String {
        var parts = [route.kindName, units.distance(route.lengthMeters)]
        if let d = route.duration { parts.append(duration(d)) }
        parts.append(route.created.formatted(date: .abbreviated, time: .omitted))
        return parts.joined(separator: " · ")
    }
}
