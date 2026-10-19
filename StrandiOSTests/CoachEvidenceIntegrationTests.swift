#if os(iOS)
import XCTest
@testable import NOOP

/// Deterministic engine tests. They use synthetic records and a driver that never invokes a model.
@MainActor
final class CoachEvidenceIntegrationTests: XCTestCase {
    private func makeEngine(data: EvidenceData, driver: EvidenceDriver, consent: Bool = true,
                            source: @escaping @MainActor () -> LocalCoachSourceScope = {
        .init(storageID: "synthetic", dataSourceID: "synthetic", revision: "1")
    }) -> LocalCoachEngine {
        let engine = LocalCoachEngine(data: data, persistence: nil, model: driver, source: source)
        engine.preferences.usePersonalData = consent
        return engine
    }

    func testCardExistsBeforeExplanationGeneration() async {
        let data = EvidenceData(), driver = EvidenceDriver()
        let engine = makeEngine(data: data, driver: driver)
        driver.beforeGeneration = { request in
            XCTAssertEqual(engine.messages.last?.cards?.count, 1)
            XCTAssertEqual(engine.messages.last?.text, "")
            XCTAssertTrue(request.requiredEvidence.contains("synthetic"))
            XCTAssertEqual(request.additionalReadLimit, 2)
        }
        await engine.send("Show my recent workouts")
        XCTAssertEqual(data.reads, ["workout_history"])
        XCTAssertEqual(engine.messages.last?.text, "Synthetic explanation")
        XCTAssertEqual(engine.responseProgress.stage, .complete)
        XCTAssertEqual(data.writes, 0)
    }

    func testNoConsentMeansNoPersonalReadOrCards() async {
        let data = EvidenceData(), driver = EvidenceDriver()
        let engine = makeEngine(data: data, driver: driver, consent: false)
        await engine.send("Show my recent workouts")
        XCTAssertTrue(data.reads.isEmpty)
        XCTAssertTrue(engine.messages.last?.cards?.isEmpty ?? true)
        XCTAssertTrue(engine.messages.last?.evidence.isEmpty ?? true)
        XCTAssertEqual(data.writes, 0)
    }

    func testGeneralEducationDoesNotPrefetchHealthRecords() async {
        let data = EvidenceData(), driver = EvidenceDriver()
        let engine = makeEngine(data: data, driver: driver)
        await engine.send("What does HRV mean?")
        XCTAssertTrue(data.reads.isEmpty)
        XCTAssertTrue(driver.lastRequest?.requiredEvidence.isEmpty ?? false)
    }

    func testRequiredReadUsesTheSameThreeReadBudget() async {
        let data = EvidenceData(), driver = EvidenceDriver()
        driver.additionalReads = 3
        let engine = makeEngine(data: data, driver: driver)
        await engine.send("Show my recent workouts")
        XCTAssertEqual(data.reads.count, 3)
        XCTAssertTrue(engine.messages.last?.isInterrupted ?? false)
        XCTAssertEqual(engine.responseProgress.stage, .failed)
        XCTAssertEqual(data.writes, 0)
    }

    func testCancellationAtReadCompletionCannotPublishALateCard() async {
        let data = EvidenceData(), driver = EvidenceDriver()
        let engine = makeEngine(data: data, driver: driver)
        data.afterRead = { engine.cancel() }
        await engine.send("Show my recent workouts")
        XCTAssertTrue(engine.messages.last?.cards?.isEmpty ?? true)
        XCTAssertEqual(driver.generations, 0)
        XCTAssertEqual(engine.responseProgress.stage, .stopped)
    }

    func testSourceChangeCannotPublishOldSourceEvidence() async {
        let data = EvidenceData(), driver = EvidenceDriver()
        var source = LocalCoachSourceScope(storageID: "synthetic-a", dataSourceID: "a", revision: "1")
        let engine = makeEngine(data: data, driver: driver, source: { source })
        data.afterRead = { source = .init(storageID: "synthetic-b", dataSourceID: "b", revision: "2") }
        await engine.send("Show my recent workouts")
        XCTAssertTrue(engine.messages.flatMap { $0.cards ?? [] }.isEmpty)
        XCTAssertEqual(driver.generations, 0)
    }

