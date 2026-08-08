#if os(iOS)
import Foundation
import HealthKit
import NoopPhase34Core
import WhoopStore
import StrandAnalytics
import StrandImport

enum HealthKitWritebackComponent: String, CaseIterable {
    case vitals, sleep, heartRate, workouts
}

enum ExactPublicationError: Error {
    case authorizationUnavailable
    case storeUnavailable
    case invalidTimeZone
}

/// Deterministic, per-component six-hour success gate for NOOP → HealthKit write plans.
/// Failed/unmarked plans retry immediately; authorization changes and repair reset all keys.
enum HealthKitWritebackFingerprint {
    static let successTTL: TimeInterval = 6 * 3_600
    private static let keyPrefix = "noop.healthKitWriteback.v1"

    static func fingerprint<S: Sequence>(_ fields: S) -> String where S.Element == String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for field in fields {
            for byte in field.utf8 { hash ^= UInt64(byte); hash &*= 1_099_511_628_211 }
            hash ^= 0xff
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    static func shouldWrite(_ component: HealthKitWritebackComponent, fingerprint: String,
                            now: Date = Date(), defaults: UserDefaults = .standard) -> Bool {
        guard defaults.string(forKey: fingerprintKey(component)) == fingerprint else { return true }
        let completedAt = defaults.double(forKey: completedAtKey(component))
        return completedAt <= 0 || now.timeIntervalSince1970 - completedAt >= successTTL
    }

    static func markSuccess(_ component: HealthKitWritebackComponent, fingerprint: String,
                            at date: Date = Date(), defaults: UserDefaults = .standard) {
        defaults.set(fingerprint, forKey: fingerprintKey(component))
        defaults.set(date.timeIntervalSince1970, forKey: completedAtKey(component))
    }

    static func reset(defaults: UserDefaults = .standard) {
        for component in HealthKitWritebackComponent.allCases {
            defaults.removeObject(forKey: fingerprintKey(component))
            defaults.removeObject(forKey: completedAtKey(component))
        }
    }

    private static func fingerprintKey(_ component: HealthKitWritebackComponent) -> String {
        "\(keyPrefix).\(component.rawValue).fingerprint"
    }

    private static func completedAtKey(_ component: HealthKitWritebackComponent) -> String {
        "\(keyPrefix).\(component.rawValue).completedAt"
    }
}

/// Pure, throwing read planner for NOOP → HealthKit writeback. It mirrors Repository's active-first
/// identity union so a re-paired strap is never hidden behind the canonical namespace.
enum HealthKitWritebackPlanner {
    struct SourcedHRBucket: Equatable {
        let sourceId: String
        let bucket: HRBucket
    }

    static func sleepSessions(store: WhoopStore, importedIds: [String], computedIds: [String],
                              from: Int, to: Int, limit: Int = 200) async throws
        -> [CachedSleepSession] {
        var merged: [Int: CachedSleepSession] = [:]
        for id in computedIds {
            for row in try await store.sleepSessions(deviceId: id, from: from, to: to, limit: limit)
            where merged[row.startTs] == nil { merged[row.startTs] = row }
        }
        var imported: [Int: CachedSleepSession] = [:]
        for id in importedIds {
            for row in try await store.sleepSessions(deviceId: id, from: from, to: to, limit: limit)
            where imported[row.startTs] == nil { imported[row.startTs] = row }
        }
        for (key, row) in imported { merged[key] = row }
        return merged.keys.sorted().compactMap { merged[$0] }
    }

    static func dailyMetrics(store: WhoopStore, importedIds: [String], computedIds: [String],
                             from: String, to: String) async throws -> [DailyMetric] {
        var merged: [String: DailyMetric] = [:]
        for id in computedIds {
            for row in try await store.dailyMetrics(deviceId: id, from: from, to: to)
            where merged[row.day] == nil { merged[row.day] = row }
        }
        var imported: [String: DailyMetric] = [:]
        for id in importedIds {
            for row in try await store.dailyMetrics(deviceId: id, from: from, to: to)
            where imported[row.day] == nil { imported[row.day] = row }
        }
        for (key, row) in imported { merged[key] = row }
        return merged.keys.sorted().compactMap { merged[$0] }
    }

    static func heartRateBuckets(store: WhoopStore, importedIds: [String],
                                 fromById: [String: Int], to: Int, bucketSeconds: Int = 60)
        async throws -> [SourcedHRBucket] {
        var byTimestamp: [Int: SourcedHRBucket] = [:]
        for id in importedIds {
            for bucket in try await store.hrBuckets(deviceId: id, from: fromById[id] ?? 0,
                                                     to: to, bucketSeconds: bucketSeconds)
            where byTimestamp[bucket.ts] == nil {
                byTimestamp[bucket.ts] = SourcedHRBucket(sourceId: id, bucket: bucket)
            }
        }
        return byTimestamp.keys.sorted().compactMap { byTimestamp[$0] }
    }

    static func workouts(store: WhoopStore, importedIds: [String], computedIds: [String],
                         from: Int, to: Int, limit: Int = 500, excludingSource: String)
        async throws -> [WorkoutRow] {
        func key(_ row: WorkoutRow) -> String { "\(row.startTs):\(row.sport)" }
        var merged: [String: WorkoutRow] = [:]
        for id in computedIds {
            for row in try await store.workouts(deviceId: id, from: from, to: to, limit: limit)
            where row.source != excludingSource && merged[key(row)] == nil { merged[key(row)] = row }
        }
        var imported: [String: WorkoutRow] = [:]
        for id in importedIds {
            for row in try await store.workouts(deviceId: id, from: from, to: to, limit: limit)
            where row.source != excludingSource && imported[key(row)] == nil { imported[key(row)] = row }
        }
        for (key, row) in imported { merged[key] = row }
        return merged.values.sorted {
            $0.startTs == $1.startTs ? $0.sport < $1.sport : $0.startTs < $1.startTs
        }
    }
}

/// HealthKit's observer acknowledgement is documented as an escaping callback but is not annotated
/// `Sendable` in the iOS 17 SDK. This one-shot box is the narrow bridge into NOOP's MainActor sync task;
/// the lock guarantees the system callback can never be acknowledged twice.
private final class HealthKitObserverAcknowledgement: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (() -> Void)?

    init(_ completion: @escaping () -> Void) {
        self.completion = completion
    }

    func callOnce() {
        let callback = lock.withLock {
            defer { completion = nil }
            return completion
        }
        callback?()
    }
}

/// Two-way Apple Health bridge for the iOS app.
///
/// iOS has HealthKit (macOS does not), so the iOS target can do far more than parse a static export:
/// it reads the user's own Health data live and maps it onto the **same** `WhoopStore` rows the
/// macOS importer produces (under the `apple-health` source id), and it writes NOOP-computed metrics
/// back into Apple Health. Everything stays on-device and strictly opt-in.
@MainActor
final class HealthKitBridge: ObservableObject {

    private enum BridgeError: LocalizedError {
        case storeUnavailable

        var errorDescription: String? {
            switch self {
            case .storeUnavailable: return String(localized: "The local NOOP database could not be opened.")
            }
        }
    }

    enum AuthState: Equatable {
        case unknown, unavailable, denied, authorized
        /// The build can't talk to HealthKit at all: it was re-signed (free Apple ID / AltStore /
        /// Sideloadly) WITHOUT the `com.apple.developer.healthkit` entitlement, so the framework is
        /// present but the app can never read/write Health and can never appear under
        /// Settings › Health › Data Access & Devices. Distinct from `.denied` (entitled build, user
        /// said no) and `.unavailable` (no HealthKit hardware) so the UI can route to the honest
        /// file/Shortcuts import path instead of giving impossible Settings instructions (#348).
        case entitlementMissing
    }

    @Published private(set) var auth: AuthState = .unknown
    @Published private(set) var lastSync: Date?
    @Published private(set) var syncing = false
    /// The most recent failure surfaced by `sync` / `writeBack`. Cleared on a successful run. UI binds
    /// here so an Apple Health auth revoke, quota hit, or invalid sample is visible instead of silent.
    @Published private(set) var lastError: String?

    private let store = HKHealthStore()
    private let repo: Repository
    /// Source id imported HealthKit data lands under (matches `AppModel.appleDeviceId`).
    private let appleDeviceId: String
    /// NOOP's own strap-derived source id, read back when writing into Health.
    private let noopDeviceId: String
    /// NOOP's on-device COMPUTED daily scores (recovery/HRV/RHR/SpO₂/resp) live under the sibling
    /// `deviceId + "-noop"` id — mirrors `Repository.computedDeviceId` / `IntelligenceEngine.computedId`.
    /// `writeBack` must read this, not the raw import id: a Bluetooth-only WHOOP user has no imported
    /// `noopDeviceId` daily row, so those metrics exist ONLY here.
    private var computedDeviceId: String { noopDeviceId + "-noop" }

    private lazy var anchorPager = HealthKitAnchorPager(
        loader: HealthKitAnchoredPageLoader(store: store)
    )
    private lazy var syncCoordinator = HealthKitSyncCoordinator(
        persistence: HealthKitPendingWindowDefaultsStore()
    ) { [weak self] window in
        guard let self else { return false }
        return await self.performSync(window: window)
    }
    private var observerScanActive = false
    private var observerScanWaiters: [CheckedContinuation<Void, Never>] = []

    init(repo: Repository, appleDeviceId: String, noopDeviceId: String) {
        self.repo = repo
        self.appleDeviceId = appleDeviceId
        self.noopDeviceId = noopDeviceId
        #if DEBUG
        if CommandLine.arguments.contains("--demo-health-denied") {
            auth = .denied
            return
        }
        #endif
        // Order matters: a free-signed build with no HealthKit entitlement is dead in the water even
        // where the hardware supports Health, so surface that first. `.unavailable` (no HealthKit at
        // all, e.g. iPad without the framework) still wins where it applies because we only reach the
        // entitlement check when `isHealthDataAvailable()` is true.
        if !HKHealthStore.isHealthDataAvailable() {
            auth = .unavailable
        } else if !HealthKitBridge.hasHealthKitEntitlement {
            auth = .entitlementMissing
        }
    }

    // MARK: - Types

    private var readTypes: Set<HKObjectType> {
        var s = Set<HKObjectType>()
        for id in HealthKitBridge.quantityReadIds { if let t = HKObjectType.quantityType(forIdentifier: id) { s.insert(t) } }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { s.insert(sleep) }
        s.insert(HKObjectType.workoutType())
        return s
    }

    private var writeTypes: Set<HKSampleType> {
        var s = Set<HKSampleType>()
        for id in HealthKitBridge.quantityWriteIds + HealthKitBridge.highResQuantityWriteIds {
            if let t = HKObjectType.quantityType(forIdentifier: id) { s.insert(t) }
        }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { s.insert(sleep) }
        s.insert(HKObjectType.workoutType())
        return s
    }

    /// The write set as it existed before the high-res write-back (4 nightly vitals + sleep). A
    /// returning user granted THIS set; `refreshAuthIfPreviouslyGranted` must resume off it — checking
    /// the full `writeTypes` would leave every pre-existing grant stuck at `.unknown` after the update
    /// because the new types are still `.notDetermined`.
    private var legacyCoreWriteTypes: Set<HKSampleType> {
        var s = Set<HKSampleType>()
        for id in HealthKitBridge.quantityWriteIds { if let t = HKObjectType.quantityType(forIdentifier: id) { s.insert(t) } }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { s.insert(sleep) }
        return s
    }

