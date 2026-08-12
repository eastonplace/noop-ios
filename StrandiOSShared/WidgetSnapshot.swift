import Foundation
import StrandDesign

/// Small, Codable glance snapshot shared between the iOS app and its widget/Live-Activity extension
/// via an App Group. The app writes it; the widget reads it. Keeping it tiny avoids any cross-process
/// database access — the widget never opens SQLite.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public var recovery: Int?
    public var bpm: Int?
    public var batteryPct: Int?
    public var bonded: Bool
    public var updated: Date
    public var verifiedContextId: String?
    public var verifiedProjectionGeneration: Int64?
    public var effort: Double?
    public var rest: Int?
    public var hrv: Int?
    public var restingHr: Int?
    public var recoveryDelta: Int?
    public var sleepMinutes: Int?
    public var steps: Int?
    public var calories: Int?
    public var hourlyStress: [Double?]?
    public var stressSummary: String?
    public var hrSparkline: [Int]?
    public var hrvSparkline: [Int]?

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

    /// Compatibility helper for non-verified callers. Verified production live data is stored as a separate
    /// `WidgetLiveOverlay` and never mutates the immutable health core.
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

    public func hasSameRenderedContent(as other: WidgetSnapshot) -> Bool {
        var lhs = self
        var rhs = other
        lhs.updated = .distantPast
        rhs.updated = .distantPast
        return lhs == rhs
    }

    public static let suiteName: String = {
        Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String
            ?? "group.com.noopapp.noop"
    }()
    public static let storageKey = "noop.widget.snapshot"

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

    public static func load() -> WidgetSnapshot? {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: storageKey),
              let snap = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { return nil }
        return snap
    }

    /// Display only health data that matches the App Group's active epoch and context. If an envelope exists
    /// but is inactive/corrupt, fail closed instead of falling back to an older legacy snapshot. Legacy data
    /// is accepted only when its own verified identity matches the active token.
    public static func loadForDisplay() -> WidgetSnapshot? {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return nil }
        if defaults.data(forKey: VerifiedWidgetEnvelopeStore.storageKey) != nil {
            return VerifiedWidgetEnvelopeStore.loadForDisplay(defaults: defaults)
        }
        guard let data = defaults.data(forKey: storageKey),
              let verified = try? JSONDecoder().decode(WidgetSnapshot.self, from: data),
              let contextId = verified.verifiedContextId,
              let generation = verified.verifiedProjectionGeneration,
              let active = ActiveVerifiedSinkEpochStore.activeToken(defaults: defaults),
              active.contextId == contextId else {
            return nil
        }
        guard let overlayData = defaults.data(
                forKey: ActiveVerifiedSinkEpochStore.widgetLiveOverlayKey
              ),
              let overlay = try? JSONDecoder().decode(WidgetLiveOverlay.self, from: overlayData),
              overlay.epoch == active.epoch,
              overlay.contextId == contextId,
              overlay.generation == generation else {
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

    @discardableResult
    public func save() -> Bool {
        save(to: UserDefaults(suiteName: WidgetSnapshot.suiteName))
    }

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
    public func acceptsVerifiedProjection(contextId: String, generation: Int64) -> Bool {
        guard let storedContext = verifiedContextId,
              let storedGeneration = verifiedProjectionGeneration,
              storedContext == contextId else {
            return true
        }
        return generation >= storedGeneration
    }
}
