import SwiftUI

/// The sheets, alerts and background work for routes and recording, kept out of `ContentView`'s
/// body (which is already long enough to slow the compiler down).
struct RouteFeatures: ViewModifier {
    @Binding var showRoutes: Bool
    @Binding var namingRoute: Bool
    @Binding var leftoverWalk: SavedRoute?
    @Binding var importMessage: String?
    let planner: RoutePlanner?
    @Binding var plannerProfile: Elevation.Profile?
    let recorder: WalkRecorder
    let follower: RouteFollower
    let scenePhase: ScenePhase
    let offlineOnly: Bool
    let library: OfflineTileLibrary
    let onSelect: (SavedRoute) -> Void
    let onNewRoute: () -> Void
    let onEdit: (SavedRoute) -> Void
    let onSaveRoute: () -> Void
    let onContinueWalk: (SavedRoute) -> Void
    let onFinishWalk: (SavedRoute) -> Void
    let onOpenFile: (URL) -> Void
    let onAppear: () -> Void

    private var plannerKey: String {
        planner.map { "\(ObjectIdentifier($0).hashValue)|\($0.version)|\(offlineOnly)" } ?? ""
    }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showRoutes) {
                RoutesView(onSelect: onSelect, onNewRoute: onNewRoute, onEdit: onEdit)
            }
            .alert("Name this route", isPresented: $namingRoute) {
                if let planner {
                    TextField("Name", text: Bindable(planner).name)
                }
                Button("Cancel", role: .cancel) {}
                Button("Save", action: onSaveRoute)
            }
            .alert("Continue recording?",
                   isPresented: Binding(get: { leftoverWalk != nil }, set: { if !$0 { leftoverWalk = nil } }),
                   presenting: leftoverWalk) { walk in
                Button("Continue") { onContinueWalk(walk) }
                Button("Finish and save") { onFinishWalk(walk) }
            } message: { walk in
                Text("“\(walk.name)” was still recording when Topo Offline closed. Points weren't recorded while it was closed.")
            }
            .alert("Location access is off",
                   isPresented: Binding(get: { recorder.permissionProblem || follower.permissionProblem },
                                        set: { recorder.permissionProblem = $0; follower.permissionProblem = $0 })) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Recording a walk or following a route needs location access. Allow it in Settings › Topo Offline › Location (While Using the App).")
            }
            .alert(importMessage ?? "",
                   isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
                Button("OK", role: .cancel) {}
            }
            .onOpenURL { onOpenFile($0) }
            .onChange(of: scenePhase) {
                if scenePhase != .active { recorder.saveNow() }
            }
            // Distance and climb for the route being drawn, shortly after each change.
            .task(id: plannerKey) {
                guard let planner, planner.waypoints.count >= 2 else {
                    plannerProfile = nil
                    return
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                let profile = await Elevation.profile(for: planner.route.asTrack, library: library, offlineOnly: offlineOnly)
                guard !Task.isCancelled else { return }
                plannerProfile = profile
            }
            .onAppear(perform: onAppear)
    }
}
