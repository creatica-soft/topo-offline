import Foundation
import CoreGraphics
import CoreLocation
import ImageIO

/// Elevation profiles from Terrain Tiles (Registry of Open Data on AWS, "terrarium" encoding):
/// SRTM-based 30 m data in Australia (Geoscience Australia), LINZ 8 m data in New Zealand.
/// Tiles are saved with area downloads (`TileSources.terrain`), so profiles also work offline.
enum Elevation {
    static let attribution = "Elevation: © Commonwealth of Australia (Geoscience Australia); Crown copyright LINZ, CC BY 3.0 NZ; SRTM data courtesy of the U.S. Geological Survey. Terrain Tiles on AWS."

    struct Profile: Equatable, Sendable {
        /// Distance from the start in metres, elevation in metres, and position, per sample.
        var distances: [Double]
        var elevations: [Double]
        var points: [CLLocationCoordinate2D]
        var ascent: Double
        var descent: Double
        /// False when the track branches and only its main line is profiled.
        var coversWholeTrack: Bool

        var lengthKm: Double { (distances.last ?? 0) / 1000 }
        var highest: Double { elevations.max() ?? 0 }
        var lowest: Double { elevations.min() ?? 0 }

        func reversed() -> Profile {
            let total = distances.last ?? 0
            return Profile(distances: distances.reversed().map { total - $0 }, elevations: elevations.reversed(),
                           points: points.reversed(), ascent: descent, descent: ascent,
                           coversWholeTrack: coversWholeTrack)
        }

        /// Position on the track at a distance along it (for the map marker while scrubbing).
        func point(atDistance d: Double) -> CLLocationCoordinate2D? {
            guard !distances.isEmpty else { return nil }
            let i = distances.firstIndex { $0 >= d } ?? distances.count - 1
            return points[i]
        }

        static func == (a: Profile, b: Profile) -> Bool {
            a.distances == b.distances && a.elevations == b.elevations
        }
    }

    /// Builds the profile for a track: joins its pieces into one line, samples it about every
    /// 10–25 m, looks up the terrain, and smooths out SRTM noise before adding up climbs.
    static func profile(for track: Track, library: OfflineTileLibrary, offlineOnly: Bool) async -> Profile? {
        let (path, usedAll) = TrackPath.chain(track.segments.map(\.points))
        guard path.count >= 2 else { return nil }
        let samples = TrackPath.sample(path, maxSamples: 600)
        let terrain = TerrainReader(library: library, offlineOnly: offlineOnly)
        var elevations: [Double?] = []
        for p in samples.points { elevations.append(await terrain.elevation(at: p)) }
        let known = elevations.compactMap { $0 }
        // Without most of the terrain (offline, area not downloaded) there's no honest profile.
        guard known.count >= max(2, elevations.count * 8 / 10) else { return nil }
        let filled = fillGaps(elevations)
        // Smooth over ~150 m: 30 m terrain data jumps between cliff tops and bottoms beside tracks
        // that run along escarpments, which would otherwise add up to a lot of phantom climbing.
        let step = samples.distances.count > 1 ? samples.distances[1] - samples.distances[0] : 10
        let smooth = movingAverage(filled, window: max(5, Int((150 / step).rounded()) | 1))
        let (up, down) = climb(smooth, threshold: 5)
        return Profile(distances: samples.distances, elevations: smooth, points: samples.points,
                       ascent: up, descent: down, coversWholeTrack: usedAll)
    }

    /// Single-point lookup (also used by the self-test).
    static func elevation(at c: CLLocationCoordinate2D, library: OfflineTileLibrary, offlineOnly: Bool) async -> Double? {
        await TerrainReader(library: library, offlineOnly: offlineOnly).elevation(at: c)
    }

    // MARK: - Maths

