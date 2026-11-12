import SwiftUI
import Charts
import CoreLocation

/// Where the elevation profile for the selected track is up to.
enum ProfileState: Equatable {
    case loading
    case ready(Elevation.Profile)
    case unavailable  // e.g. offline in an area downloaded without elevation data
}

/// Elevation profile sheet: chart (drag along it to see the spot on the map), and totals.
struct TrackDetailView: View {
    let track: Track
    let profile: Elevation.Profile
    /// Called with the position on the track while dragging along the chart (nil when released).
    let onScrub: (CLLocationCoordinate2D?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var reversed = false
    @State private var selectedKm: Double?

    private var shown: Elevation.Profile { reversed ? profile.reversed() : profile }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("\(track.kind) · \(String(format: "%.1f", shown.lengthKm)) km")
                        .foregroundStyle(.secondary)
                    readout
                    chart
                    stats
                    if !shown.coversWholeTrack {
                        Label("The profile covers \(String(format: "%.0f", shown.lengthKm)) of \(String(format: "%.0f", track.lengthKm)) km: side tracks and far-off sections aren't included.",
                              systemImage: "info.circle")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if shown.bridgedGaps {
                        Label("Where the published track has gaps (often where it follows a road), the profile joins them in a straight line.",
                              systemImage: "info.circle")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("Elevations are from 30 m terrain data (8 m in New Zealand) and smoothed, so totals are approximate.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text(Elevation.attribution).font(.caption2).foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle(track.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        reversed.toggle()
                        selectedKm = nil
                    } label: {
                        Label("Reverse", systemImage: "arrow.left.arrow.right")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .onChange(of: selectedKm) {
            onScrub(selectedKm.flatMap { shown.point(atDistance: $0 * 1000) })
        }
        .onDisappear { onScrub(nil) }
    }

    private var yDomain: ClosedRange<Double> {
        let pad = max(20, (shown.highest - shown.lowest) * 0.1)
        return (shown.lowest - pad)...(shown.highest + pad)
    }

    private var chart: some View {
        Chart {
            ForEach(shown.distances.indices, id: \.self) { i in
                AreaMark(x: .value("Distance", shown.distances[i] / 1000),
                         yStart: .value("Base", yDomain.lowerBound),
                         yEnd: .value("Elevation", shown.elevations[i]))
                    .foregroundStyle(.linearGradient(colors: [.purple.opacity(0.35), .purple.opacity(0.05)],
                                                     startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Distance", shown.distances[i] / 1000),
                         y: .value("Elevation", shown.elevations[i]))
                    .foregroundStyle(.purple)
            }
            if let km = selectedKm, let e = elevation(atKm: km) {
                RuleMark(x: .value("Selected", km))
                    .foregroundStyle(Color.gray.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("Selected", km), y: .value("Elevation", e))
                    .foregroundStyle(.purple)
                    .symbolSize(80)
            }
        }
        .chartYScale(domain: yDomain)
        .chartXAxisLabel("km")
        .chartYAxisLabel("m")
        .chartXSelection(value: $selectedKm)
        .frame(height: 220)
        .accessibilityLabel("Elevation profile, \(Int(shown.lowest)) to \(Int(shown.highest)) metres")
    }

    /// Reading while dragging along the chart; a hint otherwise. Fixed height so nothing jumps.
    private var readout: some View {
        HStack(spacing: 6) {
            if let km = selectedKm, let e = elevation(atKm: km) {
                Image(systemName: "mappin.circle.fill").foregroundStyle(.purple)
                Text("\(String(format: "%.1f", km)) km · \(Int(e)) m")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
            } else {
                Image(systemName: "hand.draw").foregroundStyle(.secondary)
                Text("Drag along the chart to see the spot on the map")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 28, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var stats: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
            GridRow {
                stat("Climb", "↑ \(Int(shown.ascent)) m")
                stat("Descent", "↓ \(Int(shown.descent)) m")
            }
            GridRow {
                stat("Highest", "\(Int(shown.highest)) m")
                stat("Lowest", "\(Int(shown.lowest)) m")
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
        }
    }

    private func elevation(atKm km: Double) -> Double? {
        let d = km * 1000
        guard let i = shown.distances.firstIndex(where: { $0 >= d }) else { return shown.elevations.last }
        return shown.elevations[i]
    }
}
