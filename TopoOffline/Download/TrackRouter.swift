import Foundation
import CoreLocation

/// Routes between two points along the walking-track network (the agencies' track data), for
/// planning. Falls back to a straight line where there's no track, as on a paper map.
/// Offline it uses only tracks saved with downloaded areas, so it makes no requests.
enum TrackRouter {
    struct Leg: Sendable {
        var points: [CLLocationCoordinate2D]
        var followsTracks: Bool
    }

    /// Longer legs aren't routed (too much track data to load): the planner asks for a point in between.
    static let maxDistance = 20_000.0
    /// Track ends this close to another track count as joined (published data often has small gaps).
    static let junctionTolerance = 15.0

    static func leg(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D, followTracks: Bool,
                    snap: Double, library: OfflineTileLibrary, offlineOnly: Bool) async -> Leg {
        let straight = Leg(points: [a, b], followsTracks: false)
        let direct = TrackPath.meters(a, b)
        guard followTracks, direct <= maxDistance else { return straight }
        let lines = await trackLines(around: [a, b], padding: max(1000, direct * 0.3),
                                     library: library, offlineOnly: offlineOnly)
        let found = await Task.detached(priority: .userInitiated) {
            route(from: a, to: b, along: lines, snap: max(30, snap))
        }.value
        guard let found else { return straight }
        return Leg(points: found, followsTracks: true)
    }

    // MARK: - Track data

    private static let cache = CellCache()
    private static let cellSize = 0.1  // degrees, about 10 km (as for the Victorian track layer)

    /// Track lines near the points: downloaded ones, plus (online) the agencies' servers, cached per cell.
    static func trackLines(around points: [CLLocationCoordinate2D], padding meters: Double,
                           library: OfflineTileLibrary, offlineOnly: Bool) async -> [[CLLocationCoordinate2D]] {
        guard let first = points.first else { return [] }
        let dLat = meters / 110_540, dLon = meters / (111_320 * cos(first.latitude * .pi / 180))
        let box = BoundingBox(minLat: points.map(\.latitude).min()! - dLat, minLon: points.map(\.longitude).min()! - dLon,
                              maxLat: points.map(\.latitude).max()! + dLat, maxLon: points.map(\.longitude).max()! + dLon)
        var segments = library.trackSegments(in: box)
        if !offlineOnly {
            segments += await cache.segments(in: box, cellSize: cellSize)
        }
        var seen = Set<[Double]>()
        return segments.filter { $0.bbox.intersects(box) && seen.insert($0.coords).inserted }.map(\.points)
    }

    private actor CellCache {
        private var cells: [String: [TrackSegment]] = [:]

        func segments(in box: BoundingBox, cellSize: Double) async -> [TrackSegment] {
            let x0 = Int(floor(box.minLon / cellSize)), x1 = Int(floor(box.maxLon / cellSize))
            let y0 = Int(floor(box.minLat / cellSize)), y1 = Int(floor(box.maxLat / cellSize))
            let keys = (y0...y1).flatMap { y in (x0...x1).map { x in (x, y) } }
            let missing = keys.filter { cells["\($0.0),\($0.1)"] == nil }
            let fetched = await withTaskGroup(of: (String, [TrackSegment]?).self) { group in
                for (x, y) in missing {
                    group.addTask {
                        let cellBox = BoundingBox(minLat: Double(y) * cellSize, minLon: Double(x) * cellSize,
                                                  maxLat: Double(y + 1) * cellSize, maxLon: Double(x + 1) * cellSize)
                        return ("\(x),\(y)", try? await TrackSources.segments(in: cellBox))
                    }
                }
                var out: [(String, [TrackSegment]?)] = []
                for await r in group { out.append(r) }
                return out
            }
            if cells.count > 300 { cells = [:] }  // keep memory bounded on long trips
            for (key, segs) in fetched where segs != nil { cells[key] = segs }
            return keys.flatMap { cells["\($0.0),\($0.1)"] ?? [] }
        }
    }

    // MARK: - Routing

