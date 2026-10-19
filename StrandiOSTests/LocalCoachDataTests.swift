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

    // MARK: Widget cards

    private func key(_ ago: Int) -> String {
        LocalCoachWindow.key(LocalCoachWindow.calendar.date(byAdding: .day, value: -ago, to: now)!)
    }

    private func metric(_ day: String, recovery: Double? = nil, sleep: Double? = nil, deep: Double? = nil,
                        rem: Double? = nil, light: Double? = nil, efficiency: Double? = nil,
                        hrv: Double? = nil, rhr: Int? = nil, strain: Double? = nil) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: sleep, efficiency: efficiency, deepMin: deep, remMin: rem,
                    lightMin: light, disturbances: nil, restingHr: rhr, avgHrv: hrv, recovery: recovery,
                    strain: strain, exerciseCount: nil, strainVersion: nil)
    }

    private func service(_ days: [DailyMetric]) -> LocalCoachDataService {
        let repo = Repository(deviceId: "coach-cards")
        repo.loaded = true
        repo.days = days
        return LocalCoachDataService(repo: repo, access: { true }, now: { self.now })
    }

    private func makeWindow(_ days: Int = 7) throws -> LocalCoachWindow {
        try LocalCoachWindow(query: "", days: days, now: now)
    }

    func testReadinessCardUsesNewestRecordAndKeepsMissingFieldsNil() async throws {
        let data = service([
            metric(key(2), recovery: 60, sleep: 400, hrv: 50, rhr: 55),
            metric(key(1), recovery: 71)
        ])
        let result = try await data.query("readiness", query: "", days: 7)
        XCTAssertEqual(result.cards.count, 1)
        guard case .recovery(let card)? = result.cards.first else { return XCTFail("Expected a recovery card") }
        XCTAssertEqual(card.day, key(1), "The card names the real record date")
        XCTAssertEqual(card.score, 71)
        XCTAssertNil(card.hrvMs, "A field missing from the newest record stays nil; it is not borrowed from an older day or zero-filled")
        XCTAssertNil(card.restingHr)
        XCTAssertNil(card.sleepMinutes)
        XCTAssertFalse(card.isStale, "Yesterday's daily record is normal before today's is scored")
        XCTAssertTrue(result.text.contains(key(1)))
    }

    func testCardsAreStaleOnlyWhenTheNewestRecordIsTwoOrMoreDaysOld() async throws {
        for (ago, stale) in [(0, false), (1, false), (2, true), (5, true)] {
            let result = try await service([metric(key(ago), recovery: 70, sleep: 400)]).query("readiness", query: "", days: 7)
            guard case .recovery(let card)? = result.cards.first else { return XCTFail("Expected a recovery card for \(ago)") }
            XCTAssertEqual(card.day, key(ago), "The date is always the record's real date")
            XCTAssertEqual(card.isStale, stale, "newest record \(ago) days before the window end")
        }
        // A window that ends in the past is judged against its own last day, not against today.
        let past = try await service([metric(key(9), recovery: 70)]).query("readiness", query: "\(key(9))", days: 1)
        guard case .recovery(let historic)? = past.cards.first else { return XCTFail("Expected a recovery card") }
        XCTAssertFalse(historic.isStale)
    }

    func testCurrentDayCardIsNotStaleWhenTodayHasARecord() async throws {
        let data = service([metric(key(0), recovery: 82, sleep: 462, hrv: 64, rhr: 52)])
        let result = try await data.query("current_day", query: "", days: 1)
        guard case .recovery(let card)? = result.cards.first else { return XCTFail("Expected a recovery card") }
        XCTAssertFalse(card.isStale)
        XCTAssertEqual([card.score, card.hrvMs, card.restingHr, card.sleepMinutes], [82, 64, 52, 462])
    }

    func testRecordsWithNoDisplayableValueProduceNoCards() async throws {
        let data = service([metric(key(0))])
        for tool in ["current_day", "readiness", "sleep_history", "metric_trends"] {
            let result = try await data.query(tool, query: "", days: 7)
            XCTAssertTrue(result.cards.isEmpty, tool)
        }
        let empty = try await service([]).query("readiness", query: "", days: 7)
        XCTAssertTrue(empty.cards.isEmpty)
    }

    func testSleepCardListsObservedNightsOnlyAndNormalizesEfficiency() async throws {
        let data = service([
            metric(key(5), sleep: 420),
            metric(key(4)),
            metric(key(3), sleep: 450, deep: 90, rem: 100, light: 260, efficiency: 0.92),
            metric(key(1), sleep: 480)
        ])
        let result = try await data.query("sleep_history", query: "", days: 7)
        guard case .sleep(let card)? = result.cards.first else { return XCTFail("Expected a sleep card") }
        XCTAssertEqual(card.day, key(1))
        XCTAssertEqual(card.totalMinutes, 480)
        XCTAssertNil(card.deepMinutes)
        XCTAssertNil(card.remMinutes)
        XCTAssertNil(card.lightMinutes)
        XCTAssertNil(card.efficiencyPercent)
        XCTAssertEqual(card.recentNights.map(\.day), [key(5), key(3), key(1)], "The unrecorded night is absent, not zero")
        XCTAssertEqual(card.recentNights.map(\.value), [420, 450, 480])
        let earlier = try await service([metric(key(3), sleep: 450, deep: 90, rem: 100, light: 260, efficiency: 0.92)])
            .query("sleep_history", query: "", days: 7)
        guard case .sleep(let full)? = earlier.cards.first else { return XCTFail("Expected a sleep card") }
        XCTAssertEqual(full.efficiencyPercent ?? 0, 92, accuracy: 0.0001)
        XCTAssertEqual([full.deepMinutes, full.remMinutes, full.lightMinutes], [90, 100, 260])
        XCTAssertTrue(full.isStale)
    }

    func testTrendCardsAreCappedAtTwoAndPrioritizeTheMetricsNamed() async throws {
        let data = service([
            metric(key(5), recovery: 60, sleep: 420, hrv: 50, rhr: 55),
            metric(key(4), recovery: 70, sleep: 450, hrv: 54),
            metric(key(3), sleep: 360, hrv: 58),
            metric(key(2), recovery: 80, sleep: 480, hrv: 62, rhr: 52)
        ])
        let named = try await data.query("metric_trends", query: "sleep and hrv", days: 14)
        let trends = named.cards.compactMap { card -> LocalCoachCard.Trend? in
            if case .trend(let value) = card { return value } else { return nil }
        }
        XCTAssertEqual(trends.map(\.metricID), ["sleep", "hrv"])
        let sleep = try XCTUnwrap(trends.first)
        XCTAssertEqual(sleep.unit, "h")
        XCTAssertEqual(sleep.points.map(\.value), [7, 7.5, 6, 8], "Sleep trend points are hours")
        XCTAssertEqual(sleep.latest, 8)
        XCTAssertEqual(sleep.minimum, 6)
        XCTAssertEqual(sleep.maximum, 8)
        XCTAssertEqual(sleep.average ?? 0, 7.125, accuracy: 0.0001)
        XCTAssertEqual(sleep.day, key(2))
        XCTAssertTrue(sleep.isStale)

        let usual = try await data.query("metric_trends", query: "", days: 14)
        let ids = usual.cards.compactMap { card -> String? in
            if case .trend(let value) = card { return value.metricID } else { return nil }
        }
        XCTAssertEqual(ids, ["recovery", "sleep"])
        let recovery = usual.cards.compactMap { card -> LocalCoachCard.Trend? in
            if case .trend(let value) = card { return value } else { return nil }
        }.first
        XCTAssertEqual(recovery?.points.map(\.day), [key(5), key(4), key(2)], "Missing recovery days are omitted, never zero-filled")
        XCTAssertEqual(recovery?.points.map(\.value), [60, 70, 80])
    }

    func testTrendCardNeedsAtLeastTwoObservedDays() async throws {
        let data = service([metric(key(1), recovery: 70, hrv: 55), metric(key(0), hrv: 57)])
        let result = try await data.query("metric_trends", query: "recovery", days: 7)
        let ids = result.cards.compactMap { card -> String? in
            if case .trend(let value) = card { return value.metricID } else { return nil }
        }
        XCTAssertEqual(ids, ["hrv"], "One observed recovery day is not a trend")
    }

    func testEffortCardKeepsCanonicalZeroToHundredAndNilWhenMissing() throws {
        let window = try makeWindow()
        let cards = LocalCoachDataService.effortCard(
            [metric(key(2), strain: 40), metric(key(1), strain: 58), metric(key(0))], workoutCount: 3, window: window)
        guard case .effort(let card)? = cards.first else { return XCTFail("Expected an effort card") }
        XCTAssertEqual(card.value, 58, "Payload stays on the canonical 0...100 axis; the view converts for display")
        XCTAssertEqual(card.day, key(1))
        XCTAssertEqual(card.workoutCount, 3)
        XCTAssertEqual(card.windowDays, 7)
        XCTAssertFalse(card.isStale, "Yesterday is normal")
        guard case .effort(let old)? = LocalCoachDataService.effortCard([metric(key(2), strain: 40)], workoutCount: 1, window: window).first
        else { return XCTFail("Expected an effort card") }
        XCTAssertTrue(old.isStale)
        XCTAssertTrue(LocalCoachDataService.effortCard([metric(key(0))], workoutCount: 1, window: window).isEmpty)
        XCTAssertTrue(LocalCoachDataService.effortCard([metric(key(0), strain: 150)], workoutCount: 1, window: window).isEmpty,
                      "Out-of-range effort is not shown")
        guard case .effort(let unknownCount)? = LocalCoachDataService.effortCard([metric(key(0), strain: 12)], workoutCount: nil, window: window).first
        else { return XCTFail("Expected an effort card") }
        XCTAssertNil(unknownCount.workoutCount)
        XCTAssertFalse(unknownCount.isStale)
    }

    func testWorkoutsCardShowsThreeNewestWithCanonicalEffortOnly() throws {
        func workout(_ ago: Double, sport: String, duration: Double?, hr: Int?, strain: Double?, version: Int?) -> WorkoutRow {
            let start = Int(now.timeIntervalSince1970 - ago * 86_400)
            return WorkoutRow(startTs: start, endTs: start + 3_000, sport: sport, source: "test", durationS: duration,
                              energyKcal: nil, avgHr: hr, maxHr: nil, strain: strain, distanceM: nil,
                              zonesJSON: nil, notes: nil, strainVersion: version)
        }
        let rows = [
            workout(0, sport: "Running", duration: 2_700, hr: 152, strain: 62, version: 2),
            workout(2, sport: "Strength\ntraining", duration: nil, hr: nil, strain: 40, version: nil),
            workout(4, sport: "Cycling", duration: 2_280, hr: 0, strain: 500, version: 2),
            workout(6, sport: "Swimming", duration: 1_800, hr: 120, strain: 30, version: 2)
        ]
        let window = try makeWindow()
        let cards = LocalCoachDataService.workoutsCard(rows, window: window)
        guard case .workouts(let card)? = cards.first else { return XCTFail("Expected a workouts card") }
        XCTAssertEqual(card.items.count, 3)
        XCTAssertFalse(card.isStale, "A workout list is history; the real dates are shown")
        XCTAssertEqual(card.day, key(0))
        XCTAssertEqual(card.windowFrom, key(6))
        XCTAssertEqual(card.windowThrough, key(0))
        XCTAssertEqual(card.items[0].effort, 62)
        XCTAssertEqual(card.items[0].avgHr, 152)
        XCTAssertEqual(card.items[0].durationS, 2_700)
        XCTAssertNil(card.items[1].effort, "Legacy/imported strain is not a canonical effort")
        XCTAssertNil(card.items[1].durationS)
        XCTAssertNil(card.items[1].avgHr)
        XCTAssertEqual(card.items[1].sport, "Strength training")
        XCTAssertNil(card.items[2].avgHr, "A zero heart rate is not a measurement")
        XCTAssertNil(card.items[2].effort, "Out-of-range effort is dropped")
        XCTAssertTrue(LocalCoachDataService.workoutsCard([], window: window).isEmpty)
    }

    func testCoachWorkoutsCollapseStrapAndAppleHealthTwinsLikeTheWorkoutsScreen() {
        func row(_ start: Int, _ end: Int, _ sport: String, _ source: String, hr: Int?) -> WorkoutRow {
            WorkoutRow(startTs: start, endTs: end, sport: sport, source: source, durationS: Double(end - start),
                       energyKcal: nil, avgHr: hr, maxHr: nil, strain: nil, distanceM: nil, zonesJSON: nil, notes: nil)
        }
        let strap = row(10_000, 13_000, "Running", "whoop", hr: 150)
        let twin = row(10_060, 13_000, "Running", "apple-health", hr: nil)
        let other = row(50_000, 52_000, "Cycling", "apple-health", hr: nil)
        let items: [LocalCoachDataService.OwnedWorkout] = [
            .init(owner: "my-whoop", row: strap), .init(owner: "apple-health", row: twin), .init(owner: "apple-health", row: other)
        ]
        // Same strap row read twice (exact duplicate) plus the Health twin and an unrelated ride.
        let withDuplicate = items + [.init(owner: "my-whoop", row: strap)]
        let result = LocalCoachDataService.dedupedWorkouts(withDuplicate, truncated: false)
        XCTAssertEqual(result.rows.count, 2, "One session recorded by strap and Apple Health is one workout, not two")
        XCTAssertEqual(result.rows.map(\.owner), ["apple-health", "my-whoop"], "Newest first, strap owner label kept")
        XCTAssertEqual(result.rows.map(\.row), [other, strap], "The richer strap row wins over its Health twin")
        XCTAssertEqual(result.rows.reduce(0.0) { $0 + ($1.row.durationS ?? 0) }, 3_000 + 2_000, "Summed duration counts the session once")
        XCTAssertFalse(result.truncated)
    }

    func testCoverageAndNutritionStatsCardsNeverMixDatesOrInventValues() throws {
        let window = try makeWindow()
        guard case .stats(let coverage)? = LocalCoachDataService.coverageCard(
            RepositoryFreshness(earliestDay: key(9), latestDay: key(0)), window: window).first
        else { return XCTFail("Expected a stats card") }
        XCTAssertEqual(coverage.title, "Data coverage")
        XCTAssertEqual(coverage.items.map(\.value), [key(0), key(9), "10 days"])
        XCTAssertFalse(coverage.isStale)
        XCTAssertTrue(LocalCoachDataService.coverageCard(RepositoryFreshness(), window: window).isEmpty)

        guard case .stats(let intake)? = LocalCoachDataService.intakeCard([
            (label: "Calories", day: key(2), text: "2150 kcal"),
            (label: "Protein", day: key(4), text: "140 g"),
            (label: "Carbs", day: key(2), text: "260 g")
        ], window: window).first else { return XCTFail("Expected a stats card") }
        XCTAssertEqual(intake.day, key(2))
        XCTAssertEqual(intake.items.map(\.label), ["Calories", "Carbs"], "Only the newest intake day is shown")
        XCTAssertTrue(intake.isStale)
        XCTAssertTrue(LocalCoachDataService.intakeCard([], window: window).isEmpty)
    }

    func testToolsWithoutAVisualProduceNoCards() async throws {
        let result = try await service([metric(key(0), recovery: 80)]).query("metric_explanations", query: "", days: 7)
        XCTAssertTrue(result.cards.isEmpty)
        XCTAssertFalse(result.text.isEmpty)
    }

    func testCardsDoNotEscapeWhenConsentIsRevokedDuringTheRead() async throws {
        let repo = Repository(deviceId: "coach-cards")
        repo.loaded = true
        repo.days = [metric(key(0), recovery: 80)]
        var allowed = true
        let data = LocalCoachDataService(repo: repo, access: { allowed }, now: { self.now })
        data.afterReadForTesting = { allowed = false }
        do {
            _ = try await data.query("readiness", query: "", days: 7)
            XCTFail("A result read before consent was revoked must not escape with its cards")
        } catch let error as LocalCoachDataError {
            XCTAssertEqual(error, .consentRequired)
        }
    }

    func testCardDateLabelsAreRelativeAndNeverGuessed() {
        XCTAssertEqual(LocalCoachCardFormat.dayLabel(key(0), now: now), "Today")
        XCTAssertEqual(LocalCoachCardFormat.dayLabel(key(1), now: now), "Yesterday")
        XCTAssertEqual(LocalCoachCardFormat.dayLabel("not-a-date", now: now), "not-a-date")
        XCTAssertEqual(LocalCoachCardFormat.duration(minutes: 462), "7h 42m")
        XCTAssertEqual(LocalCoachCardFormat.duration(minutes: 45), "45m")
        XCTAssertEqual(LocalCoachCardFormat.duration(minutes: nil), "—")
        XCTAssertEqual(LocalCoachCardFormat.duration(minutes: -3), "—")
        XCTAssertEqual(LocalCoachCardFormat.whole(nil), "—")
        XCTAssertEqual(LocalCoachCardFormat.whole(82, unit: "/100"), "82/100")
        XCTAssertEqual(LocalCoachCardFormat.whole(64, unit: "ms"), "64 ms")
    }

    func testOlderRecordsShowTheirRealDateNeverTodayOrYesterday() {
        let older = LocalCoachCardFormat.dayLabel(key(5), now: now)
        XCTAssertNotEqual(older, "Today")
        XCTAssertNotEqual(older, "Yesterday")
        XCTAssertEqual(older, LocalCoachCardFormat.humanDay(key(5), now: now))
        XCTAssertFalse(older.contains("2026"), "A date in the current year carries no year: \(older)")
        let lastYear = LocalCoachCardFormat.dayLabel("2025-09-30", now: now)
        XCTAssertTrue(lastYear.contains("2025"), lastYear)
        XCTAssertEqual(LocalCoachCardFormat.displayValue("2025-08-22", now: now), LocalCoachCardFormat.humanDay("2025-08-22", now: now))
        XCTAssertEqual(LocalCoachCardFormat.displayValue("413 days", now: now), "413 days")
        XCTAssertEqual(LocalCoachCardFormat.windowLabel(from: key(6), through: key(0), now: now), "Last 7 days")
        XCTAssertEqual(LocalCoachCardFormat.windowLabel(from: key(0), through: key(0), now: now), "Today")
        XCTAssertTrue(LocalCoachCardFormat.windowLabel(from: key(9), through: key(7), now: now)?.contains(" - ") == true)
        XCTAssertNil(LocalCoachCardFormat.windowLabel(from: "bad", through: key(0), now: now))
    }

    func testEffortToolTextCarriesBothTheDisplayAndCanonicalValue() {
        XCTAssertEqual(LocalCoachDataService.effortText(58), "12.2 of 21 (58.0/100 canonical)")
        XCTAssertEqual(LocalCoachDataService.effortText(0), "0.0 of 21 (0.0/100 canonical)")
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

/// The wording and figures the redesigned Coach pages are built from. All pure: no engine, no repository.
@MainActor
final class LocalCoachPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_438_400)

    private func key(_ daysAgo: Int) -> String {
        LocalCoachWindow.key(LocalCoachWindow.calendar.date(byAdding: .day, value: -daysAgo, to: now)!)
    }

    // MARK: Plan wording

    func testPlanEntrySubtitleCountsAndPlurals() {
        func line(_ sessions: Int?, saved: Bool) -> String {
            String(localized: CoachPlanText.entrySubtitle(sessions: sessions, saved: saved))
        }
        XCTAssertEqual(line(nil, saved: false), "Build, review and save your next workout.")
        XCTAssertEqual(line(nil, saved: true), "Build, review and save your next workout.")
        XCTAssertEqual(line(1, saved: false), "1 session · Ready for your review")
        XCTAssertEqual(line(3, saved: false), "3 sessions · Ready for your review")
        XCTAssertEqual(line(1, saved: true), "1 session · Saved to your workouts")
        XCTAssertEqual(line(4, saved: true), "4 sessions · Saved to your workouts")
        XCTAssertEqual(line(0, saved: false), "0 sessions · Ready for your review")
    }

    func testCountsHaveOneAndOtherFormsInEveryLanguage() throws {
        let keys = ["%lld sessions · Ready for your review", "%lld sessions · Saved to your workouts", "%lld source records",
                    "%lld sessions this week"]
        let bundle = Bundle(for: LocalCoachEngine.self)
        for locale in ["en", "de", "es", "it", "pt-PT", "zh-Hans", "zh-Hant"] {
            let path = try XCTUnwrap(bundle.path(forResource: "Localizable", ofType: "stringsdict",
                                                 inDirectory: nil, forLocalization: locale), "no plural table for \(locale)")
            let table = try XCTUnwrap(NSDictionary(contentsOfFile: path), locale)
            for key in keys {
                let entry = try XCTUnwrap(table[key] as? [String: Any], "\(locale) has no plural entry for: \(key)")
                let forms = try XCTUnwrap(entry.values.compactMap { $0 as? [String: Any] }.first { $0["other"] != nil },
                                          "\(locale) has no plural forms for: \(key)")
                let other = try XCTUnwrap(forms["other"] as? String)
                XCTAssertTrue(other.contains("%"), "\(locale): \(other)")
                // Chinese has no singular form. Every other language words one and many differently, except where the
                // noun itself does not change: the Italian "record".
                if !locale.hasPrefix("zh") {
                    let one = try XCTUnwrap(forms["one"] as? String, "\(locale) has no singular for: \(key)")
                    XCTAssertTrue(one.contains("%"), "\(locale): \(one)")
                    if !(locale == "it" && key == "%lld source records") {
                        XCTAssertNotEqual(one, other, "\(locale) reads the same for one and many: \(key)")
                    }
                }
            }
        }
    }

    func testMinutesPerSession() {
        XCTAssertNil(CoachPlanText.minutesPerSession([]))
        XCTAssertEqual(CoachPlanText.minutesPerSession([60]), 60)
        XCTAssertEqual(CoachPlanText.minutesPerSession([45, 45, 45]), 45)
        XCTAssertEqual(CoachPlanText.minutesPerSession([30, 45]), 38, "37.5 rounds up")
        XCTAssertEqual(CoachPlanText.minutesPerSession([20, 30, 30]), 27, "26.67 rounds to 27")
    }

    // MARK: Record dates

    func testStaleBoundaryIsTwoDays() {
        func stale(_ daysAgo: Int) -> Bool? {
            switch CoachRecordDate.trailing(day: key(daysAgo), now: now) {
            case .pillAndText, .pill: true
            case .text: false
            case .none, .custom: nil
            }
        }
        XCTAssertEqual(stale(0), false, "today's record is current")
        XCTAssertEqual(stale(1), false, "yesterday's is normal until today is scored")
        XCTAssertEqual(stale(2), true, "two days old is the first stale day")
        XCTAssertEqual(stale(9), true)
        if case .none = CoachRecordDate.trailing(day: nil, now: now) {} else { XCTFail("no record, no date") }
        if case .none = CoachRecordDate.trailing(day: "not-a-date", now: now) {} else { XCTFail("an unreadable day is not guessed") }
    }

    func testDayLabelReadsTheKeyOnceAndAgrees() {
        let date = LocalCoachWindow.date(key(5))!
        XCTAssertEqual(LocalCoachCardFormat.dayLabel(date, now: now), LocalCoachCardFormat.dayLabel(key(5), now: now))
        XCTAssertEqual(LocalCoachCardFormat.humanDay(date, now: now), LocalCoachCardFormat.humanDay(key(5), now: now))
    }

    // MARK: Durations and clock

    func testDurationReadsThroughTheSleepWording() {
        XCTAssertEqual(LocalCoachCardFormat.duration(minutes: 462), "7h 42m")
        XCTAssertEqual(LocalCoachCardFormat.duration(minutes: 425), "7h 5m", "minutes are not zero padded, as on Sleep")
        XCTAssertEqual(LocalCoachCardFormat.duration(minutes: 59.6), "1h 0m", "rounds before it splits")
        XCTAssertEqual(LocalCoachCardFormat.duration(minutes: 45), "45m")
        XCTAssertEqual(LocalCoachCardFormat.duration(minutes: 0), "0m")
        XCTAssertEqual(LocalCoachCardFormat.duration(minutes: nil), "—")
        XCTAssertEqual(LocalCoachCardFormat.duration(seconds: 3_120), "52m")
    }

    func testWorkoutStartFollowsTheAppsClockSetting() {
        let defaults = UserDefaults.standard
        let stored = defaults.object(forKey: "clockFormatPreference")
        addTeardownBlock {
            if let stored { defaults.set(stored, forKey: "clockFormatPreference") }
            else { defaults.removeObject(forKey: "clockFormatPreference") }
        }
        var parts = DateComponents()
        parts.year = 2026; parts.month = 9; parts.day = 23; parts.hour = 14; parts.minute = 5
        let start = Int(Calendar.current.date(from: parts)!.timeIntervalSince1970)

        defaults.set("twentyFourHour", forKey: "clockFormatPreference")
        XCTAssertTrue(LocalCoachCardFormat.startLabel(start).hasSuffix("14:05"), LocalCoachCardFormat.startLabel(start))
        defaults.set("twelveHour", forKey: "clockFormatPreference")
        let twelve = LocalCoachCardFormat.startLabel(start)
        XCTAssertTrue(twelve.contains("2:05"), twelve)
        XCTAssertFalse(twelve.contains("14:05"), twelve)
    }

    // MARK: Metric strip

    func testMetricFigureShowsEachRecordTheWayTheCardsDo() {
        func figure(_ id: String, _ value: String, unit: String) -> CoachMetricFigure {
            CoachMetricFigure(.init(id: id, title: id, value: value, unit: unit, detail: "", samples: []), effortScale: .whoop)
        }
        func check(_ shown: CoachMetricFigure, _ value: String, _ unit: CoachMetricFigure.Unit?,
                   line: UInt = #line) {
            XCTAssertEqual(shown.value, value, line: line)
            XCTAssertEqual(shown.unit, unit, line: line)
        }
        check(figure("recovery", "71.0", unit: "/100"), "71", .plain("/100"))
        check(figure("strain", "58.0", unit: "/100"), "12.2", .ofScale("21"))
        check(figure("sleep", "7.7", unit: "h"), "7h 42m", nil)
        check(figure("hrv", "64.0", unit: "ms"), "64", .plain("ms"))
        check(figure("hrv", "64.0", unit: ""), "64", nil)
    }

    func testARecordThatIsNotANumberReadsAsMissingNeverZero() {
        for value in ["Not recorded", "7h 42m", ""] {
            let shown = CoachMetricFigure(.init(id: "sleep", title: "Sleep", value: value, unit: "h", detail: "", samples: []),
                                          effortScale: .whoop)
            XCTAssertEqual(shown.value, "—", value)
            XCTAssertNil(shown.unit, value)
        }
    }

    // MARK: Catalog

    func testCoachLabelsAreTranslatedInEveryLanguage() throws {
        let keys = ["Training", "Habits", "Goals", "Identity", "Lifestyle", "Preferences", "Events", "Health history", "Mood",
                    "You. %@", "Recovery", "Strain", "STRAIN", "Sleep", "HRV", "BPM", "min", "of %@", "Today", "Yesterday",
                    "Last %lld days", "%lldh %lldm", "%lldm"]
        let bundle = Bundle(for: LocalCoachEngine.self)
        for locale in ["de", "es", "it", "pt-PT", "zh-Hans", "zh-Hant"] {
            let path = try XCTUnwrap(bundle.path(forResource: locale, ofType: "lproj"), locale)
            let table = try XCTUnwrap(Bundle(path: path), locale)
            for key in keys {
                XCTAssertNotEqual(table.localizedString(forKey: key, value: "\u{0}missing", table: nil), "\u{0}missing",
                                  "\(locale) has no translation for: \(key)")
            }
        }
    }
}
#endif