    func testLongPeriodDoesNotReadOrInvokeTheModel() async {
        let data = EvidenceData(), driver = EvidenceDriver()
        let engine = makeEngine(data: data, driver: driver)
        await engine.send("Show my workouts over 90 days")
        XCTAssertTrue(data.reads.isEmpty)
        XCTAssertEqual(driver.generations, 0)
        XCTAssertEqual(engine.messages.last?.text, CoachEvidencePolicy.rangeExplanation)
    }

    func testRetryDoesNotWriteAPlan() async {
        let data = EvidenceData(), driver = EvidenceDriver()
        let engine = makeEngine(data: data, driver: driver)
        await engine.send("Show my recent workouts")
        await engine.retryLatestAnswer()
        XCTAssertEqual(data.reads.count, 2)
        XCTAssertEqual(data.writes, 0)
        XCTAssertEqual(engine.messages.filter { $0.role == .user }.count, 2)
    }

    func testRetryOfAnInterruptedBriefKeepsItsKindAndUpdatesTheDailyBrief() async {
        let data = EvidenceData(), driver = EvidenceDriver()
        driver.additionalReads = 3
        let engine = makeEngine(data: data, driver: driver)
        await engine.generateBrief(kind: .morning)
        XCTAssertTrue(engine.messages.last?.isInterrupted ?? false)
        driver.additionalReads = 0
        let stale = engine.dailyBrief
        await engine.retryLatestAnswer()
        XCTAssertEqual(data.reads.suffix(1), ["current_day"], "a retried brief starts from its own record, not its wording")
        XCTAssertEqual(engine.messages.last?.text, "Synthetic explanation")
        XCTAssertNotEqual(engine.dailyBrief, stale)
        XCTAssertEqual(engine.dailyBrief, "Synthetic explanation")
    }
}

@MainActor
private final class EvidenceData: LocalCoachDataAccess {
    var reads: [String] = []
    var writes = 0
    var afterRead: (() -> Void)?
    var toolDescriptors: [LocalCoachToolDescriptor] {
        [.init(id: "workout_history", title: "Workouts", description: "Read synthetic workout records", symbol: "figure.run"),
         .init(id: "current_day", title: "Current day", description: "Read synthetic daily records", symbol: "sun.horizon")]
    }
    func snapshot() async throws -> LocalCoachSnapshot { .empty }
    func query(_ name: String, query: String, days: Int) async throws -> LocalCoachToolResult {
        reads.append(name)
        let evidence = LocalCoachEvidence(id: "fixture", title: "Synthetic record", detail: "Fixture only", source: "synthetic", date: nil)
        let card = LocalCoachCard.stats(.init(title: "Synthetic test", day: "2026-10-01", isStale: true,
                                              items: [.init(label: "Sessions", value: "1")]))
        afterRead?()
        return .init(text: "Window: 2026-10-01. synthetic fixture, one session", evidence: [evidence], cards: [card])
    }
    func makeWorkoutDraft(focus: String, minutes: Int, days: Int) async throws -> LocalCoachPlan {
        writes += 1
        throw LocalCoachFailure.missingPlan
    }
    func savePlan(_ plan: LocalCoachPlan) async throws { writes += 1 }
}

@MainActor
private final class EvidenceDriver: LocalCoachModelDriver {
    var availability: LocalCoachAvailability { .available }
    var contextCapacity: Int? { 4096 }
    var additionalReads = 0
    var generations = 0
    var lastRequest: LocalCoachRequest?
    var beforeGeneration: ((LocalCoachRequest) -> Void)?
    func stream(_ request: LocalCoachRequest, tools: [LocalCoachToolDescriptor],
                read: @escaping LocalCoachRead, receive: @escaping LocalCoachReceive) async throws {
        generations += 1
        lastRequest = request
        beforeGeneration?(request)
        for _ in 0..<additionalReads { _ = try await read("workout_history", "2026-10-01", 1) }
        receive("Synthetic explanation")
    }
}
#endif
