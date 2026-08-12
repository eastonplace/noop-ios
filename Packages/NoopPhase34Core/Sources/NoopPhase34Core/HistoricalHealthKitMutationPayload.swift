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

    private enum CodingKeys: String, CodingKey {
        case day, wakeTimestamp, restingHR, hrvMilliseconds
        case oxygenSaturationPercent, respiratoryRate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            day: container.decode(CivilDay.self, forKey: .day),
            wakeTimestamp: container.decodeIfPresent(Int.self, forKey: .wakeTimestamp),
            restingHR: container.decodeIfPresent(Int.self, forKey: .restingHR),
            hrvMilliseconds: container.decodeIfPresent(Double.self, forKey: .hrvMilliseconds),
            oxygenSaturationPercent: container.decodeIfPresent(
                Double.self, forKey: .oxygenSaturationPercent),
            respiratoryRate: container.decodeIfPresent(Double.self, forKey: .respiratoryRate)
        )
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
              endTimestamp > effectiveStartTimestamp,
              stagesJSON.map({ $0.utf8.count <= 2_000_000 }) ?? true else {
            throw HistoricalHealthKitPayloadError.invalidSleepMutation
        }
        self.stableStartTimestamp = stableStartTimestamp
        self.effectiveStartTimestamp = effectiveStartTimestamp
        self.endTimestamp = endTimestamp
        self.stagesJSON = stagesJSON
    }

    private enum CodingKeys: String, CodingKey {
        case stableStartTimestamp, effectiveStartTimestamp, endTimestamp, stagesJSON
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            stableStartTimestamp: container.decode(Int.self, forKey: .stableStartTimestamp),
            effectiveStartTimestamp: container.decode(Int.self, forKey: .effectiveStartTimestamp),
            endTimestamp: container.decode(Int.self, forKey: .endTimestamp),
            stagesJSON: container.decodeIfPresent(String.self, forKey: .stagesJSON)
        )
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
              changedDays.count <= HistoricalAnalysisWork.maximumExactDayCount,
              Set(dailyMutations.map(\.day)).isSubset(of: changedDays),
              Set(dailyMutations.map(\.day)).count == dailyMutations.count,
              Set(sleepMutations.map(\.stableStartTimestamp)).count == sleepMutations.count else {
            throw HistoricalHealthKitPayloadError.invalidPayload
        }

        let calendar = try HealthCalendar(timeZoneIdentifier: recordedTimeZoneIdentifier)
        let sleepWakeDays = try sleepMutations.map { mutation in
            try calendar.civilDay(
                containing: Date(timeIntervalSince1970: TimeInterval(mutation.endTimestamp)))
        }
        guard Set(sleepWakeDays).isSubset(of: changedDays) else {
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

    private enum CodingKeys: String, CodingKey {
        case version, contextId, deviceId, analysisGeneration, recordedTimeZoneIdentifier
        case changedDays, dailyMutations, sleepMutations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw HistoricalHealthKitPayloadError.unsupportedVersion(version)
        }
        try self.init(
            contextId: container.decode(String.self, forKey: .contextId),
            deviceId: container.decode(String.self, forKey: .deviceId),
            analysisGeneration: container.decode(Int64.self, forKey: .analysisGeneration),
            recordedTimeZoneIdentifier: container.decode(
                String.self, forKey: .recordedTimeZoneIdentifier),
            changedDays: container.decode(Set<CivilDay>.self, forKey: .changedDays),
            dailyMutations: container.decode(
                [HistoricalHealthKitDailyMutation].self, forKey: .dailyMutations),
            sleepMutations: container.decode(
                [HistoricalHealthKitSleepMutation].self, forKey: .sleepMutations)
        )
    }

    public func sleepMutationWakeDayPairs()
        throws -> [(mutation: HistoricalHealthKitSleepMutation, wakeDay: CivilDay)] {
        let calendar = try HealthCalendar(timeZoneIdentifier: recordedTimeZoneIdentifier)
        return try sleepMutations.map { mutation in
            (
                mutation,
                try calendar.civilDay(
                    containing: Date(timeIntervalSince1970: TimeInterval(mutation.endTimestamp)))
            )
        }
    }

    public func validates(
        contextId: String,
        deviceId: String,
        analysisGeneration: Int64,
        changedDays: Set<CivilDay>,
        recordedTimeZoneIdentifier: String
    ) -> Bool {
        guard version == Self.currentVersion,
              self.contextId == contextId,
              self.deviceId == deviceId,
              self.analysisGeneration == analysisGeneration,
              self.changedDays == changedDays,
              self.recordedTimeZoneIdentifier == recordedTimeZoneIdentifier else {
            return false
        }
        return (try? Self(
            contextId: self.contextId,
            deviceId: self.deviceId,
            analysisGeneration: self.analysisGeneration,
            recordedTimeZoneIdentifier: self.recordedTimeZoneIdentifier,
            changedDays: self.changedDays,
            dailyMutations: dailyMutations,
            sleepMutations: sleepMutations
        )) == self
    }

    public func validatedSleepWakeDays() -> [CivilDay] {
        guard let calendar = try? HealthCalendar(timeZoneIdentifier: recordedTimeZoneIdentifier) else {
            return []
        }
        return sleepMutations.compactMap { mutation in
            try? calendar.civilDay(
                containing: Date(timeIntervalSince1970: TimeInterval(mutation.endTimestamp))
            )
        }
    }

    /// Restrict a historical mutation to days that have not already been
    /// delivered at a newer analysis generation. The outbox identity remains
    /// the original generation; only the admitted sink scope is narrowed.
    public func restricted(to eligibleDays: Set<CivilDay>) throws -> HistoricalHealthKitMutationPayload? {
        let eligible = eligibleDays.intersection(changedDays)
        guard !eligible.isEmpty else { return nil }
        let sleep = try sleepMutationWakeDayPairs().compactMap { pair in
            eligible.contains(pair.wakeDay) ? pair.mutation : nil
        }
        return try HistoricalHealthKitMutationPayload(
            contextId: contextId,
            deviceId: deviceId,
            analysisGeneration: analysisGeneration,
            recordedTimeZoneIdentifier: recordedTimeZoneIdentifier,
            changedDays: eligible,
            dailyMutations: dailyMutations.filter { eligible.contains($0.day) },
            sleepMutations: sleep
        )
    }
}

public enum HistoricalHealthKitPayloadError: Error, Equatable, Sendable {
    case invalidDailyMutation
    case invalidSleepMutation
    case invalidPayload
    case unsupportedVersion(Int)
}
