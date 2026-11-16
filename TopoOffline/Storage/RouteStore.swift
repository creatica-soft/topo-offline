import Foundation
import Observation

/// Saved routes and recorded walks: one JSON file each in Application Support/Routes.
/// Unlike downloaded maps, these are the user's own work, so they're included in device backups.
@MainActor
@Observable
final class RouteStore {
    /// Newest first.
    private(set) var routes: [SavedRoute] = []
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

    /// Adds or replaces a route and writes its file.
    func save(_ route: SavedRoute) {
        if let i = routes.firstIndex(where: { $0.id == route.id }) {
            routes[i] = route
        } else {
            routes.insert(route, at: 0)
        }
        write(route)
    }

    func delete(_ route: SavedRoute) {
        routes.removeAll { $0.id == route.id }
        try? FileManager.default.removeItem(at: fileURL(route.id))
        setShown(route.id, false)
    }

    func rename(_ route: SavedRoute, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var r = self.route(id: route.id) else { return }
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
        let ids = Set(routes.map(\.id))
        shownIDs = Set((UserDefaults.standard.stringArray(forKey: shownKey) ?? []).compactMap(UUID.init)).intersection(ids)
    }
}
