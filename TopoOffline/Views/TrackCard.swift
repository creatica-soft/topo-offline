import SwiftUI

/// Shown at the bottom when a track is highlighted.
struct TrackCard: View {
    let track: Track
    var profile: ProfileState? = nil
    var onOpen: () -> Void = {}
    let onZoom: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "figure.hiking")
                .font(.title3)
                .foregroundStyle(.purple)
                .frame(width: 28)
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.displayName)
                        .font(.headline)
                        .lineLimit(2)
                    // One fact per line, so it reads well with large text sizes too.
                    Text(track.kind)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    switch profile {
                    case .ready(let p):
                        Text("\(length) · ↑ \(Int(p.ascent)) m ↓ \(Int(p.descent)) m")
                            .font(.subheadline.weight(.medium)).monospacedDigit()
                        if p.lengthKm < track.lengthKm * 0.9 {
                            Text("Climb for \(String(format: "%.0f", p.lengthKm)) of \(String(format: "%.0f", track.lengthKm)) km")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Label("Tap for elevation profile", systemImage: "chevron.up")
                            .font(.caption.weight(.medium)).foregroundStyle(.tint)
                    case .loading:
                        Text(length).font(.subheadline.weight(.medium)).monospacedDigit()
                        Label("Elevation…", systemImage: "chart.xyaxis.line").font(.caption).foregroundStyle(.secondary)
                    case .unavailable:
                        Text(length).font(.subheadline.weight(.medium)).monospacedDigit()
                        Text("Elevation isn't saved for all of this track. Go online to load it.")
                            .font(.caption).foregroundStyle(.secondary)
                    case nil:
                        Text(length).font(.subheadline.weight(.medium)).monospacedDigit()
                    }
                    if let credit = TrackSources.attribution(for: track.state) {
                        Text(credit)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            Button(action: onZoom) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Show whole track")
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Close")
        }
        .padding(.leading, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var length: String {
        track.lengthKm < 1
            ? "\(Int((track.lengthKm * 1000 / 10).rounded()) * 10) m"
            : String(format: "%.1f km", track.lengthKm)
    }
}
