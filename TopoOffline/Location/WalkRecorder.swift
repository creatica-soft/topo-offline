import Foundation
import CoreLocation
import Observation

/// Records a walk with GPS, including while the phone is locked (iOS shows its blue location
/// indicator). Off unless the user turns on "Record walks". Points never leave the phone.
@MainActor
@Observable
final class WalkRecorder: NSObject {
    /// How often a point is recorded: closer points use more battery.
    enum Detail: String, CaseIterable, Identifiable {
        case detailed, standard, saver
        var id: String { rawValue }

        var title: String {
            switch self {
            case .detailed: return "Detailed"
            case .standard: return "Standard"
            case .saver: return "Battery saver"
            }
        }

        var explanation: String {
            switch self {
            case .detailed: return "A point about every 5 m. Uses the most battery."
            case .standard: return "A point about every 15 m."
            case .saver: return "A point about every 50 m, less precise. Uses the least battery."
            }
        }

        var distanceFilter: CLLocationDistance {
            switch self {
            case .detailed: return 5
            case .standard: return 15
            case .saver: return 50
            }
        }

        var accuracy: CLLocationAccuracy {
            switch self {
            case .detailed: return kCLLocationAccuracyBest
            case .standard: return kCLLocationAccuracyNearestTenMeters
            case .saver: return kCLLocationAccuracyHundredMeters
            }
        }

        /// Fixes vaguer than this are dropped.
        var maxAccuracy: Double {
            switch self {
            case .detailed: return 30
            case .standard: return 50
            case .saver: return 100
            }
        }
    }

    /// The walk being recorded (saved as `inProgress` as it goes).
    private(set) var current: SavedRoute?
    private(set) var lastFix: GPSFix?
    private(set) var distance: Double = 0
    private(set) var climb: (up: Double, down: Double) = (0, 0)
    /// The recorded line so far, one piece per stretch between pauses (for the map); `version`
    /// changes with it.
    private(set) var pieces: [[CLLocationCoordinate2D]] = []
    private(set) var version = 0
    /// Paused: GPS is off (to save battery over a long break) until Resume.
    private(set) var isPaused = false
    /// Set when location access is off, so the app can explain how to turn it on.
    var permissionProblem = false

    var isRecording: Bool { current != nil }
    var startDate: Date? { current?.times.first.map { Date(timeIntervalSince1970: $0) } ?? current?.created }

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private let store: RouteStore
    @ObservationIgnored private var detail = Detail.standard
    @ObservationIgnored private var session: CLBackgroundActivitySession?
    @ObservationIgnored private var lastSave = Date.distantPast
    @ObservationIgnored private var startWhenAllowed = false

    init(store: RouteStore) {
        self.store = store
        super.init()
        manager.delegate = self
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
    }

    func start(detail: Detail) {
        guard current == nil else { return }
        var walk = SavedRoute(name: SavedRoute.recordingName(), kind: .recorded)
        walk.inProgress = true
        walk.legs = [SavedRoute.Leg(coords: [], followsTracks: false)]
        begin(walk, detail: detail)
    }

    /// Carries on with a walk left in progress (the app was closed while recording). Points
    /// weren't recorded meanwhile, so it carries on in a new piece rather than joining the gap.
    func resume(_ walk: SavedRoute, detail: Detail) {
        guard current == nil else { return }
        var w = walk
        if w.legs.last?.coords.isEmpty != true { w.legs.append(SavedRoute.Leg(coords: [], followsTracks: false)) }
        begin(w, detail: detail)
    }

    /// Turns GPS off until `resumeRecording()`, e.g. for a long lunch. The time counts as stopped.
    func pause() {
        guard current != nil, !isPaused else { return }
        stopUpdates()
        isPaused = true
        saveNow()
    }

