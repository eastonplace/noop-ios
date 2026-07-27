import HealthKit
import XCTest
@testable import NOOP

#if os(iOS)
@MainActor
private final class PendingWindowMemoryStore: HealthKitPendingWindowPersisting {
    enum Failure: Error { case injected }

    var value: HealthKitSyncWindow?
    var failNextSave = false
    private(set) var saves: [HealthKitSyncWindow?] = []

    func load() -> HealthKitSyncWindow? { value }

    func save(_ window: HealthKitSyncWindow?) throws {
        if failNextSave {
            failNextSave = false
            throw Failure.injected
        }
        value = window
        saves.append(window)
    }
}

@MainActor
private final class AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false

    func wait() async {
        isWaiting = true
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

private final class CommittedWindowRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [HealthKitSyncWindow] = []

    func record(_ window: HealthKitSyncWindow) {
        lock.withLock { storage.append(window) }
    }

    var windows: [HealthKitSyncWindow] {
        lock.withLock { storage }
    }
}

@MainActor
private final class GeneratedHeartRatePageLoader: HealthKitAnchoredPageLoading {
    enum Failure: Error { case injected }

    let totalSamples: Int
    let failOnPage: Int?
    private(set) var requestedLimits: [Int] = []
    private(set) var maximumReturnedCount = 0
    private var emitted = 0

    init(totalSamples: Int, failOnPage: Int? = nil) {
        self.totalSamples = totalSamples
        self.failOnPage = failOnPage
    }

    func loadPage(
        type: HKSampleType,
        predicate: NSPredicate?,
        anchor: HKQueryAnchor?,
        limit: Int
    ) async throws -> HealthKitAnchorPage {
        requestedLimits.append(limit)
        if requestedLimits.count == failOnPage { throw Failure.injected }

        let count = min(limit, totalSamples - emitted)
        let heartRate = try XCTUnwrap(type as? HKQuantityType)
        let samples: [HKSample] = (0..<count).map { offset in
            let timestamp = TimeInterval(emitted + offset)
            return HKQuantitySample(
                type: heartRate,
                quantity: HKQuantity(unit: HKUnit.count().unitDivided(by: .minute()), doubleValue: 60),
                start: Date(timeIntervalSince1970: timestamp),
                end: Date(timeIntervalSince1970: timestamp)
            )
        }
        emitted += count
        maximumReturnedCount = max(maximumReturnedCount, samples.count)
        return HealthKitAnchorPage(
            samples: samples,
            deletedCount: 0,
            newAnchor: HKQueryAnchor(fromValue: emitted)
        )
    }
}