    // Every id here ends up in the HealthKit permission dialog. Only request what `sync` actually
    // aggregates into `DayAgg`; adding read scopes the app never consumes makes the consent prompt
    // noisier and surfaces a privacy ask we don't honour.
    private static let quantityReadIds: [HKQuantityTypeIdentifier] = [
        .heartRate, .restingHeartRate, .heartRateVariabilitySDNN, .oxygenSaturation,
        .respiratoryRate, .bodyTemperature, .stepCount, .activeEnergyBurned,
        .basalEnergyBurned, .vo2Max,
        // Body composition — READ-ONLY (#20). Imported under the apple-health source like the file
        // importer already ingests; deliberately NOT in quantityWriteIds (we never write these back).
        .bodyMass, .bodyFatPercentage, .leanBodyMass, .bodyMassIndex
    ]
    private static let quantityWriteIds: [HKQuantityTypeIdentifier] = [
        .restingHeartRate, .heartRateVariabilitySDNN, .oxygenSaturation, .respiratoryRate
    ]
    // High-res write-back shares: the continuous 1-minute HR stream, and the energy/distance samples
    // attached to written workouts. Kept out of `quantityWriteIds` so `legacyCoreWriteTypes` (the
    // auth-resume set) stays exactly what pre-update users granted.
    private static let highResQuantityWriteIds: [HKQuantityTypeIdentifier] = [
        .heartRate, .activeEnergyBurned, .distanceWalkingRunning, .distanceCycling
    ]

    // MARK: - Authorization

