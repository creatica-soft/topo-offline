import Foundation
import Observation

/// The list of downloaded regions, saved as a small JSON index next to the map files.
@MainActor
@Observable
final class RegionStore {
    private(set) var regions: [OfflineRegion] = []
    let library: OfflineTileLibrary
    private let indexURL: URL

    init(library: OfflineTileLibrary = OfflineTileLibrary()) {
        self.library = library
        self.indexURL = library.directory.appendingPathComponent("regions.json")
        load()
    }

    func upsert(_ region: OfflineRegion) {
        if let i = regions.firstIndex(where: { $0.id == region.id }) {
            regions[i] = region
        } else {
            regions.insert(region, at: 0)
        }
        save()
        library.reload(regions: regions)
    }

    func delete(_ region: OfflineRegion) {
        regions.removeAll { $0.id == region.id }
        save()
        library.deleteFiles(for: region)
        library.reload(regions: regions)
    }

    func rename(_ region: OfflineRegion, to name: String) {
        var r = region
        r.name = name
        upsert(r)
    }

    func bytes(of region: OfflineRegion) -> Int64 { library.bytesOnDisk(for: region) }

    var totalBytes: Int64 { regions.reduce(0) { $0 + bytes(of: $1) } }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        regions = (try? decoder.decode([OfflineRegion].self, from: data)) ?? []
        library.reload(regions: regions)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(regions) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
