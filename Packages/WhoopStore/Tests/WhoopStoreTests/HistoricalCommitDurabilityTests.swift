import XCTest
import GRDB
import WhoopProtocol
@testable import WhoopStore

/// The Backfiller ACKs a history chunk (the strap then frees its only copy) as soon as
/// `commitHistoricalChunkResult` returns. Under WAL + `synchronous = NORMAL` that commit is only in the
/// OS page cache, so a kernel panic / hard reset could roll it back with the strap already trimmed.
/// The chunk commit must therefore run at `synchronous = FULL` (fsynced WAL), while the connection
/// stays at NORMAL for every other write.
final class HistoricalCommitDurabilityTests: XCTestCase {
    private let deviceId = "strap-a"

    /// Records `PRAGMA synchronous` on the writer connection at the moment each transaction commits.
    private final class SynchronousProbe: TransactionObserver, @unchecked Sendable {
        private(set) var levelsAtCommit: [Int] = []
        func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { true }
        func databaseDidChange(with event: DatabaseEvent) {}
        func databaseDidCommit(_ db: Database) {
            if let level = try? Int.fetchOne(db, sql: "PRAGMA synchronous") { levelsAtCommit.append(level) }
        }
        func databaseDidRollback(_ db: Database) {}
    }

    func testHistoricalChunkCommitRunsAtSynchronousFullThenRestoresNormal() async throws {
        let path = NSTemporaryDirectory() + "whoopstore-durable-\(UUID().uuidString).sqlite"
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } }

        let store = try await WhoopStore(path: path)
        try await store.upsertDevice(id: deviceId, mac: nil, name: nil)

        let probe = SynchronousProbe()
        store.registryWriter.add(transactionObserver: probe, extent: .observerLifetime)

        let frames: [[UInt8]] = [[0xAA, 0x18, 0x00, 0xFF, 0x28, 0x02]]
        let input = HistoricalReceivedFrameFingerprintInput(
            orderedFrames: frames,
            protocolMetadata: Data([0x49]),
            historyEndFrame: Data([0xAA, 0x02, 0x00, 0x00, 0x00, 0x00]),
            minReceivedTs: 1_700_000_000,
            maxReceivedTs: 1_700_000_005
        )
        let fingerprint = try WhoopStore.historicalReceivedFrameFingerprint(
            input: input, deviceId: deviceId, trim: 5, chunkEndUnix: 1_700_000_005
        )
        _ = try await store.commitHistoricalChunk(
            streams: Streams(hr: [HRSample(ts: 1_000, bpm: 60)]),
            deviceId: deviceId,
            trim: 5,
            chunkEndUnix: 1_700_000_005,
            rawBatch: nil,
            committedAt: 1_700_000_010,
            fingerprint: fingerprint,
            fingerprintInput: input
        )

        XCTAssertEqual(probe.levelsAtCommit, [2],
                       "the chunk commit that precedes the trim ACK must be fsynced (synchronous = FULL = 2)")
        let after = try await store.registryWriter.writeWithoutTransaction { try Int.fetchOne($0, sql: "PRAGMA synchronous") }
        XCTAssertEqual(after, 1, "other writes on the connection stay at NORMAL")
    }
}
