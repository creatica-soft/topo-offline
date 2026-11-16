import Foundation
import CoreLocation

struct LonLat: Hashable, Sendable {
    let lon: Double
    let lat: Double
    init(_ lon: Double, _ lat: Double) { self.lon = lon; self.lat = lat }

    /// Even–odd ray casting. Fine for these small, non-wrapping polygons.
    static func polygon(_ ring: [LonLat], contains p: CLLocationCoordinate2D) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in ring.indices {
            let a = ring[i], b = ring[j]
            if (a.lat > p.latitude) != (b.lat > p.latitude),
               p.longitude < (b.lon - a.lon) * (p.latitude - a.lat) / (b.lat - a.lat) + a.lon {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}

/// Rough state outlines (within a few km) used only to choose which map to show.
/// The sea side is drawn generously; only the land borders matter.
enum StateOutlines {
    /// NSW / Queensland land border, west to east: 29°S, then the Macintyre and Dumaresq rivers,
    /// then the Great Dividing Range and McPherson Range to Point Danger.
    private static let qldNswBorder: [LonLat] = [
        LonLat(141.00, -29.00), LonLat(148.95, -29.00), LonLat(149.60, -28.60), LonLat(150.30, -28.55),
        LonLat(150.90, -28.70), LonLat(151.17, -28.85), LonLat(151.55, -28.95), LonLat(151.93, -28.95),
        LonLat(152.05, -28.55), LonLat(152.50, -28.37), LonLat(152.90, -28.33), LonLat(153.20, -28.25),
        LonLat(153.55, -28.16),
    ]

    static let nsw: [LonLat] = qldNswBorder + [
        LonLat(154.20, -28.16), LonLat(154.20, -37.60),
        // Victorian border: Cape Howe, straight line to the Murray's source, then down the Murray.
        LonLat(149.98, -37.55), LonLat(148.20, -36.80), LonLat(147.90, -36.10), LonLat(146.90, -36.05),
        LonLat(144.75, -36.10), LonLat(143.55, -35.30), LonLat(142.20, -34.15), LonLat(141.00, -34.00),
    ]

    static let qld: [LonLat] = [
        LonLat(138.00, -9.00), LonLat(154.20, -9.00), LonLat(154.20, -28.16),
    ] + qldNswBorder.reversed() + [
        LonLat(141.00, -26.00), LonLat(138.00, -26.00),
    ]
}

/// Rough outlines of the United States (within several km along land borders; generous at sea),
/// used only to choose which map to show.
enum USOutlines {
    /// The lower 48: the 49th parallel, the Great Lakes and St Lawrence, Maine, then the coasts
    /// and the Mexican border (Rio Grande, then the straight lines to the Pacific).
    static let lower48: [LonLat] = canadianBorder + [
        // Atlantic and Gulf coasts (offshore)
        LonLat(-66.50, 44.20), LonLat(-69.00, 40.80), LonLat(-73.00, 39.00), LonLat(-74.80, 35.50),
        LonLat(-76.50, 33.50), LonLat(-79.50, 31.00), LonLat(-79.80, 27.00), LonLat(-79.90, 24.80),
        LonLat(-81.50, 24.30), LonLat(-83.00, 24.40), LonLat(-84.50, 27.00), LonLat(-88.00, 28.80),
        LonLat(-90.50, 28.60), LonLat(-94.00, 29.20), LonLat(-96.90, 26.50), LonLat(-97.15, 25.95),
        // Mexican border
        LonLat(-97.40, 25.84), LonLat(-99.10, 26.45), LonLat(-99.50, 27.50), LonLat(-100.30, 28.30),
        LonLat(-101.40, 29.75), LonLat(-102.40, 29.80), LonLat(-103.00, 29.00),
        // Rio Grande from Big Bend up to El Paso (El Paso on the US side, Ciudad Juárez not)
        LonLat(-104.37, 29.54), LonLat(-104.69, 30.00), LonLat(-105.00, 30.65), LonLat(-105.50, 31.00),
        LonLat(-105.95, 31.30), LonLat(-106.20, 31.47), LonLat(-106.38, 31.71), LonLat(-106.45, 31.735),
        LonLat(-106.50, 31.745), LonLat(-106.53, 31.78), LonLat(-108.20, 31.78), LonLat(-108.20, 31.33),
        LonLat(-111.07, 31.33), LonLat(-114.80, 32.49), LonLat(-114.72, 32.72), LonLat(-117.12, 32.53),
        // Pacific coast (offshore), then the Strait of Juan de Fuca back to the 49th parallel
        LonLat(-117.40, 32.30), LonLat(-120.00, 32.80), LonLat(-121.50, 34.00), LonLat(-125.00, 40.30),
        LonLat(-125.00, 48.40), LonLat(-124.00, 48.25), LonLat(-123.20, 48.20), LonLat(-123.25, 48.65),
        LonLat(-123.00, 48.80),
    ]

    /// The land border with Canada, west to east: the 49th parallel, the Great Lakes and
    /// St Lawrence, then Maine.
    static let canadianBorder: [LonLat] = [
        LonLat(-123.05, 49.00), LonLat(-95.15, 49.00), LonLat(-95.15, 49.38), LonLat(-94.82, 49.32),
        LonLat(-94.64, 48.72), LonLat(-93.00, 48.62), LonLat(-91.50, 48.05), LonLat(-89.60, 48.00),
        LonLat(-88.40, 48.30), LonLat(-84.85, 46.90), LonLat(-84.10, 46.50), LonLat(-83.60, 46.10),
        // St Clair River, Lake St Clair and the Detroit River (Detroit on the US side, Windsor not)
        LonLat(-82.50, 45.35), LonLat(-82.42, 43.00), LonLat(-82.53, 42.62), LonLat(-82.70, 42.45),
        LonLat(-82.93, 42.345), LonLat(-83.03, 42.315), LonLat(-83.08, 42.30), LonLat(-83.12, 42.23),
        LonLat(-83.14, 42.05), LonLat(-82.50, 41.70),
        LonLat(-81.00, 42.25), LonLat(-78.90, 42.90), LonLat(-79.05, 43.25), LonLat(-77.00, 43.60),
        LonLat(-76.35, 44.10), LonLat(-75.30, 44.85), LonLat(-74.70, 45.00), LonLat(-71.50, 45.01),
        LonLat(-71.10, 45.30), LonLat(-70.25, 45.90), LonLat(-70.00, 46.70), LonLat(-69.22, 47.45),
        LonLat(-68.23, 47.35), LonLat(-67.79, 47.07), LonLat(-67.78, 45.70), LonLat(-67.40, 45.20),
        LonLat(-66.98, 44.80),
    ]

    /// Alaska: the 141st meridian, the panhandle border, then the coasts (west to the date line).
    static let alaska: [LonLat] = [
        LonLat(-141.0, 72.0), LonLat(-141.0, 60.3), LonLat(-139.1, 60.35), LonLat(-137.5, 58.9),
        LonLat(-135.5, 59.8), LonLat(-133.4, 58.4), LonLat(-131.8, 56.6), LonLat(-130.0, 55.9),
        LonLat(-130.0, 54.7), LonLat(-134.0, 54.2), LonLat(-150.0, 55.0), LonLat(-165.0, 52.5),
        LonLat(-180.0, 51.0), LonLat(-180.0, 63.0), LonLat(-169.0, 65.5), LonLat(-169.0, 72.0),
    ]

    static let hawaii: [LonLat] = [
        LonLat(-161.0, 18.5), LonLat(-154.5, 18.5), LonLat(-154.5, 22.5), LonLat(-161.0, 22.5),
    ]

    /// Puerto Rico and the U.S. Virgin Islands.
    static let puertoRico: [LonLat] = [
        LonLat(-68.0, 17.5), LonLat(-64.5, 17.5), LonLat(-64.5, 18.7), LonLat(-68.0, 18.7),
    ]

    static let all = [lower48, alaska, hawaii, puertoRico]
}

/// Rough outlines of Canada, Switzerland and mainland Norway (within several km along land
/// borders; generous at sea), used only to choose which map to show.
enum CountryOutlines {
    /// Canada: the Alaska border, the Pacific, the US border (shared with `USOutlines.lower48`),
    /// the Atlantic, then up the Davis Strait and Nares Strait (midline with Greenland) to 84°N.
    static let canada: [LonLat] = [
        LonLat(-141.0, 84.0), LonLat(-141.0, 60.3), LonLat(-139.1, 60.35), LonLat(-137.5, 58.9),
        LonLat(-135.5, 59.8), LonLat(-133.4, 58.4), LonLat(-131.8, 56.6), LonLat(-130.0, 55.9),
        LonLat(-130.0, 54.7), LonLat(-134.5, 54.5), LonLat(-134.0, 51.0), LonLat(-131.0, 50.5),
        LonLat(-125.0, 48.40), LonLat(-124.0, 48.25), LonLat(-123.2, 48.20), LonLat(-123.25, 48.65),
        LonLat(-123.0, 48.80),
    ] + USOutlines.canadianBorder + [
        LonLat(-66.5, 44.2), LonLat(-65.5, 42.6), LonLat(-60.0, 43.0), LonLat(-52.0, 46.0),
        LonLat(-52.0, 53.0), LonLat(-54.0, 60.0), LonLat(-57.5, 66.0), LonLat(-61.0, 70.0),
        LonLat(-67.0, 74.0), LonLat(-73.5, 76.0), LonLat(-73.8, 78.0), LonLat(-68.5, 80.0),
        LonLat(-63.0, 81.5), LonLat(-60.0, 82.4), LonLat(-60.0, 84.0),
    ]

    /// Switzerland and Liechtenstein, clockwise from Basel.
    static let switzerland: [LonLat] = [
        LonLat(7.55, 47.60), LonLat(7.70, 47.55), LonLat(8.22, 47.62), LonLat(8.43, 47.57),
        LonLat(8.57, 47.81), LonLat(8.73, 47.70), LonLat(8.90, 47.65), LonLat(9.25, 47.66),
        LonLat(9.56, 47.54), LonLat(9.65, 47.40), LonLat(9.62, 47.06), LonLat(9.88, 46.94),
        LonLat(10.39, 47.00), LonLat(10.49, 46.86), LonLat(10.45, 46.55), LonLat(10.16, 46.23),
        LonLat(9.97, 46.38), LonLat(9.58, 46.30), LonLat(9.28, 46.50), LonLat(9.07, 45.85),
        LonLat(9.02, 45.82), LonLat(8.72, 46.10), LonLat(8.45, 46.46), LonLat(8.08, 46.26),
        LonLat(7.87, 45.92), LonLat(7.55, 45.98), LonLat(7.04, 45.93), LonLat(6.80, 46.14),
        LonLat(6.78, 46.40), LonLat(6.24, 46.30), LonLat(5.96, 46.14), LonLat(6.06, 46.42),
        LonLat(6.13, 46.58), LonLat(6.46, 46.82), LonLat(6.70, 47.04), LonLat(6.94, 47.24),
        LonLat(6.89, 47.40), LonLat(7.17, 47.49), LonLat(7.42, 47.45),
    ]

    /// Mainland Norway: the borders with Sweden, Finland and Russia, then the coast (offshore).
    static let norway: [LonLat] = [
        LonLat(11.43, 58.90), LonLat(11.68, 59.60), LonLat(11.83, 59.85), LonLat(12.50, 60.10),
        LonLat(12.22, 61.00), LonLat(12.88, 61.36), LonLat(12.15, 61.72), LonLat(12.25, 62.27),
        LonLat(12.05, 62.60), LonLat(12.20, 63.45), LonLat(12.95, 64.00), LonLat(13.98, 64.02),
        LonLat(14.15, 64.48), LonLat(13.67, 64.58), LonLat(14.50, 65.30), LonLat(14.55, 66.13),
        LonLat(15.45, 66.30), LonLat(16.40, 67.03), LonLat(16.20, 67.50), LonLat(17.25, 68.10),
        LonLat(17.88, 67.96), LonLat(18.13, 68.43), LonLat(19.95, 68.38), LonLat(20.55, 69.06),
        LonLat(21.70, 69.28), LonLat(22.40, 68.71), LonLat(23.20, 68.63), LonLat(24.90, 68.58),
        LonLat(25.75, 69.00), LonLat(26.00, 69.70), LonLat(27.00, 69.91), LonLat(28.10, 69.83),
        LonLat(28.92, 69.05), LonLat(29.13, 69.69), LonLat(30.10, 69.65), LonLat(30.85, 69.79),
        // Barents Sea, Norwegian Sea and North Sea coasts (offshore)
        LonLat(31.50, 70.30), LonLat(31.50, 71.50), LonLat(24.00, 71.60), LonLat(16.00, 70.20),
        LonLat(11.50, 67.50), LonLat(7.00, 64.00), LonLat(4.30, 62.00), LonLat(4.30, 59.00),
        LonLat(6.00, 57.80), LonLat(8.00, 57.70), LonLat(11.00, 58.80),
    ]
}
