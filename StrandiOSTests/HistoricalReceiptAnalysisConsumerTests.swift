import XCTest
import WhoopProtocol
import WhoopStore
@testable import NOOP

@MainActor
final class HistoricalReceiptAnalysisConsumerTests: XCTestCase {
    private struct PendingPayloadFixture: Codable {
        static let version = 1

        let version: Int
        let plan: HistoricalReceiptAnalysisPlan
        let timeZoneIdentifier: String
    }

    func testExactReceiptRunStagesExecutesAndAcknowledges() async throws {
        let store = try await WhoopStore.inMemory()
        let scope = HistoricalCursorScope(
            deviceId: "strap-a",
            lineage: "lineage-a",
            cursorEpoch: 0,
            trimScope: "historical"
        )
        let calendar = try gregorianCalendar(timeZone: "America/New_York")
        let timestamp = try date(calendar, year: 2026, month: 8, day: 10, hour: 22)
        let reference = try date(calendar, year: 2026, month: 8, day: 12, hour: 12)
        let receipt = try await commit(
            into: store,
            scope: scope,
            trim: 1,
            timestamp: Int(timestamp.timeIntervalSince1970),
            hasDecodedRows: true
        )

        var runs: [(CommittedAnalysisRun, CommittedAnalysisExecutionContext)] = []
        let consumer = HistoricalReceiptAnalysisConsumer(
            storeProvider: { store },
            scopeIsCurrent: { _, _ in true },
            executeRun: { run, context in
                runs.append((run, context))
                return true
            },
            timeZoneProvider: { calendar.timeZone },
            now: { reference }
        )

        let result = await consumer.drain()
        let checkpoint = try await store.historicalAnalysisCheckpoint(
            consumerId: HistoricalReceiptAnalysisConsumer.consumerId,
            for: scope
        )

        XCTAssertEqual(result.acknowledgedReceiptCount, 1)
        XCTAssertEqual(result.analysisRunCount, 1)
        XCTAssertEqual(result.deferredScopeCount, 0)
        XCTAssertEqual(runs.map { $0.0.startOffset }, [2])
        XCTAssertEqual(runs.map { $0.0.maxDays }, [1])
        XCTAssertEqual(runs.map { $0.1.timeZoneIdentifier }, ["America/New_York"])
        XCTAssertEqual(checkpoint?.throughGeneration, receipt.generation)
        XCTAssertNil(checkpoint?.pendingWork)
    }

    func testFailedExecutionResumesUsingThePersistedGregorianTimeZone() async throws {
        let store = try await WhoopStore.inMemory()
        let scope = HistoricalCursorScope(
            deviceId: "strap-a",
            lineage: "lineage-a",
            cursorEpoch: 0,
            trimScope: "historical"
        )
        let newYork = try gregorianCalendar(timeZone: "America/New_York")
        let losAngeles = try gregorianCalendar(timeZone: "America/Los_Angeles")
        let timestamp = try date(newYork, year: 2026, month: 3, day: 8, hour: 1)
        let reference = try date(newYork, year: 2026, month: 3, day: 9, hour: 12)
        let receipt = try await commit(
            into: store,
            scope: scope,
            trim: 2,
            timestamp: Int(timestamp.timeIntervalSince1970),
            hasDecodedRows: true
        )

        let failingConsumer = HistoricalReceiptAnalysisConsumer(
            storeProvider: { store },
            scopeIsCurrent: { _, _ in true },
            executeRun: { _, _ in false },
            timeZoneProvider: { newYork.timeZone },
            now: { reference }
        )
        let failed = await failingConsumer.drain()
        let staged = try await store.historicalAnalysisCheckpoint(
            consumerId: HistoricalReceiptAnalysisConsumer.consumerId,
            for: scope
        )

        var resumedRuns: [(CommittedAnalysisRun, CommittedAnalysisExecutionContext)] = []
        let resumedConsumer = HistoricalReceiptAnalysisConsumer(
            storeProvider: { store },
            scopeIsCurrent: { _, _ in true },
            executeRun: { run, context in
                resumedRuns.append((run, context))
                return true
            },
            // The device moved. Resume must ignore this provider and use the staged New York calendar.
            timeZoneProvider: { losAngeles.timeZone },
            now: { reference }
        )
        let resumed = await resumedConsumer.drain()
        let acknowledged = try await store.historicalAnalysisCheckpoint(
            consumerId: HistoricalReceiptAnalysisConsumer.consumerId,
            for: scope
        )

        XCTAssertEqual(failed.acknowledgedReceiptCount, 0)
        XCTAssertEqual(failed.deferredScopeCount, 1)
        XCTAssertEqual(staged?.pendingWork?.target.receiptId, receipt.receiptId)
        XCTAssertEqual(resumed.acknowledgedReceiptCount, 1)
        XCTAssertEqual(resumedRuns.map { $0.0.startOffset }, [1])
        XCTAssertEqual(resumedRuns.map { $0.0.maxDays }, [2])
        XCTAssertEqual(resumedRuns.map { $0.1.timeZoneIdentifier }, ["America/New_York"])
        XCTAssertEqual(acknowledged?.throughGeneration, receipt.generation)
        XCTAssertNil(acknowledged?.pendingWork)
    }

