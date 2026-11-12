import SwiftUI

/// Choose how much detail to download for the area currently on screen.
struct DownloadSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(DownloadManager.self) private var downloads

    let visibleArea: BoundingBox
    private let nationalWhenZoomedOut: Bool
    private let choices: [TileSource]

    @State private var sourceID: String
    @State private var name = ""
    @State private var minZoom: Int
    @State private var maxZoom: Int
    @State private var includeOverview = true

    /// `current` is the map shown on screen; it's used if it covers the area, otherwise the
    /// sheet picks the state map that does.
    init(current: TileSource, visibleArea: BoundingBox, nationalWhenZoomedOut: Bool) {
        self.visibleArea = visibleArea
        self.nationalWhenZoomedOut = nationalWhenZoomedOut
        let choices = TileSources.available(in: visibleArea, preferring: current)
        self.choices = choices
        let source = choices[0]
        _sourceID = State(initialValue: source.id)
        let zooms = Self.defaultZooms(for: source, area: visibleArea, nationalWhenZoomedOut: nationalWhenZoomedOut)
        _minZoom = State(initialValue: zooms.lowerBound)
        _maxZoom = State(initialValue: zooms.upperBound)
    }

    /// Full detail by default: everything the server has. Only if that's over the tile limit is
    /// the most detailed level dropped (the map then enlarges the next level when zoomed in).
    /// When the national map is shown zoomed out, state tiles below `detailFromZoom` are never
    /// displayed, so they're not downloaded (the national overview layer covers those zooms).
    private static func defaultZooms(for source: TileSource, area: BoundingBox,
                                     nationalWhenZoomedOut: Bool) -> ClosedRange<Int> {
        var lower = source.suggestedDownloadZooms.lowerBound
        if nationalWhenZoomedOut && source.id != TileSources.overview.id && source.usesNationalOverview {
            lower = max(lower, TileSources.detailFromZoom)
        }
        var upper = source.maxZoom
        lower = min(lower, upper)
        while upper > lower,
              let plan = DownloadManager.plan(name: "", area: area, source: source, zooms: lower...upper,
                                              includeOverview: true),
              DownloadManager.tileCount(of: plan) > DownloadLimits.maxTilesPerDownload {
            upper -= 1
        }
        return lower...upper
    }

    private var source: TileSource { TileSources.source(id: sourceID) ?? choices[0] }

    private var regionName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "\(source.name) – \(Date().formatted(date: .abbreviated, time: .omitted))" : trimmed
    }

    private var plan: OfflineRegion? {
        DownloadManager.plan(name: regionName, area: visibleArea, source: source,
                             zooms: minZoom...maxZoom,
                             includeOverview: includeOverview || nationalWhenZoomedOut)
    }
    private var tileCount: Int { plan.map(DownloadManager.tileCount(of:)) ?? 0 }
    private var estimatedBytes: Int64 { plan.map(DownloadManager.estimatedBytes(of:)) ?? 0 }
    private var tooBig: Bool { tileCount > DownloadLimits.maxTilesPerDownload }
    private var outsideCoverage: Bool { visibleArea.intersection(source.coverage) == nil }
    private var freeSpace: Int64? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
    private var notEnoughSpace: Bool { freeSpace.map { $0 < estimatedBytes * 2 } ?? false }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField(regionName, text: $name)
                }
                Section("Area") {
                    Picker("Map", selection: $sourceID) {
                        ForEach(choices) { s in
                            Text(s.name).tag(s.id)
                        }
                    }
                    if let box = visibleArea.intersection(source.coverage) {
                        LabeledContent("Size", value: String(format: "%.0f × %.0f km", box.widthKm, box.heightKm))
                    }
                }
                Section {
                    LabeledContent("Detail", value: maxZoom >= source.maxZoom ? "Full" : "Reduced")
                    DisclosureGroup("Advanced") {
                        // Ranges are guarded because the map can change before the zooms are reset.
                        Stepper("Least detail: zoom \(minZoom)", value: $minZoom,
                                in: source.minZoom...max(source.minZoom, maxZoom))
                        Stepper("Most detail: zoom \(maxZoom)", value: $maxZoom,
                                in: min(minZoom, source.maxZoom)...source.maxZoom)
                        // The overview is needed (and always included) when it's what shows zoomed out.
                        if source.id != TileSources.overview.id && source.usesNationalOverview && !nationalWhenZoomedOut {
                            Toggle("Include Australia overview map", isOn: $includeOverview)
                        }
                    }
                } header: {
                    Text("Detail")
                } footer: {
                    if maxZoom >= source.maxZoom {
                        Text("Everything this map has, down to the smallest height labels.")
                    } else {
                        Text("This area is too big for full detail, so the finest level is left out. You can still zoom in, but it will be less sharp. For full detail, zoom the map in to a smaller area before downloading.")
                    }
                }
                Section {
                    LabeledContent("Tiles", value: tileCount.formatted())
                    LabeledContent("Estimated size", value: ByteCountFormatter.string(fromByteCount: estimatedBytes, countStyle: .file))
                    if outsideCoverage {
                        Warning("This area is outside \(source.coverageName). Pick a different map or move the map.")
                    } else if tooBig {
                        Warning("Too large: the limit is \(DownloadLimits.maxTilesPerDownload.formatted()) tiles. Zoom the map in to a smaller area.")
                    } else if notEnoughSpace {
                        Warning("Your iPhone may not have enough free space for this download.")
                    }
                }
            }
            .onChange(of: sourceID) {
                let zooms = Self.defaultZooms(for: source, area: visibleArea, nationalWhenZoomedOut: nationalWhenZoomedOut)
                minZoom = zooms.lowerBound
                maxZoom = zooms.upperBound
            }
            .navigationTitle("Download area")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Download") {
                        if let plan { downloads.start(plan) }
                        dismiss()
                    }
                    .disabled(plan == nil || outsideCoverage || tooBig || downloads.isRunning)
                }
            }
        }
    }
}

private struct Warning: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.orange)
    }
}
