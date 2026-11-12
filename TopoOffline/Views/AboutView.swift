import SwiftUI

struct AboutView: View {
    var body: some View {
        List {
            Section {
                Link("Privacy policy", destination: URL(string: "https://creatica-soft.github.io/topo-offline/privacy/")!)
                Link("Support", destination: URL(string: "https://creatica-soft.github.io/topo-offline/support/")!)
                Link("Source code (GPL-3.0)", destination: URL(string: "https://github.com/creatica-soft/topo-offline")!)
            }
            Section("Privacy") {
                Text("No account, no ads, no analytics, no tracking. Your location is only used on this iPhone to show the blue dot and is never sent anywhere.")
                Text("The only internet traffic is map images, place-name searches, track and closure data, sent directly to the government servers credited below.")
            }

            Section {
                Text("Maps can be out of date or wrong. Always carry a paper map, compass and a way to call for help, and check park alerts before you go.")
                Text("Closures are shown for Victorian state forests and reserves (only while their dates say they apply) and for New Zealand DOC tracks, huts and campsites. A track or campsite without a closure shown may still be closed: Australian national parks and other states aren't covered, and DOC alerts have more detail.")
            } header: {
                Text("Safety")
            }

            Section {
                ForEach(TileSources.allIncludingUnavailable) { source in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(source.name).font(.headline)
                        Text(source.attribution).font(.footnote)
                        Link(source.licenceName, destination: source.licenceURL).font(.footnote)
                    }
                    .padding(.vertical, 2)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Walking tracks").font(.headline)
                    ForEach(["NSW", "QLD", "TAS", "VIC"], id: \.self) { state in
                        if let credit = TrackSources.attribution(for: state) {
                            Text(credit).font(.footnote)
                        }
                    }
                }
                .padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Campsites and closures (Victoria)").font(.headline)
                    Text(VicParkData.attribution).font(.footnote)
                }
                .padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("New Zealand").font(.headline)
                    Text("Tracks, huts, campsites and closures: \(DOC.attribution)").font(.footnote)
                    Text(NZPlaceNames.attribution).font(.footnote)
                }
                .padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Campgrounds").font(.headline)
                    Text("NSW National Parks and Wildlife Service; Vicmap Features of Interest © State of Victoria, CC BY 4.0; Composite Gazetteer of Australia © Geoscience Australia, CC BY 4.0.").font(.footnote)
                    Text("Community campsites and facilities: \(CampSource.osmCredit). Shown in teal; may be out of date.").font(.footnote)
                    Link("OpenStreetMap licence (ODbL)", destination: URL(string: "https://www.openstreetmap.org/copyright")!).font(.footnote)
                    Link("Download the campsite data used by this app", destination: CommunityCampsites.publishedExtractURL).font(.footnote)
                }
                .padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Elevation profiles").font(.headline)
                    Text(Elevation.attribution).font(.footnote)
                }
                .padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Search").font(.headline)
                    Text(Gazetteer.attribution).font(.footnote)
                    Link("CC BY 4.0", destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!).font(.footnote)
                }
                .padding(.vertical, 2)
            } header: {
                Text("Map credits")
            } footer: {
                Text("Maps are used under their open licences. Downloaded maps are re-compressed to save space. This app is not endorsed by any of these agencies.")
            }
        }
        .navigationTitle("About")
    }
}
