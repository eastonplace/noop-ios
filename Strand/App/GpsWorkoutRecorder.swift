import Foundation
import CoreLocation
import StrandAnalytics   // WorkoutsTrace + TestCentre: the GPS-fix line for the Workouts test mode
import WorkoutRouteExport

// MARK: - GPS workout recording on Apple (#524)
//
// Android has recorded a GPS route for distance-type workouts (run / ride / walk / hike) since #215 via
// a process-level `GpsSession` + a foreground `LocationManager` stream; iOS and Mac never did, so a
// manually-started run banked HR + Effort but no route or GPS distance. This file is the Apple analogue,
// built ADDITIVELY alongside the existing manual-workout lifecycle — it never touches WHOOP, scoring,
// or the HR-window capture path.
//
// It splits into four pure-or-thin pieces so the geo math and the persist round-trip are unit-testable
// off any platform location stack:
//
//   • `RouteMath`   — pure Haversine distance, pace, and the Google "Encoded Polyline Algorithm Format"
//                     (precision 5). A byte-for-byte Swift port of Android `com.noop.analytics.RouteMath`
//                     so a route encoded on one platform decodes identically on the other (the polyline
//                     round-trips through the same local stores / exports as every other workout value).
//   • `TrackFilter` — pure, stateful fix gate: drops low-accuracy fixes and physically-impossible jumps,
//                     using a sport policy (50 m accuracy gate plus speed/acceleration bounds). Bounds the
//                     UNTRUSTED stream of OS location fixes before any of it reaches the stored route.
//   • `RouteStore`  — a tiny on-device side-store (UserDefaults) keyed by a workout's natural key
//                     (startTs + sport), holding the encoded polyline + distance for that session. The
//                     shared `WhoopStore.WorkoutRow` carries no route column on Apple, so the route lives
//                     here and is read back by WorkoutDetailView — exactly how `moments` / `sleepMarks` /
//                     the durable active-workout snapshot already persist on Apple. Stored locally;
//                     GPX/FIT leaves the app only through a user-requested export.
//   • `GpsWorkoutRecorder` — the thin CoreLocation wrapper. Requests When-In-Use, streams fixes through
//                     `TrackFilter` into an accumulating route, and exposes live distance/pace. FAILS
//                     SAFE everywhere: on a Mac with no location hardware, or when permission is denied /
//                     restricted, it simply records nothing rather than crashing, so the workout still
//                     banks HR + Effort without a route (parity with Android #101).

// MARK: - RouteMath (pure; Android parity)

/// Pure geo math for GPS workouts — no platform types, fully unit-testable. A Swift port of Android
/// `RouteMath`: Haversine distance, pace, and precision-5 encoded polylines, so a route is identical on
/// both platforms.
enum RouteMath {

    /// One geographic point. Plain `Double` lat/lon — not a `CLLocationCoordinate2D` — so the math stays
    /// platform-free and testable without CoreLocation.
    struct LatLng: Codable, Equatable, Sendable {
        let lat: Double
        let lon: Double
        init(_ lat: Double, _ lon: Double) { self.lat = lat; self.lon = lon }
    }

    private static let earthR = 6_371_000.0 // metres

