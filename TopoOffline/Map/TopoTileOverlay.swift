import Foundation
import MapKit

/// A MapKit tile layer that serves downloaded tiles first, then the network (unless offline-only),
/// then the browsing cache. Above the server's highest zoom it scales up the last real tile.
final class TopoTileOverlay: MKTileOverlay, @unchecked Sendable {
    let source: TileSource
    let library: OfflineTileLibrary
    let offlineOnly: Bool
    private let session: URLSession

    /// `fromZoom` hides this layer when zoomed out further, letting the layer underneath show.
    init(source: TileSource, library: OfflineTileLibrary, offlineOnly: Bool,
         fromZoom: Int? = nil, maxOverzoom: Int = 4, session: URLSession = TileNetwork.browse,
         replacesAppleMap: Bool = true) {
        self.source = source
        self.library = library
        self.offlineOnly = offlineOnly
        self.session = session
        super.init(urlTemplate: nil)
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = max(source.minZoom, fromZoom ?? source.minZoom)
        // MapKit draws nothing above maximumZ, which shows as a white screen (the topo map replaces
        // Apple's map). On high-resolution phones it asks for up to about zoom 20–21 at full zoom-in,
        // so every layer covers at least that, enlarging its finest tiles as needed.
        maximumZ = max(source.maxZoom + maxOverzoom, Self.deepestZoom)
        // Normally the topo map replaces Apple's map entirely. Where no topo map covers the screen,
        // Apple's map is allowed to show underneath instead of a blank page.
        canReplaceMapContent = replacesAppleMap
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let key = TileKey(z: path.z, x: path.x, y: path.y)
        // Ask for the tile itself, or above the server's top zoom, for its top-zoom ancestor.
        let wanted = key.z > source.maxZoom ? Self.ancestor(of: key, levelsUp: key.z - source.maxZoom) : key
        tileData(for: wanted) { [self] data in
            if let data {
                result(wanted == key ? data : Self.enlarge(data, from: wanted, to: key), nil)
            } else {
                // Not available (typically offline, zoomed in past the downloaded detail):
                // enlarge the most detailed downloaded tile above it rather than going blank.
                result(enlargedFromLibrary(key, startingAbove: wanted), nil)
            }
        }
    }

    /// Walks up from `start` to find a downloaded tile covering `key`, and enlarges it.
    private func enlargedFromLibrary(_ key: TileKey, startingAbove start: TileKey) -> Data? {
        let lowest = max(source.minZoom, key.z - Self.maxEnlargeLevels)
        var z = start.z - 1
        while z >= lowest {
            let parent = Self.ancestor(of: key, levelsUp: key.z - z)
            if let data = library.tile(sourceID: source.id, key: parent) {
                return Self.enlarge(data, from: parent, to: key)
            }
            z -= 1
        }
        return nil
    }

    /// Zoom levels MapKit may ask for when fully zoomed in.
    static let deepestZoom = 21
    /// How far a downloaded tile may be enlarged offline. Deep enlargements are soft, but a soft
    /// map beats a blank screen (NZ's finest tiles are zoom 15, six levels below the deepest zoom).
    private static let maxEnlargeLevels = 6

    private static func ancestor(of key: TileKey, levelsUp dz: Int) -> TileKey {
        TileKey(z: key.z - dz, x: key.x >> dz, y: key.y >> dz)
    }

    private static func enlarge(_ data: Data, from parent: TileKey, to key: TileKey) -> Data? {
        let dz = key.z - parent.z
        let mask = (1 << dz) - 1
        return TileImage.overzoom(parent: data, levels: dz, offsetX: key.x & mask, offsetY: key.y & mask)
    }

    private func tileData(for key: TileKey, completion: @escaping (Data?) -> Void) {
        if let data = library.tile(sourceID: source.id, key: key) {
            completion(data)
            return
        }
        var request = URLRequest(url: source.tileURL(key))
        if offlineOnly {
            request.cachePolicy = .returnCacheDataDontLoad
        }
        let cache = session.configuration.urlCache
        let finalRequest = request  // immutable copy for the callback
        session.dataTask(with: finalRequest) { data, response, error in
            if let data, (response as? HTTPURLResponse)?.statusCode == 200, TileImage.isImage(data) {
                completion(data)
            } else if error != nil, let cached = cache?.cachedResponse(for: finalRequest)?.data, TileImage.isImage(cached) {
                completion(cached)  // no signal: fall back to what we saw earlier
            } else {
                completion(nil)
            }
        }.resume()
    }
}
