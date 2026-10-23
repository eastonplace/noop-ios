import Darwin
import Foundation
import GRDB
import XCTest
import WhoopProtocol
@testable import WhoopStore

final class AnalysisInputWitnessCostTests: XCTestCase {
    /// Both modes use the actual stream writer and identical rows. Override rows for a larger local
    /// qualification; timing has no assertion because scheduling/energy differ across hosts.
    func testActualIngestionAndDeleteCostsPreserveStoredRows() async throws {
        let count = max(100, min(Int(ProcessInfo.processInfo.environment["NOOP_D6_BENCH_ROWS"] ?? "") ?? 6_000, 180_000))
        var streams = Streams()
        for index in 0..<count {
            let ts = 20_520 * 86_400 + index * 30
            streams.hr.append(HRSample(ts: ts, bpm: 55 + index % 3))
            streams.rr.append(RRInterval(ts: ts, rrMs: 1000 + index % 11))
            streams.gravity.append(GravitySample(ts: ts, x: Double(index % 2) * 0.1, y: 0, z: 1))
        }
        var metrics: [String: Any] = ["rowsPerFamily": count, "families": 3, "fixtureOnly": true]
        var parity: [String] = []
        for mode in ["baseline", "witness"] {
            let store = try await WhoopStore.inMemory()
            if mode == "baseline" {
                let observation = await store.analysisInputObservation
                try await store.registryWriter.writeWithoutTransaction { db in db.remove(transactionObserver: observation) }
            }
            var cpu = clock(), started = Date()
            _ = try await store.insert(streams, deviceId: "witness-cost")
            metrics[mode + "BackfillCPUSeconds"] = Double(clock() - cpu) / Double(CLOCKS_PER_SEC)
            metrics[mode + "BackfillSeconds"] = Date().timeIntervalSince(started)
            cpu = clock(); started = Date()
            _ = try await store.insert(streams, deviceId: "witness-cost")
            metrics[mode + "NoOpCPUSeconds"] = Double(clock() - cpu) / Double(CLOCKS_PER_SEC)
            metrics[mode + "NoOpSeconds"] = Date().timeIntervalSince(started)
            cpu = clock(); started = Date()
            for batch in 0..<100 {
                let start = 20_600 * 86_400 + batch * 60
                let incoming = Streams(
                    hr: (0..<60).map { HRSample(ts: start + $0, bpm: 60) },
                    rr: (0..<60).map { RRInterval(ts: start + $0, rrMs: 1000) },
                    gravity: (0..<60).map { GravitySample(ts: start + $0, x: 0, y: 0, z: 1) })
                _ = try await store.insert(incoming, deviceId: "witness-cost")
            }
            metrics[mode + "Active100CommitsCPUSeconds"] = Double(clock() - cpu) / Double(CLOCKS_PER_SEC)
            metrics[mode + "Active100CommitsSeconds"] = Date().timeIntervalSince(started)
            let values = try await store.registryWriter.read { db in
                try String.fetchOne(db, sql: """
                    SELECT (SELECT COUNT(*) || ':' || SUM(bpm) FROM hrSample) || '|'
                         || (SELECT COUNT(*) || ':' || SUM(rrMs) FROM rrInterval) || '|'
                         || (SELECT COUNT(*) || ':' || SUM(x) FROM gravitySample)
                    """)!
            }
            parity.append(values)
            if mode == "witness" {
                cpu = clock(); started = Date()
                for _ in 0..<100 { _ = try await store.analysisInputWitness() }
                metrics["warmWitnessMeanCPUSeconds"] = Double(clock() - cpu) / Double(CLOCKS_PER_SEC) / 100
                metrics["warmWitnessMeanSeconds"] = Date().timeIntervalSince(started) / 100
            }
            cpu = clock(); started = Date()
            try await store.registryWriter.write { db in try db.execute(sql: "DELETE FROM hrSample") }
            metrics[mode + "BulkDeleteCPUSeconds"] = Double(clock() - cpu) / Double(CLOCKS_PER_SEC)
            metrics[mode + "BulkDeleteSeconds"] = Date().timeIntervalSince(started)
            try await store.close()
        }
        XCTAssertEqual(parity.first, parity.last, "the observer cannot alter actual ingested values")
        metrics["storedValuesParity"] = parity.first == parity.last
        let bytes = try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys, .prettyPrinted])
        try bytes.write(to: URL(fileURLWithPath: "/private/tmp/noop-d6-production-cost.json"))
        print("D6_STORE_COST " + String(decoding: bytes, as: UTF8.self))
    }
}