    /// Great-circle distance between two points, in metres (Haversine). Matches Android exactly.
    static func haversineMeters(_ a: LatLng, _ b: LatLng) -> Double {
        let dLat = (b.lat - a.lat) * .pi / 180
        let dLon = (b.lon - a.lon) * .pi / 180
        let s = sin(dLat / 2) * sin(dLat / 2)
            + cos(a.lat * .pi / 180) * cos(b.lat * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return earthR * 2 * atan2(sqrt(s), sqrt(1 - s))
    }

    /// Total route length in metres — the sum of consecutive Haversine legs. 0 for < 2 points.
    static func totalMeters(_ points: [LatLng]) -> Double {
        guard points.count > 1 else { return 0 }
        var sum = 0.0
        for i in 1..<points.count { sum += haversineMeters(points[i - 1], points[i]) }
        return sum
    }

    /// Seconds per kilometre, or nil when distance is zero (pace undefined). Matches Android.
    static func paceSecPerKm(meters: Double, seconds: Double) -> Double? {
        meters <= 0 ? nil : seconds / (meters / 1000.0)
    }

    // MARK: Encoded Polyline Algorithm Format, precision 5

    /// Encode a route to a compact polyline string (Google precision-5 format). Identical output to
    /// Android `RouteMath.encode` for the same points, so the stored string is cross-platform.
    static func encode(_ points: [LatLng]) -> String {
        var out = ""
        var prevLat = 0, prevLon = 0
        for p in points {
            let lat = Int((p.lat * 1e5).rounded())
            let lon = Int((p.lon * 1e5).rounded())
            encodeSigned(lat - prevLat, into: &out)
            encodeSigned(lon - prevLon, into: &out)
            prevLat = lat
            prevLon = lon
        }
        return out
    }

    /// Decode a polyline string back to points. Bounds-checked: an untrusted / corrupt string yields the
    /// points it can parse and stops cleanly at the end (never reads past the buffer). Matches Android.
    static func decode(_ encoded: String) -> [LatLng] {
        var out: [LatLng] = []
        let chars = Array(encoded.unicodeScalars)
        var i = 0
        var lat = 0, lon = 0
        while i < chars.count {
            guard let dLat = decodeSigned(chars, &i) else { break }
            guard let dLon = decodeSigned(chars, &i) else { break }
            lat += dLat
            lon += dLon
            let p = LatLng(Double(lat) / 1e5, Double(lon) / 1e5)
            // Drop anything off the surface of the earth — a defensive gate on a decoded-from-disk value.
            if (-90...90).contains(p.lat) && (-180...180).contains(p.lon) { out.append(p) }
        }
        return out
    }

    private static func encodeSigned(_ v: Int, into out: inout String) {
        var value = v < 0 ? ~(v << 1) : (v << 1)
        while value >= 0x20 {
            out.unicodeScalars.append(Unicode.Scalar((0x20 | (value & 0x1f)) + 63)!)
            value >>= 5
        }
        out.unicodeScalars.append(Unicode.Scalar(value + 63)!)
    }

    /// Decode one signed varint starting at `i`, advancing `i`. Returns nil if the buffer ends mid-value
    /// (a truncated / corrupt string) so the caller stops rather than over-reading.
    private static func decodeSigned(_ chars: [Unicode.Scalar], _ i: inout Int) -> Int? {
        var result = 0, shift = 0, b = 0
        repeat {
            guard i < chars.count else { return nil }
            b = Int(chars[i].value) - 63
            // A byte must be a valid polyline character (>= 63 once 63 is subtracted, i.e. >= 0).
            guard b >= 0 else { return nil }
            i += 1
            result |= (b & 0x1f) << shift
            shift += 5
            // Guard against a maliciously long run inflating `shift` past Int width.
            if shift > 35 { return nil }
        } while b >= 0x20
        return (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
    }
}

// MARK: - TrackFilter (pure; Android parity)

/// A raw GPS reading before filtering. Mirrors Android `RawFix`.
struct RawFix: Equatable {
    let lat: Double
    let lon: Double
    let accuracyM: Double   // horizontal accuracy radius; < 0 from CoreLocation means "invalid"
    let tMs: Int64          // fix time, ms since epoch
}

/// Pure, stateful fix gate: drops low-accuracy fixes and physically-impossible jumps, returning the
/// accepted point or nil. Keeps the last accepted fix to gate the next. A direct port of Android
/// `TrackFilter`, extended with explicit sport bounds for cycling and snow travel.
struct TrackFilterAcceptedFix: Equatable {
    let point: RouteMath.LatLng
    let startsNewSegment: Bool
}

/// Conservative capture bounds, not an estimate of the athlete's speed. Only explicit catalogue
/// cycling/snow sports receive faster bounds; unknown/free-text sports retain the standard ceiling.
/// The selected class is stored with the active session across pause and process restoration.
enum GpsTrackPolicy: String, Codable, Equatable, Sendable {
    case standard, cycling, snow

    static func forSport(_ sport: String) -> Self {
        switch WorkoutCatalog.sport(named: sport)?.name {
        case "Cycling": return .cycling
        case "Skiing", "Snowboarding": return .snow
        default: return .standard
        }
    }

    /// 43.2 / 108 / 144 km/h. The higher ceilings retain fast descents while still rejecting jumps.
    var maxSpeedMps: Double {
        switch self {
        case .standard: return 12
        case .cycling: return 30
        case .snow: return 40
        }
    }

    /// Deliberately generous bounds on changes in consecutive leg speeds (m/s²). The filter also
    /// allows the horizontal-accuracy uncertainty of both legs, so GPS jitter is not acceleration.
    var maxAccelerationMps2: Double {
        switch self {
        case .standard: return 6
        case .cycling: return 8
        case .snow: return 12
        }
    }
}

final class TrackFilter {
    private let maxAccuracyM: Double
    private let maxSpeedMps: Double
    private let maxAccelerationMps2: Double
    private let segmentGapSeconds: Double
    private let minimumPointDistanceM: Double
    private var last: RawFix?
    private var previousLeg: (speed: Double, seconds: Double, uncertainty: Double)?

    init(
        policy: GpsTrackPolicy = .standard,
        maxAccuracyM: Double = 50,
        maxSpeedMps: Double? = nil,
        segmentGapSeconds: Double = 120,
        minimumPointDistanceM: Double = 1
    ) {
        self.maxAccuracyM = max(0, maxAccuracyM)
        self.maxSpeedMps = max(0, maxSpeedMps ?? policy.maxSpeedMps)
        self.maxAccelerationMps2 = policy.maxAccelerationMps2
        self.segmentGapSeconds = max(1, segmentGapSeconds)
        self.minimumPointDistanceM = max(0, minimumPointDistanceM)
    }

    /// Compatibility API for existing callers and tests. New recording code uses the metadata form so a
    /// long interruption starts a separate stored segment.
    func accept(_ fix: RawFix) -> RouteMath.LatLng? {
        acceptWithMetadata(fix)?.point
    }

    /// Accept one strictly newer, non-duplicate fix. A long gap may move far without creating a line
    /// across the map. Short-interval teleports still fail the speed gate.
    func acceptWithMetadata(_ fix: RawFix) -> TrackFilterAcceptedFix? {
        guard fix.accuracyM.isFinite, fix.accuracyM >= 0, fix.accuracyM <= maxAccuracyM,
              fix.lat.isFinite, fix.lon.isFinite,
              (-90...90).contains(fix.lat), (-180...180).contains(fix.lon) else { return nil }

        let point = RouteMath.LatLng(fix.lat, fix.lon)
        var startsNewSegment = false
        var nextLeg: (speed: Double, seconds: Double, uncertainty: Double)?
        if let prev = last {
            let (elapsedMilliseconds, overflow) = fix.tMs.subtractingReportingOverflow(prev.tMs)
            guard !overflow, elapsedMilliseconds > 0 else { return nil }
            let elapsedSeconds = Double(elapsedMilliseconds) / 1000.0
            let distance = RouteMath.haversineMeters(
                RouteMath.LatLng(prev.lat, prev.lon),
                point)
            guard distance >= minimumPointDistanceM else { return nil }

            startsNewSegment = elapsedSeconds > segmentGapSeconds
            if !startsNewSegment {
                let speed = distance / elapsedSeconds
                guard speed <= maxSpeedMps else { return nil }
                let uncertainty = (prev.accuracyM + fix.accuracyM) / elapsedSeconds
                if let previousLeg {
                    let midpointSeconds = (elapsedSeconds + previousLeg.seconds) / 2
                    let allowedChange = maxAccelerationMps2 * midpointSeconds
                        + uncertainty + previousLeg.uncertainty
                    guard abs(speed - previousLeg.speed) <= allowedChange else { return nil }
                }
                nextLeg = (speed, elapsedSeconds, uncertainty)
            }
        }

        last = fix
        previousLeg = nextLeg
        return TrackFilterAcceptedFix(point: point, startsNewSegment: startsNewSegment)
    }

    func restore(lastAccepted fix: RawFix) {
        guard fix.accuracyM.isFinite, fix.accuracyM >= 0, fix.accuracyM <= maxAccuracyM,
              (-90...90).contains(fix.lat), (-180...180).contains(fix.lon) else { return }
        last = fix
        previousLeg = nil
    }
}

// MARK: - RouteStore (on-device side-store)

/// The route persisted for one finished workout: the encoded polyline + the GPS distance it implies.
/// A tiny `Codable` value, the unit a `RouteStore` keys by a workout's natural key.
struct WorkoutRoute: Equatable, Codable, Sendable {
    /// Google precision-5 polyline of the captured route (`RouteMath.encode`).
    var polyline: String
    /// Total GPS distance in metres (`RouteMath.totalMeters` of the captured points).
    var distanceM: Double
    /// Segment-aware representation. Legacy rows omit this field and continue to decode from `polyline`.
    /// New rows keep `polyline` as their first segment for safe downgrade behavior, never a flattened bridge.
    var segmentPolylines: [String]?
    /// Only measured segments carry export metadata. Legacy polylines remain drawable without
    /// timestamps or guessed accuracy. A restored legacy prefix is not included in this array.
    var pointSegments: [[RecordedRoutePoint]]?

    init(polyline: String, distanceM: Double) {
        self.polyline = polyline
        self.distanceM = distanceM
        segmentPolylines = nil
        pointSegments = nil
    }

    init(segmentPolylines: [String], distanceM: Double, pointSegments: [[RecordedRoutePoint]]? = nil) {
        let nonempty = segmentPolylines.filter { !RouteMath.decode($0).isEmpty }
        self.polyline = nonempty.first ?? ""
        self.distanceM = distanceM
        self.segmentPolylines = nonempty
        self.pointSegments = pointSegments
    }

    var decodedSegments: [[RouteMath.LatLng]] {
        let encoded = segmentPolylines?.isEmpty == false ? segmentPolylines! : [polyline]
        return encoded.map(RouteMath.decode).filter { !$0.isEmpty }
    }

    var hasDrawableSegment: Bool {
        decodedSegments.contains { $0.count >= 2 }
    }

    var hasExportableMeasurements: Bool {
        guard let pointSegments else { return false }
        guard (try? RouteExporter.validate(pointSegments)) != nil else { return false }
        // Export metadata must describe the saved map, including segment boundaries. A corrupt or
        // mismatched metadata array must never export a different route from the one being shown.
        let polylines = segmentPolylines?.isEmpty == false ? segmentPolylines! : [polyline]
        var cursor = polylines.startIndex
        for segment in pointSegments {
            let encoded = RouteMath.encode(segment.map { .init($0.latitude, $0.longitude) })
            while cursor < polylines.endIndex, polylines[cursor] != encoded { cursor += 1 }
            guard cursor < polylines.endIndex else { return false }
            cursor += 1
        }
        return true
    }

    var hasUnmeasuredSegments: Bool {
        decodedSegments.reduce(0) { $0 + $1.count }
            > (pointSegments ?? []).reduce(0) { $0 + $1.count }
    }

    private enum CodingKeys: String, CodingKey { case polyline, distanceM, segmentPolylines, pointSegments }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        polyline = try values.decode(String.self, forKey: .polyline)
        distanceM = try values.decode(Double.self, forKey: .distanceM)
        segmentPolylines = try values.decodeIfPresent([String].self, forKey: .segmentPolylines)
        // Damaged optional export metadata must not hide otherwise valid historical route maps.
        pointSegments = try? values.decodeIfPresent([[RecordedRoutePoint]].self, forKey: .pointSegments)
    }
}

/// On-device persistence for finished GPS routes, keyed by a workout's natural key (startTs + sport) so a
/// saved row can look its route back up. The shared `WhoopStore.WorkoutRow` carries no route column on
/// Apple, so the polyline lives here — mirroring how `moments` / `sleepMarks` / the active-workout
/// snapshot already persist to `UserDefaults`. Export is an explicit user action.
///
/// The codec (`encodeMap` / `decodeMap`) is pure (no `UserDefaults` dependency) so the persist round-trip
/// is unit-testable; `store` / `load` / `remove` just thread a `UserDefaults` through it. Bounded so a
/// long-lived install can't grow the blob without limit.
enum RouteStore {

