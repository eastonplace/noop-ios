import XCTest
@testable import NOOP
import WhoopStore

final class BackfillBurstPublicationTests: XCTestCase {
    private func receipt(
        generation: Int64,
        rows: HistoricalStreamInsertCounts,
        databaseInstanceId: String = "database-a",
        deviceId: String = "strap-a"
    ) -> HistoricalDataCommitReceipt {
        HistoricalDataCommitReceipt(
            receiptId: "receipt-\(generation)",
            generation: generation,
            databaseInstanceId: databaseInstanceId,
            deviceId: deviceId,
            trim: Int(generation),
            chunkEndUnix: 1_700_000_000 + Int(generation),
            committedAt: 1_700_000_001 + Int(generation),
            rawBatchId: nil,
            insertedRows: rows
        )
    }

    func testDurablePassPublishesCheapProgressBeforeBurstFinalization() {
        var burst = BackfillBurstPublication()

        let first = burst.record(rowsPersisted: 240, requiresTimestampHeal: false,
                                 latestFrontierUnix: 1_000, at: 10)
        XCTAssertEqual(first, HistoricalSyncPassProgress(rowsPersisted: 240, passNumber: 1,
                                                         latestFrontierUnix: 1_000, publishedAt: 10))
        XCTAssertTrue(burst.needsPublication)

        let second = burst.record(rowsPersisted: 360, requiresTimestampHeal: false,
                                  latestFrontierUnix: 1_100, at: 20)
        XCTAssertEqual(second?.passNumber, 2)
        XCTAssertEqual(second?.rowsPersisted, 360)
        XCTAssertTrue(burst.consume())
        XCTAssertFalse(burst.consume())
    }

    func testDurableRowsPublishOnceWhenTheBurstQuiesces() {
        var burst = BackfillBurstPublication()

        burst.record(rowsPersisted: 240, requiresTimestampHeal: false)
        burst.record(rowsPersisted: 360, requiresTimestampHeal: false)

        XCTAssertTrue(burst.consume())
        XCTAssertFalse(burst.consume())
    }

    func testEmptyFinalChunkPublishesWatermarkThroughTheProductiveReceipt() {
        var burst = BackfillBurstPublication()
        let productive = receipt(generation: 41, rows: HistoricalStreamInsertCounts(hr: 240))
        let emptyFinal = receipt(generation: 42, rows: HistoricalStreamInsertCounts())

        burst.record(receipt: productive)
        burst.record(rowsPersisted: productive.insertedRows.total, requiresTimestampHeal: false)
        burst.record(receipt: emptyFinal)
        burst.record(rowsPersisted: 0, requiresTimestampHeal: false)

        let finalization = burst.consumeFinalization()

        XCTAssertEqual(
            finalization?.watermark,
            HistoricalReceiptWatermark(
                databaseInstanceId: "database-a",
                sourceIdentity: HistoricalReceiptWatermark.SourceIdentity(deviceId: "strap-a"),
                throughGeneration: emptyFinal.generation))
        XCTAssertGreaterThanOrEqual(finalization?.watermark?.throughGeneration ?? 0, productive.generation)
        XCTAssertFalse(burst.needsPublication)
        XCTAssertNil(burst.commitWatermark)
    }

    func testLateProductiveReceiptAfterDisconnectCanStillFinalize() {
        var burst = BackfillBurstPublication()
        let productive = receipt(generation: 50, rows: HistoricalStreamInsertCounts(hr: 1))

        // didDisconnectPeripheral consumes the current burst before the suspended commit returns.
        XCTAssertNil(burst.consumeFinalization())
        XCTAssertNil(burst.commitWatermark)

        // The late receipt must create a new publication edge instead of only arming private state.
        burst.record(receipt: productive)
        let finalization = burst.consumeFinalization()

        XCTAssertEqual(finalization?.watermark?.coordinates.count, 1)
        XCTAssertEqual(finalization?.watermark?.throughGeneration, productive.generation)
        XCTAssertNil(burst.commitWatermark)
    }

