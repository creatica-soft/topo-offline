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
                    Text("\(track.kind) · \(length)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    switch profile {
                    case .loading:
                        Label("Elevation…", systemImage: "chart.xyaxis.line").font(.caption).foregroundStyle(.secondary)
                    case .ready(let p):
                        Text("↑ \(Int(p.ascent)) m  ↓ \(Int(p.descent)) m · \(Int(p.lowest))–\(Int(p.highest)) m")
                            .font(.subheadline.weight(.medium)).monospacedDigit()
                        Label("Tap for elevation profile", systemImage: "chevron.up")
                            .font(.caption.weight(.medium)).foregroundStyle(.tint)
                    case .unavailable:
                        Text("No elevation data offline here").font(.caption).foregroundStyle(.secondary)
                    case nil:
                        EmptyView()
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
