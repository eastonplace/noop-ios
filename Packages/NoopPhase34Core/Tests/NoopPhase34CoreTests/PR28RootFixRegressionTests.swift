import Foundation
import Testing
@testable import NoopPhase34Core

private func pr28Day(_ key: String) throws -> CivilDay {
    try CivilDay(key: key)
}

private func pr28Scope() throws -> HistoricalAnalysisScope {
    try HistoricalAnalysisScope(
        databaseInstanceId: "db",
        sourceId: "my-whoop",
        deviceId: "my-whoop",
        deviceLineageId: "lineage",
        cursorEpoch: 0,
        trimScope: "historical"
    )
}

@Test func exactDayWorkRejectsBroadAnalysisReceipt() throws {
    let requested = try pr28Day("2026-08-01")
    let extra = try pr28Day("2026-08-02")
    let work = try HistoricalAnalysisWork(
        scope: pr28Scope(),
        firstReceiptGeneration: 1,
        lastReceiptGeneration: 1,
        affectedDays: [requested],
        recordedTimeZoneIdentifier: "America/New_York",
        createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    #expect(!work.acceptsAnalyzedDays([requested, extra]))
    #expect(work.acceptsAnalyzedDays([requested]))
}

@Test func editedV2DoesNotBlankImportedProductionWhenModeOff() throws {
    let day = try pr28Day("2026-08-01")
    let imported = try SleepScoreCandidate(
        day: day,
        value: 82,
        sourceId: "my-whoop",
        model: .importedWhoop,
        generation: 1,
        authorityRank: 2
    )
    let editedV2 = try SleepScoreCandidate(
        day: day,
        value: 91,
        sourceId: "my-whoop-noop",
        model: .noopV2,
        modelVersion: "v2",
        generation: 1,
        authorityRank: 1,
        isUserEditedAuthority: true
    )
    let resolution = try CanonicalSleepScoreResolver.resolve(
        day: day,
        mode: .off,
        imported: [imported],
        v2: [editedV2],
        legacy: []
    )
    #expect(resolution.production == imported)
}

@Test func immutableHealthKitPayloadRoundTripsAndRejectsMismatchedGeneration() throws {
    let day = try pr28Day("2026-08-01")
    let payload = try HistoricalHealthKitMutationPayload(
        contextId: "context",
        deviceId: "my-whoop",
        analysisGeneration: 7,
        recordedTimeZoneIdentifier: "America/Los_Angeles",
        changedDays: [day],
        dailyMutations: [
            try HistoricalHealthKitDailyMutation(
                day: day,
                wakeTimestamp: 1_754_000_000,
                restingHR: 52,
                hrvMilliseconds: 64,
                oxygenSaturationPercent: 97,
                respiratoryRate: 14
            )
        ],
        sleepMutations: []
    )
    let restored = try JSONDecoder().decode(
        HistoricalHealthKitMutationPayload.self,
        from: JSONEncoder().encode(payload)
    )
    #expect(restored == payload)
    #expect(payload.validates(
        contextId: "context",
        deviceId: "my-whoop",
        analysisGeneration: 7,
        changedDays: [day],
        recordedTimeZoneIdentifier: "America/Los_Angeles"
    ))
    #expect(!payload.validates(
        contextId: "context",
        deviceId: "my-whoop",
        analysisGeneration: 8,
        changedDays: [day],
        recordedTimeZoneIdentifier: "America/Los_Angeles"
    ))
}

@Test func quiescenceCancelsOldEpochAndWaitsForOwners() async throws {
    let gate = PipelineQuiescence()
    let oldToken = try await gate.begin()

    let quiesceTask = Task { try await gate.quiesce(cancelOwners: {}) }
    await Task.yield()
    await gate.end(oldToken)
    let newEpoch = try await quiesceTask.value

    do {
        try await gate.validate(oldToken)
        Issue.record("an old pipeline token remained valid after quiescence")
    } catch PipelineQuiescenceError.superseded {
        // Expected: old work cannot pass a lifecycle boundary.
    }

    try await gate.resume(expectedEpoch: newEpoch)
    let newToken = try await gate.begin()
    try await gate.validate(newToken)
    await gate.end(newToken)
}

@Test func payloadRestrictionKeepsSleepMutationPairingAfterAnIneligibleMiddleDay() throws {
    let day1 = try pr28Day("2026-08-01")
    let day2 = try pr28Day("2026-08-02")
    let day3 = try pr28Day("2026-08-03")
    let payload = try HistoricalHealthKitMutationPayload(
        contextId: "context",
        deviceId: "my-whoop",
        analysisGeneration: 9,
        recordedTimeZoneIdentifier: "UTC",
        changedDays: [day1, day2, day3],
        dailyMutations: [],
        sleepMutations: [
            try HistoricalHealthKitSleepMutation(
                stableStartTimestamp: 1_785_542_400,
                effectiveStartTimestamp: 1_785_542_400,
                endTimestamp: 1_785_585_600,
                stagesJSON: nil),
            try HistoricalHealthKitSleepMutation(
                stableStartTimestamp: 1_785_628_800,
                effectiveStartTimestamp: 1_785_628_800,
                endTimestamp: 1_785_672_000,
                stagesJSON: nil),
            try HistoricalHealthKitSleepMutation(
                stableStartTimestamp: 1_785_715_200,
                effectiveStartTimestamp: 1_785_715_200,
                endTimestamp: 1_785_758_400,
                stagesJSON: nil)
        ])

    let restricted = try payload.restricted(to: [day3])
    #expect(restricted?.sleepMutations.map(\.stableStartTimestamp) == [1_785_715_200])
    #expect(restricted?.changedDays == [day3])
}

@Test func payloadDecoderRejectsCorruptVersionAndChildValues() throws {
    let day = try pr28Day("2026-08-01")
    let payload = try HistoricalHealthKitMutationPayload(
        contextId: "context",
        deviceId: "my-whoop",
        analysisGeneration: 7,
        recordedTimeZoneIdentifier: "UTC",
        changedDays: [day],
        dailyMutations: [
            try HistoricalHealthKitDailyMutation(
                day: day,
                wakeTimestamp: 1_754_000_000,
                restingHR: 52,
                hrvMilliseconds: 64,
                oxygenSaturationPercent: 97,
                respiratoryRate: 14)
        ],
        sleepMutations: [])
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    var wrongVersion = try JSONSerialization.jsonObject(with: encoder.encode(payload)) as! [String: Any]
    wrongVersion["version"] = 99
    let wrongVersionData = try JSONSerialization.data(withJSONObject: wrongVersion)
    #expect(throws: HistoricalHealthKitPayloadError.unsupportedVersion(99)) {
        try decoder.decode(HistoricalHealthKitMutationPayload.self, from: wrongVersionData)
    }

    var invalidChild = try JSONSerialization.jsonObject(with: encoder.encode(payload)) as! [String: Any]
    var daily = invalidChild["dailyMutations"] as! [[String: Any]]
    daily[0]["restingHR"] = 1
    invalidChild["dailyMutations"] = daily
    let invalidChildData = try JSONSerialization.data(withJSONObject: invalidChild)
    #expect(throws: HistoricalHealthKitPayloadError.invalidDailyMutation) {
        try decoder.decode(HistoricalHealthKitMutationPayload.self, from: invalidChildData)
    }
}
