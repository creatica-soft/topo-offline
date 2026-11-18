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
    /// Recorded walks (and GPX tracks with times): speed along it, and moving and stopped time.
    var speed: WalkSpeed? = nil
    /// Called with the position on the track while dragging along the chart (nil when released).
    let onScrub: (CLLocationCoordinate2D?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.units) private var units
    @State private var reversed = false
    /// The chart position being touched, in km or miles.
    @State private var selected: Double?

    private var shown: Elevation.Profile { reversed ? profile.reversed() : profile }
    private var shownSpeed: WalkSpeed? { reversed ? speed?.reversed() : speed }
    /// Both charts share the x axis, so dragging one lines up with the other.
    private var xDomain: ClosedRange<Double> { 0...max(0.01, units.distanceValue(shown.lengthKm * 1000)) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("\(track.kind) · \(units.distance(shown.lengthKm * 1000))")
                        .foregroundStyle(.secondary)
                    readout
                    chart
                    if let shownSpeed { speedChart(shownSpeed) }
                    stats
                    if !shown.coversWholeTrack {
                        Label("The profile covers \(units.roundDistance(shown.lengthKm * 1000)) of \(units.roundDistance(track.lengthKm * 1000)): side tracks and far-off sections aren't included.",
                              systemImage: "info.circle")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if shown.bridgedGaps {
                        Label("Where the published track has gaps (often where it follows a road), the profile joins them in a straight line.",
                              systemImage: "info.circle")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if speed != nil {
                        Text("Speed is worked out from the GPS times, averaged over about \(units.distance(2 * WalkSpeed.window)). Staying within \(units.distance(StopFinder.Rule.current.radius)) of one spot for \(Int(StopFinder.Rule.current.duration / 60)) minutes or more counts as stopped (change it in Settings › Recording), and the average speed leaves stops out.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("Elevations are from terrain data (a 10–30 m grid, depending on the country) and smoothed, so totals are approximate.")
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
                        selected = nil
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
        .onChange(of: selected) {
            onScrub(selected.flatMap { shown.point(atDistance: units.meters(fromDistanceValue: $0)) })
        }
        .onDisappear { onScrub(nil) }
    }

    /// Chart height range, in metres or feet.
    private var yDomain: ClosedRange<Double> {
        let pad = max(20, (shown.highest - shown.lowest) * 0.1)
        return units.heightValue(shown.lowest - pad)...units.heightValue(shown.highest + pad)
    }

    private var chart: some View {
        Chart {
            ForEach(shown.distances.indices, id: \.self) { i in
                AreaMark(x: .value("Distance", units.distanceValue(shown.distances[i])),
                         yStart: .value("Base", yDomain.lowerBound),
                         yEnd: .value("Elevation", units.heightValue(shown.elevations[i])))
                    .foregroundStyle(.linearGradient(colors: [.purple.opacity(0.35), .purple.opacity(0.05)],
                                                     startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Distance", units.distanceValue(shown.distances[i])),
                         y: .value("Elevation", units.heightValue(shown.elevations[i])))
                    .foregroundStyle(.purple)
            }
            if let x = selected, let e = elevation(at: x) {
                RuleMark(x: .value("Selected", x))
                    .foregroundStyle(Color.gray.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("Selected", x), y: .value("Elevation", units.heightValue(e)))
                    .foregroundStyle(.purple)
                    .symbolSize(80)
            }
        }
        .chartYScale(domain: yDomain)
        .chartXScale(domain: xDomain)
        .chartXAxisLabel(units.distanceUnit)
        .chartYAxisLabel(units.heightUnit)
        .chartXSelection(value: $selected)
        .frame(height: speed == nil ? 220 : 150)  // shorter with the speed chart, so both fit half a screen
        .accessibilityLabel("Elevation profile, \(Int(units.heightValue(shown.lowest))) to \(Int(units.heightValue(shown.highest))) \(units.heightUnitName)")
    }

    /// Reading while dragging along the chart; a hint otherwise. Fixed height so nothing jumps.
    private var readout: some View {
        HStack(spacing: 6) {
            if let x = selected, let e = elevation(at: x) {
                Image(systemName: "mappin.circle.fill").foregroundStyle(.purple)
                Text("\(String(format: "%.1f", x)) \(units.distanceUnit) · \(units.height(e))"
                     + (shownSpeed?.speed(atDistance: units.meters(fromDistanceValue: x)).map { " · \(units.speed($0))" } ?? ""))
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
                stat("Climb", "↑ \(units.height(shown.ascent))")
                stat("Descent", "↓ \(units.height(shown.descent))")
            }
            GridRow {
                stat("Highest", units.height(shown.highest))
                stat("Lowest", units.height(shown.lowest))
            }
            if let shownSpeed { speedStats(shownSpeed) }
        }
    }

    private func speedChart(_ s: WalkSpeed) -> some View {
        Chart {
            ForEach(s.distances.indices, id: \.self) { i in
                LineMark(x: .value("Distance", units.distanceValue(s.distances[i])),
                         y: .value("Speed", units.speedValue(s.speeds[i])))
                    .foregroundStyle(.teal)
                    .interpolationMethod(.monotone)
            }
            if let x = selected, let v = s.speed(atDistance: units.meters(fromDistanceValue: x)) {
                RuleMark(x: .value("Selected", x))
                    .foregroundStyle(Color.gray.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("Selected", x), y: .value("Speed", units.speedValue(v)))
                    .foregroundStyle(.teal)
                    .symbolSize(80)
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: 0...max(1, units.speedValue(s.speeds.max() ?? 1) * 1.15))
        .chartXAxisLabel(units.distanceUnit)
        .chartYAxisLabel(units.speedUnit)
        .chartXSelection(value: $selected)
        .frame(height: 110)
        .accessibilityLabel("Speed along the trip, averaging \(units.speed(s.averageMoving)) while moving")
    }

    @ViewBuilder
    private func speedStats(_ s: WalkSpeed) -> some View {
        GridRow {
            stat("Moving time", RouteFormat.duration(s.movingTime))
            stat("Stopped", RouteFormat.duration(s.stoppedTime))
        }
        GridRow {
            stat("Average speed", units.speed(s.averageMoving))
            stat("Total time", RouteFormat.duration(s.totalTime))
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
        }
    }

    /// Elevation in metres at a chart position (km or miles).
    private func elevation(at x: Double) -> Double? {
        let d = units.meters(fromDistanceValue: x)
        guard let i = shown.distances.firstIndex(where: { $0 >= d }) else { return shown.elevations.last }
        return shown.elevations[i]
    }
}
