import SwiftUI

@main
struct TopoOfflineApp: App {
    @State private var store: RegionStore
    @State private var downloads: DownloadManager
    @State private var routes: RouteStore
    @State private var recorder: WalkRecorder

    init() {
        let store = RegionStore()
        let routes = RouteStore()
        _store = State(initialValue: store)
        _downloads = State(initialValue: DownloadManager(store: store))
        _routes = State(initialValue: routes)
        let recorder = WalkRecorder(store: routes)
        _recorder = State(initialValue: recorder)
        Notifications.shared.setUp()
        Notifications.shared.onPause = { recorder.pause() }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(downloads)
                .environment(routes)
                .environment(recorder)
        }
    }
}
