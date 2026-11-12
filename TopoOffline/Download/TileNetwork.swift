import Foundation

/// HTTP sessions for talking to the map servers. No cookies, no analytics, no third parties:
/// the only requests this app makes are for map tiles from the servers listed in `TileSources`.
enum TileNetwork {
    static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "TopoOffline/\(version) (iOS; offline topo map viewer)"
    }()

    /// Used while browsing. Keeps a disk cache so recently viewed areas still show with no signal.
    static let browse: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 300 << 20)
        config.timeoutIntervalForRequest = 20
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config)
    }()

    /// Used for area downloads. No cache (tiles go straight into the MBTiles file) and a low
    /// connection limit so we stay polite to the government servers.
    static let download: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.httpMaximumConnectionsPerHost = DownloadLimits.maxConcurrentRequests
        return URLSession(configuration: config)
    }()
}

enum DownloadLimits {
    /// Parallel requests per download. Kept low out of courtesy to the tile servers.
    static let maxConcurrentRequests = 4
    /// Hard cap per download (≈ a 70 × 70 km area at zoom 9–16; a 20 × 20 km area is ≈ 2,300 tiles).
    static let maxTilesPerDownload = 30_000
    static let retries = 3
}
