import XCTest
import StrandAnalytics
import WhoopStore
@testable import NOOP

@MainActor
final class InsightsLoadTests: XCTestCase {
    private func repository() async throws -> Repository {
        let repo = Repository(deviceId: Repository.whoopSource)
        repo.setStoreForTesting(try await WhoopStore.inMemory())
        return repo
    }

    private func content(days: Int) -> InsightsHubViewModel.LoadedContent {
        .init(report: InsightsReport(rows: [], daysOfData: days, unclear: []), doseCards: [])
    }

    func testRetainedHubReloadsJournalDoseWithoutAWearableRefresh() async throws {
        let repo = try await repository()
        let model = InsightsHubViewModel()
        await model.load(repo: repo)
        XCTAssertTrue(model.doseCards.isEmpty)
        let before = InsightsLoadIdentity(repo: repo)
        let day = Repository.localDayKey(Date())

        await repo.saveJournalAnswer(day: day, question: "Alcohol", answeredYes: true)
        let afterSave = InsightsLoadIdentity(repo: repo)
        XCTAssertEqual(afterSave.refreshSeq, before.refreshSeq)
        XCTAssertNotEqual(afterSave, before, "Both mounted task identities must change after a Journal save")
        await model.load(repo: repo)
        XCTAssertEqual(model.doseCards.map(\.behavior), [.alcohol])

        await repo.clearJournalAnswer(day: day, question: "Alcohol")
        XCTAssertNotEqual(InsightsLoadIdentity(repo: repo), afterSave)
        await model.load(repo: repo)
        XCTAssertTrue(model.doseCards.isEmpty, "The retained model must remove a cleared habit")
        XCTAssertEqual(repo.refreshSeq, before.refreshSeq)
    }

    func testWearableRefreshChangesTheSharedTaskIdentity() async throws {
        let repo = try await repository()
        let before = InsightsLoadIdentity(repo: repo)
        repo.refreshSeq += 1
        XCTAssertNotEqual(InsightsLoadIdentity(repo: repo), before)
    }

    func testSupersededReadCannotReplaceANewerReport() async throws {
        let repo = try await repository()
        let model = InsightsHubViewModel()
        let gate = ReadGate()
        let older = content(days: 20)
        let newer = content(days: 30)
        let pending = Task { await model.load(repo: repo) { await gate.wait(); return older } }
        await gate.waitUntilStarted()
        await model.load(repo: repo) { newer }
        gate.finish()
        await pending.value
        XCTAssertTrue(model.loaded)
        XCTAssertEqual(model.report.daysOfData, 30)
    }

    func testCancelledReadKeepsTheLastPublishedReport() async throws {
        let repo = try await repository()
        let model = InsightsHubViewModel()
        let existing = content(days: 10)
        await model.load(repo: repo) { existing }
        let gate = ReadGate()
        let replacement = content(days: 20)
        let pending = Task { await model.load(repo: repo) { await gate.wait(); return replacement } }
        await gate.waitUntilStarted()
        pending.cancel()
        gate.finish()
        await pending.value
        XCTAssertEqual(model.report.daysOfData, 10)
    }

    func testJournalChangeRejectsAnOldReadBeforeTheReplacementTaskStarts() async throws {
        let repo = try await repository()
        let model = InsightsHubViewModel()
        let gate = ReadGate()
        let old = content(days: 20)
        let pending = Task { await model.load(repo: repo) { await gate.wait(); return old } }
        await gate.waitUntilStarted()
        await repo.saveJournalAnswer(day: Repository.localDayKey(Date()), question: "Alcohol", answeredYes: true)
        gate.finish()
        await pending.value
        XCTAssertFalse(model.loaded, "An obsolete read must not publish while SwiftUI schedules its replacement")
        XCTAssertEqual(model.report, .empty)
    }

    func testSourceSwitchWithoutWearableRefreshChangesTaskIdentityAndRejectsOldRead() async throws {
        let repo = try await repository()
        let model = InsightsHubViewModel()
        let before = InsightsLoadIdentity(repo: repo)
        let gate = ReadGate()
        let old = content(days: 20)
        let pending = Task { await model.load(repo: repo) { await gate.wait(); return old } }
        await gate.waitUntilStarted()

        XCTAssertTrue(repo.adoptActiveDeviceId("whoop-insights-replacement"))
        let after = InsightsLoadIdentity(repo: repo)
        XCTAssertEqual(after.refreshSeq, before.refreshSeq)
        XCTAssertEqual(after.journalRevision, before.journalRevision)
        XCTAssertNotEqual(after.sourceContext, before.sourceContext)
        XCTAssertNotEqual(after, before, "Both mounted tasks must reload for the replacement source")
        gate.finish()
        await pending.value
        XCTAssertFalse(model.loaded)
        XCTAssertEqual(model.report, .empty, "The previous source must not publish before the new task starts")

        let replacement = content(days: 30)
        await model.load(repo: repo) { replacement }
        XCTAssertTrue(model.loaded)
        XCTAssertEqual(model.report.daysOfData, 30)
    }

    /// Deterministic ordering without sleeps, including reads that do not cooperate with cancellation.
    @MainActor private final class ReadGate {
        private var pending: CheckedContinuation<Void, Never>?
        private var started: CheckedContinuation<Void, Never>?

        func wait() async {
            await withCheckedContinuation { continuation in
                pending = continuation
                started?.resume()
                started = nil
            }
        }

        func waitUntilStarted() async {
            if pending != nil { return }
            await withCheckedContinuation { started = $0 }
        }

        func finish() {
            pending?.resume()
            pending = nil
        }
    }
}
