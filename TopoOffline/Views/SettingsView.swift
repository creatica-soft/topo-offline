import SwiftUI

/// Map choice and the app's settings, opened from the gear button on the map.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("sourceID") private var sourceID = TileSources.defaultSource().id
    @AppStorage("nationalWhenZoomedOut") private var nationalWhenZoomedOut = true
    @AppStorage("units") private var unitSetting = UnitSetting.automatic.rawValue
    @AppStorage("recordingEnabled") private var recordingEnabled = false
    @AppStorage("recordingDetail") private var recordingDetail = WalkRecorder.Detail.standard.rawValue
    @Environment(\.units) private var units

    /// Countries with maps, in the order they're listed.
    private static let countries: [(code: String, name: String)] = [
        ("AU", "Australia"), ("NZ", "New Zealand"), ("US", "United States"),
        ("CA", "Canada"), ("CH", "Switzerland"), ("NO", "Norway"),
    ]

    private var source: TileSource { TileSources.source(id: sourceID) ?? TileSources.defaultSource() }
    /// Maps of the selected country (Australia has one per state, plus the national map).
    private var countryMaps: [TileSource] { TileSources.all.filter { $0.country == source.country } }

    /// Choosing a country picks its map (in Australia, NSW: the state can be changed below).
    private var country: Binding<String> {
        Binding(get: { source.country },
                set: { code in
                    if let first = TileSources.all.first(where: { $0.country == code }) { sourceID = first.id }
                })
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Country", selection: country) {
                        ForEach(Self.countries.filter { c in TileSources.all.contains { $0.country == c.code } }, id: \.code) { c in
                            Text(c.name).tag(c.code)
                        }
                    }
                    if countryMaps.count > 1 {
                        Picker("State", selection: $sourceID) {
                            ForEach(countryMaps) { m in
                                Text(m.id == TileSources.overview.id ? "Whole country (1:250k)" : m.coverageName).tag(m.id)
                            }
                        }
                    }
                    LabeledContent("Map", value: source.name)
                    if source.usesNationalOverview && source.id != TileSources.overview.id {
                        Toggle(isOn: $nationalWhenZoomedOut) {
                            Text("National map when zoomed out")
                            Text("State maps appear from about \(units.roundDistance(10_000)) across")
                        }
                    }
                } header: {
                    Text("Map")
                } footer: {
                    Text(source.allowsOffline
                         ? "The map also switches by itself when you move into another state or country."
                         : "\(source.name) works online only for now: saving it for offline use needs the provider's permission, which has been asked for. The map also switches by itself when you move into another state or country.")
                }

                Section {
                    Picker("Units", selection: $unitSetting) {
                        Text("Automatic (\(Units(.automatic).imperial ? "miles, feet" : "km, metres"))").tag(UnitSetting.automatic.rawValue)
                        Text("Metric (km, metres)").tag(UnitSetting.metric.rawValue)
                        Text("Imperial (miles, feet)").tag(UnitSetting.imperial.rawValue)
                    }
                } footer: {
                    Text("Automatic follows your iPhone's region settings.")
                }

                Section {
                    Toggle("Record walks", isOn: $recordingEnabled)
                    if recordingEnabled {
                        Picker("Detail", selection: $recordingDetail) {
                            ForEach(WalkRecorder.Detail.allCases) { d in
                                Text(d.title).tag(d.rawValue)
                            }
                        }
                    }
                } header: {
                    Text("Walk recording")
                } footer: {
                    Text(recordingEnabled
                         ? "\(WalkRecorder.Detail(rawValue: recordingDetail)?.explanation ?? "") A record button appears on the map. Recording keeps GPS on while the phone is locked, which uses a lot more battery: carry a power bank on long walks. Your walks stay on your iPhone."
                         : "Off to save battery. When on, a record button appears on the map.")
                }

                Section {
                    NavigationLink("About, privacy and map credits") { AboutView() }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