final class HealthKitSyncCoordinatorTests: XCTestCase {
    private func newYorkCalendar() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        return calendar
    }

    private func date(
        _ calendar: Calendar,
        year: Int,
        month: Int,
        day: Int,
        hour: Int = 12
    ) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour)))
    }

    @MainActor
    func testObserverBWidensPendingWindowWhileObserverAIsSyncing() async throws {
        let persistence = PendingWindowMemoryStore()
        let gate = AsyncGate()
        let notificationCenter = NotificationCenter()
        let recorder = CommittedWindowRecorder()
        let token = notificationCenter.addObserver(
            forName: HealthKitSyncPublication.name,
            object: nil,
            queue: nil
        ) { notification in
            if let window = HealthKitSyncPublication.window(from: notification) {
                recorder.record(window)
            }
        }
        defer { notificationCenter.removeObserver(token) }

        var calls: [HealthKitSyncWindow] = []
        let coordinator = HealthKitSyncCoordinator(
            persistence: persistence,
            notificationCenter: notificationCenter
        ) { window in
            calls.append(window)
            if calls.count == 1 { await gate.wait() }
            return true
        }
        let a = HealthKitSyncWindow(
            start: Date(timeIntervalSince1970: 200),
            end: Date(timeIntervalSince1970: 300)
        )
        let b = HealthKitSyncWindow(
            start: Date(timeIntervalSince1970: 100),
            end: Date(timeIntervalSince1970: 250)
        )

        try coordinator.offer(a)
        let firstRun = Task { @MainActor in await coordinator.runAndWait() }
        while !gate.isWaiting { await Task.yield() }

        try coordinator.offer(b)
        XCTAssertEqual(persistence.value, a.union(b), "B must be durable before A resumes")
        gate.open()
        await firstRun.value

        XCTAssertEqual(calls, [a, a.union(b)])
        XCTAssertEqual(recorder.windows, [a.union(b)],
                       "only the widest successfully cleared generation is published for scoring")
        XCTAssertNil(coordinator.pending)
        XCTAssertNil(persistence.value)
    }

    @MainActor
    func testFailedAggregationSurvivesRelaunchAndPublishesOnlyAfterSuccess() async throws {
        let persistence = PendingWindowMemoryStore()
        let notificationCenter = NotificationCenter()
        let recorder = CommittedWindowRecorder()
        let token = notificationCenter.addObserver(
            forName: HealthKitSyncPublication.name,
            object: nil,
            queue: nil
        ) { notification in
            if let window = HealthKitSyncPublication.window(from: notification) {
                recorder.record(window)
            }
        }
        defer { notificationCenter.removeObserver(token) }

        let window = HealthKitSyncWindow(
            start: Date(timeIntervalSince1970: 100),
            end: Date(timeIntervalSince1970: 200)
        )
        let failing = HealthKitSyncCoordinator(
            persistence: persistence,
            notificationCenter: notificationCenter
        ) { _ in false }
        try failing.offer(window)
        await failing.runAndWait()
        XCTAssertEqual(persistence.value, window)
        XCTAssertTrue(recorder.windows.isEmpty)

        var recoveredCalls: [HealthKitSyncWindow] = []
        let recovered = HealthKitSyncCoordinator(
            persistence: persistence,
            notificationCenter: notificationCenter
        ) { candidate in
            recoveredCalls.append(candidate)
            return true
        }
        await recovered.runAndWait()

        XCTAssertEqual(recoveredCalls, [window])
        XCTAssertEqual(recorder.windows, [window])
        XCTAssertNil(persistence.value)
    }

    @MainActor
    func testPendingPersistenceFailureDoesNotStartOrLoseInMemoryWork() async {
        let persistence = PendingWindowMemoryStore()
        persistence.failNextSave = true
        var operationCount = 0
        let coordinator = HealthKitSyncCoordinator(persistence: persistence) { _ in
            operationCount += 1
            return true
        }

        XCTAssertThrowsError(try coordinator.offer(HealthKitSyncWindow(
            start: Date(timeIntervalSince1970: 100),
            end: Date(timeIntervalSince1970: 200)
        )))
        await coordinator.runAndWait()

        XCTAssertEqual(operationCount, 0)
        XCTAssertNil(coordinator.pending)
        XCTAssertNil(persistence.value)
    }

    func testAnalysisRangeCoversRecentCommittedDays() throws {
        let calendar = try newYorkCalendar()
        let now = try date(calendar, year: 2026, month: 7, day: 27)
        let window = HealthKitSyncWindow(
            start: try date(calendar, year: 2026, month: 7, day: 25, hour: 8),
            end: try date(calendar, year: 2026, month: 7, day: 27, hour: 10))

        let range = HealthKitAnalysisRange(window: window, now: now, calendar: calendar)

        XCTAssertEqual(range.startOffset, 0)
        XCTAssertEqual(range.maxDays, 3)
        XCTAssertEqual(range.publicationDays, 120)
    }

    func testAnalysisRangeTargetsHistoricalWindowWithoutRescoringNewerGap() throws {
        let calendar = try newYorkCalendar()
        let now = try date(calendar, year: 2026, month: 7, day: 27)
        let window = HealthKitSyncWindow(
            start: try date(calendar, year: 2026, month: 7, day: 10),
            end: try date(calendar, year: 2026, month: 7, day: 12))

        let range = HealthKitAnalysisRange(window: window, now: now, calendar: calendar)

        XCTAssertEqual(range.startOffset, 15)
        XCTAssertEqual(range.maxDays, 3)
        XCTAssertEqual(range.publicationDays, 120)
    }

    func testAnalysisRangeUsesCalendarDaysAcrossSpringDST() throws {
        let calendar = try newYorkCalendar()
        let now = try date(calendar, year: 2026, month: 3, day: 9)
        let window = HealthKitSyncWindow(
            start: try date(calendar, year: 2026, month: 3, day: 7, hour: 23),
            end: try date(calendar, year: 2026, month: 3, day: 9, hour: 1))

        let range = HealthKitAnalysisRange(window: window, now: now, calendar: calendar)

        XCTAssertEqual(range.startOffset, 0)
        XCTAssertEqual(range.maxDays, 3,
                       "the 23-hour DST day still counts as one civil day")
    }

    func testFutureOnlyWindowFailsClosedToToday() throws {
        let calendar = try newYorkCalendar()
        let now = try date(calendar, year: 2026, month: 7, day: 27)
        let window = HealthKitSyncWindow(
            start: try date(calendar, year: 2026, month: 7, day: 28),
            end: try date(calendar, year: 2026, month: 7, day: 29))

        let range = HealthKitAnalysisRange(window: window, now: now, calendar: calendar)

        XCTAssertEqual(range.startOffset, 0)
        XCTAssertEqual(range.maxDays, 1)
    }

    @MainActor
    func testInitialLargeHistoryIsPagedInBoundedBatches() async throws {
        let total = 20_000
        let loader = GeneratedHeartRatePageLoader(totalSamples: total)
        let pager = HealthKitAnchorPager(loader: loader, pageLimit: 500)
        let type = try XCTUnwrap(HKObjectType.quantityType(forIdentifier: .heartRate))

        let result = try await pager.scan(type: type, predicate: nil, priorAnchor: nil)

        XCTAssertEqual(result.sampleCount, total)
        XCTAssertEqual(result.pageCount, 41, "An exact multiple requires one final empty page")
        XCTAssertTrue(result.wasInitialScan)
        XCTAssertEqual(loader.maximumReturnedCount, 500)
        XCTAssertTrue(loader.requestedLimits.allSatisfy { $0 == 500 })
        XCTAssertEqual(result.oldestSampleDate, Date(timeIntervalSince1970: 0))
        XCTAssertEqual(result.newestSampleDate, Date(timeIntervalSince1970: TimeInterval(total - 1)))
    }

    @MainActor
    func testPagingFailureDoesNotProduceACommittableFinalAnchor() async throws {
        let loader = GeneratedHeartRatePageLoader(totalSamples: 1_000, failOnPage: 2)
        let pager = HealthKitAnchorPager(loader: loader, pageLimit: 500)
        let type = try XCTUnwrap(HKObjectType.quantityType(forIdentifier: .heartRate))

        do {
            _ = try await pager.scan(type: type, predicate: nil, priorAnchor: nil)
            XCTFail("Expected the injected page fault")
        } catch GeneratedHeartRatePageLoader.Failure.injected {
            XCTAssertEqual(loader.requestedLimits.count, 2)
        }
    }
}
#endif
