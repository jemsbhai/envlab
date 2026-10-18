import CoreLocation
import Foundation
import Observation

/// Producer side of air & water: tells the server roughly where this phone is, so it can pull
/// open sensor data for the area. Fire and forget (`location` event); no reply.
///
/// Uses kilometer accuracy (cheap on battery) and publishes when the phone has moved about
/// 1 km or 15 minutes have passed. Coordinates are rounded to ~1 km before they leave the phone.
@Observable
@MainActor
final class LocationReporter: NSObject {
    static let sharingKey = "shareLocation"
    static let minDistance: CLLocationDistance = 1_000
    static let minInterval: TimeInterval = 15 * 60

    private(set) var authorization: CLAuthorizationStatus
    private(set) var lastLocation: CLLocation?
    private(set) var lastPublished: Date?
    private(set) var lastError: String?

    var sharing: Bool = UserDefaults.standard.object(forKey: LocationReporter.sharingKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(sharing, forKey: Self.sharingKey)
            if sharing { publishIfNeeded(force: true) }
        }
    }

    var isAuthorized: Bool { authorization == .authorizedWhenInUse || authorization == .authorizedAlways }

    /// Live sensor matching (envlab) needs precise fixes: sensors match within 100 m. When on, every
    /// fix goes to `onPreciseFix` at most every 5 seconds while the app is open (the API's suggested rate).
    var precise = false {
        didSet {
            guard precise != oldValue else { return }
            manager.desiredAccuracy = precise ? kCLLocationAccuracyBest : kCLLocationAccuracyKilometer
            manager.distanceFilter = precise ? kCLDistanceFilterNone : 500
        }
    }
    static let preciseInterval: TimeInterval = 5
    @ObservationIgnored var onPreciseFix: ((CLLocation) -> Void)?
    @ObservationIgnored private var lastPreciseFix: Date?

    /// The backend team's test spot: a current fix here matches their simulated demo sensors.
    static let demoCoordinate = CLLocationCoordinate2D(latitude: 25.7617, longitude: -80.1918)
    static let demoKey = "envlab.demoLocation"
    /// Testing only: pretend the phone is at `demoCoordinate`. Real GPS fixes aren't sent while it's on,
    /// so test fixes never mix with where you actually were.
    var useDemoLocation: Bool = UserDefaults.standard.object(forKey: LocationReporter.demoKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(useDemoLocation, forKey: Self.demoKey)
            if useDemoLocation { didUpdate(Self.demoFix()) }
        }
    }
    @ObservationIgnored private var demoTimer: Timer?

    private static func demoFix() -> CLLocation {
        CLLocation(coordinate: demoCoordinate, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: -1, timestamp: .now)
    }

    /// Demo fixes on the same 5-second cadence as real ones while the app is open.
    private func startDemoTimer() {
        demoTimer?.invalidate()
        demoTimer = Timer.scheduledTimer(withTimeInterval: Self.preciseInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.useDemoLocation else { return }
                self.didUpdate(Self.demoFix())
            }
        }
    }

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private let backend: () -> DewinBackend
    @ObservationIgnored private var publishedLocation: CLLocation?
    @ObservationIgnored private var publishing = false

    init(backend: @escaping () -> DewinBackend) {
        self.backend = backend
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.distanceFilter = 500
        if isAuthorized { manager.startUpdatingLocation() }
        startDemoTimer()
        if useDemoLocation { lastLocation = Self.demoFix() }
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    /// Called when the backend (re)connects, so a ping that failed offline goes out.
    func backendConnected() {
        publishIfNeeded(force: true)
    }

    private func publishIfNeeded(force: Bool = false) {
        guard sharing, !publishing, let location = lastLocation else { return }
        if !force, let previous = publishedLocation, let when = lastPublished,
           location.distance(from: previous) < Self.minDistance, Date().timeIntervalSince(when) < Self.minInterval {
            return
        }
        let ping = LocationPing(clientId: BackendSettings.clientID, coordinate: location.coordinate,
                                accuracy: location.horizontalAccuracy)
        publishing = true
        Task {
            defer { publishing = false }
            do {
                try await backend().publishLocation(ping)
                publishedLocation = location
                lastPublished = .now
                lastError = nil
                NSLog("[Location] published %.2f,%.2f", ping.lat, ping.lon)
            } catch {
                lastError = error.localizedDescription
                NSLog("[Location] publish failed: %@", String(describing: error))
            }
        }
    }

    fileprivate func didChangeAuthorization(_ status: CLAuthorizationStatus) {
        authorization = status
        if isAuthorized { manager.startUpdatingLocation() } else { manager.stopUpdatingLocation() }
    }

    fileprivate func didUpdate(_ location: CLLocation) {
        // While the demo location is on, ignore real GPS (demo fixes are exactly at the demo spot).
        let isDemoFix = location.coordinate.latitude == Self.demoCoordinate.latitude
            && location.coordinate.longitude == Self.demoCoordinate.longitude
        if useDemoLocation, !isDemoFix { return }
        lastLocation = location
        publishIfNeeded()
        if precise, sharing, location.horizontalAccuracy >= 0,
           Date().timeIntervalSince(lastPreciseFix ?? .distantPast) >= Self.preciseInterval {
            lastPreciseFix = .now
            onPreciseFix?(location)
        }
    }
}

extension LocationReporter: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.didChangeAuthorization(status) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in self.didUpdate(location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        NSLog("[Location] %@", String(describing: error))
    }
}
