// Add to Packages/NoopPhase34Core/Sources/NoopPhase34Core.

import Foundation

public struct HistoricalHealthKitDailyMutation: Codable, Equatable, Sendable {
    public let day: CivilDay
    public let wakeTimestamp: Int?
    public let restingHR: Int?
    public let hrvMilliseconds: Double?
    public let oxygenSaturationPercent: Double?
    public let respiratoryRate: Double?

    public init(
        day: CivilDay,
        wakeTimestamp: Int?,
        restingHR: Int?,
        hrvMilliseconds: Double?,
        oxygenSaturationPercent: Double?,
        respiratoryRate: Double?
    ) throws {
        guard wakeTimestamp.map({ $0 >= 0 }) ?? true,
              restingHR.map({ (20...300).contains($0) }) ?? true,
              hrvMilliseconds.map({ $0.isFinite && (0...1_000).contains($0) }) ?? true,
              oxygenSaturationPercent.map({ $0.isFinite && (0...100).contains($0) }) ?? true,
              respiratoryRate.map({ $0.isFinite && (1...100).contains($0) }) ?? true else {
            throw HistoricalHealthKitPayloadError.invalidDailyMutation
        }
        self.day = day
        self.wakeTimestamp = wakeTimestamp
        self.restingHR = restingHR
        self.hrvMilliseconds = hrvMilliseconds
        self.oxygenSaturationPercent = oxygenSaturationPercent
        self.respiratoryRate = respiratoryRate
    }
}

public struct HistoricalHealthKitSleepMutation: Codable, Equatable, Sendable {
    /// Immutable detected key used by HealthKit metadata/idempotency.
    public let stableStartTimestamp: Int
    public let effectiveStartTimestamp: Int
    public let endTimestamp: Int
    public let stagesJSON: String?

    public init(
        stableStartTimestamp: Int,
        effectiveStartTimestamp: Int,
        endTimestamp: Int,
        stagesJSON: String?
    ) throws {
        guard stableStartTimestamp >= 0,
              effectiveStartTimestamp >= 0,
              endTimestamp > effectiveStartTimestamp else {
            throw HistoricalHealthKitPayloadError.invalidSleepMutation
        }
        self.stableStartTimestamp = stableStartTimestamp
        self.effectiveStartTimestamp = effectiveStartTimestamp
        self.endTimestamp = endTimestamp
        self.stagesJSON = stagesJSON
    }
}

public struct HistoricalHealthKitMutationPayload: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let contextId: String
    public let deviceId: String
    public let analysisGeneration: Int64
    public let recordedTimeZoneIdentifier: String
    public let changedDays: Set<CivilDay>
    public let dailyMutations: [HistoricalHealthKitDailyMutation]
    public let sleepMutations: [HistoricalHealthKitSleepMutation]

    public init(
        contextId: String,
        deviceId: String,
        analysisGeneration: Int64,
        recordedTimeZoneIdentifier: String,
        changedDays: Set<CivilDay>,
        dailyMutations: [HistoricalHealthKitDailyMutation],
        sleepMutations: [HistoricalHealthKitSleepMutation]
    ) throws {
        guard !contextId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !deviceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              analysisGeneration > 0,
              TimeZone(identifier: recordedTimeZoneIdentifier) != nil,
              !changedDays.isEmpty,
              Set(dailyMutations.map(\.day)).isSubset(of: changedDays) else {
            throw HistoricalHealthKitPayloadError.invalidPayload
        }
        version = Self.currentVersion
        self.contextId = contextId
        self.deviceId = deviceId
        self.analysisGeneration = analysisGeneration
        self.recordedTimeZoneIdentifier = recordedTimeZoneIdentifier
        self.changedDays = changedDays
        self.dailyMutations = dailyMutations.sorted { $0.day < $1.day }
        self.sleepMutations = sleepMutations.sorted {
            ($0.effectiveStartTimestamp, $0.endTimestamp, $0.stableStartTimestamp)
                < ($1.effectiveStartTimestamp, $1.endTimestamp, $1.stableStartTimestamp)
        }
    }

    public func validates(
        contextId: String,
        deviceId: String,
        analysisGeneration: Int64,
        changedDays: Set<CivilDay>,
        recordedTimeZoneIdentifier: String
    ) -> Bool {
        version == Self.currentVersion
            && self.contextId == contextId
            && self.deviceId == deviceId
            && self.analysisGeneration == analysisGeneration
            && self.changedDays == changedDays
            && self.recordedTimeZoneIdentifier == recordedTimeZoneIdentifier
    }
}

public enum HistoricalHealthKitPayloadError: Error, Equatable, Sendable {
    case invalidDailyMutation
    case invalidSleepMutation
    case invalidPayload
}
