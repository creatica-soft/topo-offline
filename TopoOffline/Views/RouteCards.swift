import SwiftUI
import CoreLocation

/// Shown while drawing a route: distance and climb so far, and the drawing controls.
struct RoutePlannerCard: View {
    @Bindable var planner: RoutePlanner
    let profile: Elevation.Profile?
    let onSave: () -> Void
    let onCancel: () -> Void
    @Environment(\.units) private var units

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                if planner.isBusy { ProgressView().controlSize(.small) }
                Spacer()
                Text(summary).font(.subheadline.weight(.medium)).monospacedDigit()
            }
            Text(hint).font(.caption).foregroundStyle(.secondary)
            if planner.legTooLong {
                Label("Points over \(units.roundDistance(TrackRouter.maxDistance)) apart are joined in a straight line. Add points in between to follow tracks.",
                      systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            if let i = selected, planner.isEnd(i), planner.waypoints.count > 1 {
                Picker("Tap the map to", selection: $planner.extendsFromSelected) {
                    Text(i == 0 ? "Move start" : "Move end").tag(false)
                    Text(i == 0 ? "Add before start" : "Add after end").tag(true)
                }
                .pickerStyle(.segmented)
            }
            Picker("New legs", selection: $planner.followTracks) {
                Label("Follow tracks", systemImage: "point.topleft.down.to.point.bottomright.curvepath").tag(true)
                Label("Straight", systemImage: "line.diagonal").tag(false)
            }
            .pickerStyle(.segmented)
            if let i = selected {
                HStack {
                    Button(role: .destructive) { planner.remove(i) } label: { Label("Delete point", systemImage: "trash") }
                    Spacer()
                    Button { planner.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                        .disabled(!planner.canUndo)
                    Spacer()
                    Button("Done") { planner.select(nil) }
                        .fontWeight(.semibold)
                }
                .buttonStyle(.bordered)
            } else {
                HStack {
                    Button("Cancel", role: .cancel, action: onCancel)
                    Spacer()
                    Button { planner.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                        .disabled(!planner.canUndo)
                    Spacer()
                    Button("Save", action: onSave)
                        .fontWeight(.semibold)
                        .disabled(planner.waypoints.count < 2 || planner.isBusy)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    /// The selected point, if it still exists.
    private var selected: Int? {
        planner.selected.flatMap { planner.waypoints.indices.contains($0) ? $0 : nil }
    }

    private var title: String {
        guard let i = selected else { return planner.editing == nil ? "New route" : "Edit route" }
        if i == 0 { return "Start selected" }
        return i == planner.waypoints.count - 1 ? "End selected" : "Point \(i + 1) selected"
    }

    private var hint: String {
        if let i = selected {
            if planner.extendsFromSelected, planner.isEnd(i), planner.waypoints.count > 1 {
                return i == 0 ? "Tap the map to add points before the start." : "Tap the map to add points after the end."
            }
            return "Tap the map to move this point there, or drag it."
        }
        switch planner.waypoints.count {
        case 0: return "Tap the map where the route starts."
        case 1: return "Tap the next point. Zoom in to place points on tracks."
        default: return "Tap the map to add a point, or the line to insert one. Tap a point to move or delete it."
        }
    }

    private var summary: String {
        guard planner.waypoints.count >= 2 else { return "" }
        var s = units.distance(planner.lengthMeters)
        if let p = profile { s += " · \(units.climb(up: p.ascent, down: p.descent))" }
        return s
    }
}

/// Shown while recording: time, distance, climb and GPS status, with a Stop button.
struct RecordingCard: View {
    let recorder: WalkRecorder
    let onStop: () -> Void
    @Environment(\.units) private var units

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "record.circle")
                .font(.title2)
                .foregroundStyle(.red)
                .symbolEffect(.pulse)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 10) {
                    if let start = recorder.startDate {
                        Text(start, style: .timer).monospacedDigit()
                    }
                    Text(units.distance(recorder.distance)).monospacedDigit()
                    Text("↑ \(units.height(recorder.climb.up))").monospacedDigit()
                }
                .font(.subheadline.weight(.semibold))
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(action: onStop) {
                Label("Stop", systemImage: "stop.fill")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
    }

    private var status: String {
        guard let fix = recorder.lastFix else { return "Waiting for GPS…" }
        var parts: [String] = []
        if let alt = fix.altitude { parts.append("\(units.height(alt)) elevation") }
        if fix.horizontalAccuracy > 0 { parts.append("GPS ±\(units.height(fix.horizontalAccuracy))") }
        return parts.isEmpty ? "Recording" : parts.joined(separator: " · ")
    }
}

/// A saved route or recorded walk: the track card (length, climb, profile) plus route actions.
struct RouteCard: View {
    let route: SavedRoute
    let profile: ProfileState?
    let isFollowing: Bool
    let onOpen: () -> Void
    let onZoom: () -> Void
    let onClose: () -> Void
    let onFollow: () -> Void
    let onEdit: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            TrackCard(track: route.asTrack, profile: profile, onOpen: onOpen, onZoom: onZoom, onClose: onClose)
            HStack(spacing: 8) {
                Button(action: onFollow) {
                    Label(isFollowing ? "Stop following" : "Follow", systemImage: isFollowing ? "xmark" : "location.north.line")
                }
                ShareLink(item: GPXFile(route: route), preview: SharePreview(GPX.fileName(for: route))) {
                    Label("GPX", systemImage: "square.and.arrow.up")
                }
                if route.kind == .planned {
                    Button(action: onEdit) { Label("Edit", systemImage: "pencil") }
                }
                if let d = route.duration {
                    Spacer(minLength: 0)
                    Label(RouteFormat.duration(d), systemImage: "clock")
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
            }
            .font(.subheadline.weight(.medium))
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

/// Top-of-screen progress while following a route.
struct FollowChip: View {
    let route: SavedRoute
    let progress: RouteProgress?
    let onStop: () -> Void
    @Environment(\.units) private var units

    var body: some View {
        HStack(spacing: 0) {
            Label(text, systemImage: progress?.isOffRoute == true ? "exclamationmark.triangle.fill" : "location.north.line.fill")
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .lineLimit(2)
                .padding(.leading, 14)
                .padding(.vertical, 6)
            Button(action: onStop) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Stop following")
        }
        .background(progress?.isOffRoute == true ? AnyShapeStyle(Color.orange.opacity(0.9)) : AnyShapeStyle(.regularMaterial),
                    in: Capsule())
        .padding(.horizontal)
    }

    private var text: String {
        guard let p = progress else { return "Following \(route.name): waiting for your location…" }
        if p.isOffRoute { return "Off route by \(units.distance(p.offBy))" }
        return "\(units.distance(p.done)) done · \(units.distance(p.remaining)) to go"
    }
}
