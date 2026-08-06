import Foundation
import StrandDesign

/// Small, Codable glance snapshot shared between the iOS app and its widget/Live-Activity extension
/// via an App Group. The app writes it; the widget reads it. Keeping it tiny avoids any cross-process
/// database access — the widget never opens SQLite.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public var recovery: Int?    // Recovery (0–100)
    public var bpm: Int?
    public var batteryPct: Int?
    public var bonded: Bool
    public var updated: Date
    /// Durable identity of the verified projection that supplied the headline values.
    public var verifiedContextId: String?
    public var verifiedProjectionGeneration: Int64?
    // Richer glance fields (#446). All OPTIONAL with nil defaults so a snapshot written by an OLDER app
    // build (which never encoded these keys) still decodes — Codable fills a missing optional with nil.
    public var effort: Double?   // Strain on the canonical 0–21 display axis
    public var rest: Int?        // Sleep (sleep_performance) score, 0–100
    public var hrv: Int?         // HRV (ms), whole-number for the glance
    public var restingHr: Int?   // Resting heart rate (bpm)
    public var recoveryDelta: Int?
    public var sleepMinutes: Int?
    public var steps: Int?
    public var calories: Int?
    /// Twenty-four real hourly stress averages (0–3). nil elements are hours without evidence.
    public var hourlyStress: [Double?]?
    public var stressSummary: String?
    /// Recent HR points, bounded at the publication boundary so the App Group payload stays tiny.
    public var hrSparkline: [Int]?
    /// Recent daily HRV values for the rectangular Lock Screen accessory. Optional so snapshots
    /// written before component 41 continue decoding unchanged.
    public var hrvSparkline: [Int]?

    /// New code speaks Strain while preserving the serialized `effort` key for older snapshots.
    public var strain: Double? {
        get { effort }
        set { effort = newValue }
    }

    public init(recovery: Int?, bpm: Int?, batteryPct: Int?, bonded: Bool, updated: Date,
                effort: Double? = nil, rest: Int? = nil, hrv: Int? = nil, restingHr: Int? = nil,
                recoveryDelta: Int? = nil, sleepMinutes: Int? = nil, steps: Int? = nil,
                calories: Int? = nil, hourlyStress: [Double?]? = nil,
                stressSummary: String? = nil, hrSparkline: [Int]? = nil,
                hrvSparkline: [Int]? = nil,
                verifiedContextId: String? = nil,
                verifiedProjectionGeneration: Int64? = nil) {
        self.recovery = recovery
        self.bpm = bpm
        self.batteryPct = batteryPct
        self.bonded = bonded
        self.updated = updated
        self.verifiedContextId = verifiedContextId
        self.verifiedProjectionGeneration = verifiedProjectionGeneration
        self.effort = effort
        self.rest = rest
        self.hrv = hrv
        self.restingHr = restingHr
        self.recoveryDelta = recoveryDelta
        self.sleepMinutes = sleepMinutes
        self.steps = steps
        self.calories = calories
        self.hourlyStress = hourlyStress
        self.stressSummary = stressSummary
        self.hrSparkline = hrSparkline.map { Array($0.filter { (30...240).contains($0) }.suffix(48)) }
        self.hrvSparkline = hrvSparkline.map { Array($0.filter { (5...300).contains($0) }.suffix(12)) }
    }

    /// Canonical phone publication boundary for the three scores. Stored Strain is
    /// converted exactly once here; every widget consumer receives the 0–21 value.
    public static func publishing(
        recovery: Double?,
        storedStrain: Double?,
        sleepScore: Double?,
        bpm: Int?,
        batteryPct: Double?,
        bonded: Bool,
        hrv: Double?,
        restingHr: Int?,
        recoveryDelta: Int? = nil,
        sleepMinutes: Int? = nil,
        steps: Int? = nil,
        calories: Int? = nil,
        hourlyStress: [Double?]? = nil,
        stressSummary: String? = nil,
        hrSparkline: [Int]? = nil,
        hrvSparkline: [Int]? = nil,
        verifiedContextId: String? = nil,
        verifiedProjectionGeneration: Int64? = nil,
        updated: Date = Date()
    ) -> WidgetSnapshot {
        WidgetSnapshot(
            recovery: recovery.map { Int($0.rounded()) },
            bpm: bpm,
            batteryPct: batteryPct.map { Int($0.rounded()) },
            bonded: bonded,
            updated: updated,
            effort: storedStrain.map { StrainScale.displayValue(fromStored: $0) },
            rest: sleepScore.map { Int($0.rounded()) },
            hrv: hrv.map { Int($0.rounded()) },
            restingHr: restingHr,
            recoveryDelta: recoveryDelta,
            sleepMinutes: sleepMinutes,
            steps: steps,
            calories: calories,
            hourlyStress: hourlyStress,
            stressSummary: stressSummary,
            hrSparkline: hrSparkline,
            hrvSparkline: hrvSparkline,
            verifiedContextId: verifiedContextId,
            verifiedProjectionGeneration: verifiedProjectionGeneration
        )
    }

    /// Fast-lane update. It intentionally preserves every dashboard field from the last slow publish.
    public func mergingLive(bpm: Int?, batteryPct: Double?, bonded: Bool,
                            storedStrain: Double?, hrSparkline: [Int]? = nil,
                            updated: Date = Date()) -> WidgetSnapshot {
        var copy = self
        copy.bpm = bpm
        copy.batteryPct = batteryPct.map { Int($0.rounded()) }
        copy.bonded = bonded
        copy.updated = updated
        copy.strain = storedStrain.map { StrainScale.displayValue(fromStored: $0) }
        if let hrSparkline { copy.hrSparkline = Array(hrSparkline.filter { (30...240).contains($0) }.suffix(48)) }
        return copy
    }

    /// Compare everything a widget can render while deliberately ignoring the publication timestamp.
    /// Full refreshes often recompute an identical dashboard payload after an unrelated repository change;
    /// treating `updated` as content forced an App Group write + `reloadAllTimelines()` every time. Publishers
    /// use this equality with a bounded heartbeat so freshness can still advance without reload storms.
    public func hasSameRenderedContent(as other: WidgetSnapshot) -> Bool {
        var lhs = self
        var rhs = other
        lhs.updated = .distantPast
        rhs.updated = .distantPast
        return lhs == rhs
    }

    /// App Group suite the app and widget both use. Injected from the `APP_GROUP_ID` build setting
    /// (see project.yml) via the `AppGroupIdentifier` Info.plist key, so the value lives in exactly
    /// one place rather than being duplicated here. Must match the `com.apple.security.application-groups`
    /// entitlement on both targets (which also reads `$(APP_GROUP_ID)`). If the entitlement is missing on
    /// either side, `UserDefaults(suiteName:)` returns nil and every consumer (PendingIntents,
    /// WidgetSnapshot.publish, Live Activity) silently no-ops — see `assertGroupProvisioned` for the
    /// debug-time canary. The fallback is the canonical upstream group and only applies if the Info.plist
    /// key is somehow absent (each process reads its OWN bundle, so the app and the widget extension
    /// each carry the key in their generated Info.plist).
    public static let suiteName: String = {
        Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String
            ?? "group.com.noopapp.noop"
    }()
    public static let storageKey = "noop.widget.snapshot"

    /// Debug-only canary: trips on the first run after a misprovisioning so the silent no-op gets
    /// caught immediately rather than masquerading as "widget shows nothing yet." Release builds do
    /// nothing — App Store apps can't crash on a missing entitlement.
    public static func assertGroupProvisioned() {
        assert(UserDefaults(suiteName: suiteName) != nil,
               "App Group '\(suiteName)' not provisioned on this target — check the entitlement.")
    }

    public static var placeholder: WidgetSnapshot {
        WidgetSnapshot(recovery: 72, bpm: 58, batteryPct: 84, bonded: true, updated: Date(),
                       effort: 8, rest: 81, hrv: 64, restingHr: 52,
                       recoveryDelta: 6, sleepMinutes: 432, steps: 11_204, calories: 2_140,
                       hourlyStress: [0.4, 0.5, 0.4, 0.3, 0.3, 0.4, 0.6, 0.8, 1.1, 1.4, 1.7, 1.2,
                                      0.9, 1.1, 1.5, 1.8, 1.3, 0.8, 0.7, 0.9, 0.6, nil, nil, nil],
                       stressSummary: "Moderate · easing",
                       hrSparkline: [88, 94, 112, 125, 118, 139, 152, 145, 158, 149, 154],
                       hrvSparkline: [55, 58, 54, 61, 63, 60, 66, 64])
    }

    public static var empty: WidgetSnapshot {
        WidgetSnapshot(recovery: nil, bpm: nil, batteryPct: nil, bonded: false, updated: Date())
    }

    /// Read the last-published snapshot from the shared suite, if any.
    public static func load() -> WidgetSnapshot? {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: storageKey),
              let snap = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { return nil }
        return snap
    }

    /// Merge a matching live overlay only at read time. A nil or mismatched overlay leaves the verified
    /// snapshot untouched, so the widget cannot display live values under a different source identity.
    public static func loadForDisplay() -> WidgetSnapshot? {
        if let defaults = UserDefaults(suiteName: suiteName),
           let envelopeSnapshot = VerifiedWidgetEnvelopeStore.loadForDisplay(defaults: defaults) {
            return envelopeSnapshot
        }
        guard let verified = load() else { return nil }
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: ActiveVerifiedSinkEpochStore.widgetLiveOverlayKey),
              let overlay = try? JSONDecoder().decode(WidgetLiveOverlay.self, from: data),
              let active = ActiveVerifiedSinkEpochStore.activeToken(defaults: defaults),
              verified.verifiedContextId == overlay.contextId,
              verified.verifiedProjectionGeneration == overlay.generation,
              active.epoch == overlay.epoch,
              active.contextId == overlay.contextId else {
            return verified
        }
        var merged = verified
        merged.bpm = overlay.bpm
        merged.batteryPct = overlay.batteryPct
        merged.bonded = overlay.bonded
        merged.hrSparkline = overlay.hrSparkline
        merged.updated = overlay.updated
        return merged
    }

    /// Persist this snapshot into the shared suite. The result lets publishers avoid updating their
    /// in-process throttle cache or asking WidgetKit to reload when the App Group write could not happen.
    @discardableResult
    public func save() -> Bool {
        save(to: UserDefaults(suiteName: WidgetSnapshot.suiteName))
    }

    /// Test seam and shared implementation for `save()`. Internal so production callers always use the
    /// configured App Group while unit tests can supply an isolated defaults suite or nil failure case.
    @discardableResult
    func save(to defaults: UserDefaults?) -> Bool {
        guard let defaults, let data = try? JSONEncoder().encode(self) else { return false }
        defaults.set(data, forKey: WidgetSnapshot.storageKey)
        return true
    }

    @discardableResult
    public func saveAndReadBack(to defaults: UserDefaults?) -> Bool {
        guard let defaults, let data = try? JSONEncoder().encode(self) else { return false }
        defaults.set(data, forKey: Self.storageKey)
        guard let stored = defaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode(Self.self, from: stored) else { return false }
        return decoded == self
    }
}