    func testStaleSourceScopeNeverExecutesOrAcknowledges() async throws {
        let store = try await WhoopStore.inMemory()
        let scope = HistoricalCursorScope(
            deviceId: "strap-a",
            lineage: "old-lineage",
            cursorEpoch: 0,
            trimScope: "historical"
        )
        let calendar = try gregorianCalendar(timeZone: "UTC")
        let timestamp = try date(calendar, year: 2026, month: 8, day: 10, hour: 12)
        _ = try await commit(
            into: store,
            scope: scope,
            trim: 3,
            timestamp: Int(timestamp.timeIntervalSince1970),
            hasDecodedRows: true
        )

        var executeCount = 0
        let consumer = HistoricalReceiptAnalysisConsumer(
            storeProvider: { store },
            scopeIsCurrent: { _, _ in false },
            executeRun: { _, _ in
                executeCount += 1
                return true
            },
            timeZoneProvider: { calendar.timeZone },
            now: { timestamp }
        )

        let result = await consumer.drain()
        let checkpoint = try await store.historicalAnalysisCheckpoint(
            consumerId: HistoricalReceiptAnalysisConsumer.consumerId,
            for: scope
        )
        let pending = try await store.pendingHistoricalAnalysisScopes(
            consumerId: HistoricalReceiptAnalysisConsumer.consumerId
        )

        XCTAssertEqual(result.acknowledgedReceiptCount, 0)
        XCTAssertEqual(result.deferredScopeCount, 1)
        XCTAssertEqual(executeCount, 0)
        XCTAssertNil(checkpoint)
        XCTAssertEqual(pending.map(\.scope), [scope])
    }

    func testScopeSwitchDuringPlanStagingNeverExecutesOrAcknowledges() async throws {
        let store = try await WhoopStore.inMemory()
        let scope = HistoricalCursorScope(
            deviceId: "strap-a",
            lineage: "lineage-a",
            cursorEpoch: 0,
            trimScope: "historical"
        )
        let calendar = try gregorianCalendar(timeZone: "UTC")
        let timestamp = try date(calendar, year: 2026, month: 8, day: 10, hour: 12)
        let receipt = try await commit(
            into: store,
            scope: scope,
            trim: 33,
            timestamp: Int(timestamp.timeIntervalSince1970),
            hasDecodedRows: true
        )

        var scopeChecks = 0
        var executeCount = 0
        let consumer = HistoricalReceiptAnalysisConsumer(
            storeProvider: { store },
            scopeIsCurrent: { _, _ in
                scopeChecks += 1
                return scopeChecks == 1
            },
            executeRun: { _, _ in
                executeCount += 1
                return true
            },
            timeZoneProvider: { calendar.timeZone },
            now: { timestamp }
        )

        let result = await consumer.drain()
        let checkpoint = try await store.historicalAnalysisCheckpoint(
            consumerId: HistoricalReceiptAnalysisConsumer.consumerId,
            for: scope
        )

        XCTAssertEqual(result.acknowledgedReceiptCount, 0)
        XCTAssertEqual(result.deferredScopeCount, 1)
        XCTAssertEqual(scopeChecks, 2)
        XCTAssertEqual(executeCount, 0)
        XCTAssertEqual(checkpoint?.pendingWork?.target.receiptId, receipt.receiptId)
        XCTAssertEqual(checkpoint?.throughGeneration, 0)
    }

