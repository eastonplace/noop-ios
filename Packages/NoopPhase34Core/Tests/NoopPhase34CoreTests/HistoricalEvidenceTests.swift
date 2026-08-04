import Foundation
import Testing
@testable import NoopPhase34Core

private let zeroCounts = try! HistoricalStreamCounts()
private let oneHR = try! HistoricalStreamCounts(hr: 1)

@Test func decodedEvidenceRequiresAnalysisEvenWhenInsertCountIsZero() throws {
    let bucket = try HistoricalTimestampBucket(minimumTs: 1_700_000_000, maximumTs: 1_700_000_000)
    let evidence = try HistoricalReceiptEvidence(
        generation: 1,
        recordedTimeZoneIdentifier: "America/New_York",
        decodedRows: oneHR,
        insertedRows: zeroCounts,
        timestampBuckets: [bucket]
    )
    #expect(evidence.requiresAnalysis)
}

@Test func sparseBucketsDoNotFillInterveningMonths() throws {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(secondsFromGMT: 0)!
    let jan = try #require(utc.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 12)))
    let mar = try #require(utc.date(from: DateComponents(year: 2026, month: 3, day: 1, hour: 12)))
    let buckets = try HistoricalTimestampBucketBuilder.buckets(from: [
        Int(jan.timeIntervalSince1970), Int(mar.timeIntervalSince1970),
    ])
    let evidence = try HistoricalReceiptEvidence(
        generation: 1,
        recordedTimeZoneIdentifier: "America/New_York",
        decodedRows: try HistoricalStreamCounts(hr: 2),
        insertedRows: zeroCounts,
        timestampBuckets: buckets
    )
    let days = try HistoricalAffectedDayPlanner.affectedDays(for: [evidence])
    #expect(days.count <= 4)
    #expect(days.contains(try CivilDay(key: "2026-01-01")))
    #expect(days.contains(try CivilDay(key: "2026-03-01")))
}

@Test func fingerprintPayloadIgnoresDerivedRangesAndCapturePolicyByConstruction() throws {
    let payload1 = try HistoricalFingerprintV2Payload(
        deviceLineage: "strap-a",
        cursorEpoch: 3,
        trimScope: "history",
        trim: 42,
        orderedFrames: [Data([1, 2, 3])],
        protocolMetadata: Data([9]),
        historyEndFrame: Data([7, 8])
    )
    let payload2 = try HistoricalFingerprintV2Payload(
        deviceLineage: "strap-a",
        cursorEpoch: 3,
        trimScope: "history",
        trim: 42,
        orderedFrames: [Data([1, 2, 3])],
        protocolMetadata: Data([9]),
        historyEndFrame: Data([7, 8])
    )
    #expect(try payload1.canonicalData() == payload2.canonicalData())
}

@Test func mixedReceiptTimeZonesMustBeSplitBeforePlanning() throws {
    let bucket = try HistoricalTimestampBucket(minimumTs: 1_700_000_000, maximumTs: 1_700_000_100)
    let newYork = try HistoricalReceiptEvidence(
        generation: 1,
        recordedTimeZoneIdentifier: "America/New_York",
        decodedRows: oneHR,
        insertedRows: oneHR,
        timestampBuckets: [bucket]
    )
    let london = try HistoricalReceiptEvidence(
        generation: 2,
        recordedTimeZoneIdentifier: "Europe/London",
        decodedRows: oneHR,
        insertedRows: oneHR,
        timestampBuckets: [bucket]
    )
    #expect(throws: HistoricalEvidenceError.mixedTimeZoneEvidence) {
        try HistoricalAffectedDayPlanner.affectedDays(for: [newYork, london])
    }
}

@Test func rangeEvidenceWithoutDecodedRowsDoesNotCreateAnalysisWork() throws {
    let bucket = try HistoricalTimestampBucket(minimumTs: 1_700_000_000, maximumTs: 1_700_000_100)
    let evidence = try HistoricalReceiptEvidence(
        generation: 2,
        recordedTimeZoneIdentifier: "America/New_York",
        decodedRows: zeroCounts,
        insertedRows: zeroCounts,
        timestampBuckets: [bucket]
    )
    #expect(!evidence.requiresAnalysis)
    #expect(try HistoricalAffectedDayPlanner.affectedDays(for: [evidence]).isEmpty)
}

@Test func largeExactBacklogIsSplitIntoBoundedWorkBatches() throws {
    let calendar = try HealthCalendar(timeZoneIdentifier: "America/New_York")
    let first = try CivilDay(key: "2025-01-01")
    let days = try (0..<130).map { try calendar.adding(days: $0, to: first) }
    let evidence = try days.enumerated().map { index, day in
        try HistoricalReceiptEvidence(
            generation: Int64(index + 1),
            recordedTimeZoneIdentifier: "America/New_York",
            decodedRows: zeroCounts,
            insertedRows: zeroCounts,
            timestampBuckets: [],
            explicitDays: [day]
        )
    }
    let batches = try HistoricalExactWorkBatchPlanner.batches(
        for: evidence,
        maximumDaysPerBatch: 64
    )
    #expect(batches.count == 3)
    #expect(batches.allSatisfy { $0.affectedDays.count <= 64 })
    #expect(Set(batches.flatMap(\.affectedDays)) == Set(days))
    #expect(batches.first?.firstReceiptGeneration == 1)
    #expect(batches.last?.lastReceiptGeneration == 130)
}

@Test func streamCountsRejectIntegerOverflow() {
    #expect(throws: HistoricalEvidenceError.invalidCount) {
        _ = try HistoricalStreamCounts(hr: Int.max, rr: 1)
    }
}