    /// Single `UserDefaults` key holding a JSON `[key: WorkoutRoute]` map. Namespaced like `moments`.
    static let defaultsKey = "noop.workoutRoutes"

    /// Cap on stored routes — newest kept, oldest evicted (keys sort by the leading startTs).
    /// Timestamped measurements live with their polylines so backups and deletion stay consistent.
    static let maxRoutes = 400

    /// Natural key for a session's route: "<startTs>|<sport>". Stable across launches; matches the
    /// `WorkoutRow` natural key the detail screen reads. Sport is included so two sessions that share a
    /// start second (different sports) never collide.
    static func key(startTs: Int, sport: String) -> String { "\(startTs)|\(sport)" }

    /// Encode a route map to JSON. Drops any entry whose distance isn't a finite, non-negative number
    /// FIRST — JSON has no representation for NaN/Inf, so a single corrupt distance would otherwise make
    /// `JSONEncoder` throw and take the WHOLE map down with it (silently losing every valid route). We
    /// sanitise per-entry so one bad row can never poison the blob. Returns nil only if encoding the
    /// already-clean map fails (never expected for this shape).
    static func encodeMap(_ map: [String: WorkoutRoute]) -> Data? {
        let clean = map.filter { $0.value.distanceM.isFinite && $0.value.distanceM >= 0 }
            .mapValues { route in
                var route = route
                if route.pointSegments != nil, !route.hasExportableMeasurements { route.pointSegments = nil }
                return route
            }
        return try? JSONEncoder().encode(clean)
    }

