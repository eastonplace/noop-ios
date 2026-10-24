#if os(iOS)
import XCTest
import Foundation
import StrandAnalytics
@testable import NOOP

/// Synthetic model/data dependencies exercise the production weekly task and its persisted cache.
@MainActor
final class LocalCoachWeeklyInsightOwnershipTests: XCTestCase {
    private var savedInsight: Data?
    private let now = Date(timeIntervalSince1970: 1_781_352_000) // Saturday, safely past the thin Monday window.

    override func setUp() async throws {
        savedInsight = UserDefaults.standard.data(forKey: WeeklyCoachInsightStore.defaultsKey)
        WeeklyCoachInsightStore.clear()
    }

    override func tearDown() async throws {
        if let savedInsight { UserDefaults.standard.set(savedInsight, forKey: WeeklyCoachInsightStore.defaultsKey) }
        else { WeeklyCoachInsightStore.clear() }
    }

    private func fixture(scope: WeeklyInsightScope = WeeklyInsightScope(),
                         data: WeeklyInsightData = WeeklyInsightData(),
                         model: WeeklyInsightModel = WeeklyInsightModel()) -> LocalCoachEngine {
        let engine = LocalCoachEngine(data: data, persistence: nil, model: model, source: { scope.value })
        engine.preferences.usePersonalData = true
        return engine
    }

    private var weekStart: String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: now)
        let day = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
        return WeeklyDigestEngine.mondayOfWeek(containing: day)!
    }

    private func saveCache(owner: String?) throws {
        var object: [String: Any] = ["weekStart": weekStart, "text": "Earlier source HRV increased.",
                                     "generatedAt": now.timeIntervalSinceReferenceDate]
        if let owner { object["sourceID"] = owner }
        UserDefaults.standard.set(try JSONSerialization.data(withJSONObject: object),
                                  forKey: WeeklyCoachInsightStore.defaultsKey)
    }

    func testDatabaseScopeChangeClearsCachedSameWeekInsightImmediately() async throws {
        let scope = WeeklyInsightScope()
        let engine = fixture(scope: scope)
        try saveCache(owner: "database-a")

        scope.value.storageID = "database-b"
        scope.value.revision = "replacement"
        await engine.waitForHydration()

        XCTAssertNil(WeeklyCoachInsightStore.load(), "A restored database must not show the earlier database's insight")
    }

    func testRelaunchWithDifferentDatabaseRegeneratesCachedSameWeekInsight() async throws {
        try saveCache(owner: "database-a")
        let scope = WeeklyInsightScope()
        scope.value.storageID = "database-b"
        let model = WeeklyInsightModel()
        let engine = fixture(scope: scope, model: model)

        await engine.refreshWeeklyInsightIfNeeded(now: now)

        XCTAssertEqual(model.calls, 1)
        XCTAssertEqual(WeeklyCoachInsightStore.load()?.text, "Current source HRV is steady.")
    }

    func testLegacyCacheWithoutOwnerIsRegenerated() async throws {
        try saveCache(owner: nil)
        let model = WeeklyInsightModel()
        let engine = fixture(model: model)

        await engine.refreshWeeklyInsightIfNeeded(now: now)

        XCTAssertEqual(model.calls, 1)
        XCTAssertEqual(WeeklyCoachInsightStore.load()?.text, "Current source HRV is steady.")
    }

    func testCurrentSourceSameDayCacheStillAvoidsDuplicateGeneration() async throws {
        try saveCache(owner: "database-a")
        let model = WeeklyInsightModel()
        let engine = fixture(model: model)

        await engine.refreshWeeklyInsightIfNeeded(now: now)

        XCTAssertEqual(model.calls, 0)
        XCTAssertEqual(WeeklyCoachInsightStore.load()?.text, "Earlier source HRV increased.")
    }

    func testFenceThatReopensDuringQueryStillRejectsOldContext() async {
        let scope = WeeklyInsightScope()
        let data = WeeklyInsightData()
        let model = WeeklyInsightModel()
        let gate = WeeklyInsightGate()
        data.beforeQuery = { await gate.wait() }
        let engine = fixture(scope: scope, data: data, model: model)
        let request = Task { await engine.refreshWeeklyInsightIfNeeded(now: now) }
        await gate.waitUntilEntered()

        scope.value.fenced = true
        await engine.waitForHydration()
        scope.value.fenced = false
        await engine.waitForHydration()
        gate.release()
        await request.value

        XCTAssertEqual(model.calls, 0)
        XCTAssertNil(WeeklyCoachInsightStore.load())
    }

    func testSourceChangeDuringCompletionRejectsLateInsight() async {
        let scope = WeeklyInsightScope()
        let model = WeeklyInsightModel()
        let gate = WeeklyInsightGate()
        model.completion = { await gate.wait(); return "Earlier source private insight." }
        let engine = fixture(scope: scope, model: model)
        let request = Task { await engine.refreshWeeklyInsightIfNeeded(now: now) }
        await gate.waitUntilEntered()

        scope.value.storageID = "database-b"
        await engine.waitForHydration()
        gate.release()
        await request.value

        XCTAssertNil(WeeklyCoachInsightStore.load())
    }

    func testRevocationThenReenableDoesNotReviveEarlierCompletion() async {
        let model = WeeklyInsightModel()
        let gate = WeeklyInsightGate()
        model.completion = { await gate.wait(); return "Revoked private insight." }
        let engine = fixture(model: model)
        let request = Task { await engine.refreshWeeklyInsightIfNeeded(now: now) }
        await gate.waitUntilEntered()

        engine.preferences.usePersonalData = false
        engine.preferences.usePersonalData = true
        gate.release()
        await request.value

        XCTAssertNil(WeeklyCoachInsightStore.load())
    }

    func testOldCompletionCannotReleaseNewWeeklyTaskAdmission() async {
        let model = WeeklyInsightModel()
        let oldGate = WeeklyInsightGate()
        let newGate = WeeklyInsightGate()
        model.completion = { [weak model] in
            if model?.calls == 1 { await oldGate.wait(); return "Obsolete insight." }
            if model?.calls == 2 { await newGate.wait(); return "Current insight." }
            return "Unexpected overlapping insight."
        }
        let engine = fixture(model: model)
        let oldRequest = Task { await engine.refreshWeeklyInsightIfNeeded(now: now) }
        await oldGate.waitUntilEntered()
        engine.clearWeeklyInsight()
        let newRequest = Task { await engine.refreshWeeklyInsightIfNeeded(now: now.addingTimeInterval(60)) }
        await newGate.waitUntilEntered()
        oldGate.release()
        await oldRequest.value

        await engine.refreshWeeklyInsightIfNeeded(now: now.addingTimeInterval(31 * 60))
        XCTAssertEqual(model.calls, 2, "An old defer must not release the new task's admission slot")
        XCTAssertNil(WeeklyCoachInsightStore.load())
        newGate.release()
        await newRequest.value
        XCTAssertEqual(WeeklyCoachInsightStore.load()?.text, "Current insight.")
    }
}

