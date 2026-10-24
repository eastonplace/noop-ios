import XCTest
import GRDB
import StrandAnalytics
import WhoopStore
@testable import NOOP

@MainActor
final class RepositorySleepMutationTests: XCTestCase {
    private let detectedStart = 1_792_454_400
    private let canonical = "my-whoop-noop"

    private func row(edited: Bool = false, adjusted: Int? = nil) -> CachedSleepSession {
        CachedSleepSession(startTs: detectedStart, endTs: detectedStart + 8 * 3_600,
                           efficiency: 0.9, restingHr: 52, avgHrv: 61,
                           stagesJSON: "{\"awake\":30,\"light\":280,\"deep\":80,\"rem\":90}",
                           userEdited: edited, startTsAdjusted: adjusted)
    }

    private func repository(_ store: WhoopStore, active: String = "my-whoop") -> Repository {
        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(store)
        repo.adoptActiveDeviceId(active)
        return repo
    }

    private func preservingDismissals(_ body: () async throws -> Void) async rethrows {
        let key = Repository.dismissedSleepDefaultsKey
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try await body()
    }

    private func rows(_ store: WhoopStore, owner: String) async throws -> [CachedSleepSession] {
        try await store.sleepSessions(deviceId: owner, from: detectedStart - 3_600,
                                     to: detectedStart + 9 * 3_600, limit: 10)
    }

    func testEditCanonicalNightAfterSourceReadd() async throws {
        let store = try await WhoopStore.inMemory()
        let original = row()
        _ = try await store.upsertSleepSessions([original], deviceId: canonical)
        let repo = repository(store, active: "whoop-readded")

        await repo.editSleepTimes(detectedStartTs: original.startTs, oldEndTs: original.endTs,
                                 storedStagesJSON: original.stagesJSON,
                                 newStartTs: original.startTs + 40 * 60, newEndTs: original.endTs)

        let saved = try await rows(store, owner: canonical)
        let active = try await rows(store, owner: "whoop-readded-noop")
        XCTAssertEqual(saved.first?.effectiveStartTs, original.startTs + 40 * 60)
        XCTAssertEqual(saved.first?.userEdited, true)
        XCTAssertTrue(active.isEmpty)
    }

    func testDeleteCanonicalNightAfterSourceReaddRestoresSameOwnerAndTracks() async throws {
        try await preservingDismissals {
            let store = try await WhoopStore.inMemory()
            let original = row()
            _ = try await store.upsertSleepSessions([original], deviceId: canonical)
            _ = try await store.persistSessionMotion(deviceId: canonical, sessionStart: detectedStart,
                                                      motionEpochs: [0.1, 0.4])
            _ = try await store.persistSessionSleepState(deviceId: canonical, sessionStart: detectedStart,
                                                          states: [1, 3])
            let repo = repository(store, active: "whoop-readded")

            let deleted = await repo.deleteSleepSession(detectedStartTs: detectedStart, endTs: original.endTs)
            let snapshot = try XCTUnwrap(deleted)
            let afterDelete = try await rows(store, owner: canonical)
            XCTAssertTrue(afterDelete.isEmpty)
            XCTAssertEqual(snapshot.ownerDeviceId, canonical)
            XCTAssertEqual(repo.dismissedSleepWindows().count, 1)

            await repo.undoDeleteSleepSession(snapshot)

            let restored = try await rows(store, owner: canonical)
            let active = try await rows(store, owner: "whoop-readded-noop")
            let motion = try await store.sessionMotion(deviceId: canonical, sessionStart: detectedStart)
            let states = try await store.sessionSleepState(deviceId: canonical, sessionStart: detectedStart)
            XCTAssertEqual(restored, [original])
            XCTAssertTrue(active.isEmpty)
            XCTAssertEqual(motion, [0.1, 0.4])
            XCTAssertEqual(states, [1, 3])
            XCTAssertTrue(repo.dismissedSleepWindows().isEmpty)
        }
    }