    func testRegistrySwitchAfterAnalysisLeavesReceiptPending() async throws {
        let store = try await WhoopStore.inMemory()
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        let scope = try registry.historicalCursorScope(for: "my-whoop")
        let calendar = try gregorianCalendar(timeZone: "UTC")
        let timestamp = try date(calendar, year: 2026, month: 8, day: 10, hour: 12)
        _ = try await commit(
            into: store,
            scope: scope,
            trim: 34,
            timestamp: Int(timestamp.timeIntervalSince1970),
            hasDecodedRows: true
        )

        var runs: [CommittedAnalysisRun] = []
        let consumer = HistoricalReceiptAnalysisConsumer(
            storeProvider: { store },
            // The callback is intentionally stale. The final store operation must still reject the ACK.
            scopeIsCurrent: { _, _ in true },
            executeRun: { run, _ in
                runs.append(run)
                try? registry.setPeripheralId(scope.deviceId, peripheralId: "replacement-peripheral")
                return true
            },
            timeZoneProvider: { calendar.timeZone },
            now: { timestamp }
        )

        let result = await consumer.drain()
        let checkpoint = try await store.historicalAnalysisCheckpoint(
            consumerId: HistoricalReceiptAnalysisConsumer.consumerId,
            for: scope
        )

        XCTAssertEqual(result.acknowledgedReceiptCount, 0)
        XCTAssertEqual(result.analysisRunCount, 0)
        XCTAssertEqual(result.deferredScopeCount, 1)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(checkpoint?.throughGeneration, 0)
        XCTAssertNotNil(checkpoint?.pendingWork)
    }

    func testScopeSwitchBetweenRunsStopsBeforeTheNextRun() async throws {
        let store = try await WhoopStore.inMemory()
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        let scope = try registry.historicalCursorScope(for: "my-whoop")
        let calendar = try gregorianCalendar(timeZone: "UTC")
        let timestamp = try date(calendar, year: 2026, month: 8, day: 10, hour: 12)
        let reference = try date(calendar, year: 2026, month: 8, day: 12, hour: 12)
        let receipt = try await commit(
            into: store,
            scope: scope,
            trim: 35,
            timestamp: Int(timestamp.timeIntervalSince1970),
            hasDecodedRows: true
        )
        let dayNear = try XCTUnwrap(AnalysisCivilDay(year: 2026, month: 8, day: 10))
        let dayFar = try XCTUnwrap(AnalysisCivilDay(year: 2026, month: 8, day: 5))
        let plan = HistoricalReceiptAnalysisPlan(
            databaseInstanceId: receipt.databaseInstanceId,
            scope: scope,
            throughGeneration: receipt.generation,
            outcome: .analysis(window: CommittedAnalysisWindow(
                touchedCivilDays: Set([dayNear, dayFar])
            ))
        )
        let payload = try JSONEncoder().encode(PendingPayloadFixture(
            version: PendingPayloadFixture.version,
            plan: plan,
            timeZoneIdentifier: calendar.timeZone.identifier
        ))
        let staged = try await store.stageHistoricalAnalysis(
            consumerId: HistoricalReceiptAnalysisConsumer.consumerId,
            for: scope,
            through: receipt,
            payload: payload
        )

        var runs: [CommittedAnalysisRun] = []
        let consumer = HistoricalReceiptAnalysisConsumer(
            storeProvider: { store },
            scopeIsCurrent: { store, expected in
                let currentRegistry = DeviceRegistryStore(dbQueue: store.registryWriter)
                return (try? currentRegistry.historicalCursorScope(for: expected.deviceId)) == expected
            },
            executeRun: { run, _ in
                runs.append(run)
                if runs.count == 1 {
                    try? registry.setPeripheralId(scope.deviceId, peripheralId: "replacement-peripheral")
                }
                return true
            },
            timeZoneProvider: { calendar.timeZone },
            now: { reference }
        )

        let result = await consumer.drain()
        let checkpoint = try await store.historicalAnalysisCheckpoint(
            consumerId: HistoricalReceiptAnalysisConsumer.consumerId,
            for: scope
        )

        XCTAssertEqual(result.acknowledgedReceiptCount, 0)
        XCTAssertEqual(result.analysisRunCount, 0)
        XCTAssertEqual(result.deferredScopeCount, 1)
        XCTAssertEqual(runs.map(\.startOffset), [2])
        XCTAssertEqual(checkpoint?.throughGeneration, 0)
        XCTAssertEqual(checkpoint?.pendingWork, staged.pendingWork)
    }

