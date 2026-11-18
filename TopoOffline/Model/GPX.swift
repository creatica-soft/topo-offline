import Foundation
import CoreLocation

/// GPX 1.1 files: export routes and recorded walks, and read routes from other apps and websites.
enum GPX {
    // MARK: - Writing

    static func data(for route: SavedRoute) -> Data {
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Topo Offline" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata><name>\(escape(route.name))</name><time>\(timeString(route.created.timeIntervalSince1970))</time></metadata>
          <trk>
            <name>\(escape(route.name))</name>

        """
        let hasTimes = route.kind == .recorded || !route.times.isEmpty
        if hasTimes, !route.legs.isEmpty {
            // A recording has a time (and usually an altitude) per point, and one segment per
            // stretch between pauses.
            var i = 0
            for leg in route.legs where !leg.coords.isEmpty {
                out += "    <trkseg>\n"
                for p in leg.points {
                    out += "      <trkpt lat=\"\(fmt(p.latitude))\" lon=\"\(fmt(p.longitude))\">"
                    if i < route.altitudes.count, let ele = route.altitudes[i] { out += "<ele>\(String(format: "%.1f", ele))</ele>" }
                    if i < route.times.count { out += "<time>\(timeString(route.times[i]))</time>" }
                    out += "</trkpt>\n"
                    i += 1
                }
                out += "    </trkseg>\n"
            }
        } else {
            out += "    <trkseg>\n"
            for p in route.path {
                out += "      <trkpt lat=\"\(fmt(p.latitude))\" lon=\"\(fmt(p.longitude))\"/>\n"
            }
            out += "    </trkseg>\n"
        }
        out += "  </trk>\n</gpx>\n"
        return Data(out.utf8)
    }

    /// A file name for sharing: the route's name without characters that file systems dislike.
    static func fileName(for route: SavedRoute) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let clean = route.name.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return (clean.isEmpty ? "Route" : clean) + ".gpx"
    }

    private static func fmt(_ v: Double) -> String { String(format: "%.6f", v) }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func timeString(_ t: Double) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date(timeIntervalSince1970: t))
    }

    // MARK: - Reading

    /// Every track (`trk`) and route (`rte`) in the file, as imported routes. Waypoints (`wpt`) are skipped.
    static func routes(from data: Data, fallbackName: String) -> [SavedRoute] {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.shouldProcessNamespaces = true
        guard parser.parse() || !reader.lines.isEmpty else { return [] }
        let fileName = reader.metadataName ?? fallbackName
        return reader.lines.enumerated().compactMap { i, line in
            let pieces = line.pieces.filter { $0.count >= 2 }
            guard !pieces.isEmpty else { return nil }
            let name = line.name ?? (reader.lines.count > 1 ? "\(fileName) \(i + 1)" : fileName)
            var route = SavedRoute(name: name, kind: .imported)
            route.legs = pieces.map { SavedRoute.Leg(coords: $0.flatMap { [$0.lon, $0.lat] }, followsTracks: false) }
            let all = pieces.joined()
            // Keep times and altitudes only for a single piece where every point has a time.
            if pieces.count == 1, all.allSatisfy({ $0.time != nil }) {
                route.times = all.map { $0.time! }
                route.altitudes = all.map(\.ele)
            }
            if let t = route.times.first { route.created = Date(timeIntervalSince1970: t) }
            return route
        }
    }

    private struct Point {
        var lat: Double
        var lon: Double
        var ele: Double?
        var time: Double?
    }

    private struct Line {
        var name: String?
        var pieces: [[Point]] = []
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var lines: [Line] = []
        var metadataName: String?
        private var current: Line?
        private var point: Point?
        private var text = ""
        private var inMetadata = false
        private var inWaypoint = false
        private let isoFull: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        private let iso = ISO8601DateFormatter()

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            switch name {
            case "metadata": inMetadata = true
            case "wpt": inWaypoint = true
            case "trk", "rte": current = Line()
            case "trkseg": current?.pieces.append([])
            case "trkpt", "rtept":
                if let lat = attributes["lat"].flatMap(Double.init), let lon = attributes["lon"].flatMap(Double.init),
                   abs(lat) <= 90, abs(lon) <= 180 {
                    point = Point(lat: lat, lon: lon)
                }
                if name == "rtept", current?.pieces.isEmpty == true { current?.pieces.append([]) }
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "metadata": inMetadata = false
            case "wpt": inWaypoint = false
            case "name":
                if inMetadata, metadataName == nil, !value.isEmpty { metadataName = value }
                else if !inWaypoint, point == nil, current != nil, current?.name == nil, !value.isEmpty { current?.name = value }
            case "ele": point?.ele = Double(value)
            case "time":
                if point != nil { point?.time = (isoFull.date(from: value) ?? iso.date(from: value))?.timeIntervalSince1970 }
            case "trkpt", "rtept":
                if let p = point, current != nil {
                    if current!.pieces.isEmpty { current!.pieces.append([]) }
                    current!.pieces[current!.pieces.count - 1].append(p)
                }
                point = nil
            case "trk", "rte":
                if let line = current { lines.append(line) }
                current = nil
            default: break
            }
            text = ""
        }
    }
}
