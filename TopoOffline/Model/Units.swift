import Foundation

/// The user's choice of units (Settings in the map menu). Automatic follows the phone's region.
enum UnitSetting: String, CaseIterable, Identifiable, Sendable {
    case automatic, metric, imperial
    var id: String { rawValue }
}

/// Distances and heights as text, in kilometres/metres or miles/feet. Everything is stored and
/// computed in metres; this is only for showing it.
struct Units: Equatable, Sendable {
    let imperial: Bool

    static let metric = Units(imperial: false)
    static let usCustomary = Units(imperial: true)
    static let metersPerFoot = 0.3048
    static let metersPerMile = 1609.344

    init(imperial: Bool) { self.imperial = imperial }

    init(_ setting: UnitSetting, locale: Locale = .current) {
        switch setting {
        case .metric: imperial = false
        case .imperial: imperial = true
        case .automatic: imperial = locale.measurementSystem == .us
        }
    }

    /// "850 m", "1.2 km", "120 km" / "320 ft", "1.2 mi", "120 mi".
    func distance(_ meters: Double) -> String {
        if imperial {
            let miles = meters / Self.metersPerMile
            if miles < 0.1 { return "\(Int((meters / Self.metersPerFoot / 10).rounded()) * 10) ft" }
            return miles < 100 ? String(format: "%.1f mi", miles) : String(format: "%.0f mi", miles)
        }
        if meters < 1000 { return "\(Int((meters / 10).rounded()) * 10) m" }
        let km = meters / 1000
        return km < 100 ? String(format: "%.1f km", km) : String(format: "%.0f km", km)
    }

    /// A rough length, whole numbers only: "20 km" / "12 mi".
    func roundDistance(_ meters: Double) -> String {
        imperial ? "\(Int((meters / Self.metersPerMile).rounded())) mi" : "\(Int((meters / 1000).rounded())) km"
    }

    /// "1,234 m" / "4,049 ft".
    func height(_ meters: Double) -> String {
        "\(Int(heightValue(meters).rounded()).formatted()) \(heightUnit)"
    }

    /// "↑ 120 m ↓ 80 m"
    func climb(up: Double, down: Double) -> String {
        "↑ \(height(up)) ↓ \(height(down))"
    }

    // MARK: - Charts

    var distanceUnit: String { imperial ? "mi" : "km" }
    var heightUnit: String { imperial ? "ft" : "m" }
    var heightUnitName: String { imperial ? "feet" : "metres" }

    /// Metres as kilometres or miles (chart x values).
    func distanceValue(_ meters: Double) -> Double { meters / (imperial ? Self.metersPerMile : 1000) }
    func meters(fromDistanceValue v: Double) -> Double { v * (imperial ? Self.metersPerMile : 1000) }
    /// Metres as metres or feet (chart y values).
    func heightValue(_ meters: Double) -> Double { imperial ? meters / Self.metersPerFoot : meters }

    // MARK: - Scale bar

    /// The longest round length (1, 2 or 5 × 10ⁿ of the unit) that fits in `maxPoints` on screen.
    func scaleBar(metersPerPoint: Double, maxPoints: Double) -> (points: Double, label: String)? {
        guard metersPerPoint > 0, metersPerPoint.isFinite else { return nil }
        let best = Self.scaleSteps(imperial: imperial).last { $0.meters / metersPerPoint <= maxPoints }
        return best.map { ($0.meters / metersPerPoint, $0.label) }
    }

    private static let metricSteps = steps(1, 5_000_000).map { m in
        (meters: m, label: m < 1000 ? "\(Int(m)) m" : "\(Int(m / 1000)) km")
    }
    private static let imperialSteps =
        steps(10, 2000).map { ft in (meters: ft * metersPerFoot, label: "\(Int(ft)) ft") }
        + [(meters: 0.5 * metersPerMile, label: "½ mi")]
        + steps(1, 5000).map { mi in (meters: mi * metersPerMile, label: "\(Int(mi)) mi") }

    private static func scaleSteps(imperial: Bool) -> [(meters: Double, label: String)] {
        imperial ? imperialSteps : metricSteps
    }

    /// 1, 2, 5, 10, 20, 50… from `low` up to `high`.
    private static func steps(_ low: Double, _ high: Double) -> [Double] {
        var out: [Double] = []
        var p = 1.0
        while p <= high {
            for m in [1.0, 2, 5] where p * m >= low && p * m <= high { out.append(p * m) }
            p *= 10
        }
        return out
    }
}
