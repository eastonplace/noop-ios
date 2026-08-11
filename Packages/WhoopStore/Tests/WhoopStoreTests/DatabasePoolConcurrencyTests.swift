import XCTest
import GRDB
import WhoopProtocol
@testable import WhoopStore

/// #755: `WhoopStore` opens its file-backed connection as a GRDB `DatabasePool` (WAL) so the
/// dashboard's reads run CONCURRENTLY with the backfill's bulk writes instead of serializing behind
/// them on a single `DatabaseQueue`. These tests prove (a) a file-backed store round-trips writes and
/// reads unchanged, and (b) a read issued WHILE a write transaction is still open returns the
/// last-committed snapshot immediately, rather than blocking until the writer commits.
final class DatabasePoolConcurrencyTests: XCTestCase {

    private func tempPath() -> String {
        NSTemporaryDirectory() + "whoopstore-pool-\(UUID().uuidString).sqlite"
    }

    private func removeDB(_ path: String) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    /// The file-backed store (now Pool-backed) writes then reads the same rows back unchanged:
    /// the migration from Queue to Pool must not alter any stored data or query result.
    func testFileBackedStoreWritesAndReadsBackUnchanged() async throws {
        let path = tempPath()
        defer { removeDB(path) }

        let store = try await WhoopStore(path: path)
        let streams = Streams(hr: [
            HRSample(ts: 1_000, bpm: 60),
            HRSample(ts: 1_001, bpm: 61),
            HRSample(ts: 1_002, bpm: 62),
        ])
        let inserted = try await store.insert(streams, deviceId: "dev")
        XCTAssertEqual(inserted.hr, 3)

        let counts = try await store.storageStats_rowCountsForTest()
        XCTAssertEqual(counts.hr, 3, "rows written via the Pool must read back identically")
    }