@MainActor
private final class WeeklyInsightScope {
    var value = LocalCoachSourceScope(storageID: "database-a", dataSourceID: "same-device", revision: "1")
}

@MainActor
private final class WeeklyInsightData: LocalCoachDataAccess {
    var toolDescriptors: [LocalCoachToolDescriptor] { [] }
    var beforeQuery: (() async -> Void)?
    func snapshot() async throws -> LocalCoachSnapshot { .empty }
    func query(_ name: String, query: String, days: Int) async throws -> LocalCoachToolResult {
        await beforeQuery?()
        return .init(text: "Synthetic HRV is 73 ms.", evidence: [])
    }
    func makeWorkoutDraft(focus: String, minutes: Int, days: Int) async throws -> LocalCoachPlan {
        .init(title: focus, summary: "Synthetic", sourceID: "same-device", days: [])
    }
    func savePlan(_ plan: LocalCoachPlan) async throws {}
}

@MainActor
private final class WeeklyInsightModel: LocalCoachModelDriver {
    var availability: LocalCoachAvailability { .available }
    var contextCapacity: Int? { 4_096 }
    var calls = 0
    var completion: (() async -> String)?
    func stream(_ request: LocalCoachRequest, tools: [LocalCoachToolDescriptor],
                read: @escaping LocalCoachRead, receive: @escaping LocalCoachReceive) async throws {}
    func shortCompletion(instructions: String, prompt: String) async throws -> String {
        calls += 1
        return await completion?() ?? "Current source HRV is steady."
    }
}

@MainActor
private final class WeeklyInsightGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func waitUntilEntered() async {
        for _ in 0..<2_000 {
            if continuation != nil { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("The controlled weekly operation did not start")
    }
    func release() { continuation?.resume(); continuation = nil }
}
#endif
