#if os(iOS)
import XCTest
import WhoopStore
@testable import NOOP
@testable import ReceiptLiftFeature

@MainActor
final class LocalCoachDataTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_438_400)

    func testWindowRejectsUnboundedInvalidAndFutureDates() throws {
        for days in [0, -1, 366, Int.max] {
            XCTAssertThrowsError(try LocalCoachWindow(query: "", days: days, now: now))
        }
        XCTAssertThrowsError(try LocalCoachWindow(query: "2026-02-30", days: 7, now: now))
        XCTAssertThrowsError(try LocalCoachWindow(query: "2099-01-01", days: 7, now: now))
        XCTAssertThrowsError(try LocalCoachWindow(query: "2026-09-20 to 2026-09-01", days: 30, now: now))
        let range = try LocalCoachWindow(query: "2026-09-01 to 2026-09-03", days: 30, now: now)
        XCTAssertEqual(range.from, "2026-09-01")
        XCTAssertEqual(range.through, "2026-09-03")
    }

    func testSnapshotKeepsMissingMetricsAndRealSampleDates() async throws {
        let repo = Repository(deviceId: "coach-test")
        repo.loaded = true
        repo.days = [day("2026-09-01", recovery: 71, sleep: 420), day("2026-09-02", recovery: nil, sleep: nil)]
        let service = LocalCoachDataService(repo: repo, access: { true }, now: { self.now })
        let snapshot = try await service.snapshot()
        XCTAssertEqual(snapshot.metrics.count, 4)
        XCTAssertEqual(snapshot.latestDay, "2026-09-02")
        XCTAssertEqual(snapshot.metrics.first { $0.id == "recovery" }?.value, "Not recorded")
        XCTAssertEqual(snapshot.metrics.first { $0.id == "recovery" }?.samples, [71])
        XCTAssertTrue(snapshot.context.contains("2026-09-01"))
        XCTAssertTrue(snapshot.summary.lowercased().contains("stale"))
        XCTAssertFalse(snapshot.context.contains("recovery 0"))
    }

    func testSourceSwitchAcrossAwaitDiscardsSnapshot() async throws {
        let repo = Repository(deviceId: "coach-a")
        repo.loaded = true
        let service = LocalCoachDataService(repo: repo, access: { true }, now: { self.now })
        service.afterReadForTesting = { _ = repo.adoptActiveDeviceId("coach-b") }
        do {
            _ = try await service.snapshot()
            XCTFail("A result from the old source must not escape.")
        } catch let error as LocalCoachDataError {
            XCTAssertEqual(error, .sourceChanged)
        }
    }

    func testConsentRevocationAcrossAwaitDiscardsResult() async throws {
        let repo = Repository(deviceId: "coach-test")
        var allowed = true
        let service = LocalCoachDataService(repo: repo, access: { allowed }, now: { self.now })
        service.afterReadForTesting = { allowed = false }
        do {
            _ = try await service.snapshot()
            XCTFail("Revoked data consent must discard the result.")
        } catch let error as LocalCoachDataError {
            XCTAssertEqual(error, .consentRequired)
        }
    }

    func testOrdinaryRefreshDoesNotInvalidateAnOwnedSnapshotRead() async throws {
        let repo = Repository(deviceId: "coach-refresh")
        repo.loaded = true
        repo.days = [day("2026-09-02", recovery: 71, sleep: 420)]
        let service = LocalCoachDataService(repo: repo, access: { true }, now: { self.now })
        service.afterReadForTesting = {
            repo.refreshSeq += 1
            repo.todayHealthSnapshotRevision += 1
        }
        let snapshot = try await service.snapshot()
        XCTAssertEqual(snapshot.sourceID, "coach-refresh")
        XCTAssertEqual(snapshot.latestDay, "2026-09-02")
        XCTAssertEqual(Double(snapshot.metrics.first { $0.id == "recovery" }?.value ?? ""), 71)
    }

    func testCompletedInvalidationDuringReadStillDiscardsOldRecords() async throws {
        let repo = Repository(deviceId: "coach-invalidation")
        repo.loaded = true
        let service = LocalCoachDataService(repo: repo, access: { true }, now: { self.now })
        service.afterReadForTesting = {
            repo.verifiedExternalSurfaceFenced = true
            repo.verifiedExternalSurfaceFenced = false
        }
        do {
            _ = try await service.snapshot()
            XCTFail("An invalidation must reject an old read even after the fence reopens")
        } catch let error as LocalCoachDataError {
            XCTAssertEqual(error, .sourceChanged)
        }
    }

    func testPlanValidationRejectsUnknownExerciseAndInvalidPrescription() throws {
        var plan = fixturePlan()
        let catalog = [fixtureExercise()]
        try LocalCoachPlanAdapter.validate(plan, catalog: catalog)
        plan.days[0].exercises[0].catalogID = UUID().uuidString
        XCTAssertThrowsError(try LocalCoachPlanAdapter.validate(plan, catalog: catalog))
        plan = fixturePlan()
        plan.days[0].exercises[0].sets = 0
        XCTAssertThrowsError(try LocalCoachPlanAdapter.validate(plan, catalog: catalog))
        plan = fixturePlan()
        plan.days[0].exercises[0].restSeconds = -1
        XCTAssertThrowsError(try LocalCoachPlanAdapter.validate(plan, catalog: catalog))
        plan = fixturePlan()
        plan.days[0].minutes = 500
        XCTAssertThrowsError(try LocalCoachPlanAdapter.validate(plan, catalog: catalog))
        plan = fixturePlan()
        plan.days[0].exercises[0].reps = 31
        XCTAssertThrowsError(try LocalCoachPlanAdapter.validate(plan, catalog: catalog))
        plan = fixturePlan()
        plan.days[0].dayOffset = 365
        XCTAssertThrowsError(try LocalCoachPlanAdapter.validate(plan, catalog: catalog))
    }

    func testReceiptMergeIsIdempotentAndPreservesExistingState() throws {
        let original = try envelope()
        let plan = fixturePlan()
        let saved = try XCTUnwrap(LocalCoachPlanAdapter.merging(plan, into: original, catalog: [fixtureExercise()]))
        XCTAssertNil(try LocalCoachPlanAdapter.merging(plan, into: saved, catalog: [fixtureExercise()]))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        XCTAssertEqual((json["routines"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((json["scheduledWorkouts"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(json["futureField"] as? String, "preserve me")
        XCTAssertEqual((json["sessions"] as? [[String: Any]])?.first?["title"] as? String, "Existing workout")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let native = try decoder.decode(LiftDataEnvelope.self, from: saved)
        XCTAssertEqual(native.schemaVersion, LiftDataEnvelope.currentSchemaVersion)
        XCTAssertEqual(native.routines.first?.exerciseIDs.first?.uuidString.lowercased(), fixtureExercise().id)
        XCTAssertEqual(native.scheduledWorkouts.first?.routineID, native.routines.first?.id)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // ReceiptLift encodes UUIDs with uppercase hex and fills optional/default fields.
        // A real typed round-trip must remain idempotent.
        XCTAssertNil(try LocalCoachPlanAdapter.merging(plan, into: encoder.encode(native), catalog: [fixtureExercise()]))
        var edited = plan
        edited.days[0].exercises[0].reps += 1
        XCTAssertThrowsError(try LocalCoachPlanAdapter.merging(edited, into: saved, catalog: [fixtureExercise()]))
    }

    func testReceiptMergeRejectsActiveWorkoutAndUnknownVersion() throws {
        XCTAssertThrowsError(try LocalCoachPlanAdapter.merging(fixturePlan(), into: envelope(active: true), catalog: [fixtureExercise()]))
        XCTAssertThrowsError(try LocalCoachPlanAdapter.merging(fixturePlan(), into: envelope(version: 99), catalog: [fixtureExercise()]))
    }

    func testDraftUsesRealCatalogAndStatedBodyweightEquipment() throws {
        let catalog = actualCatalog()
        XCTAssertGreaterThan(catalog.count, 1_000)
        XCTAssertEqual(LocalCoachPlanAdapter.receiptCatalogID("0662"), fixtureExercise().id)
        let plan = try LocalCoachPlanAdapter.draft(focus: "Full body, no equipment", minutes: 30, days: 3,
            sourceID: "coach-test", now: now, catalog: catalog, routines: [])
        XCTAssertEqual(plan.days.map(\.dayOffset), [0, 2, 4])
        XCTAssertTrue(plan.days.allSatisfy { $0.exercises.count >= 2 })
        XCTAssertTrue(plan.days.flatMap(\.exercises).allSatisfy { $0.equipment == "body weight" })
        XCTAssertFalse(plan.days.flatMap(\.exercises).contains { $0.name.localizedCaseInsensitiveContains("bench") })
        try LocalCoachPlanAdapter.validate(plan, catalog: catalog)
        XCTAssertThrowsError(try LocalCoachPlanAdapter.draft(focus: "marathon running", minutes: 30, days: 3,
            sourceID: "coach-test", now: now, catalog: catalog, routines: []))
    }

    func testDraftUsesExistingReceiptLiftPresetOrder() throws {
        let catalog = actualCatalog()
        let names = ["dumbbell bench press", "dumbbell bent over row", "push-up"]
        let items = try names.map { name in try XCTUnwrap(catalog.first { $0.name == name }) }
        let preset = LocalCoachRoutineTemplate(id: UUID().uuidString, name: "Upper A", exerciseIDs: items.map(\.id))
        let plan = try LocalCoachPlanAdapter.draft(focus: "Upper body, full gym", minutes: 40, days: 2,
            sourceID: "coach-test", now: now, catalog: catalog, routines: [preset])
        XCTAssertEqual(plan.days.first?.exercises.map(\.catalogID), items.map(\.id))
        XCTAssertTrue(plan.summary.contains("Upper A"))
        try LocalCoachPlanAdapter.validate(plan, catalog: catalog)
    }

    func testStoredZoneDictionariesKeepMissingFieldsAndRejectConflicts() {
        let result = LocalCoachDataService.zoneDescription(#"{"z1":12.5,"zone2":25}"#)
        XCTAssertTrue(result.contains("Zone 1: 12.5 %"))
        XCTAssertTrue(result.contains("Zone 3: not recorded"))
        XCTAssertTrue(LocalCoachDataService.zoneDescription(#"{"z1":20,"zone1":30}"#).contains("conflict"))
        XCTAssertTrue(LocalCoachDataService.zoneDescription(#"{"z1":90,"z2":90}"#).contains("exceed"))
        XCTAssertTrue(LocalCoachDataService.zoneDescription(nil).contains("not recorded"))
    }

    private func actualCatalog() -> [LocalCoachCatalogExercise] {
        LiftExerciseCatalog.catalogExercises().map {
            .init(id: $0.id.uuidString.lowercased(), name: $0.name, equipment: $0.equipment,
                  target: $0.muscleGroup, instructions: $0.instructions)
        }
    }

    private func day(_ key: String, recovery: Double?, sleep: Double?) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: sleep, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil,
                    recovery: recovery, strain: nil, exerciseCount: nil, strainVersion: nil)
    }

    private func fixtureExercise() -> LocalCoachCatalogExercise {
        .init(id: "00000000-0000-4000-8000-000000000296", name: "push-up",
              equipment: "body weight", target: "pectorals", instructions: "Controlled repetitions.")
    }

    private func fixturePlan() -> LocalCoachPlan {
        let exercise = fixtureExercise()
        return LocalCoachPlan(title: "Test plan", summary: "User-reviewed draft", createdAt: now,
            sourceID: "coach-test", days: [.init(dayOffset: 0, title: "Session 1", focus: "strength",
                minutes: 30, exercises: [.init(catalogID: exercise.id, name: exercise.name,
                    equipment: exercise.equipment, sets: 3, reps: 8, restSeconds: 90)])])
    }

    private func envelope(active: Bool = false, version: Int = 2) throws -> Data {
        var object: [String: Any] = ["schemaVersion": version, "starterBankVersion": 1,
            "userExercises": [], "routines": [], "scheduledWorkouts": [],
            "sessions": [["id": UUID().uuidString, "title": "Existing workout",
                          "startedAt": "2026-09-01T12:00:00Z", "endedAt": "2026-09-01T13:00:00Z", "sets": []]],
            "settings": ["defaultRestSeconds": 90],
            "futureField": "preserve me"]
        if active { object["activeSession"] = ["id": UUID().uuidString] }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
#endif