    /// Decode a route map from JSON, dropping any entry whose distance isn't a finite, non-negative
    /// number — never trust the persisted blob to be clean (belt-and-braces with `encodeMap`'s sanitise).
    /// nil/garbage yields an empty map.
    static func decodeMap(_ data: Data?) -> [String: WorkoutRoute] {
        guard let data, !data.isEmpty,
              let raw = try? JSONDecoder().decode([String: WorkoutRoute].self, from: data) else { return [:] }
        return raw.filter { $0.value.distanceM.isFinite && $0.value.distanceM >= 0 }
    }

    /// Read the whole stored map (bound-checked).
    static func loadMap(from defaults: UserDefaults = .standard) -> [String: WorkoutRoute] {
        decodeMap(defaults.data(forKey: defaultsKey))
    }

    /// The route for a finished workout, or nil if none was recorded.
    static func load(startTs: Int, sport: String, from defaults: UserDefaults = .standard) -> WorkoutRoute? {
        loadMap(from: defaults)[key(startTs: startTs, sport: sport)]
    }

    /// Persist `route` for a workout, evicting the oldest entries if the cap is exceeded. A no-op when the
    /// route has no usable polyline (so we never store an empty placeholder — honest "no route").
    static func store(_ route: WorkoutRoute, startTs: Int, sport: String,
                      into defaults: UserDefaults = .standard) {
        guard route.hasDrawableSegment else { return }
        var map = loadMap(from: defaults)
        map[key(startTs: startTs, sport: sport)] = route
        if map.count > maxRoutes {
            // Keys lead with the startTs, so a lexicographic sort by the numeric prefix evicts the oldest.
            let ordered = map.keys.sorted { lhs, rhs in
                (Int(lhs.split(separator: "|").first ?? "") ?? 0)
                    < (Int(rhs.split(separator: "|").first ?? "") ?? 0)
            }
            for k in ordered.prefix(map.count - maxRoutes) { map.removeValue(forKey: k) }
        }
        guard let data = encodeMap(map) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    /// Remove a workout's route (used when a session is deleted; keeps the side-store from leaking).
    static func remove(startTs: Int, sport: String, from defaults: UserDefaults = .standard) {
        var map = loadMap(from: defaults)
        guard map.removeValue(forKey: key(startTs: startTs, sport: sport)) != nil,
              let data = encodeMap(map) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}

// MARK: - GpsWorkoutRecorder (CoreLocation wrapper)

/// Seam over `CLBackgroundActivitySession` (iOS 17+, unavailable on macOS) so tests can assert the session is
/// held while a route records and released afterwards without touching the real CoreLocation service.
protocol GpsBackgroundActivity: AnyObject {
    func invalidate()
}

#if os(iOS)
extension CLBackgroundActivitySession: GpsBackgroundActivity {}
#endif

/// What a start screen can truthfully say about route capture, from the location permission as it stands.
enum GpsAvailability: Equatable {
    /// Authorised (while using the app, or always): a route will record.
    case ready
    /// Not decided yet: starting a workout asks once, so nothing is promised until the person answers.
    case willAsk
    /// The person said no, or Location Services is off for the whole device (CoreLocation reports both as denied). They
    /// can turn it on in Settings.
    case denied
    /// Restricted (screen-time limits or device management): the person cannot change it here.
    case restricted

    static func of(status: CLAuthorizationStatus) -> GpsAvailability {
        switch status {
        case .authorizedWhenInUse, .authorizedAlways: return .ready
        case .notDetermined: return .willAsk
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .willAsk
        }
    }
}

/// Records the route of an in-flight GPS workout from CoreLocation. Thin and fail-safe: requests
/// When-In-Use authorization, streams fixes through `TrackFilter`, and accumulates the route + live
/// distance/pace. The owning `AppModel` starts it when a distance-type sport is begun and reads the final
/// route on End.
///
/// Availability:
///   • iOS — full GPS. (The Info.plist must carry `NSLocationWhenInUseUsageDescription`, and the iOS
///     target's `UIBackgroundModes` should include `location` for the route to keep accruing while the
///     screen is off, mirroring Android's foreground service. See the lane's notes.)
///   • macOS — `CLLocationManager` exists but most Macs have no GPS; if no fixes arrive the route simply
///     stays empty. Either way nothing crashes.
///
/// `@MainActor` so its `@Published` live values drive SwiftUI directly. CoreLocation delivers its
/// delegate callbacks on the run loop the manager was created on — here the main thread — so MainActor
/// isolation is sound; the `@preconcurrency CLLocationManagerDelegate` extension below lets this
/// `@MainActor` type satisfy the nonisolated delegate requirements (the same idiom `StandardHRSource`
/// uses for its CoreBluetooth delegate).
@MainActor
final class GpsWorkoutRecorder: NSObject, ObservableObject {

    /// True while a route is being recorded. The active-workout card can show a "GPS" pill off this.
    @Published private(set) var isRecording = false
    /// Live route distance in metres (0 until two accepted fixes). Honest: 0 when nothing was captured.
    @Published private(set) var distanceM: Double = 0
    /// Live pace in seconds per kilometre, or nil when distance is still zero (pace undefined).
    @Published private(set) var paceSecPerKm: Double?
    /// Number of accepted route points so far (lets the UI distinguish "recording, no fix yet" from "off").
    @Published private(set) var pointCount = 0
    /// True while the user has granted only approximate location (Settings > Privacy > Location > Precise
    /// Location off). The route still records, but fixes are kilometres coarse and TrackFilter's 50 m
    /// accuracy gate will reject most of them, so a screen can explain the sparse route.
    @Published private(set) var isReducedAccuracy = false
    /// What the location permission allows right now, kept current as the person answers the prompt or changes it in
    /// Settings, so a start screen never claims GPS is ready before it is.
    @Published private(set) var availability: GpsAvailability = .willAsk
    /// True while the workout is paused. Location updates and the background session stay open, so the workout can be
    /// resumed from a locked phone, but no fix is added to the route or the distance until it is resumed.
    @Published private(set) var isPaused = false
    /// The latest fix the system delivered, accepted or not, and the latest the filter kept. A screen compares them with
    /// the clock to say the signal is weak or gone; a person standing still delivers no new fixes, which is not a fault.
    private(set) var lastRawFixAt: Date?
    private(set) var lastAcceptedFixAt: Date?
    /// Set when the system reports a location error, cleared by the next delivered fix.
    private(set) var lastErrorAt: Date?
    /// When this recording (or its restore) began, the start of the "no fix yet" wait.
    private(set) var recordingBeganAt: Date?
    /// Seconds the workout has actually run, for live pace. The owner of the workout supplies it so a pause never slows
    /// the pace; nil falls back to the wall clock since the start.
    var activeElapsedProvider: (() -> TimeInterval?)?

    private let manager: CLLocationManager
    /// Keeps a When-In-Use app's location updates alive while the screen is locked (iOS 17+). Held from the
    /// moment updates begin until `stop()`. A session can only become active while the app is in the
    /// foreground, so it is recreated whenever the app returns to the foreground mid-recording.
    private var backgroundActivity: GpsBackgroundActivity?
    private let makeBackgroundActivity: () -> GpsBackgroundActivity?
    private var filterPolicy: GpsTrackPolicy = .standard
    private var filter = TrackFilter()
    private var segments: [[RouteMath.LatLng]] = []
    /// Shape matches `segments`; nil points are a legacy route restored without measurements.
    private var pointMeasurements: [[GpsPointMeasurement?]] = []
    private var lastRecordedTimestampMs: Int64?
    private var sessionID: UUID?
    private var startMs: Int64 = 0
    private var startsNewSegmentOnNextFix = true
    private var hadTerminatedGap = false

    /// Read-only live route segments. A map must draw each segment separately so a terminated interval
    /// never becomes a synthetic line. The recorder remains the sole owner of the arrays.
    var routeSegments: [[RouteMath.LatLng]] { segments }
    var routePoints: [RouteMath.LatLng] { segments.flatMap { $0 } }

    /// Whether this device can offer route capture right now. `.notDetermined` is available —
    /// Start will ask once — while denied/restricted states stay honest and hide GPS-ready UI.
    var canRecordRoute: Bool {
        guard CLLocationManager.locationServicesEnabled() else { return false }
        switch manager.authorizationStatus {
        case .denied, .restricted: return false
        default: return true
        }
    }

    #if DEBUG
    /// Deterministic screenshot fixture, stripped from Release. It fills the same published
    /// fields the CoreLocation ingest path owns without changing the production recorder path.
    func seedDemoRoute(points: [RouteMath.LatLng], elapsedSeconds: Double,
                       paused: Bool = false, signalLost: Bool = false) {
        segments = points.isEmpty ? [] : [points]
        pointMeasurements = points.isEmpty ? [] : [points.map { _ in nil }]
        lastRecordedTimestampMs = nil
        pointCount = points.count
        distanceM = RouteMath.totalMeters(points)
        paceSecPerKm = RouteMath.paceSecPerKm(meters: distanceM, seconds: elapsedSeconds)
        startsNewSegmentOnNextFix = points.isEmpty
        isRecording = true
        isPaused = paused
        availability = .ready
        let now = Date()
        recordingBeganAt = now.addingTimeInterval(-elapsedSeconds)
        lastRawFixAt = now.addingTimeInterval(signalLost ? -75 : -1)
        lastAcceptedFixAt = lastRawFixAt
        lastErrorAt = signalLost ? now.addingTimeInterval(-40) : nil
    }
    #endif

    /// Workouts & GPS test mode (Test Centre): the tagged sink for the `.workouts` GPS-fix lines, wired by
    /// AppModel to `live.append(log:domain:)`. Default nil (inert). We ALWAYS check `TestCentre.active(.workouts)`
    /// BEFORE building any line, so the recorder pays nothing when the mode is off. Diagnostic only - it never
    /// changes the route. `rawFixCount` is the running count of raw fixes seen (accepted + rejected) so the
    /// line can show the filter's accept rate; reset on `start`.
    var workoutsLog: ((String) -> Void)?
    /// This is an action-only checkpoint hook; it does not expose the recorder as a broad publisher.
    var onCheckpoint: ((ActiveGpsWorkoutPersistence.Checkpoint) -> Void)?
    private var rawFixCount = 0

    init(manager: CLLocationManager = CLLocationManager(),
         makeBackgroundActivity: @escaping () -> GpsBackgroundActivity? = GpsWorkoutRecorder.liveBackgroundActivity) {
        self.manager = manager
        self.makeBackgroundActivity = makeBackgroundActivity
        super.init()
        manager.delegate = self
        refreshAvailability()
        manager.desiredAccuracy = kCLLocationAccuracyBest
        // ~5 m between callbacks; TrackFilter still gates on accuracy + speed. Matches the cadence intent
        // of Android's 2 s / 0 m platform request (let the filter, not the platform, do the gating).
        manager.distanceFilter = 5
        #if os(iOS)
        // Keep the route accruing while the screen is off, matching Android's foreground-service capture.
        // Safe only because the iOS target declares the `location` UIBackgroundMode (project.yml); setting
        // this without that mode would crash when updates start.
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .fitness
        // The system's blue "NOOP is using your location" pill, which also lets the user tap back into the app.
        manager.showsBackgroundLocationIndicator = true
        #endif
    }

    /// Re-read the location permission. The authorization callback keeps `availability` current while the app runs; a
    /// screen calls this when it appears or the app returns to the foreground, in case the change was made in Settings
    /// while the app was suspended.
    func refreshAvailability() {
        let next = GpsAvailability.of(status: manager.authorizationStatus)
        if next != availability { availability = next }
    }

    /// The production session factory. nil off iOS, where `CLBackgroundActivitySession` does not exist.
    nonisolated static func liveBackgroundActivity() -> GpsBackgroundActivity? {
        #if os(iOS)
        return CLBackgroundActivitySession()
        #else
        return nil
        #endif
    }

    /// Begin recording a fresh route for a workout started at `startMs` (unix milliseconds). Requests
    /// When-In-Use if not yet decided; fails safe (records nothing) if denied / restricted / unavailable.
    /// A re-arm resets the track. Returns immediately — fixes arrive asynchronously via the delegate.
    func start(sessionID: UUID = UUID(), startMs: Int64, sport: String = WorkoutCatalog.defaultSportName) {
        segments.removeAll()
        pointMeasurements.removeAll()
        lastRecordedTimestampMs = nil
        filterPolicy = .forSport(sport)
        filter = TrackFilter(policy: filterPolicy)
        self.sessionID = sessionID
        self.startMs = startMs
        distanceM = 0
        paceSecPerKm = nil
        pointCount = 0
        rawFixCount = 0
        startsNewSegmentOnNextFix = true
        hadTerminatedGap = false
        isRecording = true
        isPaused = false
        resetSignal()
        releaseBackgroundActivity()
        refreshAccuracyAuthorization()

        switch manager.authorizationStatus {
        case .notDetermined:
            // Ask now; updates begin in `locationManagerDidChangeAuthorization` once the user answers.
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            beginUpdates()
        default:
            // Denied / restricted: stay armed but capture nothing. The workout still banks HR + Effort,
            // and the saved row carries no route (honest "—"), exactly like Android when permission is
            // refused (#101). We do NOT re-prompt — that's the user's Settings choice to reverse.
            break
        }
    }

    /// Stop recording and return the final accumulated route. Safe to call when not recording (returns
    /// whatever was captured, possibly empty). Tears down location updates so no battery is spent after.
    @discardableResult
    func stop() -> [RouteMath.LatLng] {
        manager.stopUpdatingLocation()
        releaseBackgroundActivity()
        isRecording = false
        isPaused = false
        isReducedAccuracy = false
        return routePoints
    }

    /// Whether `capturedRoute()` would return a route: some one segment holds two points. The same test the save applies, so
    /// "would this workout save" never says yes for two fixes that were never joined (one before a pause, one after).
    var hasDrawableRoute: Bool { segments.contains { $0.count >= 2 } }

    /// The encoded polyline + distance for the captured route, or nil when fewer than two points landed
    /// (honest: no route drawn unless points were actually captured). Used by `AppModel` to persist via
    /// `RouteStore` when the session ends.
    func capturedRoute() -> WorkoutRoute? {
        let drawableSegments = segments.filter { $0.count >= 2 }
        guard !drawableSegments.isEmpty else { return nil }
        let measuredSegments: [[RecordedRoutePoint]] = segments.indices.compactMap { index in
            let segment = segments[index]
            guard segment.count >= 2, pointMeasurements.indices.contains(index),
                  pointMeasurements[index].count == segment.count,
                  pointMeasurements[index].allSatisfy({ $0 != nil }) else { return nil }
            return zip(segment, pointMeasurements[index]).compactMap { point, measurement in
                measurement.map { RecordedRoutePoint(latitude: point.lat, longitude: point.lon,
                    timestampMs: $0.timestampMs, horizontalAccuracyM: $0.horizontalAccuracyM) }
            }
        }
        return WorkoutRoute(
            segmentPolylines: drawableSegments.map(RouteMath.encode),
            distanceM: distanceM,
            pointSegments: measuredSegments.isEmpty ? nil : measuredSegments
        )
    }

    /// Metadata-only checkpoint used for the synchronous Start commit. Normal batches call the private
    /// overload with only their accepted suffix, so they never copy or encode the growing route.
    func persistenceCheckpoint() -> ActiveGpsWorkoutPersistence.Checkpoint? {
        makePersistenceCheckpoint(appendedPoints: [])
    }

    /// Preserve only the pre-termination route. Resuming uses this foreground process; it never implies
    /// CoreLocation kept recording while NOOP was closed.
    func restore(_ snapshot: ActiveGpsWorkoutPersistence.Snapshot,
                 sport: String = WorkoutCatalog.defaultSportName) {
        guard snapshot.isValid else { return }
        segments = snapshot.segments
        pointMeasurements = snapshot.pointMeasurements ?? snapshot.segments.map { $0.map { _ in nil } }
        lastRecordedTimestampMs = pointMeasurements.flatMap { $0 }.compactMap { $0?.timestampMs }.last
        sessionID = snapshot.sessionID
        startMs = snapshot.workoutStartMs
        rawFixCount = snapshot.rawFixCount
        // A restored pre-termination fix must never seed the new speed window. The first fresh fix starts
        // a separate segment and becomes the filter's new baseline.
        filterPolicy = snapshot.filterPolicy ?? .forSport(sport)
        filter = TrackFilter(policy: filterPolicy)
        startsNewSegmentOnNextFix = true
        hadTerminatedGap = snapshot.hadTerminatedGap || snapshot.recordingWasActive
        pointCount = snapshot.acceptedPointCount
        distanceM = snapshot.distanceM
        paceSecPerKm = RouteMath.paceSecPerKm(meters: distanceM, seconds: elapsedSeconds())
        isRecording = snapshot.recordingWasActive
        isPaused = false
        resetSignal()
        if isRecording {
            refreshAccuracyAuthorization()
        }
        if isRecording, (manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways) {
            beginUpdates()
        }
    }

    /// Pause or resume the route. Idempotent. Pausing leaves CoreLocation and the background session running; it only
    /// stops fixes reaching the route and the distance. Resuming forgets the filter's last fix and starts a new segment,
    /// so wherever the person moved while paused is never drawn as a line or added to the distance.
    func setPaused(_ paused: Bool) {
        guard isRecording, paused != isPaused else { return }
        isPaused = paused
        if !paused {
            filter = TrackFilter(policy: filterPolicy)
            startsNewSegmentOnNextFix = true
            recordingBeganAt = Date()
            lastErrorAt = nil
        }
    }

    /// Seconds the workout has run, as its owner counts them; the wall clock since the start when there is no owner.
    private func elapsedSeconds() -> Double {
        if let active = activeElapsedProvider?() { return max(0, active) }
        return max(0, Double(Int64(Date().timeIntervalSince1970 * 1000) - startMs) / 1000)
    }

    private func resetSignal() {
        lastRawFixAt = nil
        lastAcceptedFixAt = nil
        lastErrorAt = nil
        recordingBeganAt = Date()
    }

    /// What the live screen may truthfully say about the signal. A standing person gets no new fixes, so silence after
    /// a good fix is not reported; only a wait for the first fix, rejected-only fixes and system errors are.
    enum SignalState: Equatable {
        case notRecording, paused, ok, searching, weak, lost
    }

    func signalState(now: Date = Date(), patience: TimeInterval = 30) -> SignalState {
        guard isRecording, availability == .ready else { return .notRecording }
        if isPaused { return .paused }
        if let lastErrorAt, lastErrorAt > (lastRawFixAt ?? .distantPast),
           now.timeIntervalSince(lastErrorAt) > 5 { return .lost }
        if lastAcceptedFixAt == nil {
            guard let began = recordingBeganAt, now.timeIntervalSince(began) > patience else { return .ok }
            return lastRawFixAt == nil ? .searching : .weak
        }
        if let raw = lastRawFixAt, let accepted = lastAcceptedFixAt,
           raw > accepted, now.timeIntervalSince(accepted) > patience, now.timeIntervalSince(raw) < patience {
            return .weak
        }
        return .ok
    }

    /// Re-arm CoreLocation when the app returns to the foreground mid-recording. `startUpdatingLocation()`
    /// is idempotent, so this is safe when updates never stopped; it recovers the case where they did
    /// (the system ended them, or a permission change was missed while suspended). The background session
    /// is recreated too, because only a foreground app can start one and an ended session cannot reactivate.
    func resumeUpdatesIfNeeded() {
        guard isRecording else { return }
        refreshAccuracyAuthorization()
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            renewBackgroundActivity()
            beginUpdates()
        default:
            break
        }
    }

    // MARK: Updates

    fileprivate func beginUpdates() {
        // Wrapped: a Mac with no location services, or an OEM quirk, must never crash the app — just
        // record nothing. Mirrors Android's try/catch around requestLocationUpdates (#101).
        // `type(of:)` dispatches dynamically so a test double can stub the class-level availability check.
        guard type(of: manager).locationServicesEnabled() else { return }
        if backgroundActivity == nil { backgroundActivity = makeBackgroundActivity() }
        manager.startUpdatingLocation()
    }

    fileprivate func releaseBackgroundActivity() {
        backgroundActivity?.invalidate()
        backgroundActivity = nil
    }

    /// Replace the held session with a fresh one. The new session exists before the old one is invalidated,
    /// so recording is never momentarily without a session.
    private func renewBackgroundActivity() {
        let previous = backgroundActivity
        backgroundActivity = makeBackgroundActivity()
        previous?.invalidate()
    }

    fileprivate func refreshAccuracyAuthorization() {
        let reduced = manager.accuracyAuthorization == .reducedAccuracy
        guard reduced != isReducedAccuracy else { return }
        isReducedAccuracy = reduced
        if reduced {
            logWorkouts("gps reducedAccuracy=true (approximate location only; route fixes will be coarse)")
        }
    }

    /// One diagnostic line on the Workouts & GPS test-mode channel. The mode gate comes first so the recorder
    /// formats nothing when the mode is off.
    fileprivate func logWorkouts(_ line: @autoclosure () -> String) {
        if TestCentre.active(.workouts), let workoutsLog {
            workoutsLog(line())
        }
    }

    /// Fold a batch of (already bound-checked at the source) fixes into the route, updating live
    /// distance/pace. No-op when not recording.
    fileprivate func ingest(_ fixes: [RawFix]) {
        guard isRecording else { return }
        // Paused: the system keeps delivering so the session stays alive, but nothing reaches the route or distance. The
        // fixes are not noted either: a raw fix that never became an accepted one would, after the resume, read as a
        // signal that is arriving and being rejected ("Weak GPS signal") on a perfectly good one.
        guard !isPaused else { return }
        if !fixes.isEmpty {
            lastRawFixAt = Date()
            lastErrorAt = nil
        }
        rawFixCount += fixes.count
        var appendedPoints: [ActiveGpsJournalPoint] = []
        appendedPoints.reserveCapacity(fixes.count)
        for fix in fixes {
            // CoreLocation may deliver cached fixes on start/resume. Do not export a point from before
            // this workout, or let resetting the speed filter make the route's timeline go backwards.
            guard fix.tMs >= startMs, fix.tMs > 0, fix.tMs <= 253_402_300_799_999,
                  lastRecordedTimestampMs.map({ fix.tMs > $0 }) ?? true else { continue }
            if let accepted = filter.acceptWithMetadata(fix) {
                let pt = accepted.point
                let measurement = GpsPointMeasurement(timestampMs: fix.tMs, horizontalAccuracyM: fix.accuracyM)
                let beginsSegment = startsNewSegmentOnNextFix
                    || accepted.startsNewSegment
                    || segments.isEmpty
                if beginsSegment {
                    segments.append([pt])
                    pointMeasurements.append([measurement])
                    startsNewSegmentOnNextFix = false
                } else {
                    if let previous = segments[segments.count - 1].last {
                        distanceM += RouteMath.haversineMeters(previous, pt)
                    }
                    segments[segments.count - 1].append(pt)
                    pointMeasurements[pointMeasurements.count - 1].append(measurement)
                }
                lastRecordedTimestampMs = fix.tMs
                pointCount += 1
                appendedPoints.append(ActiveGpsJournalPoint(
                    point: pt,
                    startsNewSegment: beginsSegment,
                    measurement: measurement
                ))
            }
        }
        guard !appendedPoints.isEmpty else { return }
        lastAcceptedFixAt = Date()
        paceSecPerKm = RouteMath.paceSecPerKm(meters: distanceM, seconds: elapsedSeconds())
        // Workouts & GPS test mode: one GPS-fix-progress line tagged `.workouts` per batch that added a point,
        // showing raw fixes seen, how many the accuracy/speed filter accepted, and the running distance, so a
        // route that under-records (weak signal / denied permission) is visible. Zero-cost when off (the gate
        // is one UserDefaults bool read), and gated on a non-nil sink so non-prod recorders stay silent.
        if TestCentre.active(.workouts), let workoutsLog {
            workoutsLog(WorkoutsTrace.gpsLine(rawFixes: rawFixCount, acceptedPoints: pointCount,
                                              distanceM: distanceM))
        }
        if let checkpoint = makePersistenceCheckpoint(appendedPoints: appendedPoints) {
            onCheckpoint?(checkpoint)
        }
    }

    private func makePersistenceCheckpoint(
        appendedPoints: [ActiveGpsJournalPoint]
    ) -> ActiveGpsWorkoutPersistence.Checkpoint? {
        guard let sessionID else { return nil }
        return ActiveGpsWorkoutPersistence.Checkpoint(
            sessionID: sessionID,
            workoutStartMs: startMs,
            appendedPoints: appendedPoints,
            distanceM: distanceM,
            rawFixCount: rawFixCount,
            acceptedPointCount: pointCount,
            recordingWasActive: isRecording,
            hadTerminatedGap: hadTerminatedGap,
            filterPolicy: filterPolicy
        )
    }
}

// MARK: - CLLocationManagerDelegate
//
// The queue-less manager (created on main) delivers callbacks on the main thread, so MainActor isolation
// is sound; `@preconcurrency` lets this `@MainActor` type satisfy the nonisolated delegate requirements
// (same pattern as `StandardHRSource`'s CoreBluetooth delegate).

extension GpsWorkoutRecorder: @preconcurrency CLLocationManagerDelegate {

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        refreshAvailability()
        guard isRecording else { return }
        refreshAccuracyAuthorization()
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            // First-run grant: the prompt is shown in the foreground, so the session `beginUpdates` creates
            // can become active. An existing session is deliberately left alone here: this callback can also
            // arrive in the background, where a replacement would start inactive.
            beginUpdates()
        case .denied, .restricted:
            // Revoked mid-session: stop streaming but keep whatever route was captured so far (honest).
            manager.stopUpdatingLocation()
            releaseBackgroundActivity()
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // CoreLocation hands us an UNTRUSTED batch — map to RawFix and let TrackFilter bound-check every
        // field (accuracy, coordinate range, speed) before any of it reaches the stored route.
        let fixes: [RawFix] = locations.compactMap {
            let milliseconds = $0.timestamp.timeIntervalSince1970 * 1_000
            guard milliseconds.isFinite, milliseconds > 0, milliseconds <= 253_402_300_799_999 else { return nil }
            return RawFix(lat: $0.coordinate.latitude,
                   lon: $0.coordinate.longitude,
                   accuracyM: $0.horizontalAccuracy,
                   tMs: Int64(milliseconds))
        }
        ingest(fixes)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // A transient failure (no fix yet) is normal and self-heals; we never tear down on it. A hard
        // denial arrives via the auth callback instead. Never throw so a GPS hiccup can't crash a workout,
        // but leave a trace: a route that silently stops accruing is otherwise impossible to diagnose.
        let nsError = error as NSError
        lastErrorAt = Date()
        logWorkouts("gps locationError domain=\(nsError.domain) code=\(nsError.code)")
    }
}
