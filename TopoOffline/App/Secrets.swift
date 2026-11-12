import Foundation

/// API keys and related settings, read from the app's Info.plist. They're filled in at build time
/// from `Config/Secrets.xcconfig`, which is ignored by git (copy `Config/Secrets.example.xcconfig`).
/// Nothing secret lives in source control.
enum Secrets {
    /// LINZ Basemaps key for the New Zealand topo map (Topo50/Topo250). Empty hides the NZ map.
    /// The `LINZ_API_KEY` environment variable is used when there's no Info.plist value
    /// (Tools/selftest.sh runs the code outside the app).
    static let linzAPIKey: String = {
        if let key = Bundle.main.object(forInfoDictionaryKey: "LINZAPIKey") as? String, !key.isEmpty {
            return key
        }
        return ProcessInfo.processInfo.environment["LINZ_API_KEY"] ?? ""
    }()

    /// Standard keys are limited to 1,000 tiles a minute, so downloads are slowed to stay under
    /// that. Developer keys (issued by LINZ on request) have no limit.
    static let linzKeyIsDeveloperKey: Bool = {
        let value = (Bundle.main.object(forInfoDictionaryKey: "LINZKeyIsDeveloper") as? String) ?? ""
        return ["YES", "TRUE", "1"].contains(value.uppercased())
    }()
}
