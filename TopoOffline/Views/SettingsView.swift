import SwiftUI

/// Map choice and the app's settings, opened from the gear button on the map.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("sourceID") private var sourceID = TileSources.defaultSource().id
    @AppStorage("nationalWhenZoomedOut") private var nationalWhenZoomedOut = true
    @AppStorage("units") private var unitSetting = UnitSetting.automatic.rawValue
    @AppStorage("recordingEnabled") private var recordingEnabled = false
    @AppStorage("recordingDetail") private var recordingDetail = WalkRecorder.Detail.standard.rawValue
    @AppStorage(RouteFollower.warnKey) private var warnMeters = RouteProgress.offRouteMeters
    @AppStorage(StopFinder.Rule.radiusKey) private var stopRadius = StopFinder.Rule.standard.radius
    @AppStorage(StopFinder.Rule.durationKey) private var stopDuration = StopFinder.Rule.standard.duration
    @AppStorage(WalkRecorder.reminderKey) private var pauseReminder = true
    @Environment(RouteStore.self) private var routes
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
                    Toggle("Record walks and rides", isOn: $recordingEnabled)
                    if recordingEnabled {
                        Picker("Detail", selection: $recordingDetail) {
                            ForEach(WalkRecorder.Detail.allCases) { d in
                                Text(d.title).tag(d.rawValue)
                            }
                        }
                    }
                } header: {
                    Text("Recording")
                } footer: {
                    Text(recordingEnabled
                         ? "\(WalkRecorder.Detail(rawValue: recordingDetail)?.explanation ?? "") A record button appears on the map. Recording keeps GPS on while the phone is locked, which uses a lot more battery: carry a power bank on long trips. Your recordings stay on your iPhone."
                         : "Off to save battery. When on, a record button appears on the map.")
                }

                if recordingEnabled {
                    Section {
                        Picker("Stopped when within", selection: $stopRadius) {
                            ForEach(StopFinder.Rule.radiusChoices, id: \.self) { Text(units.distance($0)).tag($0) }
                        }
                        Picker("For at least", selection: $stopDuration) {
                            ForEach(StopFinder.Rule.durationChoices, id: \.self) { Text("\(Int($0 / 60)) min").tag($0) }
                        }
                        Toggle("Remind me to pause", isOn: $pauseReminder)
                    } header: {
                        Text("Stops")
                    } footer: {
                        Text("Staying within \(units.distance(stopRadius)) of one spot for \(Int(stopDuration / 60)) minutes counts as a stop: it isn't counted in moving time or speed, and GPS wandering there (indoors, around camp) isn't drawn or added to the distance. A larger distance or shorter time catches more stops, but walking slower than about \(units.speed(StopFinder.Rule(radius: stopRadius, duration: stopDuration).slowestMoving)) could then count as stopped. The reminder is a notification with a Pause button, so a long stop doesn't run the battery down. Pausing is always the surest way.")
                    }
                    .onChange(of: stopRadius) { routes.retidy() }
                    .onChange(of: stopDuration) { routes.retidy() }
                }

                Section {
                    Picker("Warn when off route by", selection: $warnMeters) {
                        ForEach(RouteFollower.warnChoices, id: \.self) { m in
                            Text(units.distance(m)).tag(m)
                        }
                    }
                } header: {
                    Text("Following a route")
                } footer: {
                    Text("While you follow a route, GPS stays on with the phone locked, and you get a notification with sound if you stray this far. You can also change it by tapping the banner at the top of the map.")
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