    func testForwardEditedNightDeletionOffersUndoWithoutTombstone() async throws {
        try await preservingDismissals {
            let store = try await WhoopStore.inMemory()
            let original = row(edited: true, adjusted: detectedStart + 40 * 60)
            _ = try await store.upsertSleepSessions([original], deviceId: canonical)
            let repo = repository(store)

            let deleted = await repo.deleteSleepSession(detectedStartTs: detectedStart, endTs: original.endTs)
            let snapshot = try XCTUnwrap(deleted)
            XCTAssertEqual(snapshot.session, original)
            XCTAssertTrue(repo.dismissedSleepWindows().isEmpty)
            await repo.undoDeleteSleepSession(snapshot)
            let restored = try await rows(store, owner: canonical)
            XCTAssertEqual(restored, [original])
        }
    }

    func testMissingSleepDeletionDoesNotCreateTombstoneOrRescore() async throws {
        try await preservingDismissals {
            let store = try await WhoopStore.inMemory()
            let repo = repository(store)

            let snapshot = await repo.deleteSleepSession(detectedStartTs: detectedStart, endTs: row().endTs)

            XCTAssertNil(snapshot)
            XCTAssertTrue(repo.dismissedSleepWindows().isEmpty)
            XCTAssertTrue(repo.editedDayRescoreQueue.timestamps.isEmpty)
        }
    }