/// Fast live values are an overlay, never a relabelled copy of the last verified snapshot. The exact
/// epoch/context/generation is checked again by the App Group sink before this record is written.
public struct WidgetLiveOverlay: Codable, Equatable, Sendable {
    public let epoch: UInt64
    public let contextId: String
    public let generation: Int64
    public let bpm: Int?
    public let batteryPct: Int?
    public let bonded: Bool
    public let hrSparkline: [Int]?
    public let updated: Date

    public init(
        epoch: UInt64,
        contextId: String,
        generation: Int64,
        bpm: Int?,
        batteryPct: Int?,
        bonded: Bool,
        hrSparkline: [Int]?,
        updated: Date
    ) {
        self.epoch = epoch
        self.contextId = contextId
        self.generation = generation
        self.bpm = bpm
        self.batteryPct = batteryPct
        self.bonded = bonded
        self.hrSparkline = hrSparkline.map { Array($0.filter { (30...240).contains($0) }.suffix(48)) }
        self.updated = updated
    }
}

extension WidgetSnapshot {
    /// Reject an older verified generation for the same context at the persisted App Group sink.
    public func acceptsVerifiedProjection(contextId: String, generation: Int64) -> Bool {
        guard let storedContext = verifiedContextId,
              let storedGeneration = verifiedProjectionGeneration,
              storedContext == contextId else {
            return true
        }
        return generation >= storedGeneration
    }
}