    static func climb(_ e: [Double], threshold: Double) -> (Double, Double) {
        guard var anchor = e.first else { return (0, 0) }
        var up = 0.0, down = 0.0
        for v in e.dropFirst() {
            if v - anchor >= threshold { up += v - anchor; anchor = v }
            else if anchor - v >= threshold { down += anchor - v; anchor = v }
        }
        return (up, down)
    }

    static func movingAverage(_ e: [Double], window: Int) -> [Double] {
        guard e.count > window else { return e }
        let half = window / 2
        return e.indices.map { i in
            let lo = max(0, i - half), hi = min(e.count - 1, i + half)
            return e[lo...hi].reduce(0, +) / Double(hi - lo + 1)
        }
    }

    private static func fillGaps(_ e: [Double?]) -> [Double] {
        var out: [Double] = []
        var last = e.compactMap { $0 }.first ?? 0
        for v in e {
            if let v { last = v }
            out.append(last)
        }
        return out
    }
}

/// Joining a track's pieces into one continuous line, and sampling it evenly.
enum TrackPath {
    /// Greedy chaining: start with the longest piece and keep attaching the nearest piece whose end
    /// touches either end of the line (within `gap` metres), flipping pieces as needed.
    static func chain(_ pieces: [[CLLocationCoordinate2D]], gaps: [Double] = [60, 250]) -> (path: [CLLocationCoordinate2D], usedAll: Bool) {
        var remaining = pieces.filter { $0.count >= 2 }
        guard !remaining.isEmpty else { return ([], true) }
        let firstIndex = remaining.indices.max { length(remaining[$0]) < length(remaining[$1]) }!
        var path = remaining.remove(at: firstIndex)
        // Prefer pieces that touch; only then bridge small gaps in the published data.
        var gapIndex = 0
        while gapIndex < gaps.count {
            let gap = gaps[gapIndex]
            var best: (index: Int, atEnd: Bool, flip: Bool, dist: Double)?
            for (i, piece) in remaining.enumerated() {
                let options: [(Bool, Bool, Double)] = [
                    (true, false, meters(path.last!, piece.first!)),
                    (true, true, meters(path.last!, piece.last!)),
                    (false, true, meters(path.first!, piece.first!)),
                    (false, false, meters(path.first!, piece.last!)),
                ]
                for (atEnd, flip, d) in options where d <= gap && d < (best?.dist ?? .infinity) {
                    best = (i, atEnd, flip, d)
                }
            }
            guard let b = best else {
                gapIndex += 1
                continue
            }
            gapIndex = 0
            var piece = remaining.remove(at: b.index)
            if b.flip { piece.reverse() }
            if b.atEnd { path += piece } else { path = piece + path }
        }
        return (path, remaining.isEmpty)
    }

    static func sample(_ path: [CLLocationCoordinate2D], maxSamples: Int) -> (points: [CLLocationCoordinate2D], distances: [Double]) {
        var cumulative = [0.0]
        for (a, b) in zip(path, path.dropFirst()) { cumulative.append(cumulative.last! + meters(a, b)) }
        let total = cumulative.last!
        let step = max(10, total / Double(maxSamples))
        var points: [CLLocationCoordinate2D] = [], distances: [Double] = []
        var d = 0.0, j = 0
        while d <= total {
            while j < path.count - 2 && cumulative[j + 1] < d { j += 1 }
            let segLen = cumulative[j + 1] - cumulative[j]
            let t = segLen > 0 ? (d - cumulative[j]) / segLen : 0
            let a = path[j], b = path[j + 1]
            points.append(CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                                 longitude: a.longitude + (b.longitude - a.longitude) * t))
            distances.append(d)
            d += step
        }
        if distances.last != total { points.append(path.last!); distances.append(total) }
        return (points, distances)
    }

    static func length(_ p: [CLLocationCoordinate2D]) -> Double {
        zip(p, p.dropFirst()).reduce(0) { $0 + meters($1.0, $1.1) }
    }

    static func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let dLat = (b.latitude - a.latitude) * 110_540
        let dLon = (b.longitude - a.longitude) * 111_320 * cos(a.latitude * .pi / 180)
        return (dLat * dLat + dLon * dLon).squareRoot()
    }
}