    /// The shortest way from `a` to `b` along `lines`, starting and ending at the closest points on
    /// the network (each must be within `snap` metres of a line). Nil when either point is off the
    /// network, the two aren't connected, or the way round is absurdly long (> 5× the straight line).
    static func route(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D,
                      along lines: [[CLLocationCoordinate2D]], snap: Double) -> [CLLocationCoordinate2D]? {
        // Flat x/y in metres around `a`: accurate enough over tens of kilometres.
        let lat0 = a.latitude, lon0 = a.longitude
        let kx = 111_320 * cos(lat0 * .pi / 180), ky = 110_540.0
        func xy(_ c: CLLocationCoordinate2D) -> P { P(x: (c.longitude - lon0) * kx, y: (c.latitude - lat0) * ky) }
        func ll(_ p: P) -> CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat0 + p.y / ky, longitude: lon0 + p.x / kx) }

        let polys = lines.filter { $0.count >= 2 }.map { $0.map(xy) }
        guard !polys.isEmpty else { return nil }
        let grid = EdgeGrid(polys)
        var graph = Graph()
        var splits: [[(edge: Int, t: Double, node: Int)]] = Array(repeating: [], count: polys.count)
        var links: [(Int, Int, Double)] = []

        // Join each line's ends to any line passing within the junction tolerance.
        for (i, poly) in polys.enumerated() {
            for (end, edgeAtEnd) in [(poly[0], 0), (poly[poly.count - 1], poly.count - 2)] {
                guard let hit = grid.nearest(to: end, within: junctionTolerance, skip: { j, e in j == i && abs(e - edgeAtEnd) <= 1 })
                else { continue }
                let n = graph.node(hit.point)
                splits[hit.poly].append((hit.edge, hit.t, n))
                links.append((graph.node(end), n, hit.dist))
            }
        }
        // Start and finish: the closest points on the network.
        guard let sa = grid.nearest(to: xy(a), within: snap, skip: { _, _ in false }),
              let sb = grid.nearest(to: xy(b), within: snap, skip: { _, _ in false }) else { return nil }
        let start = graph.node(sa.point), goal = graph.node(sb.point)
        splits[sa.poly].append((sa.edge, sa.t, start))
        splits[sb.poly].append((sb.edge, sb.t, goal))

        // Edges along every line, through any junction/start/finish points added on it.
        for (i, poly) in polys.enumerated() {
            let extra = splits[i].sorted { ($0.edge, $0.t) < ($1.edge, $1.t) }
            var k = 0
            var prev = graph.node(poly[0])
            for e in 0..<(poly.count - 1) {
                while k < extra.count, extra[k].edge == e {
                    graph.link(prev, extra[k].node)
                    prev = extra[k].node
                    k += 1
                }
                let next = graph.node(poly[e + 1])
                graph.link(prev, next)
                prev = next
            }
        }
        for (u, v, d) in links { graph.link(u, v, d) }

        guard let path = graph.shortestPath(from: start, to: goal) else { return nil }
        let points = path.map { ll(graph.points[$0]) }
        let length = TrackPath.length(points)
        guard length <= TrackPath.meters(a, b) * 5 + 300 else { return nil }
        return points.count >= 2 ? points : [ll(sa.point), ll(sb.point)]
    }

    struct P: Sendable {
        var x: Double
        var y: Double
        func dist(_ o: P) -> Double { ((x - o.x) * (x - o.x) + (y - o.y) * (y - o.y)).squareRoot() }
    }

    /// Line edges bucketed in 50 m cells, for "closest point on any line" lookups.
    private struct EdgeGrid {
        let polys: [[P]]
        private var cells: [Int64: [(Int32, Int32)]] = [:]
        private let size = 50.0

        init(_ polys: [[P]]) {
            self.polys = polys
            for (i, poly) in polys.enumerated() {
                for e in 0..<(poly.count - 1) {
                    let a = poly[e], b = poly[e + 1]
                    for cx in cell(min(a.x, b.x))...cell(max(a.x, b.x)) {
                        for cy in cell(min(a.y, b.y))...cell(max(a.y, b.y)) {
                            cells[key(cx, cy), default: []].append((Int32(i), Int32(e)))
                        }
                    }
                }
            }
        }

        private func cell(_ v: Double) -> Int { Int(floor(v / size)) }
        private func key(_ cx: Int, _ cy: Int) -> Int64 { Int64(cx) << 32 | Int64(UInt32(bitPattern: Int32(truncatingIfNeeded: cy))) }

        struct Hit {
            var poly: Int
            var edge: Int
            var t: Double
            var point: P
            var dist: Double
        }

        func nearest(to q: P, within r: Double, skip: (Int, Int) -> Bool) -> Hit? {
            var best: Hit?
            for cx in cell(q.x - r)...cell(q.x + r) {
                for cy in cell(q.y - r)...cell(q.y + r) {
                    for (pi, ei) in cells[key(cx, cy)] ?? [] {
                        let i = Int(pi), e = Int(ei)
                        if skip(i, e) { continue }
                        let a = polys[i][e], b = polys[i][e + 1]
                        let dx = b.x - a.x, dy = b.y - a.y
                        let len2 = dx * dx + dy * dy
                        let t = len2 == 0 ? 0 : max(0, min(1, ((q.x - a.x) * dx + (q.y - a.y) * dy) / len2))
                        let p = P(x: a.x + t * dx, y: a.y + t * dy)
                        let d = p.dist(q)
                        if d <= r, d < (best?.dist ?? .infinity) { best = Hit(poly: i, edge: e, t: t, point: p, dist: d) }
                    }
                }
            }
            return best
        }
    }

    private struct Graph {
        var points: [P] = []
        var edges: [[(Int, Double)]] = []
        private var index: [Int64: Int] = [:]

        /// The node at `p`; points within ~10 cm are the same node (shared ends of track pieces).
        mutating func node(_ p: P) -> Int {
            let k = Int64((p.x * 10).rounded()) << 32 | Int64(UInt32(bitPattern: Int32(truncatingIfNeeded: Int((p.y * 10).rounded()))))
            if let n = index[k] { return n }
            points.append(p)
            edges.append([])
            index[k] = points.count - 1
            return points.count - 1
        }

        mutating func link(_ u: Int, _ v: Int, _ d: Double? = nil) {
            guard u != v else { return }
            let w = d ?? points[u].dist(points[v])
            edges[u].append((v, w))
            edges[v].append((u, w))
        }

        /// A* with straight-line distance as the estimate.
        func shortestPath(from s: Int, to g: Int) -> [Int]? {
            if s == g { return [s] }
            var dist = [Double](repeating: .infinity, count: points.count)
            var came = [Int](repeating: -1, count: points.count)
            var heap = MinHeap()
            dist[s] = 0
            heap.push(points[s].dist(points[g]), s)
            while let (_, u) = heap.pop() {
                if u == g { break }
                for (v, w) in edges[u] where dist[u] + w < dist[v] {
                    dist[v] = dist[u] + w
                    came[v] = u
                    heap.push(dist[v] + points[v].dist(points[g]), v)
                }
            }
            guard dist[g].isFinite else { return nil }
            var path = [g]
            while let last = path.last, last != s { path.append(came[last]) }
            return path.reversed()
        }
    }

    private struct MinHeap {
        private var items: [(Double, Int)] = []

        mutating func push(_ key: Double, _ value: Int) {
            items.append((key, value))
            var i = items.count - 1
            while i > 0 {
                let parent = (i - 1) / 2
                guard items[i].0 < items[parent].0 else { break }
                items.swapAt(i, parent)
                i = parent
            }
        }

        mutating func pop() -> (Double, Int)? {
            guard !items.isEmpty else { return nil }
            items.swapAt(0, items.count - 1)
            let top = items.removeLast()
            var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1
                var m = i
                if l < items.count, items[l].0 < items[m].0 { m = l }
                if r < items.count, items[r].0 < items[m].0 { m = r }
                guard m != i else { break }
                items.swapAt(i, m)
                i = m
            }
            return top
        }
    }
}
