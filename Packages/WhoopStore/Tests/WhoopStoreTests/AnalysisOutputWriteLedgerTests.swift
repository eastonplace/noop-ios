import Foundation
import GRDB
import XCTest
@testable import WhoopStore

final class AnalysisOutputWriteLedgerTests: XCTestCase {
    private func daily(_ value: Double, day: String = "2026-03-01") -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
                    disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil, strain: nil,
                    exerciseCount: nil, activeKcalEst: value)
    }

    func testOnlyThisPassContiguousDailyAndSeriesCommitsCanAdvanceTheStartWitness() async throws {
        let store = try await WhoopStore.inMemory()
        let start = try await store.analysisInputWitness()
        let ledger = AnalysisOutputWriteLedger()
        _ = try await store.upsertDailyMetrics([daily(100)], deviceId: "computed", outputWrites: ledger)
        _ = try await store.upsertMetricSeries([MetricPoint(day: "2026-03-01", key: "fill", value: 100)],
                                              deviceId: "computed", outputWrites: ledger)
        let end = try await store.analysisInputWitness()
        let acknowledged = start.acknowledgingOwnOutputs(ledger)
        XCTAssertEqual(acknowledged.signature(tables: ["dailyMetric", "metricSeries"]),
                       end.signature(tables: ["dailyMetric", "metricSeries"]))
        XCTAssertEqual(start.signature(tables: ["hrSample", "sleepSession"]),
                       acknowledged.signature(tables: ["hrSample", "sleepSession"]))
        try await store.close()
    }

    func testUnownedDailyOrSeriesCommitBeforeBetweenOrAfterOwnWritesCannotBeAcknowledged() async throws {
        for isDaily in [true, false] {
            for position in 0..<3 {
                let store = try await WhoopStore.inMemory()
                let start = try await store.analysisInputWitness()
                let ledger = AnalysisOutputWriteLedger()
                func owned(_ value: Double) async throws {
                    if isDaily {
                        _ = try await store.upsertDailyMetrics([daily(value)], deviceId: "computed", outputWrites: ledger)
                    } else {
                        _ = try await store.upsertMetricSeries([MetricPoint(day: "2026-03-01", key: "fill", value: value)],
                                                              deviceId: "computed", outputWrites: ledger)
                    }
                }
                func unrelated() async throws {
                    if isDaily {
                        _ = try await store.upsertDailyMetrics([daily(75, day: "2026-02-28")], deviceId: "imported")
                    } else {
                        _ = try await store.upsertMetricSeries([MetricPoint(day: "2026-02-28", key: "import", value: 75)],
                                                              deviceId: "imported")
                    }
                }
                if position == 0 { try await unrelated() }
                try await owned(100)
                if position == 1 { try await unrelated() }
                try await owned(110)
                if position == 2 { try await unrelated() }
                let end = try await store.analysisInputWitness()
                let acknowledged = start.acknowledgingOwnOutputs(ledger)
                let table = isDaily ? "dailyMetric" : "metricSeries"
                XCTAssertNotEqual(acknowledged.signature(tables: [table]), end.signature(tables: [table]),
                                  "unowned \(table) commit at position \(position) must wake the next pass")
                try await store.close()
            }
        }
    }

    func testOwnOutputAcknowledgmentRetainsRawFallbackControlAndUnknownStartFences() async throws {
        let store = try await WhoopStore.inMemory()
        let start = try await store.analysisInputWitness()
        let ledger = AnalysisOutputWriteLedger()
        _ = try await store.upsertDailyMetrics([daily(100)], deviceId: "computed", outputWrites: ledger)
        try await store.registryWriter.write { db in
            try db.execute(sql: "INSERT INTO hrSample(deviceId,ts,bpm) VALUES('raw',1000,55)")
            try db.execute(sql: "INSERT INTO sleepSession(deviceId,startTs,endTs) VALUES('computed',1000,2000)")
            try db.execute(sql: "INSERT INTO liftStrainControl(scope,disabled,updatedAt) VALUES('global',1,0)")
        }
        _ = try await store.upsertMetricSeries([MetricPoint(day: "2026-03-01", key: "fill", value: 100)],
                                              deviceId: "computed", outputWrites: ledger)
        let end = try await store.analysisInputWitness()
        let acknowledged = start.acknowledgingOwnOutputs(ledger)
        for table in ["hrSample", "sleepSession", "liftStrainControl"] {
            XCTAssertNotEqual(acknowledged.signature(tables: [table]), end.signature(tables: [table]), table)
        }
        try await store.registryWriter.write { db in try db.notifyChanges(in: .fullDatabase) }
        let unknown = try await store.analysisInputWitness()
        XCTAssertNotEqual(acknowledged.signature(tables: ["dailyMetric"]), unknown.signature(tables: ["dailyMetric"]))
        try await store.close()
    }

    func testExtraReplaceUniquenessCannotHideAnImplicitlyDeletedFallbackRow() async throws {
        for table in ["dailyMetric", "metricSeries"] {
            let store = try await WhoopStore.inMemory()
            try await store.registryWriter.write { db in
                var definition = try XCTUnwrap(String.fetchOne(db,
                    sql: "SELECT sql FROM sqlite_master WHERE type='table' AND name=?", arguments: [table]))
                let end = try XCTUnwrap(definition.lastIndex(of: ")"))
                let valueColumn = table == "dailyMetric" ? "activeKcalEst" : "value"
                definition.insert(contentsOf: ", UNIQUE(\(valueColumn)) ON CONFLICT REPLACE", at: end)
                try db.execute(sql: "ALTER TABLE \(table) RENAME TO witnessOldOutput")
                try db.execute(sql: definition)
                try db.execute(sql: "DROP TABLE witnessOldOutput")
            }
            if table == "dailyMetric" {
                _ = try await store.upsertDailyMetrics([daily(75, day: "2026-02-28")], deviceId: "computed")
            } else {
                _ = try await store.upsertMetricSeries([MetricPoint(day: "2026-02-28", key: "fill", value: 75)], deviceId: "computed")
            }
            let start = try await store.analysisInputWitness()
            let ledger = AnalysisOutputWriteLedger()
            if table == "dailyMetric" {
                _ = try await store.upsertDailyMetrics([daily(75)], deviceId: "computed", outputWrites: ledger)
                let rows = try await store.dailyMetrics(deviceId: "computed", from: "2026-02-28", to: "2026-03-01")
                XCTAssertEqual(rows.map(\.day), ["2026-03-01"])
            } else {
                _ = try await store.upsertMetricSeries([MetricPoint(day: "2026-03-01", key: "fill", value: 75)],
                                                      deviceId: "computed", outputWrites: ledger)
                let rows = try await store.metricSeries(deviceId: "computed", key: "fill", from: "2026-02-28", to: "2026-03-01")
                XCTAssertEqual(rows.map(\.day), ["2026-03-01"])
            }
            let end = try await store.analysisInputWitness()
            XCTAssertNotEqual(start.acknowledgingOwnOutputs(ledger).signature(tables: [table]),
                              end.signature(tables: [table]), "implicit deletion in \(table) is fallback input")
            try await store.close()
        }
    }

    func testTriggerFeedbackDuringAnOwnedWriteStillRequiresSettlement() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertDailyMetrics([daily(100), daily(75, day: "2026-02-28")], deviceId: "computed")
        try await store.registryWriter.write { db in
            try db.execute(sql: """
                CREATE TRIGGER witnessDailyFeedback AFTER UPDATE ON dailyMetric
                WHEN NEW.day='2026-03-01'
                BEGIN UPDATE dailyMetric SET avgHrv=55 WHERE day='2026-02-28'; END
                """)
        }
        let start = try await store.analysisInputWitness()
        let ledger = AnalysisOutputWriteLedger()
        _ = try await store.upsertDailyMetrics([daily(110)], deviceId: "computed", outputWrites: ledger)
        let end = try await store.analysisInputWitness()
        XCTAssertNotEqual(start.acknowledgingOwnOutputs(ledger).signature(tables: ["dailyMetric"]),
                          end.signature(tables: ["dailyMetric"]))
        try await store.close()
    }

    func testFailedOwnedTransactionCannotPublishAnAcknowledgment() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertDailyMetrics([daily(100)], deviceId: "computed")
        try await store.registryWriter.write { db in
            try db.execute(sql: """
                CREATE TRIGGER witnessRejectDaily BEFORE UPDATE ON dailyMetric
                BEGIN SELECT RAISE(ABORT,'fixture rollback'); END
                """)
        }
        let start = try await store.analysisInputWitness()
        let ledger = AnalysisOutputWriteLedger()
        do {
            _ = try await store.upsertDailyMetrics([daily(110)], deviceId: "computed", outputWrites: ledger)
            XCTFail("expected aborted output transaction")
        } catch {}
        let end = try await store.analysisInputWitness()
        XCTAssertEqual(start.acknowledgingOwnOutputs(ledger), end)
        try await store.close()
    }
}