    func testUnchangedSecondImportedSleepEditDoesNotTrimStagesAgain() async throws {
        let store = try await WhoopStore.inMemory()
        let original = row()
        _ = try await store.upsertSleepSessions([original], deviceId: "my-whoop")
        let repo = repository(store)
        let start = detectedStart + 40 * 60

        await repo.editSleepTimes(detectedStartTs: detectedStart, oldEndTs: original.endTs,
                                 storedStagesJSON: original.stagesJSON, newStartTs: start, newEndTs: original.endTs)
        let firstRows = try await rows(store, owner: "my-whoop")
        let first = try XCTUnwrap(firstRows.first)
        await repo.editSleepTimes(detectedStartTs: detectedStart, oldEndTs: first.endTs,
                                 storedStagesJSON: first.stagesJSON, newStartTs: start, newEndTs: first.endTs)

        let secondRows = try await rows(store, owner: "my-whoop")
        let second = try XCTUnwrap(secondRows.first)
        let data = try XCTUnwrap(second.stagesJSON?.data(using: .utf8))
        let minutes = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Double])
        XCTAssertEqual(minutes, ["awake": 0, "light": 270, "deep": 80, "rem": 90])
        XCTAssertEqual(second.effectiveStartTs, start)
    }

    func testFailedDeleteDoesNotCreateTombstoneOrUndoSnapshot() async throws {
        try await preservingDismissals {
            let store = try await WhoopStore.inMemory()
            let original = row()
            _ = try await store.upsertSleepSessions([original], deviceId: canonical)
            try await store.registryWriter.write { db in
                try db.execute(sql: """
                    CREATE TRIGGER fail_sleep_delete BEFORE DELETE ON sleepSession
                    BEGIN SELECT RAISE(ABORT, 'injected delete failure'); END
                    """)
            }
            let repo = repository(store)

            let snapshot = await repo.deleteSleepSession(detectedStartTs: detectedStart, endTs: original.endTs)

            let saved = try await rows(store, owner: canonical)
            XCTAssertNil(snapshot)
            XCTAssertEqual(saved, [original])
            XCTAssertTrue(repo.dismissedSleepWindows().isEmpty)
            XCTAssertTrue(repo.editedDayRescoreQueue.timestamps.isEmpty)
        }
    }

    func testUndoConflictPreservesNewerRowAndTombstone() async throws {
        try await preservingDismissals {
            let store = try await WhoopStore.inMemory()
            let original = row()
            _ = try await store.upsertSleepSessions([original], deviceId: canonical)
            let repo = repository(store)
            let deleted = await repo.deleteSleepSession(detectedStartTs: detectedStart, endTs: original.endTs)
            let snapshot = try XCTUnwrap(deleted)
            let newer = row(edited: true, adjusted: detectedStart + 3_600)
            _ = try await store.upsertSleepSessions([newer], deviceId: canonical)

            let restored = await repo.undoDeleteSleepSession(snapshot)

            let saved = try await rows(store, owner: canonical)
            XCTAssertFalse(restored)
            XCTAssertEqual(saved, [newer])
            XCTAssertEqual(repo.dismissedSleepWindows().count, 1)
        }
    }

    func testHabitualTimingMatchesEngineAcrossDSTAndMainNightSelection() async throws {
        let store = try await WhoopStore.inMemory()
        let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) throws -> Date {
            try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                            hour: hour, minute: minute)))
        }
        let first = try date(2026, 10, 18, 3)
        let now = try date(2026, 11, 15, 12)
        var history: [CachedSleepSession] = []
        for index in 0..<28 {
            let midpoint = try XCTUnwrap(calendar.date(byAdding: .day, value: index, to: first))
            let ts = Int(midpoint.timeIntervalSince1970)
            history.append(CachedSleepSession(startTs: ts - 4 * 3_600, endTs: ts + 4 * 3_600,
                                               efficiency: nil, restingHr: nil, avgHrv: nil, stagesJSON: nil))
        }
        _ = try await store.upsertSleepSessions(history, deviceId: canonical)
        let repo = repository(store)
        let actual = await repo.habitualMidsleepSec(days: 30, now: now, timeZone: zone)
        let engine = await IntelligenceEngine.computeHabitualMidsleep(
            store: store, importedId: "my-whoop", computedId: canonical,
            windowStart: Int(try date(2026, 10, 16, 12).timeIntervalSince1970),
            windowEnd: Int(try date(2026, 11, 16, 12).timeIntervalSince1970), timeZone: zone)

        XCTAssertEqual(actual, 3 * 3_600)
        XCTAssertEqual(actual, engine)
        let candidates = [
            SleepStageTotals.NightBlock(start: Int(try date(2026, 11, 14, 21, 50).timeIntervalSince1970),
                                       end: Int(try date(2026, 11, 15, 1, 50).timeIntervalSince1970)),
            SleepStageTotals.NightBlock(start: Int(try date(2026, 11, 15, 3, 30).timeIntervalSince1970),
                                       end: Int(try date(2026, 11, 15, 7, 30).timeIntervalSince1970)),
        ]
        let offset = zone.secondsFromGMT(for: now)
        let selected = SleepStageTotals.mainNightGroupIndices(candidates, offsetSec: offset,
                                                               habitualMidsleepSec: actual)
        XCTAssertEqual(selected, [1])
        XCTAssertEqual(selected, SleepStageTotals.mainNightGroupIndices(
            candidates, offsetSec: offset, habitualMidsleepSec: engine))
    }

    func testHabitualTimingDoesNotPromoteShiftedDuplicatesPastHistoryGate() async throws {
        let store = try await WhoopStore.inMemory()
        let zone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let first = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 1)))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 12)))
        var originals: [CachedSleepSession] = []
        var shifted: [CachedSleepSession] = []
        for index in 0..<7 {
            let midpoint = try XCTUnwrap(calendar.date(byAdding: .day, value: index * 2, to: first))
            let ts = Int(midpoint.timeIntervalSince1970)
            originals.append(CachedSleepSession(startTs: ts - 4 * 3_600, endTs: ts + 4 * 3_600,
                                                 efficiency: nil, restingHr: nil, avgHrv: nil, stagesJSON: nil))
            shifted.append(CachedSleepSession(startTs: ts - 8 * 3_600, endTs: ts - 3_600,
                                               efficiency: nil, restingHr: nil, avgHrv: nil, stagesJSON: nil))
        }
        _ = try await store.upsertSleepSessions(originals, deviceId: canonical)
        _ = try await store.upsertSleepSessions(shifted, deviceId: "my-whoop")
        let repo = repository(store)

        let actual = await repo.habitualMidsleepSec(days: 30, now: now, timeZone: zone)
        let engine = await IntelligenceEngine.computeHabitualMidsleep(
            store: store, importedId: "my-whoop", computedId: canonical,
            windowStart: Int(first.timeIntervalSince1970) - 30 * 86_400,
            windowEnd: Int(now.timeIntervalSince1970), timeZone: zone)

        XCTAssertNil(actual, "seven nights duplicated under shifted timestamps must remain below the 14-day gate")
        XCTAssertEqual(actual, engine)
    }
}
