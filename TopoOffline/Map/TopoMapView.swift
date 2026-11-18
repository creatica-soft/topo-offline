import SwiftUI
import MapKit

/// MKMapView wrapped for SwiftUI. (SwiftUI's own `Map` can't show custom tile layers.)
struct TopoMapView: UIViewRepresentable {
    let source: TileSource
    let offlineOnly: Bool
    /// Let Apple's map show underneath: used where no topo map covers the screen (Online only).
    let showAppleMap: Bool
    /// Show the national map instead of the state map when zoomed out.
    let nationalWhenZoomedOut: Bool
    let library: OfflineTileLibrary
    let regions: [OfflineRegion]
    /// Search result to mark with a pin.
    let pin: PlaceName?
    /// Track to highlight.
    let track: Track?
    /// All tracks to draw (Victoria, which has no topo map); `areaTracksVersion` changes with them.
    let areaTracks: [TrackSegment]
    let areaTracksVersion: Int
    /// Victorian campsites/huts to show as pins, and current closures to draw in red.
    let sites: [Campsite]
    let closedLines: [ClosedLine]
    /// NZ freedom-camping rule areas (shaded).
    let campingRules: [CampingRule]
    /// Position shown while dragging along an elevation profile.
    let profileMarker: CLLocationCoordinate2D?
    /// The campsite whose card is open (other pins get deselected).
    let selectedSiteID: String?
    let onSelectSite: (Campsite) -> Void
    let controller: MapController
    /// Single tap on the map: coordinate, and a tap tolerance in metres (≈ a fingertip at this zoom).
    let onTap: (CLLocationCoordinate2D, Double) -> Void
    /// Saved routes and recorded walks to draw; `routesKey` changes with them.
    var routes: [SavedRoute] = []
    var routesKey = ""
    /// The route being planned, if any.
    var draft: RouteDraft? = nil
    /// The walk being recorded; `liveVersion` changes with it.
    var liveLine: [[CLLocationCoordinate2D]] = []
    var liveVersion = 0
    /// A waypoint of the route being planned was tapped or dragged.
    var onWaypoint: (WaypointEvent) -> Void = { _ in }

    struct RouteDraft {
        var waypoints: [CLLocationCoordinate2D]
        var legs: [SavedRoute.Leg]
        /// Changes with every edit (and differs between planning sessions).
        var key: String
        /// The highlighted point.
        var selected: Int?
    }