    /// Request read + write permission. HealthKit never reveals whether *read* was granted, so we
    /// treat a successful request as `.authorized` and let queries return empty if the user declined.
    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else { auth = .unavailable; return }
        // A free-signed build (no `com.apple.developer.healthkit` entitlement) can NEVER reach Health:
        // `requestAuthorization` either throws "Missing application-identifier"/"missing entitlement"
        // or returns without ever presenting the sheet and leaves every type `.notDetermined`. Either
        // way the honest answer is "this build can't use Apple Health directly", NOT "you denied it" —
        // so never fall through to `.denied` (which tells the user to fix it in Settings, where the app
        // can never appear). Detect via the embedded provisioning profile up front (#348).
        guard HealthKitBridge.hasHealthKitEntitlement else { auth = .entitlementMissing; return }
        do {
            try await store.requestAuthorization(toShare: writeTypes, read: readTypes)
            HealthKitWritebackFingerprint.reset()
            // The entitlement is present (the guard above proved it via the embedded profile, or there's
            // no profile = App Store build), so a successful request means the bridge is usable. We do
            // NOT reclassify to `.entitlementMissing` off the post-request `.notDetermined` heuristic
            // here: on a genuinely-entitled build the user could grant only reads (writes stay
            // `.notDetermined`) or dismiss the share sheet, and that must stay `.authorized` with the
            // normal Settings guidance — never the file-import reroute. The provisioning-profile check is
            // the authoritative signal; the `.notDetermined` fallback only matters when that check can't
            // run, which on iOS means an App Store build that by definition has the entitlement.
            auth = .authorized
        } catch {
            // A thrown error here is on a build that carries the entitlement (guarded above), so it's a
            // genuine denial / request failure — keep the normal `.denied` "enable in Settings" path,
            // never the entitlement-missing reroute.
            auth = .denied
        }
        // First successful grant in this process: arm the live HealthKit stream so a watch-only user
        // gets continuous ingestion (new SDNN/RHR/sleep/etc. land within the hour) instead of only on
        // app foreground. Guarded inside enableLiveDelivery on auth == .authorized, so the .denied path
        // above is a no-op.
        enableLiveDelivery()
    }

    /// Resume a prior grant on launch without re-prompting. `auth` is a fresh `.unknown` every
    /// process (the bridge isn't persisted), so a user who already enabled Apple Health would
    /// otherwise have to re-tap "Enable" each session before the scenePhase sync runs. HealthKit
    /// never reveals *read* status, but *write*/share status is observable — if the user already
    /// authorized all of our write types, treat the bridge as `.authorized`. This only reads
    /// status, so no system permission sheet is shown.
    func refreshAuthIfPreviouslyGranted() {
        guard auth == .unknown, HKHealthStore.isHealthDataAvailable() else { return }
        let granted = legacyCoreWriteTypes.allSatisfy { store.authorizationStatus(for: $0) == .sharingAuthorized }
        if granted {
            auth = .authorized
            // A returning user who already granted access should get the live stream re-armed for this
            // process. enableLiveDelivery is idempotent (HealthKit dedups observers + background
            // delivery per type), so calling it here as well as after a fresh requestAuthorization is safe.
            enableLiveDelivery()
            // The high-res write-back added share types (HR stream, workouts, energy/distance) that a
            // pre-update grant has as `.notDetermined`. Re-request once: HealthKit shows a single sheet
            // listing ONLY the new types, and each write feature independently guards on its own type's
            // share status, so declining any checkbox just skips that feature.
            // Raw request, NOT requestAuthorization(): that method reclassifies a thrown error as
            // `.denied`, which must never demote a bridge that just resumed a valid legacy grant.
            let newTypesPending = writeTypes.contains { store.authorizationStatus(for: $0) == .notDetermined }
            if newTypesPending {
                Task {
                    if (try? await store.requestAuthorization(toShare: writeTypes, read: readTypes)) != nil {
                        HealthKitWritebackFingerprint.reset()
                    }
                }
            }
        }
    }

    // MARK: - Live delivery (continuous ingestion)

    /// Long-lived observer queries, retained so HealthKit doesn't tear them down. Keyed by the sample
    /// type's identifier so a second `enableLiveDelivery()` call replaces rather than duplicates.
    private var observerQueries: [String: HKObserverQuery] = [:]

    /// Register one `HKObserverQuery` per scored read type and turn on hourly background delivery, so
    /// new Apple Watch data is ingested continuously. Each observer's update handler runs an anchored
    /// delta sync of just the affected window and then calls HealthKit's completion handler (required —
    /// HealthKit stops delivering to an observer that never acknowledges). Idempotent and guarded behind
    /// `auth == .authorized`; safe to call from several entry points.
    func enableLiveDelivery() {
        guard auth == .authorized, HKHealthStore.isHealthDataAvailable() else { return }

        // Deletion reconciliation must observe every imported type, not only the score-moving subset:
        // a deleted body-composition or sleep object still has to retract its local Apple projection.
        let types = readTypes.compactMap { $0 as? HKSampleType }

        for type in types {
            let key = type.identifier
            // Tear down a prior observer for this type before re-registering, so a re-arm (e.g. a
            // returning user hitting both requestAuthorization and refreshAuthIfPreviouslyGranted) can
            // never leave two live observers fighting over the same completion handler.
            if let existing = observerQueries[key] {
                store.stop(existing)
                observerQueries[key] = nil
            }
            let observer = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, _ in
                // HealthKit invokes this on a background queue. Hop to the main actor (the bridge is
                // @MainActor and `sync` mutates published state), run the incremental catch-up, then
                // ALWAYS call completion so HealthKit keeps delivering. We don't tie completion to sync
                // success: a transient store error shouldn't make HealthKit think we never handled the
                // update and back off — the next foreground catch-up will reconcile.
                let acknowledgement = HealthKitObserverAcknowledgement(completion)
                guard let self else { acknowledgement.callOnce(); return }
                Task { @MainActor in
                    await self.syncFromObserver(type: type)
                    acknowledgement.callOnce()
                }
            }
            store.execute(observer)
            observerQueries[key] = observer

            // Hourly is the finest cadence HealthKit honours for most types and is plenty for daily
            // aggregate scores. Failure here is non-fatal: the foreground catch-up still backfills.
            store.enableBackgroundDelivery(for: type, frequency: .hourly) { _, _ in }
        }

        // Resume a window journaled before a prior process was suspended or killed. The coordinator
        // is single-flight, so this is safe alongside observer wakes and the foreground catch-up.
        syncCoordinator.start()
    }

    /// Foreground catch-up. Call on app-active so anything background delivery missed (the system can
    /// throttle or skip wakes) is backfilled. A short window is enough because live delivery keeps the
    /// recent days current; 7 covers a weekend of missed wakes. Exposed for the existing scenePhase
    /// hook in `StrandiOSApp` to call — no other file is edited.
    func foregroundCatchUp() async {
        await sync(days: 7)
    }

    /// Clears only NOOP's write-plan success gates. The next sync repairs every authorized HealthKit
    /// component without deleting local history or changing Health authorization.
    func resetWritebackFingerprints() {
        HealthKitWritebackFingerprint.reset()
    }

    /// Deliver only the durable canonical days named by an external-publication outbox item. This
    /// destination never requests authorization and never widens a historical mutation into a rolling
    /// refresh window. The existing bounded write-back remains the user-invoked repair path; this method
    /// is the exact historical delivery path.
    func publishExactHealthKit(payload: HistoricalHealthKitMutationPayload) async throws {
        guard auth == .authorized else { throw ExactPublicationError.authorizationUnavailable }
        guard !payload.deviceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let timeZone = TimeZone(identifier: payload.recordedTimeZoneIdentifier) else {
            throw ExactPublicationError.invalidTimeZone
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        var firstError: Error?
        do {
            try await writeExactVitals(payload, calendar: calendar)
        } catch {
            firstError = error
        }
        do {
            try await writeExactSleep(payload, calendar: calendar)
        } catch {
            if firstError == nil { firstError = error }
        }
        if let firstError { throw firstError }
    }

    private func writeExactVitals(
        _ payload: HistoricalHealthKitMutationPayload,
        calendar: Calendar
    ) async throws {
        struct Candidate {
            let type: HKQuantityType
            let key: String
            let value: Double
            let at: Date
            let sample: HKQuantitySample
        }

        var candidates: [Candidate] = []
        func add(
            _ id: HKQuantityTypeIdentifier,
            _ unit: HKUnit,
            _ value: Double,
            _ day: CivilDay,
            _ at: Date
        ) {
            guard value.isFinite,
                  let type = HKQuantityType.quantityType(forIdentifier: id),
                  store.authorizationStatus(for: type) == .sharingAuthorized else { return }
            let key = "noop:\(payload.deviceId):\(id.rawValue):\(day.key)"
            candidates.append(Candidate(
                type: type,
                key: key,
                value: value,
                at: at,
                sample: HKQuantitySample(
                    type: type,
                    quantity: HKQuantity(unit: unit, doubleValue: value),
                    start: at,
                    end: at,
                    metadata: [HKMetadataKeyExternalUUID: key]
                )
            ))
        }

        let allDays = payload.changedDays.sorted()
        var deletionKeysByType: [HKQuantityType: [String]] = [:]
        for day in allDays {
            for id in HealthKitBridge.quantityWriteIds {
                guard let type = HKQuantityType.quantityType(forIdentifier: id),
                      store.authorizationStatus(for: type) == .sharingAuthorized else { continue }
                deletionKeysByType[type, default: []].append(
                    "noop:\(payload.deviceId):\(id.rawValue):\(day.key)"
                )
            }
        }

        for mutation in payload.dailyMutations {
            let start = try mutation.day.date(in: calendar)
            let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: start) ?? start
            let at = mutation.wakeTimestamp.map {
                Date(timeIntervalSince1970: TimeInterval($0))
            } ?? noon
            if let value = mutation.restingHR {
                add(
                    .restingHeartRate,
                    HKUnit.count().unitDivided(by: .minute()),
                    Double(value),
                    mutation.day,
                    at
                )
            }
            if let value = mutation.hrvMilliseconds {
                add(.heartRateVariabilitySDNN, .secondUnit(with: .milli), value, mutation.day, at)
            }
            if let value = mutation.oxygenSaturationPercent {
                add(.oxygenSaturation, .percent(), value / 100, mutation.day, at)
            }
            if let value = mutation.respiratoryRate {
                add(
                    .respiratoryRate,
                    HKUnit.count().unitDivided(by: .minute()),
                    value,
                    mutation.day,
                    at
                )
            }
        }
        let fingerprint = HealthKitWritebackFingerprint.fingerprint(
            ["analysis|\(payload.analysisGeneration)"]
                + deletionKeysByType.values.flatMap { $0.sorted().map { "delete|\($0)" } }
                + candidates.sorted { $0.key < $1.key }.map {
                    "\($0.key)|\($0.value)|\(Int($0.at.timeIntervalSince1970))"
                }
        )
        guard HealthKitWritebackFingerprint.shouldWrite(.vitals, fingerprint: fingerprint) else { return }

        let bySource = HKQuery.predicateForObjects(from: HKSource.default())
        for (type, keys) in deletionKeysByType {
            let byKey = HKQuery.predicateForObjects(
                withMetadataKey: HKMetadataKeyExternalUUID,
                allowedValues: Array(Set(keys))
            )
            _ = try await store.deleteObjects(
                of: type,
                predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [bySource, byKey])
            )
        }
        if !candidates.isEmpty {
            try await store.save(candidates.map(\.sample))
        }
        HealthKitWritebackFingerprint.markSuccess(.vitals, fingerprint: fingerprint)
    }

    private func writeExactSleep(
        _ payload: HistoricalHealthKitMutationPayload,
        calendar: Calendar
    ) async throws {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis),
              store.authorizationStatus(for: type) == .sharingAuthorized else { return }

        let fragments = payload.sleepMutations.map {
            HealthWriteback.SleepFragment(
                startTs: $0.stableStartTimestamp,
                effectiveStartTs: $0.effectiveStartTimestamp,
                endTs: $0.endTimestamp,
                stagesJSON: $0.stagesJSON
            )
        }
        let byDay = Dictionary(grouping: fragments) { fragment -> String in
            let date = Date(timeIntervalSince1970: TimeInterval(fragment.endTs))
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
        }

        var groups: [[HealthWriteback.SleepFragment]] = []
        for dayFragments in byDay.values {
            let ordered = dayFragments.sorted { $0.effectiveStartTs < $1.effectiveStartTs }
            let blocks = ordered.map {
                SleepStageTotals.NightBlock(start: $0.effectiveStartTs, end: $0.endTs)
            }
            guard let reference = ordered.first else { continue }
            let wake = Date(timeIntervalSince1970: TimeInterval(reference.endTs))
            let offset = calendar.timeZone.secondsFromGMT(for: wake)
            let bridged = SleepStageTotals.bridgedNightGroups(blocks, offsetSec: offset)
            groups.append(contentsOf: bridged.map { group in
                group.indices.map { ordered[$0] }
            })
        }

        let plan = HealthWriteback.mergedSleepPlan(groups: groups)
        guard let durableStore = await repo.storeHandle() else {
            throw ExactPublicationError.storeUnavailable
        }
        let ledger = try await durableStore.healthKitSleepLedger(
            contextId: payload.contextId,
            deviceId: payload.deviceId,
            days: payload.changedDays)
        let repairDays = payload.changedDays.subtracting(ledger.coveredDays)
        let repairedKeys = repairDays.isEmpty
            ? []
            : try await noopAuthoredSleepKeys(
                ownerDeviceId: payload.deviceId,
                changedDays: repairDays,
                calendar: calendar,
                type: type)
        try await saveExactSleepPlan(
            plan,
            ownerDeviceId: payload.deviceId,
            type: type,
            analysisGeneration: payload.analysisGeneration,
            existingKeys: ledger.keys.union(repairedKeys),
            forceWrite: !repairDays.isEmpty
        )

        let ledgerEntries = try plan.flatMap { entry in
            let wakeDate = Date(timeIntervalSince1970: TimeInterval(entry.spanEnd))
            let components = calendar.dateComponents([.year, .month, .day], from: wakeDate)
            let wakeDay = try CivilDay(key: String(format: "%04d-%02d-%02d",
                                                    components.year!, components.month!, components.day!))
            return entry.allKeyStartTs.map { start in
                HealthKitSleepLedgerEntry(
                    wakeDay: wakeDay,
                    stableStartTimestamp: start,
                    externalUUID: "noop:\(payload.deviceId):sleep:\(start)")
            }
        }
        let keysByDay = Dictionary(grouping: ledgerEntries, by: \.wakeDay)
        for day in payload.changedDays {
            let keys = (keysByDay[day] ?? []).map {
                (stableStartTimestamp: $0.stableStartTimestamp, externalUUID: $0.externalUUID)
            }
            try await durableStore.replaceHealthKitSleepLedgerChunked(
                contextId: payload.contextId,
                deviceId: payload.deviceId,
                wakeDay: day,
                analysisGeneration: payload.analysisGeneration,
                keys: keys,
                now: Date())
        }
    }

    private func noopAuthoredSleepKeys(
        ownerDeviceId: String,
        changedDays: Set<CivilDay>,
        calendar: Calendar,
        type: HKCategoryType
    ) async throws -> Set<String> {
        var keys = Set<String>()
        let prefix = "noop:\(ownerDeviceId):sleep:"
        let windows = try HealthKitSleepRepairPlanner.contiguousWindows(
            days: changedDays,
            timeZoneIdentifier: calendar.timeZone.identifier)
        var samples: [HKSample] = []
        for window in windows {
            let start = try window.first.date(in: calendar).addingTimeInterval(-20 * 3_600)
            let end = try calendar.date(byAdding: .day, value: 1, to: window.last.date(in: calendar))!
                .addingTimeInterval(4 * 3_600)
            let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                HKQuery.predicateForObjects(from: HKSource.default()),
                HKQuery.predicateForSamples(withStart: start, end: end, options: []),
            ])
            let windowSamples: [HKSample] = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<[HKSample], any Error>) in
                let query = HKSampleQuery(
                    sampleType: type,
                    predicate: predicate,
                    limit: HKObjectQueryNoLimit,
                    sortDescriptors: nil
                ) { _, objects, error in
                    if let error { continuation.resume(throwing: error); return }
                    continuation.resume(returning: objects ?? [])
                }
                store.execute(query)
            }
            samples.append(contentsOf: windowSamples)
        }
        for sample in samples {
            guard let key = sample.metadata?[HKMetadataKeyExternalUUID] as? String,
                  key.hasPrefix(prefix) else { continue }
            let components = calendar.dateComponents([.year, .month, .day], from: sample.endDate)
            guard let year = components.year, let month = components.month, let day = components.day,
                  let wakeDay = try? CivilDay(key: String(format: "%04d-%02d-%02d", year, month, day)),
                  changedDays.contains(wakeDay) else { continue }
            keys.insert(key)
        }
        return keys
    }

    private func saveExactSleepPlan(
        _ plan: [HealthWriteback.MergedSleepEntry],
        ownerDeviceId: String,
        type: HKCategoryType,
        analysisGeneration: Int64,
        existingKeys: Set<String>,
        forceWrite: Bool
    ) async throws {
        let fingerprint = HealthKitWritebackFingerprint.fingerprint(
            ["owner|\(ownerDeviceId)", "analysis|\(analysisGeneration)"] + plan.flatMap { entry in
                ["night|\(entry.keyStartTs)|\(entry.spanStart)|\(entry.spanEnd)"]
                    + entry.intervals.map { "stage|\($0.kind)|\($0.start)|\($0.end)" }
            }
        )
        guard forceWrite || HealthKitWritebackFingerprint.shouldWrite(.sleep, fingerprint: fingerprint) else { return }

        var samples: [HKCategorySample] = []
        var keys: [String] = Array(existingKeys)
        for entry in plan {
            let key = "noop:\(ownerDeviceId):sleep:\(entry.keyStartTs)"
            let metadata = [HKMetadataKeyExternalUUID: key]
            keys.append(contentsOf: entry.allKeyStartTs.map {
                "noop:\(ownerDeviceId):sleep:\($0)"
            })
            samples.append(HKCategorySample(
                type: type,
                value: HKCategoryValueSleepAnalysis.inBed.rawValue,
                start: Date(timeIntervalSince1970: TimeInterval(entry.spanStart)),
                end: Date(timeIntervalSince1970: TimeInterval(entry.spanEnd)),
                metadata: metadata
            ))
            for interval in entry.intervals {
                let value: HKCategoryValueSleepAnalysis
                switch interval.kind {
                case .awake: value = .awake
                case .light: value = .asleepCore
                case .deep: value = .asleepDeep
                case .rem: value = .asleepREM
                case .unspecified: value = .asleepUnspecified
                }
                samples.append(HKCategorySample(
                    type: type,
                    value: value.rawValue,
                    start: Date(timeIntervalSince1970: TimeInterval(interval.start)),
                    end: Date(timeIntervalSince1970: TimeInterval(interval.end)),
                    metadata: metadata
                ))
            }
        }
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: HKSource.default()),
            HKQuery.predicateForObjects(
                withMetadataKey: HKMetadataKeyExternalUUID,
                allowedValues: Array(Set(keys))
            ),
        ])
        if !keys.isEmpty {
            _ = try await store.deleteObjects(of: type, predicate: predicate)
        }
        if !samples.isEmpty {
            try await store.save(samples)
        }
        HealthKitWritebackFingerprint.markSuccess(.sleep, fingerprint: fingerprint)
    }

    /// Drive an incremental sync off an observer wake. We use an `HKAnchoredObjectQuery` per type to
    /// learn the span of days touched since we last looked (persisting the anchor so the same samples
    /// aren't walked twice and nothing between wakes is missed), then re-aggregate just that day window
    /// via the existing `sync(days:)` path. Re-aggregating the window (rather than the deltas alone)
    /// keeps every per-day average correct and idempotent — `sync` upserts are keyed by day.
    private func syncFromObserver(type: HKSampleType) async {
        guard auth == .authorized else { return }
        await acquireObserverScanLease()
        defer { releaseObserverScanLease() }

        guard let cache = await repo.storeHandle() else {
            lastError = String(localized: "Apple Health observer sync failed: \(BridgeError.storeUnavailable.localizedDescription)")
            return
        }

        let key = HealthKitBridge.anchorDefaultsKey(for: type)
        let priorAnchor = Self.loadAnchor(forKey: key)

        do {
            // Keep this aggregate bit, not the deletion UUIDs. An anchored first-run can contain years
            // of tombstones; each page resolves its own identities below and is then released.
            var hasUnknownHistoricalDeletion = false
            let scan = try await anchorPager.scan(
                type: type,
                predicate: Self.notNoopAuthored,
                priorAnchor: priorAnchor,
                handlePage: { [appleDeviceId] page in
                    let sampleIDs = page.samples.map { $0.uuid.uuidString }
                    let historical = try await cache.healthKitObjectIdentities(
                        sampleType: type.identifier,
                        objectUUIDs: sampleIDs + page.deletedObjectUUIDs,
                        deviceId: appleDeviceId
                    )
                    let deletedIDs = Set(page.deletedObjectUUIDs)
                    let knownDeleted = historical.lazy.filter {
                        deletedIDs.contains($0.objectUUID)
                    }.count
                    hasUnknownHistoricalDeletion = hasUnknownHistoricalDeletion
                        || knownDeleted < page.deletedObjectUUIDs.count
                    let current = page.samples.map {
                        HealthKitObjectIdentity(
                            sampleType: type.identifier,
                            objectUUID: $0.uuid.uuidString,
                            startTs: Int($0.startDate.timeIntervalSince1970),
                            endTs: Int($0.endDate.timeIntervalSince1970)
                        )
                    }
                    try await cache.upsertHealthKitObjectIdentities(current, deviceId: appleDeviceId)
                    let dates = page.samples.flatMap { [$0.startDate, $0.endDate] }
                        + historical.flatMap {
                            [Date(timeIntervalSince1970: TimeInterval($0.startTs)),
                             Date(timeIntervalSince1970: TimeInterval($0.endTs))]
                        }
                    guard let first = dates.min(), let last = dates.max() else { return nil }
                    return HealthKitSyncWindow(start: first, end: last)
                }
            )

            let changedObjects = scan.sampleCount + scan.deletedCount
            guard changedObjects > 0 else {
                try Self.saveAnchor(scan.finalAnchor, forKey: key)
                return
            }

            let now = Date()
            let fallbackStart = Calendar.current.date(byAdding: .day, value: -31, to: now) ?? now
            var start = scan.oldestSampleDate ?? fallbackStart
            // A database created before v31 has no UUID mapping for historic objects. Do the expensive
            // but correct thing once: widen to the oldest locally projected Apple Health row rather than
            // pretending a deletion-only delta happened in the last month.
            if hasUnknownHistoricalDeletion,
               let earliest = try await cache.earliestAppleHealthTimestamp(deviceId: appleDeviceId) {
                start = min(start, Date(timeIntervalSince1970: TimeInterval(earliest)))
            }
            // Establishing the first cursor may page through years of history. Foreground/manual sync
            // already owns deep import; the initial live-delivery catch-up intentionally covers only
            // the latest month. Later deltas retain their exact old dates, so an edited historical
            // sample is never silently clamped away after the cursor exists.
            if scan.wasInitialScan && !hasUnknownHistoricalDeletion { start = max(start, fallbackStart) }
            let window = HealthKitSyncWindow(
                start: Calendar.current.startOfDay(for: start),
                end: max(now, scan.newestSampleDate ?? now)
            )

            // Crash-safety ordering is deliberate: persist/widen pending work, flush it, then advance
            // the HealthKit cursor. A kill after the cursor write still leaves the aggregation window
            // recoverable; a kill before it merely replays an idempotent page scan.
            try syncCoordinator.offer(window)
            do {
                try Self.saveAnchor(scan.finalAnchor, forKey: key)
            } catch {
                syncCoordinator.start()
                throw error
            }
            syncCoordinator.start()
        } catch {
            lastError = String(localized: "Apple Health observer sync failed: \(error.localizedDescription)")
        }
    }

    /// HealthKit can invoke several observer handlers while an anchored query is suspended. Keep the
    /// scan-and-anchor transaction FIFO so an older page result can never overwrite a newer cursor.
    private func acquireObserverScanLease() async {
        guard observerScanActive else {
            observerScanActive = true
            return
        }
        await withCheckedContinuation { observerScanWaiters.append($0) }
    }

    private func releaseObserverScanLease() {
        guard !observerScanWaiters.isEmpty else {
            observerScanActive = false
            return
        }
        observerScanWaiters.removeFirst().resume()
    }

    private static func loadAnchor(forKey key: String) -> HKQueryAnchor? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    private static func saveAnchor(_ anchor: HKQueryAnchor, forKey key: String) throws {
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: anchor,
            requiringSecureCoding: true
        )
        UserDefaults.standard.set(data, forKey: key)
        guard UserDefaults.standard.synchronize(), UserDefaults.standard.data(forKey: key) == data else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// UserDefaults key for a type's persisted HealthKit anchor. Namespaced so it can't collide with
    /// other app defaults, and keyed by the stable HK identifier so it survives across launches.
    private static func anchorDefaultsKey(for type: HKSampleType) -> String {
        "hkAnchor.v1.\(type.identifier)"
    }

    // MARK: - Read → store

    /// Pull the last `days` of Apple Health into the on-device store under the `apple-health` source,
    /// then write NOOP's own computed metrics back into Health. Safe to call repeatedly (idempotent
    /// upserts keyed by day).
    func sync(days: Int = 30) async {
        guard auth == .authorized else { return }
        let now = Date()
        guard let start = Calendar.current.date(
            byAdding: .day,
            value: -max(1, days),
            to: Calendar.current.startOfDay(for: now)
        ) else { return }
        do {
            try syncCoordinator.offer(HealthKitSyncWindow(start: start, end: now))
            await syncCoordinator.runAndWait()
        } catch {
            lastError = String(localized: "Apple Health sync failed: \(error.localizedDescription)")
        }
    }

    /// Remove every HealthKit projection that can contain the source being privacy-deleted, then rebuild the
    /// same affected windows from the remaining source namespaces. AppModel calls this only while the raw and
    /// derived target fences are blocked, so a suspended ordinary write-back cannot republish the deleted source.
    func prepareSourceDeletion(_ sourceDeviceId: String) async throws {
        guard auth == .authorized else { throw ExactPublicationError.authorizationUnavailable }
        guard let whoopStore = await repo.storeHandle() else { throw BridgeError.storeUnavailable }
        let raw = sourceDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        let derived = raw + "-noop"
        let remainingImportedIds = repo.importedReadIds.filter { $0 != raw && $0 != derived }
        let remainingComputedIds = repo.computedReadIds.filter { $0 != raw && $0 != derived }
        HealthKitWritebackFingerprint.reset()

        let rawDaily = try await whoopStore.dailyMetrics(
            deviceId: raw, from: "0001-01-01", to: "9999-12-31")
        let derivedDaily = try await whoopStore.dailyMetrics(
            deviceId: derived, from: "0001-01-01", to: "9999-12-31")
        let sourceDaily = rawDaily + derivedDaily
        let deliveredExactDays = try await whoopStore.healthKitMutationWatermarkDays(deviceId: raw)
        let affectedDays = Set(sourceDaily.compactMap { try? CivilDay(key: $0.day) }).union(deliveredExactDays)
        try await deleteNoopVitals(
            ownerDeviceIds: [noopDeviceId, raw],
            dayKeys: Set(affectedDays.map(\.key)))
        if !affectedDays.isEmpty {
            try await writeVitals(
                whoopStore: whoopStore,
                days: 1,
                sessions: [],
                importedIds: remainingImportedIds,
                computedIds: remainingComputedIds,
                dayKeys: Set(affectedDays.map(\.key)))
        }

        let sourceSessions = try await HealthKitWritebackPlanner.sleepSessions(
            store: whoopStore,
            importedIds: [raw],
                computedIds: [derived],
                from: 0,
                to: Int.max,
                limit: Int.max)
        let exactSleepLedger = try await whoopStore.healthKitSleepLedgerEntries(deviceId: raw)
        let affectedSleepDays = Set(sourceSessions.compactMap { session in
            try? CivilDay(key: Self.dayString(Date(timeIntervalSince1970: TimeInterval(session.endTs))))
        }).union(exactSleepLedger.map(\.wakeDay))
        try await deleteNoopSleep(
            ownerDeviceIds: [noopDeviceId, raw],
            wakeDays: affectedSleepDays,
            exactKeys: Set(exactSleepLedger.map(\.externalUUID)))
        if !affectedSleepDays.isEmpty {
            let remainingSessions = try await HealthKitWritebackPlanner.sleepSessions(
                store: whoopStore,
                importedIds: remainingImportedIds,
                computedIds: remainingComputedIds,
                from: 0,
                to: Int.max,
                limit: Int.max)
                .filter { session in
                    guard let day = try? CivilDay(
                        key: Self.dayString(Date(timeIntervalSince1970: TimeInterval(session.endTs))))
                    else { return false }
                    return affectedSleepDays.contains(day)
                }
            try await writeSleep(sessions: remainingSessions)
        }

        let sourceWorkouts = try await HealthKitWritebackPlanner.workouts(
            store: whoopStore,
            importedIds: [raw],
            computedIds: [derived],
            from: 0,
            to: Int.max,
            limit: Int.max,
            excludingSource: Self.appleWorkoutSource)
        try await deleteNoopWorkouts(startTimestamps: Set(sourceWorkouts.map(\.startTs)))
        if let first = sourceWorkouts.map(\.startTs).min(),
           let last = sourceWorkouts.map(\.endTs).max() {
            try await writeWorkouts(
                whoopStore: whoopStore,
                importedIds: remainingImportedIds,
                computedIds: remainingComputedIds,
                fromTs: first,
                toTs: last,
                limit: Int.max)
        }

        if let bounds = try await whoopStore.hrTimestampBounds(deviceId: raw) {
            try await replaceNoopHeartRateRange(
                whoopStore: whoopStore,
                remainingImportedIds: remainingImportedIds,
                fromTs: bounds.earliest,
                toTs: bounds.latest)
        }
    }

    private func deleteNoopVitals(ownerDeviceIds: [String], dayKeys: Set<String>) async throws {
        guard !dayKeys.isEmpty else { return }
        let owners = Array(Set(ownerDeviceIds.filter { !$0.isEmpty }))
        let bySource = HKQuery.predicateForObjects(from: HKSource.default())
        for id in Self.quantityWriteIds {
            guard let type = HKQuantityType.quantityType(forIdentifier: id),
                  store.authorizationStatus(for: type) == .sharingAuthorized else { continue }
            let keys = owners.flatMap { owner in
                dayKeys.map { "noop:\(owner):\(id.rawValue):\($0)" }
            }
            let byKey = HKQuery.predicateForObjects(
                withMetadataKey: HKMetadataKeyExternalUUID,
                allowedValues: keys)
            _ = try await store.deleteObjects(
                of: type,
                predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [bySource, byKey]))
        }
    }

    private func deleteNoopSleep(
        ownerDeviceIds: [String],
        wakeDays: Set<CivilDay>,
        exactKeys: Set<String>
    ) async throws {
        guard !wakeDays.isEmpty,
              let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis),
              store.authorizationStatus(for: type) == .sharingAuthorized else { return }
        let calendar = Calendar.current
        var keys = exactKeys
        for ownerDeviceId in Set(ownerDeviceIds.filter { !$0.isEmpty }) {
            keys.formUnion(try await noopAuthoredSleepKeys(
                ownerDeviceId: ownerDeviceId,
                changedDays: wakeDays,
                calendar: calendar,
                type: type))
        }
        guard !keys.isEmpty else { return }
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: HKSource.default()),
            HKQuery.predicateForObjects(
                withMetadataKey: HKMetadataKeyExternalUUID,
                allowedValues: Array(keys)),
        ])
        _ = try await store.deleteObjects(of: type, predicate: predicate)
    }

    private func deleteNoopWorkouts(startTimestamps: Set<Int>) async throws {
        guard !startTimestamps.isEmpty,
              store.authorizationStatus(for: .workoutType()) == .sharingAuthorized else { return }
        let keys = startTimestamps.map { "noop:\(noopDeviceId):workout:\($0)" }
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: HKSource.default()),
            HKQuery.predicateForObjects(
                withMetadataKey: HKMetadataKeyExternalUUID,
                allowedValues: keys),
        ])
        _ = try await store.deleteObjects(of: .workoutType(), predicate: predicate)
    }

    private func replaceNoopHeartRateRange(
        whoopStore: WhoopStore,
        remainingImportedIds: [String],
        fromTs: Int,
        toTs: Int
    ) async throws {
        guard let type = HKQuantityType.quantityType(forIdentifier: .heartRate),
              store.authorizationStatus(for: type) == .sharingAuthorized,
              toTs >= fromTs else { return }
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: HKSource.default()),
            HKQuery.predicateForSamples(
                withStart: Date(timeIntervalSince1970: TimeInterval(fromTs)),
                end: Date(timeIntervalSince1970: TimeInterval(toTs) + 60),
                options: []),
        ])
        _ = try await store.deleteObjects(of: type, predicate: predicate)

        var priorCursors: [String: Int] = [:]
        for sourceId in remainingImportedIds {
            let key = hrWriteCursorKey(for: sourceId)
            priorCursors[sourceId] = UserDefaults.standard.integer(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
        HealthKitWritebackFingerprint.reset()
        try await writeHeartRate(
            whoopStore: whoopStore,
            importedIds: remainingImportedIds,
            fromTs: fromTs,
            nowTs: toTs)
        for (sourceId, prior) in priorCursors where prior > 0 {
            let key = hrWriteCursorKey(for: sourceId)
            UserDefaults.standard.set(max(prior, UserDefaults.standard.integer(forKey: key)), forKey: key)
        }
    }

    private func performSync(window: HealthKitSyncWindow) async -> Bool {
        guard auth == .authorized else { return false }
        syncing = true
        defer { syncing = false }
        guard let store = await repo.storeHandle() else {
            lastError = String(localized: "Apple Health sync failed: \(BridgeError.storeUnavailable.localizedDescription)")
            return false
        }

        let cal = Calendar.current
        let start = cal.startOfDay(for: window.start)
        let end = max(Date(), window.end)

        do {
        var byDay: [String: DayAgg] = [:]
        func merge(_ values: [String: Double], update: (inout DayAgg, Double) -> Void) {
            for (day, value) in values {
                var aggregate = byDay[day] ?? DayAgg()
                update(&aggregate, value)
                byDay[day] = aggregate
            }
        }

        // Quantity aggregates per day.
        merge(try await collect(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()), start: start, end: end, op: .discreteAverage)) { $0.restingHr = Self.finite($1, in: 20...300) }
        merge(try await collect(.heartRate, unit: HKUnit.count().unitDivided(by: .minute()), start: start, end: end, op: .discreteAverage)) { $0.avgHr = Self.finite($1, in: 20...300) }
        merge(try await collect(.heartRate, unit: HKUnit.count().unitDivided(by: .minute()), start: start, end: end, op: .discreteMax)) { $0.maxHr = Self.finite($1, in: 20...300) }
        merge(try await collect(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), start: start, end: end, op: .discreteAverage)) { $0.hrv = Self.finite($1, in: 0...1_000) }
        merge(try await collect(.oxygenSaturation, unit: .percent(), start: start, end: end, op: .discreteAverage)) { $0.spo2 = Self.finite($1 * 100, in: 0...100) }
        merge(try await collect(.respiratoryRate, unit: HKUnit.count().unitDivided(by: .minute()), start: start, end: end, op: .discreteAverage)) { $0.respRate = Self.finite($1, in: 1...100) }
        merge(try await collect(.stepCount, unit: .count(), start: start, end: end, op: .cumulativeSum)) { $0.steps = Self.finite($1, in: 0...10_000_000) }
        merge(try await collect(.activeEnergyBurned, unit: .kilocalorie(), start: start, end: end, op: .cumulativeSum)) { $0.activeKcal = Self.finite($1, in: 0...100_000) }
        merge(try await collect(.basalEnergyBurned, unit: .kilocalorie(), start: start, end: end, op: .cumulativeSum)) { $0.basalKcal = Self.finite($1, in: 0...100_000) }
        merge(try await collect(.vo2Max, unit: HKUnit(from: "ml/kg*min"), start: start, end: end, op: .discreteAverage)) { $0.vo2max = Self.finite($1, in: 5...150) }

        // Body composition — READ-ONLY import under the apple-health source (#20). Weight, lean mass
        // and BMI are point-in-time readings, so take the latest-of-day; body-fat reads fine as a
        // daily average. Body-fat HealthKit gives a 0…1 fraction, scaled to percent like spo2 above.
        merge(try await collect(.bodyMass, unit: .gramUnit(with: .kilo), start: start, end: end, op: .mostRecent)) { $0.weightKg = Self.finite($1, in: 20...500) }
        merge(try await collect(.bodyFatPercentage, unit: .percent(), start: start, end: end, op: .discreteAverage)) { $0.bodyFatPct = Self.finite($1 * 100, in: 1...80) }
        merge(try await collect(.leanBodyMass, unit: .gramUnit(with: .kilo), start: start, end: end, op: .mostRecent)) { $0.leanMassKg = Self.finite($1, in: 10...300) }
        merge(try await collect(.bodyMassIndex, unit: .count(), start: start, end: end, op: .mostRecent)) { $0.bmi = Self.finite($1, in: 10...80) }

        // Sleep minutes per day (asleep stages summed; attributed to wake day).
        for (day, sleep) in try await collectSleep(start: start, end: end) {
            var aggregate = byDay[day] ?? DayAgg()
            aggregate.asleepMin = sleep.asleepMin
            aggregate.deepMin = sleep.deepMin
            aggregate.remMin = sleep.remMin
            aggregate.coreMin = sleep.coreMin
            byDay[day] = aggregate
        }

        // Build + upsert the store rows under the apple-health source.
        let appleRows = byDay.map { (day, a) in
            AppleDaily(day: day, steps: a.steps.flatMap { Self.roundedInt($0, in: 0...10_000_000) },
                       activeKcal: a.activeKcal, basalKcal: a.basalKcal, vo2max: a.vo2max,
                       avgHr: a.avgHr.flatMap { Self.roundedInt($0, in: 20...300) }, maxHr: a.maxHr.flatMap { Self.roundedInt($0, in: 20...300) },
                       walkingHr: nil, weightKg: a.weightKg)
        }
        let dmRows = byDay.map { (day, a) in
            DailyMetric(day: day, totalSleepMin: a.asleepMin, efficiency: nil,
                        deepMin: a.deepMin, remMin: a.remMin, lightMin: a.coreMin, disturbances: nil,
                        restingHr: a.restingHr.flatMap { Self.roundedInt($0, in: 20...300) }, avgHrv: a.hrv,
                        recovery: nil, strain: nil, exerciseCount: nil,
                        spo2Pct: a.spo2, skinTempDevC: nil, respRateBpm: a.respRate)
        }
        // Flatten to the generic metricSeries the shared Apple Health screen, the Today apple-health
        // sparklines, and the Metric Explorer read from — repo.series(key:source:"apple-health")
        // queries ONLY metricSeries, so without this every tile/chart renders "—" after a successful
        // sync. Reuse the importer's canonical key mapping so the keys match the macOS path exactly.
        // Body composition (weight/body_fat/lean_mass/bmi) now reads live on iOS (#20) and flows
        // through the same metricPoints keys as the file importer. iOS still doesn't collect
        // awake/in-bed minutes, so those stay nil and emit no points — correct.
        let aggregates = byDay.map { (day, a) in
            AppleDailyAggregate(
                day: day,
                restingHr: a.restingHr,
                hrvSDNN: a.hrv,
                spo2Pct: a.spo2,
                respRate: a.respRate,
                avgHr: a.avgHr,
                maxHr: a.maxHr,
                steps: a.steps,
                activeKcal: a.activeKcal,
                basalKcal: a.basalKcal,
                vo2max: a.vo2max,
                weightKg: a.weightKg,
                bodyFatPct: a.bodyFatPct,
                leanMassKg: a.leanMassKg,
                bmi: a.bmi,
                asleepMin: a.asleepMin,
                deepMin: a.deepMin,
                remMin: a.remMin,
                coreMin: a.coreMin
            )
        }
        let points = AppleHealthAggregator.metricPoints(aggregates)
            .map { MetricPoint(day: $0.day, key: $0.key, value: $0.value) }

        // Workouts the user logged in Apple Health (Apple Watch rings, gym apps, etc.). macOS already
        // imports these from a static Health export and Android reads them from Health Connect; iOS now
        // reads them live on-device too, so the platforms reach parity. ON-DEVICE ONLY: this is a plain
        // HealthKit read of workouts NOOP did NOT author, never any cloud/3rd-party API. (#835)
        // The queried window is authoritative. First replace daily projections and retract the entire
        // Apple-workout range (an empty query is meaningful), then stream bounded workout batches back in.
        // The pending-window journal remains uncleared until every batch succeeds, so a kill between
        // batches reruns the same idempotent replacement instead of leaving a committed partial import.
            try await store.replaceAppleHealthRange(
                appleDaily: appleRows,
                dailyMetrics: dmRows,
                metricPoints: points,
                workouts: [],
                deviceId: appleDeviceId,
                fromDay: Self.dayString(start),
                toDay: Self.dayString(end),
                fromTimestamp: Int(start.timeIntervalSince1970),
                toTimestamp: Int(end.timeIntervalSince1970),
                workoutSource: Self.appleWorkoutSource
            )
            try await streamWorkouts(start: start, end: end) { rows in
                guard !rows.isEmpty else { return }
                _ = try await store.upsertWorkouts(rows, deviceId: appleDeviceId)
            }
            // Inbound Health data is already durably committed. Outbound mirroring is a separate,
            // best-effort side effect and must never keep the import journal alive or prevent the scoring
            // coordinator from publishing Recovery. Per-component writeback fingerprints retain only
            // successful exports, so the next ordinary sync retries any failed component idempotently.
            do {
                try await writeBack(whoopStore: store)
                lastError = nil
            } catch {
                lastError = String(localized: "Apple Health data imported; write-back will retry: \(error.localizedDescription)")
            }
            lastSync = Date()
            return true
        } catch {
            lastError = String(localized: "Apple Health sync failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Write back (NOOP → Health)

    /// Write NOOP's strap-derived data into Apple Health: sleep sessions with full stage segments,
    /// the continuous 1-minute heart-rate stream, strap/manual workouts, and the nightly vitals
    /// (resting HR, HRV, SpO₂, respiratory rate) stamped at that day's wake time.
    ///
    /// Each feature saves independently and guards on ITS OWN type's share status, so one declined
    /// Health checkbox (or a save error) skips that feature without sinking the rest; the first error
    /// is rethrown at the end so `sync` still surfaces it in `lastError` without advancing `lastSync`.
    ///
    /// Dedup model (vitals): each emitted sample carries a deterministic `HKMetadataKeyExternalUUID`
    /// from `noopDeviceId + metric + day`. Before saving, we delete any of *our* prior samples that
    /// carry the same key (scoped to `HKSource.default()` so we never touch another app's data) and
    /// then save the fresh batch. HealthKit assigns a new UUID per save, so the previous strategy
    /// (no metadata, no delete) flooded Health with duplicates on every `sync()`.
    ///
    /// Throws on save failure so the caller can decide whether to advance `lastSync`.
    private func writeBack(whoopStore: WhoopStore, days: Int = 14) async throws {
        guard auth == .authorized else { return }
        let importedIds = repo.importedReadIds
        let computedIds = repo.computedReadIds
        try await TargetScopedPipelineFence.shared.withLeases(
            sourceIds: importedIds + computedIds
        ) { [weak self] in
            guard let self else { return }
            try await self.writeBackFenced(
                whoopStore: whoopStore,
                days: days,
                importedIds: importedIds,
                computedIds: computedIds)
        }
    }

    private func writeBackFenced(
        whoopStore: WhoopStore,
        days: Int,
        importedIds: [String],
        computedIds: [String]
    ) async throws {
        let now = Date()
        guard let fromDate = Calendar.current.date(byAdding: .day, value: -days, to: now) else { return }
        let fromTs = Int(fromDate.timeIntervalSince1970)
        let nowTs = Int(now.timeIntervalSince1970)

        let sessions = try await HealthKitWritebackPlanner.sleepSessions(
            store: whoopStore, importedIds: importedIds, computedIds: computedIds,
            from: fromTs, to: nowTs)

        var firstError: Error?
        func attempt(_ op: () async throws -> Void) async {
            do { try await op() } catch { if firstError == nil { firstError = error } }
        }
        await attempt {
            try await writeVitals(whoopStore: whoopStore, days: days, sessions: sessions,
                                  importedIds: importedIds, computedIds: computedIds)
        }
        await attempt { try await writeSleep(sessions: sessions) }
        await attempt {
            try await writeHeartRate(whoopStore: whoopStore, importedIds: importedIds,
                                     fromTs: fromTs, nowTs: nowTs)
        }
        await attempt {
            try await writeWorkouts(whoopStore: whoopStore, importedIds: importedIds,
                                    computedIds: computedIds, fromTs: fromTs, toTs: nowTs)
        }
        if let firstError { throw firstError }
    }

    /// The nightly vitals write (the original write-back), now stamped at the day's wake time when
    /// that day has a sleep session — a real timestamp inside the night the value describes, instead
    /// of a fabricated noon. Keys are unchanged, so re-stamped samples replace their noon ancestors.
    private func writeVitals(whoopStore: WhoopStore, days: Int, sessions: [CachedSleepSession],
                             importedIds: [String], computedIds: [String],
                             dayKeys: Set<String>? = nil) async throws {
        let cal = Calendar.current
        let from: String
        let to: String
        if let dayKeys, let first = dayKeys.min(), let last = dayKeys.max() {
            from = first
            to = last
        } else {
            to = HealthKitBridge.dayString(Date())
            guard let fromDate = cal.date(byAdding: .day, value: -days, to: Date()) else { return }
            from = HealthKitBridge.dayString(fromDate)
        }

        // day (of wake) → wake instant. Ascending session order means the latest wake of a day wins,
        // matching collectSleep's end-date day attribution.
        var wakeByDay: [String: Date] = [:]
        for s in sessions where s.endTs > s.effectiveStartTs {
            let wake = Date(timeIntervalSince1970: TimeInterval(s.endTs))
            wakeByDay[HealthKitBridge.dayString(wake)] = wake
        }
        let rows = try await HealthKitWritebackPlanner.dailyMetrics(
            store: whoopStore, importedIds: importedIds, computedIds: computedIds,
            from: from, to: to
        ).filter { row in
            dayKeys?.contains(row.day) ?? true
        }

        struct Candidate {
            let type: HKQuantityType
            let key: String
            let value: Double
            let at: Date
            let sample: HKQuantitySample
        }
        var candidates: [Candidate] = []
        func add(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ value: Double, _ day: String, _ at: Date) {
            guard let type = HKQuantityType.quantityType(forIdentifier: id),
                  store.authorizationStatus(for: type) == .sharingAuthorized else { return }
            let key = "noop:\(noopDeviceId):\(id.rawValue):\(day)"
            let sample = HKQuantitySample(
                type: type,
                quantity: .init(unit: unit, doubleValue: value),
                start: at, end: at,
                metadata: [HKMetadataKeyExternalUUID: key]
            )
            candidates.append(Candidate(type: type, key: key, value: value, at: at, sample: sample))
        }

        for row in rows {
            guard let date = HealthKitBridge.date(from: row.day) else { continue }
            let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
            let at = wakeByDay[row.day] ?? noon
            if let rhr = row.restingHr {
                add(.restingHeartRate, HKUnit.count().unitDivided(by: .minute()), Double(rhr), row.day, at)
            }
            if let hrv = row.avgHrv {
                add(.heartRateVariabilitySDNN, .secondUnit(with: .milli), hrv, row.day, at)
            }
            if let spo2 = row.spo2Pct {
                add(.oxygenSaturation, .percent(), spo2 / 100, row.day, at)
            }
            if let rr = row.respRateBpm {
                add(.respiratoryRate, HKUnit.count().unitDivided(by: .minute()), rr, row.day, at)
            }
        }
        guard !candidates.isEmpty else { return }
        let fingerprint = HealthKitWritebackFingerprint.fingerprint(
            candidates.sorted { $0.key < $1.key }.map {
                "\($0.key)|\($0.value)|\(Int($0.at.timeIntervalSince1970))"
            })
        guard HealthKitWritebackFingerprint.shouldWrite(.vitals, fingerprint: fingerprint) else { return }

        // Delete any of OUR prior samples that carry the same metadata keys, then write the fresh
        // batch. Scoped to HKSource.default() so we never touch a sample written by another app
        // that happens to use the same external UUID. Delete failures are non-fatal (e.g., nothing
        // to delete on first run) — only the save throws.
        let bySource = HKQuery.predicateForObjects(from: HKSource.default())
        let grouped = Dictionary(grouping: candidates, by: { $0.type })
        for (type, items) in grouped {
            let keys = Array(Set(items.map { $0.key }))
            let byKey = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID,
                                                    allowedValues: keys)
            let pred = NSCompoundPredicate(andPredicateWithSubpredicates: [bySource, byKey])
            _ = try await self.store.deleteObjects(of: type, predicate: pred)
        }
        try await self.store.save(candidates.map { $0.sample })
        HealthKitWritebackFingerprint.markSuccess(.vitals, fingerprint: fingerprint)
    }

    /// Write each BRIDGED NIGHT (#364) as one `.inBed` sample plus one category sample per stage
    /// segment (`deep → .asleepDeep`, `rem → .asleepREM`, `light → .asleepCore`, `wake → .awake`) —
    /// the same shape Oura and Apple Watch write, so Health renders the full hypnogram. A night the
    /// detector split on a brief mid-night wake exports as ONE entry whose gap is an explicit
    /// `.awake` segment (grouped by `SleepStageTotals.bridgedNightGroups`, the SAME bridge the daily
    /// totals score with, #561); naps never bridge and stay their own entries. Fragments whose
    /// `stagesJSON` carries no timing (the legacy aggregate-minutes shapes) get one honest
    /// `.asleepUnspecified` block instead of fabricated stage placement.
    ///
    /// Dedup: every sample of a night carries `HKMetadataKeyExternalUUID =
    /// noop:<deviceId>:sleep:<startTs>` keyed by the group's EARLIEST fragment's immutable detected
    /// onset (a user edit moves the span, never the key). The delete predicate carries EVERY
    /// fragment's key, so a night previously written as two entries fully clears when it becomes
    /// one; delete-then-write scoped to our own `HKSource`, like the vitals.
    private func writeSleep(sessions: [CachedSleepSession]) async throws {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis),
              store.authorizationStatus(for: type) == .sharingAuthorized else { return }
        let blocks = sessions.map { SleepStageTotals.NightBlock(start: $0.effectiveStartTs, end: $0.endTs) }
        let groups = SleepStageTotals.bridgedNightGroups(blocks, offsetSec: TimeZone.current.secondsFromGMT())
            .map { g in
                g.indices.map { i -> HealthWriteback.SleepFragment in
                    let s = sessions[i]
                    return .init(startTs: s.startTs, effectiveStartTs: s.effectiveStartTs,
                                 endTs: s.endTs, stagesJSON: s.stagesJSON)
                }
            }
        let plan = HealthWriteback.mergedSleepPlan(groups: groups)
        let fingerprint = HealthKitWritebackFingerprint.fingerprint(plan.flatMap { entry in
            ["night|\(entry.keyStartTs)|\(entry.spanStart)|\(entry.spanEnd)"]
                + entry.intervals.map { "stage|\($0.kind)|\($0.start)|\($0.end)" }
        })
        guard HealthKitWritebackFingerprint.shouldWrite(.sleep, fingerprint: fingerprint) else { return }
        var samples: [HKCategorySample] = []
        var keys: [String] = []
        for entry in plan {
            let key = "noop:\(noopDeviceId):sleep:\(entry.keyStartTs)"
            let meta = [HKMetadataKeyExternalUUID: key]
            keys.append(contentsOf: entry.allKeyStartTs.map { "noop:\(noopDeviceId):sleep:\($0)" })
            samples.append(HKCategorySample(type: type, value: HKCategoryValueSleepAnalysis.inBed.rawValue,
                                            start: Date(timeIntervalSince1970: TimeInterval(entry.spanStart)),
                                            end: Date(timeIntervalSince1970: TimeInterval(entry.spanEnd)),
                                            metadata: meta))
            for seg in entry.intervals {
                let value: HKCategoryValueSleepAnalysis
                switch seg.kind {
                case .awake:       value = .awake
                case .light:       value = .asleepCore
                case .deep:        value = .asleepDeep
                case .rem:         value = .asleepREM
                case .unspecified: value = .asleepUnspecified
                }
                samples.append(HKCategorySample(
                    type: type, value: value.rawValue,
                    start: Date(timeIntervalSince1970: TimeInterval(seg.start)),
                    end: Date(timeIntervalSince1970: TimeInterval(seg.end)),
                    metadata: meta))
            }
        }
        guard !samples.isEmpty else { return }
        let pred = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: HKSource.default()),
            HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID, allowedValues: keys),
        ])
        _ = try await store.deleteObjects(of: type, predicate: pred)
        try await store.save(samples)
        HealthKitWritebackFingerprint.markSuccess(.sleep, fingerprint: fingerprint)
    }

    /// Per-real-source cursor. A newly active/re-paired strap has a fresh key and therefore backfills
    /// instead of inheriting the canonical source's cursor.
    private func hrWriteCursorKey(for sourceId: String) -> String {
        "hkHRWriteCursor.v2.\(sourceId)"
    }

    /// Write the strap's continuous heart rate as 1-minute mean samples — the same `hrBuckets` SQL
    /// the charts read (measured-first, PPG fallback), so Health sees exactly what NOOP plots. Raw
    /// ~1 Hz is deliberately downsampled: a fully-worn day is ~86k samples, which bloats the Health
    /// store; 1/min matches Apple Watch's background cadence.
    ///
    /// Dedup: forward-only cursor plus a 48 h rewrite window. Each run deletes OUR OWN prior HR
    /// samples in `[windowStart, now]` (source-scoped, date-range predicate — far cheaper than per-
    /// sample external-UUID keys at this volume) and rewrites the window, so a strap offload that
    /// backfills a recent night reconciles. Offloads older than 48 h behind the cursor are missed
    /// until the cursor is cleared — accepted trade-off for not re-walking 14 days every sync.
    private func writeHeartRate(whoopStore: WhoopStore, importedIds: [String],
                                fromTs: Int, nowTs: Int) async throws {
        guard let type = HKQuantityType.quantityType(forIdentifier: .heartRate),
              store.authorizationStatus(for: type) == .sharingAuthorized else { return }
        var cursors: [String: Int] = [:]
        var fromById: [String: Int] = [:]
        for id in importedIds {
            let cursor = UserDefaults.standard.integer(forKey: hrWriteCursorKey(for: id))
            cursors[id] = cursor
            fromById[id] = cursor > 0 ? max(fromTs, cursor - 48 * 3600) : fromTs
        }
        let sourced = try await HealthKitWritebackPlanner.heartRateBuckets(
            store: whoopStore, importedIds: importedIds, fromById: fromById, to: nowTs)
        guard !sourced.isEmpty else { return }
        let fingerprint = HealthKitWritebackFingerprint.fingerprint(sourced.map {
            "\($0.sourceId)|\($0.bucket.ts)|\($0.bucket.bpm)"
        })
        guard HealthKitWritebackFingerprint.shouldWrite(.heartRate, fingerprint: fingerprint) else { return }
        let windowStart = fromById.values.min() ?? fromTs

        let pred = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: HKSource.default()),
            HKQuery.predicateForSamples(withStart: Date(timeIntervalSince1970: TimeInterval(windowStart)),
                                        end: Date(timeIntervalSince1970: TimeInterval(nowTs) + 60),
                                        options: []),
        ])
        _ = try await store.deleteObjects(of: type, predicate: pred)

        let unit = HKUnit.count().unitDivided(by: .minute())
        var samples: [HKQuantitySample] = []
        samples.reserveCapacity(sourced.count)
        for item in sourced {
            let b = item.bucket
            let start = Date(timeIntervalSince1970: TimeInterval(b.ts))
            // Span the bucket, clamped so a bucket at the window edge can't end in the future
            // (HealthKit rejects future-dated samples).
            let end = Date(timeIntervalSince1970: TimeInterval(min(b.ts + 60, nowTs)))
            samples.append(HKQuantitySample(type: type,
                                            quantity: .init(unit: unit, doubleValue: b.bpm),
                                            start: start, end: max(start, end)))
        }
        // First run backfills ~20k samples (14 d × 1440/day); chunk the saves so no single HealthKit
        // transaction is oversized. Cursor only advances past what actually saved.
        var savedThroughById = cursors
        var pending = samples[...]
        var pendingRows = sourced[...]
        while !pending.isEmpty {
            let chunk = Array(pending.prefix(5000))
            let chunkRows = Array(pendingRows.prefix(5000))
            pending = pending.dropFirst(chunk.count)
            pendingRows = pendingRows.dropFirst(chunk.count)
            try await store.save(chunk)
            for row in chunkRows {
                savedThroughById[row.sourceId] = max(savedThroughById[row.sourceId] ?? 0, row.bucket.ts)
            }
            for (id, cursor) in savedThroughById where cursor > 0 {
                UserDefaults.standard.set(cursor, forKey: hrWriteCursorKey(for: id))
            }
        }
        HealthKitWritebackFingerprint.markSuccess(.heartRate, fingerprint: fingerprint)
    }

    /// Write strap-detected and manual workouts into Health via `HKWorkoutBuilder`, with an
    /// `activeEnergyBurned` sample when the row has energy and a distance sample for distance
    /// sports. Workouts whose source is `apple-health` are EXCLUDED — those were imported FROM
    /// Health, and writing them back would duplicate the user's own Apple Watch/gym-app workouts.
    ///
    /// Dedup: `HKMetadataKeyExternalUUID = noop:<deviceId>:workout:<startTs>` in the workout
    /// metadata; delete-then-write scoped to our own source, like sleep and the vitals.
    private func writeWorkouts(whoopStore: WhoopStore, importedIds: [String], computedIds: [String],
                               fromTs: Int, toTs: Int, limit: Int = 500) async throws {
        guard store.authorizationStatus(for: .workoutType()) == .sharingAuthorized else { return }
        let rows = try await HealthKitWritebackPlanner.workouts(
            store: whoopStore, importedIds: importedIds, computedIds: computedIds,
            from: fromTs, to: toTs, limit: limit, excludingSource: HealthKitBridge.appleWorkoutSource)
        guard !rows.isEmpty else { return }
        let fingerprint = HealthKitWritebackFingerprint.fingerprint(rows.map {
            "\($0.startTs)|\($0.endTs)|\($0.sport)|\($0.energyKcal ?? -1)|\($0.distanceM ?? -1)"
        })
        guard HealthKitWritebackFingerprint.shouldWrite(.workouts, fingerprint: fingerprint) else { return }

        func key(_ row: WorkoutRow) -> String { "noop:\(noopDeviceId):workout:\(row.startTs)" }
        let pred = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: HKSource.default()),
            HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID,
                                        allowedValues: rows.map(key)),
        ])
        _ = try await store.deleteObjects(of: .workoutType(), predicate: pred)

        for row in rows {
            let start = Date(timeIntervalSince1970: TimeInterval(row.startTs))
            let end = Date(timeIntervalSince1970: TimeInterval(row.endTs))
            guard end > start else { continue }
            let config = HKWorkoutConfiguration()
            config.activityType = Self.activityType(forSport: row.sport)
            let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())
            do {
                try await builder.beginCollection(at: start)
                try await builder.addMetadata([HKMetadataKeyExternalUUID: key(row)])
                var extras: [HKSample] = []
                if let kcal = row.energyKcal, kcal > 0,
                   let t = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned),
                   store.authorizationStatus(for: t) == .sharingAuthorized {
                    extras.append(HKQuantitySample(type: t, quantity: .init(unit: .kilocalorie(), doubleValue: kcal),
                                                   start: start, end: end))
                }
                if let meters = row.distanceM, meters > 0,
                   let id = Self.distanceTypeId(forSport: row.sport),
                   let t = HKQuantityType.quantityType(forIdentifier: id),
                   store.authorizationStatus(for: t) == .sharingAuthorized {
                    extras.append(HKQuantitySample(type: t, quantity: .init(unit: .meter(), doubleValue: meters),
                                                   start: start, end: end))
                }
                if !extras.isEmpty { try await builder.addSamples(extras) }
                try await builder.endCollection(at: end)
                _ = try await builder.finishWorkout()
            } catch {
                builder.discardWorkout()
                throw error
            }
        }
        HealthKitWritebackFingerprint.markSuccess(.workouts, fingerprint: fingerprint)
    }

    /// Reverse of `sportName`: NOOP's sport label → the `HKWorkoutActivityType` written to Health.
    /// Labels the forward map collapses (e.g. boxing/kickboxing → "Boxing") reverse to the first
    /// member; unknown labels fall back to `.other`, never dropped.
    private static func activityType(forSport sport: String) -> HKWorkoutActivityType {
        if sport == LiftingImporter.sport { return .traditionalStrengthTraining }
        switch sport.lowercased() {
        case "running":       return .running
        case "walking":       return .walking
        case "hiking":        return .hiking
        case "cycling":       return .cycling
        case "hiit":          return .highIntensityIntervalTraining
        case "core training": return .coreTraining
        case "yoga":          return .yoga
        case "pilates":       return .pilates
        case "rowing":        return .rowing
        case "elliptical":    return .elliptical
        case "stairs":        return .stairClimbing
        case "jump rope":     return .jumpRope
        case "boxing":        return .boxing
        case "basketball":    return .basketball
        case "soccer":        return .soccer
        case "football":      return .americanFootball
        case "baseball":      return .baseball
        case "badminton":     return .badminton
        case "tennis":        return .tennis
        case "table tennis":  return .tableTennis
        case "volleyball":    return .volleyball
        case "squash":        return .squash
        case "martial arts":  return .martialArts
        case "dancing":       return .socialDance
        case "golf":          return .golf
        case "climbing":      return .climbing
        case "skiing":        return .downhillSkiing
        case "snowboarding":  return .snowboarding
        case "swimming":      return .swimming
        case "surfing":       return .surfingSports
        case "paddling":      return .paddleSports
        default:              return .other
        }
    }

    /// Which distance quantity a sport's `distanceM` maps to; nil for sports whose Health distance
    /// type NOOP doesn't request share access for (e.g. swimming).
    private static func distanceTypeId(forSport sport: String) -> HKQuantityTypeIdentifier? {
        switch sport.lowercased() {
        case "running", "walking", "hiking": return .distanceWalkingRunning
        case "cycling":                      return .distanceCycling
        default:                             return nil
        }
    }

    private struct DayAgg {
        var restingHr: Double?; var avgHr: Double?; var maxHr: Double?; var hrv: Double?
        var spo2: Double?; var respRate: Double?; var steps: Double?
        var activeKcal: Double?; var basalKcal: Double?; var vo2max: Double?
        var weightKg: Double?; var bodyFatPct: Double?; var leanMassKg: Double?; var bmi: Double?
        var asleepMin: Double?; var deepMin: Double?; var remMin: Double?; var coreMin: Double?
    }

    /// HealthKit is an input boundary: third-party writers can store absurd but finite values. Keep
    /// conversions exact and domain-aware so a malformed quantity cannot trap an `Int` conversion or
    /// poison the local Apple Health projection.
    private static func finite(_ value: Double, in domain: ClosedRange<Double>) -> Double? {
        guard value.isFinite, domain.contains(value) else { return nil }
        return value
    }

    private static func roundedInt(_ value: Double, in domain: ClosedRange<Int>) -> Int? {
        guard value.isFinite,
              let integer = Int(exactly: value.rounded()),
              domain.contains(integer)
        else { return nil }
        return integer
    }

    private struct SleepDayAgg: Sendable {
        var asleepMin: Double?
        var deepMin: Double?
        var remMin: Double?
        var coreMin: Double?
    }

    /// Excludes NOOP's own write-back samples from reads, so the two-way sync never reads its own
    /// output back in as "apple-health" data — which would make the strap and "Apple Health" plot the
    /// same line for a strap-only user, and bias the apple-health average for someone who also has a
    /// watch. `HKSource.default()` is this app's own source. (Reimplemented from @vulnix0x4's PR #375.)
    private static var notNoopAuthored: NSPredicate {
        NSCompoundPredicate(notPredicateWithSubpredicate: HKQuery.predicateForObjects(from: [HKSource.default()]))
    }

    private func collect(_ id: HKQuantityTypeIdentifier, unit: HKUnit, start: Date, end: Date,
                         op: HKStatisticsOptions) async throws -> [String: Double] {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return [:] }
        let cal = Calendar.current
        let anchor = cal.startOfDay(for: start)
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate),
            Self.notNoopAuthored,
        ])
        return try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<[String: Double], Error>) in
            let q = HKStatisticsCollectionQuery(quantityType: type, quantitySamplePredicate: predicate,
                                                options: op, anchorDate: anchor,
                                                intervalComponents: DateComponents(day: 1))
            q.initialResultsHandler = { _, results, error in
                if let error { cont.resume(throwing: error); return }
                var values: [String: Double] = [:]
                results?.enumerateStatistics(from: start, to: end) { stats, _ in
                    let q: HKQuantity?
                    switch op {
                    case .cumulativeSum:     q = stats.sumQuantity()
                    case .discreteAverage:   q = stats.averageQuantity()
                    case .discreteMax:       q = stats.maximumQuantity()
                    case .mostRecent: q = stats.mostRecentQuantity()
                    default:                 q = stats.averageQuantity()
                    }
                    if let q {
                        values[HealthKitBridge.dayString(stats.startDate)] = q.doubleValue(for: unit)
                    }
                }
                cont.resume(returning: values)
            }
            store.execute(q)
        }
    }

    /// Live HealthKit import owns daily Apple projections and Apple workouts only. It deliberately never
    /// writes `sleepSession` under `apple-health`; those rows remain static-import/strap-owned and therefore
    /// are not claimed by this authoritative live replacement transaction. Reconciles one civil day at a
    /// time so an unknown deletion spanning years cannot materialize the whole library in memory.
    private static let historyQueryChunkDays = 1

    private func queryWindows(start: Date, end: Date) -> [(start: Date, end: Date)] {
        guard start < end else { return [] }
        var result: [(start: Date, end: Date)] = []
        var cursor = start
        let calendar = Calendar.current
        while cursor < end {
            let next = calendar.date(byAdding: .day, value: Self.historyQueryChunkDays, to: cursor) ?? end
            let boundary = min(next, end)
            result.append((cursor, boundary))
            cursor = boundary
        }
        return result
    }

    private func collectSleep(start: Date, end: Date) async throws -> [String: SleepDayAgg] {
        var merged: [String: SleepDayAgg] = [:]
        for (index, window) in queryWindows(start: start, end: end).enumerated() {
            let chunk = try await collectSleepChunk(
                start: window.start,
                end: window.end,
                includesLeadingOverlap: index == 0
            )
            for (day, value) in chunk {
                var total = merged[day] ?? SleepDayAgg(asleepMin: nil, deepMin: nil, remMin: nil, coreMin: nil)
                total.asleepMin = Self.boundedSleepSum(total.asleepMin, value.asleepMin)
                total.deepMin = Self.boundedSleepSum(total.deepMin, value.deepMin)
                total.remMin = Self.boundedSleepSum(total.remMin, value.remMin)
                total.coreMin = Self.boundedSleepSum(total.coreMin, value.coreMin)
                merged[day] = total
            }
        }
        return merged
    }

    private static func boundedSleepSum(_ lhs: Double?, _ rhs: Double?) -> Double? {
        switch (lhs, rhs) {
        case (nil, nil): return nil
        case (let value?, nil), (nil, let value?): return value
        case (let lhs?, let rhs?):
            let sum = lhs + rhs
            return sum.isFinite ? min(sum, 24 * 60) : nil
        }
    }

    private func collectSleepChunk(
        start: Date,
        end: Date,
        includesLeadingOverlap: Bool
    ) async throws -> [String: SleepDayAgg] {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return [:] }
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(
                withStart: start,
                end: end,
                options: includesLeadingOverlap ? [] : .strictStartDate
            ),
            Self.notNoopAuthored,
        ])
        return try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<[String: SleepDayAgg], Error>) in
            let q = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error { cont.resume(throwing: error); return }
                var asleep: [String: Double] = [:], deep: [String: Double] = [:]
                var rem: [String: Double] = [:], core: [String: Double] = [:]
                for case let s as HKCategorySample in samples ?? [] {
                    let mins = s.endDate.timeIntervalSince(s.startDate) / 60
                    guard mins.isFinite, mins > 0, mins <= 24 * 60 else { continue }
                    let day = HealthKitBridge.dayString(s.endDate)
                    switch s.value {
                    case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:
                        deep[day, default: 0] += mins; asleep[day, default: 0] += mins
                    case HKCategoryValueSleepAnalysis.asleepREM.rawValue:
                        rem[day, default: 0] += mins; asleep[day, default: 0] += mins
                    case HKCategoryValueSleepAnalysis.asleepCore.rawValue, HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue:
                        core[day, default: 0] += mins; asleep[day, default: 0] += mins
                    default:
                        break
                    }
                }
                let values = Dictionary(uniqueKeysWithValues: Set(asleep.keys).map { day in
                    (day, SleepDayAgg(asleepMin: asleep[day], deepMin: deep[day],
                                      remMin: rem[day], coreMin: core[day]))
                })
                cont.resume(returning: values)
            }
            store.execute(q)
        }
    }

    // MARK: - Workouts (#835)

    /// Read the workouts the user logged in Apple Health over `[start, end)` and map each to a
    /// `WorkoutRow` under the apple-health source. ON-DEVICE ONLY: a straight HealthKit `HKWorkout` query,
    /// no cloud or third-party API. NOOP-authored workouts are excluded (the same `notNoopAuthored`
    /// predicate the metric reads use) so our own write-back never re-imports as "Apple Health". Mirrors
    /// the macOS export importer and the Android Health Connect importer, which already ingest workouts,
    /// closing the iOS gap. The upsert is idempotent on (deviceId, startTs), so re-running a sync window
    /// refreshes rather than duplicates.
    /// Streams bounded one-day workout batches after the caller retracts the authoritative range. This
    /// avoids retaining every historical HealthKit workout before the replacement transaction begins.
    private func streamWorkouts(
        start: Date,
        end: Date,
        consume: ([WorkoutRow]) async throws -> Void
    ) async throws {
        for (index, window) in queryWindows(start: start, end: end).enumerated() {
            let rows = try await collectWorkoutChunk(
                start: window.start,
                end: window.end,
                includesLeadingOverlap: index == 0
            )
            try await consume(rows)
        }
    }

    private func collectWorkoutChunk(
        start: Date,
        end: Date,
        includesLeadingOverlap: Bool
    ) async throws -> [WorkoutRow] {
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(
                withStart: start,
                end: end,
                options: includesLeadingOverlap ? [] : .strictStartDate
            ),
            Self.notNoopAuthored,
        ])
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[WorkoutRow], Error>) in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let q = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, error in
                if let error { cont.resume(throwing: error); return }
                var rows: [WorkoutRow] = []
                for case let workout as HKWorkout in samples ?? [] {
                    let startTs = Int(workout.startDate.timeIntervalSince1970)
                    let endTs = max(Int(workout.endDate.timeIntervalSince1970), startTs)
                    let duration = workout.duration > 0 ? workout.duration : Double(endTs - startTs)
                    rows.append(WorkoutRow(
                        startTs: startTs,
                        endTs: endTs,
                        sport: Self.sportName(workout.workoutActivityType),
                        source: HealthKitBridge.appleWorkoutSource,
                        durationS: duration,
                        energyKcal: workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()),
                        avgHr: nil,
                        maxHr: nil,
                        strain: nil,
                        distanceM: workout.totalDistance?.doubleValue(for: .meter()),
                        zonesJSON: nil,
                        notes: nil))
                }
                cont.resume(returning: rows)
            }
            store.execute(q)
        }
    }

    /// Source tag stamped on workouts imported from Apple Health. Matches the macOS importer's
    /// `WorkoutSource.appleHealthSource` ("apple-health") and `appleDeviceId`, so the workout list and
    /// source filters treat an iOS-read workout exactly like a macOS-imported one.
    nonisolated static let appleWorkoutSource = "apple-health"

    /// Map an `HKWorkoutActivityType` to NOOP's human sport label. Strength training routes to the
    /// shared lifting sport so a gym session lands in the Lifting lane; anything we don't name explicitly
    /// falls back to a generic "Workout" rather than an opaque numeric type.
    nonisolated private static func sportName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running:                    return "Running"
        case .walking:                    return "Walking"
        case .hiking:                     return "Hiking"
        case .cycling:                    return "Cycling"
        case .traditionalStrengthTraining,
             .functionalStrengthTraining: return LiftingImporter.sport
        case .highIntensityIntervalTraining: return "HIIT"
        case .coreTraining:               return "Core training"
        case .yoga:                       return "Yoga"
        case .pilates:                    return "Pilates"
        case .rowing:                     return "Rowing"
        case .elliptical:                 return "Elliptical"
        case .stairClimbing, .stairs:     return "Stairs"
        case .jumpRope:                   return "Jump rope"
        case .boxing, .kickboxing:        return "Boxing"
        case .basketball:                 return "Basketball"
        case .soccer:                     return "Soccer"
        case .americanFootball:           return "Football"
        case .baseball:                   return "Baseball"
        case .badminton:                  return "Badminton"
        case .tennis:                     return "Tennis"
        case .tableTennis:                return "Table tennis"
        case .volleyball:                 return "Volleyball"
        case .squash, .racquetball:       return "Squash"
        case .martialArts, .taiChi:       return "Martial arts"
        case .dance, .cardioDance, .socialDance: return "Dancing"
        case .golf:                       return "Golf"
        case .climbing:                   return "Climbing"
        case .downhillSkiing, .crossCountrySkiing: return "Skiing"
        case .snowboarding:               return "Snowboarding"
        case .swimming:                   return "Swimming"
        case .surfingSports:              return "Surfing"
        case .paddleSports:               return "Paddling"
        default:                          return "Workout"
        }
    }

    // MARK: - Entitlement detection (#348)

    /// True when this running build actually carries the `com.apple.developer.healthkit` entitlement —
    /// i.e. it can genuinely reach Apple Health. False for a free-Apple-ID / AltStore / Sideloadly
    /// re-sign, which strips the HealthKit capability: the framework links and `isHealthDataAvailable()`
    /// is still true, but `requestAuthorization` is a dead-end and the app can never appear under
    /// Settings › Health › Data Access & Devices.
    ///
    /// Resolution order (most authoritative first), mirroring `IOSDiagnostics`'s profile parse:
    ///  1. If an `embedded.mobileprovision` is present (every dev / sideloaded / TestFlight build ships
    ///     one), slice the wrapped XML plist and look for `com.apple.developer.healthkit` in its
    ///     `Entitlements` dict. A free re-sign re-writes this profile WITHOUT that key. This is the
    ///     definitive signal and is unaffected by whether the user later granted/denied permission.
    ///  2. No embedded profile → an App Store install (App Store strips it). Those are properly signed
    ///     with whatever capabilities the app declares, so treat the entitlement as PRESENT. This is the
    ///     conservative default: it never down-routes a legitimately-signed build, so a user who simply
    ///     denied permission keeps the normal Settings guidance rather than the file-import reroute.
    ///
    /// Computed once and cached: the bundle's profile can't change within a process lifetime.
    static let hasHealthKitEntitlement: Bool = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else {
            // No embedded profile = App Store build = properly signed. Assume present.
            return true
        }
        guard let xmlStart = data.range(of: Data("<?xml".utf8)),
              let xmlEnd = data.range(of: Data("</plist>".utf8)) else {
            // Profile present but unparseable — don't claim a missing entitlement off a parse failure;
            // assume present so we never wrongly down-route a real build.
            return true
        }
        let plistData = data.subdata(in: xmlStart.lowerBound..<xmlEnd.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else {
            return true
        }
        // The key is present (and truthy) on an entitled build; a free re-sign omits it entirely.
        return entitlements["com.apple.developer.healthkit"] != nil
    }()

    // MARK: - Date helpers

    // LOCAL civil day: the rest of the store keys days by the device-local civil day —
    // AppleHealthAggregator.localDay shifts each sample into its own offset, and
    // Repository.dayFormatter leaves timeZone at the default (local) zone. The
    // HKStatisticsCollectionQuery here already buckets in Calendar.current (anchor =
    // startOfDay, interval = 1 day), so labelling those local-midnight bucket starts with a
    // matching local formatter is strictly 1:1; using UTC instead mislabelled a full local day
    // under the previous UTC date for users east of UTC, so apple-health rows never merged with
    // the strap-computed/imported rows for the same civil day.
    // `nonisolated` so the HealthKit query completion handlers — which HealthKit invokes on a private
    // background queue (a nonisolated context) — can label day buckets without a main-actor-isolation
    // warning. They only read a thread-safe DateFormatter, so this is safe off the main actor.
    nonisolated private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone.current; return f
    }()
    nonisolated private static func dayString(_ date: Date) -> String { dayFormatter.string(from: date) }
    nonisolated private static func date(from day: String) -> Date? { dayFormatter.date(from: day) }
}
#endif
