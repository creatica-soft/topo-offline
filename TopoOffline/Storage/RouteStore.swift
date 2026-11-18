import Foundation
import Observation

/// Saved routes and recorded walks: one JSON file each in Application Support/Routes.
/// Unlike downloaded maps, these are the user's own work, so they're included in device backups.
@MainActor
@Observable
final class RouteStore {
    /// Newest first, as shown: recordings with their stops tidied up (`SavedRoute.tidyingStops`).
    /// Files keep every recorded point; `original(_:)` gives them back (for GPX export and edits).
    private(set) var routes: [SavedRoute] = []
    /// Recordings as recorded, by id.
    private var originals: [UUID: SavedRoute] = [:]
    /// Routes drawn on the map.
    private(set) var shownIDs: Set<UUID> = []
    let directory: URL
    private let shownKey: String

    init(directory: URL = RouteStore.defaultDirectory, shownKey: String = "shownRouteIDs") {
        self.directory = directory
        self.shownKey = shownKey
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Routes", isDirectory: true)
    }

    var shown: [SavedRoute] { routes.filter { shownIDs.contains($0.id) && !$0.inProgress } }

    /// Changes whenever anything drawn on the map changes (cheap change detection for MapKit).
    var shownKeyForMap: String {
        shown.map { "\($0.id)|\($0.modified.timeIntervalSince1970)" }.joined(separator: ",")
    }

    func route(id: UUID) -> SavedRoute? { routes.first { $0.id == id } }

    /// A route as saved: for a recording, every recorded point.
    func original(_ route: SavedRoute) -> SavedRoute { originals[route.id] ?? route }

    /// Adds or replaces a route (as recorded or planned, not a tidied copy) and writes its file.
    func save(_ route: SavedRoute) {
        let shown = remember(route)
        if let i = routes.firstIndex(where: { $0.id == route.id }) {
            routes[i] = shown
        } else {
            routes.insert(shown, at: 0)
        }
        write(route)
    }

    /// Works the stops out again after the stop rule changes in Settings.
    func retidy() {
        routes = routes.map { remember(original($0)) }
    }

    /// Keeps a recording's original and returns the copy to show.
    private func remember(_ route: SavedRoute) -> SavedRoute {
        guard route.kind == .recorded else { originals[route.id] = nil; return route }
        originals[route.id] = route
        return route.tidyingStops()
    }

    func delete(_ route: SavedRoute) {
        routes.removeAll { $0.id == route.id }
        originals[route.id] = nil
        try? FileManager.default.removeItem(at: fileURL(route.id))
        setShown(route.id, false)
    }

    func rename(_ route: SavedRoute, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var r = self.route(id: route.id).map(original) else { return }
        r.name = trimmed
        r.modified = Date()
        save(r)
    }

    func setShown(_ id: UUID, _ shown: Bool) {
        if shown { shownIDs.insert(id) } else { shownIDs.remove(id) }
        UserDefaults.standard.set(shownIDs.map(\.uuidString), forKey: shownKey)
    }

    /// Reads a GPX file into new routes (shown on the map). Returns what was added.
    @discardableResult
    func importGPX(_ data: Data, fileName: String) -> [SavedRoute] {
        let name = (fileName as NSString).deletingPathExtension
        let added = GPX.routes(from: data, fallbackName: name.isEmpty ? "Imported route" : name)
        for r in added.reversed() {
            save(r)
            setShown(r.id, true)
        }
        return added
    }

    /// Imports a GPX file picked in Files or opened from another app. Files that iOS copied into
    /// the app's Inbox are deleted afterwards.
    @discardableResult
    func importGPX(at url: URL) -> [SavedRoute] {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return [] }
        let added = importGPX(data, fileName: url.lastPathComponent)
        if url.path.contains("/Documents/Inbox/") { try? FileManager.default.removeItem(at: url) }
        return added
    }

    func fileURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }

    private func write(_ route: SavedRoute) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(route) else { return }
        try? data.write(to: fileURL(route.id), options: .atomic)
    }

    private func load() {
        let decoder = JSONDecoder()
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        routes = files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(SavedRoute.self, from: Data(contentsOf: $0)) }
            .sorted { $0.created > $1.created }
            .map { remember($0) }
        let ids = Set(routes.map(\.id))
        shownIDs = Set((UserDefaults.standard.stringArray(forKey: shownKey) ?? []).compactMap(UUID.init)).intersection(ids)
    }
}