    enum WaypointEvent {
        case tap(Int)
        case move(Int, CLLocationCoordinate2D)
    }

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsCompass = false  // shown by ContentView instead, so it doesn't sit under the buttons
        map.showsScale = false    // ditto: ContentView shows an always-visible scale bar
        map.isPitchEnabled = false
        map.isRotateEnabled = true
        map.pointOfInterestFilter = .excludingAll
        map.cameraZoomRange = MKMapView.CameraZoomRange(minCenterCoordinateDistance: 200)
        map.setRegion(MapController.startRegion(), animated: false)
        // When Apple's map is shown (no topo map for the area), keep it quiet so tracks and pins stand out.
        map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        DispatchQueue.main.async { controller.attach(map) }  // not during a SwiftUI view update
        context.coordinator.attachTapGestures(to: map)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.configure(map, source: source, offlineOnly: offlineOnly, showAppleMap: showAppleMap,
                                      nationalWhenZoomedOut: nationalWhenZoomedOut,
                                      library: library, regions: regions)
        context.coordinator.showPin(pin, on: map)
        context.coordinator.showAreaTracks(areaTracks, version: areaTracksVersion, on: map)
        context.coordinator.showClosedLines(closedLines, on: map)
        context.coordinator.showRules(campingRules, on: map)
        context.coordinator.showSites(sites, selectedID: selectedSiteID, on: map)
        context.coordinator.onSelectSite = onSelectSite
        context.coordinator.showTrack(track, on: map)
        context.coordinator.showProfileMarker(profileMarker, on: map)
        context.coordinator.showRoutes(routes, key: routesKey, on: map)
        context.coordinator.showLive(liveLine, version: liveVersion, on: map)
        context.coordinator.showDraft(draft, on: map)
        context.coordinator.onTap = onTap
        context.coordinator.onWaypoint = onWaypoint
    }

    /// Two layers so the highlighted track stands out on any map: a white casing and a coloured line.
    final class TrackCasing: MKMultiPolyline {}
    final class TrackLine: MKMultiPolyline {}
    /// Every track in view, drawn like tracks on a printed topo map (thin dashed brown).
    final class AreaTracks: MKMultiPolyline {}
    /// Closed tracks and roads (red dashes).
    final class ClosedLines: MKMultiPolyline {}
    /// A freedom-camping rule area; `title` is "prohibited" or "restricted".
    final class RulePolygon: MKPolygon {}

    final class ProfileMarker: MKPointAnnotation {}

    /// Saved routes (blue) and recorded walks (orange), on a white casing.
    final class RouteCasing: MKMultiPolyline {}
    final class RouteLine: MKMultiPolyline {}
    final class WalkLine: MKMultiPolyline {}
    /// The route being planned: legs along tracks solid, straight legs dashed.
    final class DraftCasing: MKMultiPolyline {}
    final class DraftLine: MKMultiPolyline {}
    final class DraftStraight: MKMultiPolyline {}
    /// The walk being recorded (red).
    final class LiveLine: MKMultiPolyline {}
    final class WaypointAnnotation: MKPointAnnotation {
        var index = 0
        var isEnd = false
        var isSelected = false
    }
    /// Drags the selected route point. It sits on the map rather than on the point's view and starts
    /// when a drag begins near the point on screen, so it doesn't depend on MapKit delivering the
    /// touch to the annotation view (it doesn't always). MapKit's own dragging needs its selection
    /// and a long press.
    final class WaypointPan: UIPanGestureRecognizer {
        weak var point: WaypointAnnotation?
        var offset = CGPoint.zero
        var original = CLLocationCoordinate2D()
    }

    final class SiteAnnotation: NSObject, MKAnnotation {
        let site: Campsite
        init(_ site: Campsite) { self.site = site }
        var coordinate: CLLocationCoordinate2D { site.coordinate }
        var title: String? { site.name }
    }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var onTap: ((CLLocationCoordinate2D, Double) -> Void)?
        private var trackOverlays: [MKOverlay] = []
        private var shownTrack: Track?
        private var areaOverlay: AreaTracks?
        private var areaVersion = -1
        var onSelectSite: ((Campsite) -> Void)?
        private var siteAnnotations: [String: SiteAnnotation] = [:]
        private var closedOverlay: ClosedLines?
        private var closedKey = ""
        private var ruleOverlays: [String: RulePolygon] = [:]
        private var marker: ProfileMarker?
        var onWaypoint: ((WaypointEvent) -> Void)?
        private var routeOverlays: [MKOverlay] = []
        private var routesKey: String?
        private var draftOverlays: [MKOverlay] = []
        private var waypointAnnotations: [WaypointAnnotation] = []
        private var draftKey: String?
        private var liveOverlay: LiveLine?
        private var liveVersion = -1

        private static func polylines(_ lines: [[CLLocationCoordinate2D]]) -> [MKPolyline] {
            lines.filter { $0.count >= 2 }.map { pts in
                var pts = pts
                return MKPolyline(coordinates: &pts, count: pts.count)
            }
        }

        /// Adds overlays under the highlighted track (if any), so the selection stays on top.
        @MainActor
        private func addBelowHighlight(_ overlays: [MKOverlay], on map: MKMapView) {
            for o in overlays {
                if let below = trackOverlays.first {
                    map.insertOverlay(o, below: below)
                } else {
                    map.addOverlay(o, level: .aboveLabels)
                }
            }
        }

        @MainActor
        func showRoutes(_ routes: [SavedRoute], key: String, on map: MKMapView) {
            guard key != routesKey else { return }
            routesKey = key
            map.removeOverlays(routeOverlays)
            routeOverlays = []
            guard !routes.isEmpty else { return }
            let planned = Self.polylines(routes.filter { $0.kind != .recorded }.map(\.path))
            // A recording is drawn piece by piece, with no line across a pause.
            let walked = Self.polylines(routes.filter { $0.kind == .recorded }.flatMap { $0.legs.map(\.points) })
            var overlays: [MKOverlay] = [RouteCasing(planned + walked)]
            if !planned.isEmpty { overlays.append(RouteLine(planned)) }
            if !walked.isEmpty { overlays.append(WalkLine(walked)) }
            addBelowHighlight(overlays, on: map)
            routeOverlays = overlays
        }

        @MainActor
        func showLive(_ pieces: [[CLLocationCoordinate2D]], version: Int, on map: MKMapView) {
            guard version != liveVersion else { return }
            liveVersion = version
            if let old = liveOverlay { map.removeOverlay(old) }
            liveOverlay = nil
            let lines = Self.polylines(pieces)
            guard !lines.isEmpty else { return }
            let line = LiveLine(lines)
            map.addOverlay(line, level: .aboveLabels)
            liveOverlay = line
        }

        @MainActor
        func showDraft(_ draft: RouteDraft?, on map: MKMapView) {
            guard draft?.key != draftKey else {
                // Same route: just move the highlight.
                for a in waypointAnnotations where a.isSelected != (a.index == draft?.selected) {
                    a.isSelected = a.index == draft?.selected
                    if let view = map.view(for: a) { Self.style(view, for: a) }
                }
                return
            }
            draftKey = draft?.key
            map.removeOverlays(draftOverlays)
            map.removeAnnotations(waypointAnnotations)
            draftOverlays = []
            waypointAnnotations = []
            guard let draft else { return }
            let along = Self.polylines(draft.legs.filter(\.followsTracks).map(\.points))
            let straight = Self.polylines(draft.legs.filter { !$0.followsTracks }.map(\.points))
            if !along.isEmpty || !straight.isEmpty {
                draftOverlays = [DraftCasing(along + straight)]
                if !along.isEmpty { draftOverlays.append(DraftLine(along)) }
                if !straight.isEmpty { draftOverlays.append(DraftStraight(straight)) }
                for o in draftOverlays { map.addOverlay(o, level: .aboveLabels) }
            }
            for (i, c) in draft.waypoints.enumerated() {
                let a = WaypointAnnotation()
                a.coordinate = c
                a.index = i
                a.isEnd = i == 0 || i == draft.waypoints.count - 1
                a.isSelected = i == draft.selected
                a.title = i == 0 ? "Start" : (i == draft.waypoints.count - 1 ? "End" : "Point \(i + 1)")
                waypointAnnotations.append(a)
            }
            map.addAnnotations(waypointAnnotations)
        }

        @objc func dragWaypoint(_ g: WaypointPan) {
            guard let map = g.view as? MKMapView else { return }
            guard let a = g.point else {
                map.isScrollEnabled = true
                return
            }
            let touch = g.location(in: map)
            switch g.state {
            case .began:
                // Keep the point where it is under the finger rather than jumping to the touch.
                let centre = map.convert(a.coordinate, toPointTo: map)
                g.offset = CGPoint(x: touch.x - centre.x, y: touch.y - centre.y)
                g.original = a.coordinate
                map.isScrollEnabled = false
            case .changed:
                a.coordinate = map.convert(CGPoint(x: touch.x - g.offset.x, y: touch.y - g.offset.y), toCoordinateFrom: map)
            case .ended:
                map.isScrollEnabled = true
                onWaypoint?(.move(a.index, a.coordinate))
            default:
                map.isScrollEnabled = true
                a.coordinate = g.original
            }
        }

        /// A route point: a coloured dot (green start, red end, blue in between) in a fingertip-sized
        /// tap area. The selected point is bigger, with a halo, and is the only one that can be dragged
        /// (so a drag anywhere else always moves the map); see `WaypointPan`.
        static func style(_ view: MKAnnotationView, for w: WaypointAnnotation) {
            let colour: UIColor = w.index == 0 ? .systemGreen : (w.isEnd ? .systemRed : .systemBlue)
            let dot: CGFloat = w.isSelected ? 26 : (w.isEnd ? 22 : 16)
            let side: CGFloat = w.isSelected ? 44 : 34
            view.image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { ctx in
                let cg = ctx.cgContext
                let mid = side / 2
                if w.isSelected {
                    colour.withAlphaComponent(0.3).setFill()
                    cg.fillEllipse(in: CGRect(x: 0, y: 0, width: side, height: side))
                    UIColor.black.withAlphaComponent(0.25).setFill()
                    cg.fillEllipse(in: CGRect(x: mid - dot / 2 - 1, y: mid - dot / 2 - 1, width: dot + 2, height: dot + 2))
                }
                UIColor.white.setFill()
                cg.fillEllipse(in: CGRect(x: mid - dot / 2, y: mid - dot / 2, width: dot, height: dot))
                colour.setFill()
                let inset: CGFloat = w.isSelected ? 5 : 3
                cg.fillEllipse(in: CGRect(x: mid - dot / 2 + inset, y: mid - dot / 2 + inset,
                                          width: dot - 2 * inset, height: dot - 2 * inset))
            }
            // The selected point on top of its neighbours (their tap areas can overlap).
            view.zPriority = w.isSelected ? .max : MKAnnotationViewZPriority(rawValue: 900)
            view.accessibilityLabel = w.title
            view.accessibilityTraits = w.isSelected ? [.button, .selected] : .button
        }

        @MainActor
        func showProfileMarker(_ c: CLLocationCoordinate2D?, on map: MKMapView) {
            guard let c else {
                if let m = marker { map.removeAnnotation(m) }
                marker = nil
                return
            }
            if let m = marker {
                m.coordinate = c  // moves smoothly while dragging
            } else {
                let m = ProfileMarker()
                m.coordinate = c
                map.addAnnotation(m)
                marker = m
            }
        }

        @MainActor
        func showRules(_ rules: [CampingRule], on map: MKMapView) {
            let wanted = Set(rules.map(\.id))
            for (id, poly) in ruleOverlays where !wanted.contains(id) {
                map.removeOverlay(poly)
                ruleOverlays[id] = nil
            }
            for rule in rules where ruleOverlays[rule.id] == nil {
                guard let ring = rule.rings.first else { continue }
                var pts = stride(from: 0, to: ring.count - 1, by: 2).map {
                    CLLocationCoordinate2D(latitude: ring[$0 + 1], longitude: ring[$0])
                }
                let poly = RulePolygon(coordinates: &pts, count: pts.count)
                poly.title = rule.prohibited ? "prohibited" : "restricted"
                if let below = trackOverlays.first {
                    map.insertOverlay(poly, below: below)
                } else {
                    map.addOverlay(poly, level: .aboveLabels)
                }
                ruleOverlays[rule.id] = poly
            }
        }

        @MainActor
        func showSites(_ sites: [Campsite], selectedID: String?, on map: MKMapView) {
            let wanted = Dictionary(sites.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            // Re-add a pin if its closure status changed (the colour depends on it).
            let stale = siteAnnotations.filter { id, a in wanted[id] == nil || wanted[id] != a.site }
            map.removeAnnotations(Array(stale.values))
            stale.keys.forEach { siteAnnotations[$0] = nil }
            let added = wanted.filter { siteAnnotations[$0.key] == nil }.map { SiteAnnotation($0.value) }
            map.addAnnotations(added)
            added.forEach { siteAnnotations[$0.site.id] = $0 }
            if selectedID == nil {
                for a in map.selectedAnnotations where a is SiteAnnotation { map.deselectAnnotation(a, animated: true) }
            }
        }

        @MainActor
        func showClosedLines(_ lines: [ClosedLine], on map: MKMapView) {
            let key = lines.map(\.id).joined(separator: "|")
            guard key != closedKey else { return }
            closedKey = key
            if let old = closedOverlay { map.removeOverlay(old) }
            closedOverlay = nil
            guard !lines.isEmpty else { return }
            let overlay = ClosedLines(lines.flatMap(\.segments).map { s -> MKPolyline in
                var pts = s.points
                return MKPolyline(coordinates: &pts, count: pts.count)
            })
            if let below = trackOverlays.first {
                map.insertOverlay(overlay, below: below)
            } else {
                map.addOverlay(overlay, level: .aboveLabels)
            }
            closedOverlay = overlay
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is ProfileMarker {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: "profile")
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: "profile")
                view.annotation = annotation
                let size: CGFloat = 18
                view.image = UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { ctx in
                    UIColor.white.setFill()
                    ctx.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: size, height: size))
                    UIColor.systemPurple.setFill()
                    ctx.cgContext.fillEllipse(in: CGRect(x: 3, y: 3, width: size - 6, height: size - 6))
                }
                view.displayPriority = .required
                view.zPriority = .max
                return view
            }
            if let w = annotation as? WaypointAnnotation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: "waypoint")
                    ?? MKAnnotationView(annotation: w, reuseIdentifier: "waypoint")
                view.annotation = w
                Self.style(view, for: w)
                view.canShowCallout = false
                view.displayPriority = .required
                return view
            }
            guard let a = annotation as? SiteAnnotation else { return nil }  // default views for the rest
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: "site") as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: a, reuseIdentifier: "site")
            view.annotation = a
            view.clusteringIdentifier = "sites"
            view.displayPriority = .defaultLow
            view.canShowCallout = false
            view.glyphImage = UIImage(systemName: a.site.symbol)
            switch a.site.closureStatus {
            case .current: view.markerTintColor = .systemRed
            case .upcoming: view.markerTintColor = .systemOrange
            case .none:
                // Community (OpenStreetMap) sites in teal, official ones in green.
                view.markerTintColor = a.site.isCommunity
                    ? .systemTeal : UIColor(red: 0.18, green: 0.45, blue: 0.25, alpha: 1)
            }
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let w = view.annotation as? WaypointAnnotation {
                // The planner keeps track of the selection; MapKit's own would swallow the next map tap.
                mapView.deselectAnnotation(w, animated: false)
                onWaypoint?(.tap(w.index))
            } else if let a = view.annotation as? SiteAnnotation {
                onSelectSite?(a.site)
            } else if let cluster = view.annotation as? MKClusterAnnotation {
                // Tapping a group of pins zooms in on them.
                mapView.showAnnotations(cluster.memberAnnotations, animated: true)
                mapView.deselectAnnotation(cluster, animated: false)
            }
        }

        @MainActor
        func showAreaTracks(_ segments: [TrackSegment], version: Int, on map: MKMapView) {
            guard version != areaVersion else { return }
            areaVersion = version
            if let old = areaOverlay { map.removeOverlay(old) }
            areaOverlay = nil
            guard !segments.isEmpty else { return }
            let overlay = AreaTracks(segments.map { s -> MKPolyline in
                var pts = s.points
                return MKPolyline(coordinates: &pts, count: pts.count)
            })
            // Keep the highlighted track (if any) on top.
            if let below = trackOverlays.first {
                map.insertOverlay(overlay, below: below)
            } else {
                map.addOverlay(overlay, level: .aboveLabels)
            }
            areaOverlay = overlay
        }

        func attachTapGestures(to map: MKMapView) {
            // Our single tap must wait for a double tap (MapKit's zoom-in) to fail.
            let double = UITapGestureRecognizer(target: nil, action: nil)
            double.numberOfTapsRequired = 2
            double.cancelsTouchesInView = false
            double.delegate = self
            let single = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            single.require(toFail: double)
            single.cancelsTouchesInView = false
            single.delegate = self
            map.addGestureRecognizer(double)
            map.addGestureRecognizer(single)
            let drag = WaypointPan(target: self, action: #selector(dragWaypoint(_:)))
            drag.maximumNumberOfTouches = 1
            drag.delegate = self
            map.addGestureRecognizer(drag)
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            !(g is WaypointPan || other is WaypointPan)
        }

        /// Only the selected route point can be dragged, by a drag that starts on or next to it.
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? WaypointPan else { return true }
            pan.point = nil
            guard let map = pan.view as? MKMapView,
                  let a = waypointAnnotations.first(where: \.isSelected) else { return false }
            let now = pan.location(in: map), moved = pan.translation(in: map)
            let start = CGPoint(x: now.x - moved.x, y: now.y - moved.y)
            let centre = map.convert(a.coordinate, toPointTo: map)
            guard hypot(start.x - centre.x, start.y - centre.y) <= 30 else { return false }
            pan.point = a
            return true
        }

        /// While a point is being dragged the map doesn't pan.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            g is WaypointPan && other is UIPanGestureRecognizer
        }

        @objc private func handleTap(_ g: UITapGestureRecognizer) {
            guard g.state == .ended, let map = g.view as? MKMapView else { return }
            let point = g.location(in: map)
            // Leave taps on pins and the blue dot to MapKit.
            var hit = map.hitTest(point, with: nil)
            while let v = hit {
                if v is MKAnnotationView { return }
                hit = v.superview
            }
            let c = map.convert(point, toCoordinateFrom: map)
            let metersPerPoint = MKMetersPerMapPointAtLatitude(c.latitude) * map.visibleMapRect.size.width
                / max(Double(map.bounds.width), 1)
            onTap?(c, metersPerPoint * 22)
        }

        @MainActor
        func showTrack(_ track: Track?, on map: MKMapView) {
            guard track != shownTrack else { return }
            shownTrack = track
            map.removeOverlays(trackOverlays)
            trackOverlays = []
            guard let track else { return }
            let lines = track.segments.map { s -> MKPolyline in
                var pts = s.points
                return MKPolyline(coordinates: &pts, count: pts.count)
            }
            let casing = TrackCasing(lines)
            let line = TrackLine(lines)
            map.addOverlay(casing, level: .aboveLabels)
            map.addOverlay(line, level: .aboveLabels)
            trackOverlays = [casing, line]
        }

        private let controller: MapController
        private var layerKey = ""
        private var tileOverlays: [MKTileOverlay] = []
        private var outlines: [UUID: MKPolygon] = [:]
        private var pinAnnotation: MKPointAnnotation?
        private var pinID: String?

        @MainActor
        func showPin(_ place: PlaceName?, on map: MKMapView) {
            guard place?.id != pinID else { return }
            if let old = pinAnnotation { map.removeAnnotation(old) }
            pinAnnotation = nil
            pinID = place?.id
            guard let place else { return }
            let a = MKPointAnnotation()
            a.coordinate = place.coordinate
            a.title = place.name
            a.subtitle = place.kind
            map.addAnnotation(a)
            pinAnnotation = a
        }

        init(controller: MapController) {
            self.controller = controller
        }

        @MainActor
        func configure(_ map: MKMapView, source: TileSource, offlineOnly: Bool, showAppleMap: Bool,
                       nationalWhenZoomedOut: Bool, library: OfflineTileLibrary, regions: [OfflineRegion]) {
            // Tile layers: the national overview underneath, the chosen map on top
            // (optionally only once zoomed in far enough).
            let key = "\(source.id)|\(offlineOnly)|\(nationalWhenZoomedOut)|\(showAppleMap)"
            if key != layerKey {
                layerKey = key
                map.removeOverlays(tileOverlays)
                var layers: [MKTileOverlay] = []
                let isStateMap = source.id != TileSources.overview.id && source.usesNationalOverview
                if isStateMap {
                    layers.append(TopoTileOverlay(source: TileSources.overview, library: library,
                                                  offlineOnly: offlineOnly, maxOverzoom: 6,
                                                  replacesAppleMap: !showAppleMap))
                }
                layers.append(TopoTileOverlay(source: source, library: library, offlineOnly: offlineOnly,
                                              fromZoom: isStateMap && nationalWhenZoomedOut ? TileSources.detailFromZoom : nil,
                                              replacesAppleMap: !showAppleMap))
                for (i, layer) in layers.enumerated() {
                    map.insertOverlay(layer, at: i, level: .aboveLabels)
                }
                tileOverlays = layers
            }

            // Dashed outlines around downloaded areas, drawn above the tiles.
            let wanted = Dictionary(uniqueKeysWithValues: regions.map { ($0.id, $0) })
            for (id, polygon) in outlines where wanted[id] == nil {
                map.removeOverlay(polygon)
                outlines[id] = nil
            }
            for (id, region) in wanted where outlines[id] == nil {
                let b = region.bbox
                var corners = [
                    CLLocationCoordinate2D(latitude: b.minLat, longitude: b.minLon),
                    CLLocationCoordinate2D(latitude: b.minLat, longitude: b.maxLon),
                    CLLocationCoordinate2D(latitude: b.maxLat, longitude: b.maxLon),
                    CLLocationCoordinate2D(latitude: b.maxLat, longitude: b.minLon),
                ]
                let polygon = MKPolygon(coordinates: &corners, count: corners.count)
                map.addOverlay(polygon, level: .aboveLabels)
                outlines[id] = polygon
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tiles = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tiles)
            }
            if let closed = overlay as? ClosedLines {
                let r = MKMultiPolylineRenderer(multiPolyline: closed)
                r.strokeColor = UIColor.systemRed.withAlphaComponent(0.9)
                r.lineWidth = 3.5
                r.lineDashPattern = [7, 5]
                r.lineCap = .round
                return r
            }
            if let tracks = overlay as? AreaTracks {
                let r = MKMultiPolylineRenderer(multiPolyline: tracks)
                r.strokeColor = UIColor(red: 0.62, green: 0.22, blue: 0.08, alpha: 0.95)
                r.lineWidth = 2.2
                r.lineDashPattern = [5, 3]
                r.lineCap = .round
                return r
            }
            if let casing = overlay as? TrackCasing {
                let r = MKMultiPolylineRenderer(multiPolyline: casing)
                r.strokeColor = UIColor.white.withAlphaComponent(0.9)
                r.lineWidth = 9
                r.lineCap = .round
                r.lineJoin = .round
                return r
            }
            if let line = overlay as? TrackLine {
                let r = MKMultiPolylineRenderer(multiPolyline: line)
                r.strokeColor = .systemPurple
                r.lineWidth = 5
                r.lineCap = .round
                r.lineJoin = .round
                return r
            }
            if let casing = overlay as? RouteCasing ?? overlay as? DraftCasing {
                let r = MKMultiPolylineRenderer(multiPolyline: casing)
                r.strokeColor = UIColor.white.withAlphaComponent(0.85)
                r.lineWidth = 7
                r.lineCap = .round
                r.lineJoin = .round
                return r
            }
            if let line = overlay as? RouteLine ?? overlay as? DraftLine {
                let r = MKMultiPolylineRenderer(multiPolyline: line)
                r.strokeColor = .systemBlue
                r.lineWidth = 4
                r.lineCap = .round
                r.lineJoin = .round
                return r
            }
            if let line = overlay as? DraftStraight {
                let r = MKMultiPolylineRenderer(multiPolyline: line)
                r.strokeColor = .systemBlue
                r.lineWidth = 4
                r.lineDashPattern = [8, 6]
                return r
            }
            if let line = overlay as? WalkLine {
                let r = MKMultiPolylineRenderer(multiPolyline: line)
                r.strokeColor = .systemOrange
                r.lineWidth = 4
                r.lineCap = .round
                r.lineJoin = .round
                return r
            }
            if let line = overlay as? LiveLine {
                let r = MKMultiPolylineRenderer(multiPolyline: line)
                r.strokeColor = .systemRed
                r.lineWidth = 4
                r.lineCap = .round
                r.lineJoin = .round
                return r
            }
            if let rule = overlay as? RulePolygon {
                let r = MKPolygonRenderer(polygon: rule)
                let color: UIColor = rule.title == "prohibited" ? .systemRed : .systemOrange
                r.fillColor = color.withAlphaComponent(0.12)
                r.strokeColor = color.withAlphaComponent(0.8)
                r.lineWidth = 1.5
                r.lineDashPattern = [4, 3]
                return r
            }
            if let polygon = overlay as? MKPolygon {
                let r = MKPolygonRenderer(polygon: polygon)
                r.strokeColor = .systemOrange
                r.lineWidth = 2
                r.lineDashPattern = [6, 4]
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            MainActor.assumeIsolated { controller.mapDidMove(mapView) }
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            MainActor.assumeIsolated { controller.mapIsMoving(mapView) }
        }
    }
}
