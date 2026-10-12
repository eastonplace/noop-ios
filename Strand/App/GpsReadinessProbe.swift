import CoreLocation
import Foundation

/// What the setup page can truthfully say about the GPS before a workout starts, from the location permission and the
/// freshest fix: it asks first if the wearer has not answered, says it is locating until a fix is good, then how good it is.
enum GpsReadiness: Equatable, Sendable {
    /// Not decided yet: "Allow location" asks.
    case allowNeeded
    /// Allowed, and there is no good fix yet.
    case locating
    /// A fix at least as good as `goodAccuracyMeters`; its accuracy in whole metres.
    case locked(accuracyMeters: Int)
    /// Denied, or Location Services is off for the whole device: Settings can turn it on.
    case off
    /// Restricted (Screen Time, device management): the wearer cannot change it here.
    case restricted

    /// A fix is "locked" at this horizontal accuracy or better.
    static let goodAccuracyMeters: Double = 20
    /// A fix older than this no longer says where the wearer is.
    static let freshFixSeconds: TimeInterval = 20

    /// Pure. `accuracy` is the freshest fix's horizontal accuracy (negative means invalid) and `fixAge` how old it is.
    static func make(status: CLAuthorizationStatus, servicesEnabled: Bool, accuracy: Double?, fixAge: TimeInterval?) -> GpsReadiness {
        guard servicesEnabled else { return .off }
        switch status {
        case .notDetermined: return .allowNeeded
        case .denied: return .off
        case .restricted: return .restricted
        case .authorizedWhenInUse, .authorizedAlways: break
        @unknown default: return .allowNeeded
        }
        guard let accuracy, accuracy >= 0, accuracy <= goodAccuracyMeters,
              let fixAge, fixAge <= freshFixSeconds else { return .locating }
        return .locked(accuracyMeters: Int(accuracy.rounded()))
    }

    /// The route can be recorded (or will be asked for) from here: everything but a refusal.
    var canRecordRoute: Bool {
        switch self {
        case .allowNeeded, .locating, .locked: true
        case .off, .restricted: false
        }
    }
}

/// A standalone location manager that listens while the setup page is on screen, so "GPS: locked ±6 m" is true before Start
/// and the first kilometre does not begin with a search. It never records and never writes anything; the recorder owns that.
/// It stops when the page goes away and when a workout begins (the recorder takes over), so it costs nothing in a run.
///
/// `@MainActor`, with the manager created on main, so CoreLocation's callbacks arrive on the main thread and the
/// `@preconcurrency` delegate conformance is sound (the idiom `GpsWorkoutRecorder` uses).
@MainActor
final class GpsReadinessProbe: NSObject, ObservableObject {
    @Published private(set) var readiness: GpsReadiness
    private let manager: CLLocationManager
    private var accuracy: Double?
    private var fixAt: Date?
    private var isListening = false
    private var clock: Task<Void, Never>?

    init(manager: CLLocationManager = CLLocationManager()) {
        self.manager = manager
        readiness = GpsReadiness.make(status: manager.authorizationStatus,
                                      servicesEnabled: CLLocationManager.locationServicesEnabled(),
                                      accuracy: nil, fixAge: nil)
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
    }

    /// Start listening (when location is allowed) and ask CoreLocation for a first fix. Idempotent.
    func start() {
        isListening = true
        refresh()
        beginIfAllowed()
        // A fix goes stale without anything arriving to say so: look again on a clock while listening.
        guard clock == nil else { return }
        clock = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                self?.refresh()
            }
        }
    }

    /// Stop listening. Idempotent.
    func stop() {
        isListening = false
        clock?.cancel()
        clock = nil
        manager.stopUpdatingLocation()
    }

    /// "Allow location": asks once. The answer arrives through `locationManagerDidChangeAuthorization`.
    func requestAuthorization() {
        guard manager.authorizationStatus == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
    }

    private func beginIfAllowed() {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: manager.startUpdatingLocation()
        default: break
        }
    }

    private func refresh() {
        let next = GpsReadiness.make(status: manager.authorizationStatus,
                                     servicesEnabled: CLLocationManager.locationServicesEnabled(),
                                     accuracy: accuracy, fixAge: fixAt.map { Date().timeIntervalSince($0) })
        if next != readiness { readiness = next }
    }
}

extension GpsReadinessProbe: @preconcurrency CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if isListening { beginIfAllowed() }
        refresh()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        accuracy = latest.horizontalAccuracy
        fixAt = latest.timestamp
        refresh()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // No fix yet is normal and self-heals; a refusal arrives through the authorization callback.
        refresh()
    }
}
