import XCTest
import WhoopStore
@testable import NOOP

@MainActor
final class IntelligenceTimestampSafetyTests: XCTestCase {
    func testMidnightHelpersPreserveRepresentableDatesAndRejectOverflow() throws {
        let utcTimestamp = 1_623_805_200
        let localMidnight = try XCTUnwrap(
            IntelligenceEngine.midnightLocal(utcTimestamp, offsetSec: -4 * 3_600))
        XCTAssertEqual(localMidnight, 1_623_729_600)
        XCTAssertEqual(
            try XCTUnwrap(IntelligenceEngine.midnightLocal(utcTimestamp, offsetSec: 0)),
            try XCTUnwrap(IntelligenceEngine.midnightUtc(utcTimestamp)))

        XCTAssertNil(IntelligenceEngine.midnightUtc(Int.min))
        XCTAssertNil(IntelligenceEngine.midnightLocal(Int.max, offsetSec: 1))
        XCTAssertNil(IntelligenceEngine.midnightLocal(Int.min, offsetSec: -1))
    }

    func testBandSleepStateSamplesKeepsValidSeriesWhenExtremeInputIsRejected() async throws {
        let store = try await WhoopStore.inMemory()
        let deviceId = "timestamp-test-noop"
        let validStart = 1_780_000_000
        let corruptStart = Int.max - 10

        try await store.upsertSleepSessions([
            CachedSleepSession(startTs: validStart, endTs: validStart + 1_800, efficiency: 0.9,
                               restingHr: nil, avgHrv: nil, stagesJSON: nil),
            CachedSleepSession(startTs: corruptStart, endTs: Int.max, efficiency: nil,
                               restingHr: nil, avgHrv: nil, stagesJSON: nil),
        ], deviceId: deviceId)
        try await store.persistSessionSleepState(deviceId: deviceId, sessionStart: validStart,
                                                 states: [1, 2, 3])
        try await store.persistSessionSleepState(deviceId: deviceId, sessionStart: corruptStart,
                                                 states: [3])

        let samples = await IntelligenceEngine.bandSleepStateSamples(
            computedId: deviceId, from: validStart, to: Int.max, store: store)

        XCTAssertEqual(samples.map(\.ts), [validStart, validStart + 30, validStart + 60])
        XCTAssertEqual(samples.map(\.state), [1, 2, 3])
    }

    func testBandSleepStateSamplesRejectsSeriesThatEscapesItsSession() async throws {
        let store = try await WhoopStore.inMemory()
        let deviceId = "timestamp-series-test-noop"
        let start = 1_780_000_000

        try await store.upsertSleepSessions([
            CachedSleepSession(startTs: start, endTs: start + 1_800, efficiency: 0.9,
                               restingHr: nil, avgHrv: nil, stagesJSON: nil)
        ], deviceId: deviceId)
        try await store.persistSessionSleepState(deviceId: deviceId, sessionStart: start,
                                                 states: Array(repeating: 1, count: 62))

        let samples = await IntelligenceEngine.bandSleepStateSamples(
            computedId: deviceId, from: start, to: start + 1_800, store: store)

        XCTAssertTrue(samples.isEmpty)
    }
}