    func testEmptyReceiptAcknowledgesWithoutRunningAnalysis() async throws {
        let store = try await WhoopStore.inMemory()
        let scope = HistoricalCursorScope(
            deviceId: "strap-a",
            lineage: "lineage-a",
            cursorEpoch: 0,
            trimScope: "historical"
        )
        let calendar = try gregorianCalendar(timeZone: "UTC")
        let timestamp = try date(calendar, year: 2026, month: 8, day: 10, hour: 12)
        let receipt = try await commit(
            into: store,
            scope: scope,
            trim: 4,
            timestamp: Int(timestamp.timeIntervalSince1970),
            hasDecodedRows: false
        )

        var executeCount = 0
        let consumer = HistoricalReceiptAnalysisConsumer(
            storeProvider: { store },
            scopeIsCurrent: { _, _ in true },
            executeRun: { _, _ in
                executeCount += 1
                return true
            },
            timeZoneProvider: { calendar.timeZone },
            now: { timestamp }
        )

        let result = await consumer.drain()
        let checkpoint = try await store.historicalAnalysisCheckpoint(
            consumerId: HistoricalReceiptAnalysisConsumer.consumerId,
            for: scope
        )

        XCTAssertEqual(result.acknowledgedReceiptCount, 1)
        XCTAssertEqual(result.analysisRunCount, 0)
        XCTAssertEqual(executeCount, 0)
        XCTAssertEqual(checkpoint?.throughGeneration, receipt.generation)
        XCTAssertNil(checkpoint?.pendingWork)
    }

    private func commit(
        into store: WhoopStore,
        scope: HistoricalCursorScope,
        trim: Int,
        timestamp: Int,
        hasDecodedRows: Bool
    ) async throws -> HistoricalDataCommitReceipt {
        let frames = [[UInt8(0xAA), UInt8(truncatingIfNeeded: trim), 0x01]]
        let input = HistoricalReceivedFrameFingerprintInput(
            orderedFrames: frames,
            protocolMetadata: Data([0x49, UInt8(truncatingIfNeeded: trim)]),
            historyEndFrame: Data([0xAA, 0x02, UInt8(truncatingIfNeeded: trim)]),
            minReceivedTs: timestamp,
            maxReceivedTs: timestamp
        )
        let fingerprint = try WhoopStore.historicalReceivedFrameFingerprint(
            input: input,
            deviceId: scope.deviceId,
            trim: trim,
            chunkEndUnix: timestamp
        )
        return try await store.commitHistoricalChunk(
            streams: hasDecodedRows ? Streams(hr: [HRSample(ts: timestamp, bpm: 60)]) : Streams(),
            deviceId: scope.deviceId,
            trim: trim,
            chunkEndUnix: timestamp,
            rawBatch: nil,
            committedAt: timestamp + 1,
            scope: scope,
            fingerprint: fingerprint,
            fingerprintInput: input
        )
    }

    private func gregorianCalendar(timeZone identifier: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: identifier))
        return calendar
    }

    private func date(
        _ calendar: Calendar,
        year: Int,
        month: Int,
        day: Int,
        hour: Int
    ) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour
        )))
    }
}