/// Reads elevations from terrarium tiles: downloaded first, then the network (unless offline).
/// Decoded tiles are kept for the duration of one profile.
actor TerrainReader {
    private let library: OfflineTileLibrary
    private let offlineOnly: Bool
    private var tiles: [TileKey: [Float]?] = [:]

    init(library: OfflineTileLibrary, offlineOnly: Bool) {
        self.library = library
        self.offlineOnly = offlineOnly
    }

    func elevation(at c: CLLocationCoordinate2D) async -> Double? {
        let z = TileSources.terrain.maxZoom
        let n = Double(1 << z)
        let fx = (c.longitude + 180) / 360 * n
        let rad = c.latitude * .pi / 180
        let fy = (1 - log(tan(rad) + 1 / cos(rad)) / .pi) / 2 * n
        let key = TileKey(z: z, x: Int(fx), y: Int(fy))
        guard let grid = await grid(for: key) else { return nil }
        // Bilinear interpolation between the four surrounding pixels.
        let px = (fx - floor(fx)) * 256 - 0.5, py = (fy - floor(fy)) * 256 - 0.5
        let x0 = max(0, min(255, Int(floor(px)))), y0 = max(0, min(255, Int(floor(py))))
        let x1 = min(255, x0 + 1), y1 = min(255, y0 + 1)
        let tx = max(0, min(1, px - Double(x0))), ty = max(0, min(1, py - Double(y0)))
        func v(_ x: Int, _ y: Int) -> Double { Double(grid[y * 256 + x]) }
        let top = v(x0, y0) * (1 - tx) + v(x1, y0) * tx
        let bottom = v(x0, y1) * (1 - tx) + v(x1, y1) * tx
        return top * (1 - ty) + bottom * ty
    }

    private func grid(for key: TileKey) async -> [Float]? {
        if let cached = tiles[key] { return cached }
        var data = library.tile(sourceID: TileSources.terrain.id, key: key)
        if data == nil, !offlineOnly {
            var request = URLRequest(url: TileSources.terrain.tileURL(key))
            request.cachePolicy = .returnCacheDataElseLoad
            if let (d, r) = try? await TileNetwork.browse.data(for: request), (r as? HTTPURLResponse)?.statusCode == 200 {
                data = d
            }
        }
        let decoded = data.flatMap(Self.decode)
        tiles[key] = decoded
        return decoded
    }

    /// Terrarium encoding: elevation = R × 256 + G + B / 256 − 32768 (metres).
    static func decode(_ data: Data) -> [Float]? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
              image.width == 256, image.height == 256, image.bitsPerComponent == 8,
              let raw = image.dataProvider?.data, let bytes = CFDataGetBytePtr(raw) else { return nil }
        let bpp = image.bitsPerPixel / 8
        guard bpp == 3 || bpp == 4 else { return nil }
        let alphaFirst = [CGImageAlphaInfo.first, .premultipliedFirst, .noneSkipFirst].contains(image.alphaInfo)
        let littleEndian = image.bitmapInfo.contains(.byteOrder32Little)
        let (ri, gi, bi): (Int, Int, Int) = {
            if bpp == 4 && littleEndian { return alphaFirst ? (2, 1, 0) : (3, 2, 1) }  // BGRA / ABGR in memory
            let o = (bpp == 4 && alphaFirst) ? 1 : 0
            return (o, o + 1, o + 2)
        }()
        var out = [Float](repeating: 0, count: 256 * 256)
        for y in 0..<256 {
            let row = bytes + y * image.bytesPerRow
            for x in 0..<256 {
                let p = row + x * bpp
                out[y * 256 + x] = Float(p[ri]) * 256 + Float(p[gi]) + Float(p[bi]) / 256 - 32768
            }
        }
        return out
    }
}
