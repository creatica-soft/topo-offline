import SwiftUI

@main
struct TopoOfflineApp: App {
    @State private var store: RegionStore
    @State private var downloads: DownloadManager

    init() {
        let store = RegionStore()
        _store = State(initialValue: store)
        _downloads = State(initialValue: DownloadManager(store: store))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(downloads)
        }
    }
}