    /// CORE #755 ASSERTION: under a `DatabasePool`, a read started while a write transaction is
    /// still open does NOT block on the writer; it returns the last committed snapshot at once.
    ///
    /// The writer task opens a `.write`, signals that it is inside the transaction, then parks on a
    /// semaphore (simulating a long backfill chunk). A second task issues a `.read`; with a serial
    /// `DatabaseQueue` that read would be stuck behind the open write, but a Pool serves it from the
    /// WAL snapshot. We assert the read finishes (returns the pre-write committed value) BEFORE we
    /// release the writer. Then, after the writer commits, a fresh read sees the new value, proving
    /// reads still observe only committed data, never a partial write.
    func testConcurrentReadDuringOpenWriteReturnsCommittedData() async throws {
        let path = tempPath()
        defer { removeDB(path) }

        // Open the same configuration the store uses (WAL via Pool) directly so the test can hold a
        // write transaction open and observe a concurrent read. A single shared seed row is committed
        // first so the snapshot read has a known committed value.
        var config = Configuration()
        config.busyMode = .timeout(5)
        let pool = try DatabasePool(path: path, configuration: config)
        try await pool.write { db in
            try db.execute(sql: "CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER NOT NULL)")
            try db.execute(sql: "INSERT INTO t (id, v) VALUES (1, 100)")
        }

        let insideWrite = DispatchSemaphore(value: 0)   // writer → test: transaction is open
        let releaseWrite = DispatchSemaphore(value: 0)   // test → writer: you may commit now

        // Long writer: opens a transaction, mutates the row, signals, then parks until released.
        let writer = Task.detached {
            try pool.write { db in
                try db.execute(sql: "UPDATE t SET v = 200 WHERE id = 1")
                insideWrite.signal()
                releaseWrite.wait()   // hold the write transaction open
            }
        }

        // Wait until the writer is provably inside its open transaction.
        XCTAssertEqual(insideWrite.wait(timeout: .now() + 5), .success,
                       "writer never entered its transaction")

        // Concurrent read WHILE the write is still open. On a Pool this returns the last committed
        // snapshot (v = 100) immediately; on a serial Queue it would block until the writer commits.
        let snapshotValue = try await withThrowingTaskGroup(of: Int.self) { group -> Int in
            group.addTask {
                try pool.read { db in
                    try Int.fetchOne(db, sql: "SELECT v FROM t WHERE id = 1") ?? -1
                }
            }
            // Bound the read so a regression (read blocking on the writer) fails fast instead of
            // hanging the suite: the read must complete while the writer is still parked.
            group.addTask {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                throw ConcurrencyTimeout.readBlockedOnWriter
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
        XCTAssertEqual(snapshotValue, 100,
                       "a concurrent read during an open write must see the committed snapshot (100), not the uncommitted 200")

        // Release the writer, let it commit, and confirm a subsequent read sees the new value:
        // reads observe committed data, just without serializing behind the writer.
        releaseWrite.signal()
        try await writer.value
        let committedValue = try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT v FROM t WHERE id = 1") ?? -1
        }
        XCTAssertEqual(committedValue, 200, "after the writer commits, reads must see the new value")
    }

    /// #755 review finding-1: every OTHER store test uses `inMemory()` (a `DatabaseQueue`) or, above, a
    /// bare `Configuration()`, so none drive the production `init(path:)` config. Its `prepareDatabase`
    /// PRAGMA block (synchronous/cache_size/mmap_size/temp_store) must run on EVERY connection a Pool
    /// opens, the writer AND each reader, not just once. This opens the REAL store and reads
    /// `PRAGMA cache_size` + `journal_mode` back off a pooled reader connection: `-16000` and `wal`
    /// prove `prepareDatabase` applied per-connection, closing the inMemory/Queue blind spot the
    /// migration's read/write concurrency depends on (a writer-only pragma would be the classic footgun).
    func testProductionPoolRunsPrepareDatabaseOnReaderConnections() async throws {
        let path = tempPath()
        defer { removeDB(path) }

        let store = try await WhoopStore(path: path)
        let pool = store.registryWriter   // the production-configured DatabasePool

        // A `.read` runs on a pooled reader connection; cache_size reflects its prepareDatabase pragma.
        let cacheSize = try await pool.read { db in
            try Int.fetchOne(db, sql: "PRAGMA cache_size") ?? 0
        }
        XCTAssertEqual(cacheSize, -16000,
                       "production prepareDatabase pragmas must apply on pooled reader connections, not just the writer")

        let journalMode = try await pool.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? ""
        }
        XCTAssertEqual(journalMode.lowercased(), "wal", "DatabasePool must put the file in WAL mode")
    }