    func testProductiveReceiptsFromTwoSourcesRemainInOneWatermark() {
        var burst = BackfillBurstPublication()
        let sourceA = HistoricalReceiptWatermark.SourceIdentity(
            deviceId: "strap-a", lineage: "ble:A", epoch: 7)
        let sourceB = HistoricalReceiptWatermark.SourceIdentity(
            deviceId: "strap-b", lineage: "ble:B", epoch: 8)
        let receiptA = receipt(generation: 61, rows: HistoricalStreamInsertCounts(hr: 2), deviceId: "strap-a")
        let receiptB = receipt(generation: 12, rows: HistoricalStreamInsertCounts(hr: 3), deviceId: "strap-b")

        burst.record(receipt: receiptA, sourceIdentity: sourceA)
        burst.record(receipt: receiptB, sourceIdentity: sourceB)
        let finalization = burst.consumeFinalization()

        XCTAssertEqual(finalization?.watermark?.coordinates.map { $0.sourceIdentity.deviceId }, ["strap-a", "strap-b"])
        XCTAssertEqual(finalization?.watermark?.coordinates.map { $0.throughGeneration }, [61, 12])
        XCTAssertEqual(finalization?.watermark?.coordinates.map { $0.sourceIdentity.epoch }, [7, 8])
    }

    func testEmptyOnlyReceiptDoesNotArmLaterHealPublication() {
        var burst = BackfillBurstPublication()
        let empty = receipt(generation: 71, rows: HistoricalStreamInsertCounts())

        burst.record(receipt: empty)
        XCTAssertNil(burst.consumeFinalization())
        XCTAssertNil(burst.commitWatermark)

        burst.record(rowsPersisted: 0, requiresTimestampHeal: true)
        let healFinalization = burst.consumeFinalization()

        XCTAssertNotNil(healFinalization)
        XCTAssertNil(healFinalization?.watermark)
        XCTAssertNil(burst.commitWatermark)
        XCTAssertFalse(burst.needsPublication)
    }

    @MainActor
    func testFinalizationKeepsTimestampStatusButPublishesWatermarkIdentity() {
        let live = LiveState()
        let watermark = HistoricalReceiptWatermark(
            databaseInstanceId: "database-a",
            sourceIdentity: HistoricalReceiptWatermark.SourceIdentity(deviceId: "strap-a"),
            throughGeneration: 42)

        live.finalizeHistoricalSyncBurst(at: 2_000, watermark: watermark)

        XCTAssertEqual(live.finalizedHistoricalDataCommitWatermark, watermark)
        XCTAssertEqual(live.backfillDataAvailableAt, 2_000)
    }

    @MainActor
    func testLiveStateCarriesAllFinalizedSourceCoordinates() {
        let live = LiveState()
        let watermark = HistoricalReceiptWatermark(coordinates: [
            .init(databaseInstanceId: "database-a",
                  sourceIdentity: .init(deviceId: "strap-a", lineage: "ble:A", epoch: 1),
                  throughGeneration: 10),
            .init(databaseInstanceId: "database-a",
                  sourceIdentity: .init(deviceId: "strap-b", lineage: "ble:B", epoch: 2),
                  throughGeneration: 20),
        ])

        live.finalizeHistoricalSyncBurst(at: 3_000, watermark: watermark)

        XCTAssertEqual(live.finalizedHistoricalDataCommitWatermark, watermark)
        XCTAssertEqual(live.finalizedHistoricalBurst?.watermark, watermark)
        XCTAssertEqual(live.finalizedHistoricalBurst?.watermark?.coordinates.count, 2)
    }

    func testTimestampHealPublishesEvenWhenTheBadRowsWereRejected() {
        var burst = BackfillBurstPublication()

        burst.record(rowsPersisted: 0, requiresTimestampHeal: true)

        XCTAssertTrue(burst.consume())
    }

    func testEmptyBurstDoesNotRefreshTheDashboard() {
        var burst = BackfillBurstPublication()

        burst.record(rowsPersisted: 0, requiresTimestampHeal: false)

        XCTAssertFalse(burst.consume())
    }
}
