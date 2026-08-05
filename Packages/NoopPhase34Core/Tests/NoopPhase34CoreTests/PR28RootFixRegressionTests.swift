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