    /// #261: two openers hit the SAME file at once (BLEManager's backfill store + the MetricsRepository)
    /// on a cold background relaunch right after an update adds a migration. Before the `StoreOpenGate`,
    /// both migrators read "migration unapplied", both applied it, and the loser's bookkeeping INSERT
    /// threw `UNIQUE constraint failed: grdb_migrations.identifier` — that open failed and the offload
    /// stalled. This opens the same FRESH (unmigrated) path from many tasks concurrently — the exact
    /// window — and asserts every open succeeds AND lands on a usable, fully-migrated store. Serialized
    /// open+migrate makes this deterministic; without it the concurrent migrators race and some throw.
    func testConcurrentOpensOfSameFreshFileAllSucceed() async throws {
        let path = tempPath()
        defer { removeDB(path) }

        // Open the same not-yet-created file from 16 tasks at once. Every handle must reuse one pool,
        // so migration and all later writes have one process-wide owner.
        let writers = try await withThrowingTaskGroup(of: ObjectIdentifier.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    let store = try await WhoopStore(path: path)
                    // A trivial read proves the returned store is migrated and usable, not a half-open
                    // handle that merely dodged the throw.
                    let applied = try await store.registryWriter.read { db in
                        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations") ?? 0
                    }
                    XCTAssertGreaterThan(applied, 0, "each concurrent open must land on a fully-migrated store")
                    return ObjectIdentifier(store.registryWriter as AnyObject)
                }
            }
            var result: [ObjectIdentifier] = []
            for try await writer in group { result.append(writer) }
            return result
        }
        XCTAssertEqual(Set(writers).count, 1,
                       "all WhoopStore handles for one path must share one writer pool")
    }

    /// Device regression: BLEManager and MetricsRepository used to open separate pools. A long write in
    /// one pool could exhaust the other's five-second busy timeout and fail a HISTORY_END commit with
    /// `SQLITE_BUSY`. Shared-pool writes queue behind one another inside GRDB and both commit.
    func testSamePathHandlesSerializeWritesWithoutSQLiteBusy() async throws {
        let path = tempPath()
        defer { removeDB(path) }

        let bleStore = try await WhoopStore(path: path)
        let repositoryStore = try await WhoopStore(path: path)
        XCTAssertEqual(
            ObjectIdentifier(bleStore.registryWriter as AnyObject),
            ObjectIdentifier(repositoryStore.registryWriter as AnyObject))

        let writerEntered = DispatchSemaphore(value: 0)
        let releaseWriter = DispatchSemaphore(value: 0)
        let repositoryWrite = Task.detached {
            try repositoryStore.registryWriter.write { db in
                try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('repo', 1, 60)")
                writerEntered.signal()
                releaseWriter.wait()
            }
        }
        XCTAssertEqual(writerEntered.wait(timeout: .now() + 5), .success)

        let bleWrite = Task.detached {
            try await bleStore.insert(Streams(hr: [HRSample(ts: 2, bpm: 61)]), deviceId: "ble")
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        releaseWriter.signal()
        try await repositoryWrite.value
        let inserted = try await bleWrite.value
        XCTAssertEqual(inserted.hr, 1)

        let count = try await bleStore.registryWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hrSample") ?? 0
        }
        XCTAssertEqual(count, 2)
    }

    /// Atomic replacement closes the currently shared pool once and removes it from the path cache.
    /// A later open must receive a fresh, migrated pool rather than the closed generation.
    func testCloseEvictsSharedPoolAndReopenGetsFreshWriter() async throws {
        let path = tempPath()
        defer { removeDB(path) }

        let first = try await WhoopStore(path: path)
        let staleSibling = try await WhoopStore(path: path)
        let firstWriter = ObjectIdentifier(first.registryWriter as AnyObject)
        try await first.close()

        let reopened = try await WhoopStore(path: path)
        XCTAssertNotEqual(firstWriter, ObjectIdentifier(reopened.registryWriter as AnyObject))
        try await staleSibling.close()
        let inserted = try await reopened.insert(
            Streams(hr: [HRSample(ts: 3, bpm: 62)]),
            deviceId: "reopened")
        XCTAssertEqual(inserted.hr, 1)
    }

    /// Local performance guard for the shared writer owner. Alternating handles exercises the same
    /// BLEManager/Repository route as production without adding a second SQLite writer connection.
    func testSharedPoolCommitLatencyBenchmark() async throws {
        let path = tempPath()
        defer { removeDB(path) }

        let bleStore = try await WhoopStore(path: path)
        let repositoryStore = try await WhoopStore(path: path)
        var milliseconds: [Double] = []
        milliseconds.reserveCapacity(200)

        for index in 0..<200 {
            let store = index.isMultiple(of: 2) ? bleStore : repositoryStore
            let started = DispatchTime.now().uptimeNanoseconds
            _ = try await store.insert(
                Streams(hr: [HRSample(ts: 10_000 + index, bpm: 60 + index % 20)]),
                deviceId: "benchmark")
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            milliseconds.append(Double(elapsed) / 1_000_000)
        }

        let sorted = milliseconds.sorted()
        let p50 = sorted[99]
        let p95 = sorted[189]
        let maximum = sorted.last ?? 0
        print(String(format: "SHARED_POOL_COMMIT_TIMING n=200 p50=%.3fms p95=%.3fms max=%.3fms",
                     p50, p95, maximum))
        XCTAssertLessThan(p95, 50, "shared-pool small commits must stay responsive")
        XCTAssertLessThan(maximum, 500, "shared-pool small commits must not produce a UI-scale stall")
    }

    private enum ConcurrencyTimeout: Error { case readBlockedOnWriter }
}