    /// GPS back on, in a new piece of the walk (so wherever you went meanwhile isn't drawn as a
    /// straight line or counted as distance).
    func resumeRecording() {
        guard var walk = current, isPaused else { return }
        isPaused = false
        if walk.legs.last?.coords.isEmpty != true { walk.legs.append(SavedRoute.Leg(coords: [], followsTracks: false)) }
        current = walk
        pieces.append([])
        lastFix = nil
        switch manager.authorizationStatus {
        case .denied, .restricted: permissionProblem = true
        default: startUpdates()
        }
    }

    /// Stops and saves the walk. Returns it (nil if nothing was recorded, in which case it's discarded).
    @discardableResult
    func stop() -> SavedRoute? {
        guard var walk = current else { return nil }
        stopUpdates()
        startWhenAllowed = false
        current = nil
        walk.inProgress = false
        walk.modified = Date()
        walk.legs.removeAll { $0.coords.isEmpty }
        defer { reset() }
        guard walk.legs.reduce(0, { $0 + $1.coords.count / 2 }) >= 4 else {
            store.delete(walk)
            return nil
        }
        store.save(walk)
        store.setShown(walk.id, true)
        return walk
    }

    /// Writes the walk so far (called periodically and when the app goes to the background).
    func saveNow() {
        guard let walk = current else { return }
        store.save(walk)
        lastSave = Date()
    }

    private func begin(_ walk: SavedRoute, detail: Detail) {
        self.detail = detail
        current = walk
        pieces = walk.legs.map(\.points)
        distance = pieces.reduce(0) { $0 + TrackPath.length($1) }
        climb = RecordingFilter.climb(walk)
        lastFix = nil
        isPaused = false
        version += 1
        saveNow()
        manager.distanceFilter = detail.distanceFilter
        manager.desiredAccuracy = detail.accuracy
        switch manager.authorizationStatus {
        case .notDetermined:
            startWhenAllowed = true
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            permissionProblem = true
            current = nil
            store.delete(walk)
            reset()
        default:
            startUpdates()
        }
    }

    private func stopUpdates() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        session?.invalidate()
        session = nil
    }

    private func startUpdates() {
        // Keeps location updates coming while locked, with "When In Use" permission only.
        session = CLBackgroundActivitySession()
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
    }

    private func reset() {
        pieces = []
        isPaused = false
        distance = 0
        climb = (0, 0)
        lastFix = nil
        version += 1
    }

    private func record(_ location: CLLocation) {
        guard var walk = current, !isPaused else { return }
        let fix = GPSFix(coordinate: location.coordinate, time: location.timestamp.timeIntervalSince1970,
                         horizontalAccuracy: location.horizontalAccuracy,
                         altitude: location.verticalAccuracy >= 0 ? location.altitude : nil)
        guard RecordingFilter.accept(fix, after: lastFix, maxAccuracy: detail.maxAccuracy) else { return }
        if let last = lastFix { distance += TrackPath.meters(last.coordinate, fix.coordinate) }
        lastFix = fix
        if walk.legs.isEmpty { walk.legs = [SavedRoute.Leg(coords: [], followsTracks: false)] }
        walk.legs[walk.legs.count - 1].coords += [fix.coordinate.longitude, fix.coordinate.latitude]
        walk.times.append(fix.time)
        walk.altitudes.append(fix.altitude)
        current = walk
        if pieces.isEmpty { pieces = [[]] }
        pieces[pieces.count - 1].append(fix.coordinate)
        climb = RecordingFilter.climb(walk)
        version += 1
        if Date().timeIntervalSince(lastSave) > 60 { saveNow() }
    }
}

extension WalkRecorder: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            for l in locations { record(l) }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            guard startWhenAllowed else { return }
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                startWhenAllowed = false
                startUpdates()
            case .denied, .restricted:
                startWhenAllowed = false
                permissionProblem = true
                if let walk = current { store.delete(walk) }
                current = nil
                reset()
            default: break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Temporary failures (no fix yet, under heavy cover) are normal: keep going.
    }
}
