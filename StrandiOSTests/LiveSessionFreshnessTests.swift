import XCTest
import Combine
import StrandAnalytics
import WhoopProtocol
@testable import NOOP

@MainActor
final class LiveSessionFreshnessTests: XCTestCase {
    func testTimerDoesNotRefreshTheLastHeartRate() {
        let model = AppModel(startRuntimeTasks: false)
        let runner = LiveSessionRunner()
        runner.start(model: model, repo: model.repo, ble: model.ble, profile: model.profile)
        defer { runner.end() }

        let source = LiveHeartRateSource(deviceId: model.repo.deviceId, peripheralID: UUID(), connectionGeneration: 1)
        model.live.activateHeartRateSource(source)
        let observedAt = Date()
        model.ble.parseStandardHR([0, 140], observedAt: observedAt, source: source)
        XCTAssertEqual(runner.output?.sampleArrived, true)
        let sampleSecond = Int(observedAt.timeIntervalSince1970)
        runner.tick(now: sampleSecond + 1)
        XCTAssertEqual(runner.output?.sampleArrived, false)
        runner.tick(now: sampleSecond + LiveSessionEngine.staleAfterSec + 1)
        XCTAssertEqual(runner.output?.status, .stale)
    }

    func testSubscriptionDoesNotTreatCachedHeartRateAsAnArrival() {
        let model = AppModel(startRuntimeTasks: false)
        model.live.heartRate = 140
        let runner = LiveSessionRunner()
        runner.start(model: model, repo: model.repo, ble: model.ble, profile: model.profile)
        defer { runner.end() }
        runner.tick(now: runner.startTs)
        XCTAssertEqual(runner.output?.sampleArrived, false)
        XCTAssertEqual(runner.output?.status, .stale)
    }

    func testNewEqualValuedReadingsRemainFreshAndUseTheEmittedValue() async throws {
        let model = AppModel(startRuntimeTasks: false)
        let runner = LiveSessionRunner()
        runner.start(model: model, repo: model.repo, ble: model.ble, profile: model.profile)
        defer { runner.end() }

        let source = LiveHeartRateSource(deviceId: model.repo.deviceId, peripheralID: UUID(), connectionGeneration: 1)
        model.live.activateHeartRateSource(source)
        // The actual parser emits owned receipts, including equal readings in different seconds.
        model.ble.parseStandardHR([0, 141], observedAt: Date(), source: source)
        XCTAssertEqual(runner.output?.smoothedBpm, 141)
        XCTAssertEqual(runner.output?.sampleArrived, true)
        try await Task.sleep(for: .milliseconds(1_100))
        model.ble.parseStandardHR([0, 141], observedAt: Date(), source: source)
        XCTAssertEqual(runner.output?.sampleArrived, true)
        XCTAssertNotEqual(runner.output?.status, .stale)
    }

    func testSteadyStandardHeartRateRemainsFreshWithoutRepeatedDisplayPublication() {
        let model = AppModel(startRuntimeTasks: false)
        let source = LiveHeartRateSource(deviceId: model.repo.deviceId, peripheralID: UUID(), connectionGeneration: 1)
        model.live.activateHeartRateSource(source)
        var engine = LiveSessionEngine(config: .init(restingHR: 60, hrMax: 190, charge: 50), startTs: 1_000)
        var now = 1_000
        var output: LiveSessionEngine.Output?
        var displayPublications = 0
        let display = model.live.$heartRate.dropFirst().sink { _ in displayPublications += 1 }
        let arrivals = model.live.heartRateReceipts.sink { receipt in
            output = engine.update(now: receipt.observedSecond, bpm: receipt.bpm)
        }
        defer { display.cancel(); arrivals.cancel() }

        for second in 0...30 {
            now = 1_000 + second
            let observedAt = Date(timeIntervalSince1970: Double(now))
            model.ble.parseStandardHR([0, 141], observedAt: observedAt, source: source, admissionTime: observedAt)
            XCTAssertEqual(output?.sampleArrived, true)
            XCTAssertNotEqual(output?.status, .stale)
        }
        XCTAssertEqual(displayPublications, 1, "equal arrivals must not republish the display snapshot")
        XCTAssertEqual(engine.update(now: now + LiveSessionEngine.staleAfterSec + 1, bpm: nil).status, .stale)
    }

    func testProprietaryRealtimeNotificationsKeepEqualHeartRateArrivals() {
        // Existing synthetic WHOOP 4 protocol fixture, not user health data.
        let hex = "aa1800ff28020f3de10100003c0000000000000000000000b7e67942"
        let characters = Array(hex)
        let frame = stride(from: 0, to: characters.count, by: 2).map {
            UInt8(String(characters[$0...($0 + 1)]), radix: 16)!
        }
        let live = LiveState()
        let source = LiveHeartRateSource(deviceId: "whoop-a", peripheralID: UUID(), connectionGeneration: 1)
        live.activateHeartRateSource(source)
        let router = FrameRouter(state: live)
        var arrivals: [Int] = []
        let subscription = live.heartRateReceipts.sink { arrivals.append($0.bpm) }
        defer { subscription.cancel() }
        let observedAt = Date()
        router.handle(frame: frame, observedAt: observedAt.addingTimeInterval(-2), source: source)
        router.handle(frame: frame, observedAt: observedAt, source: source)
        XCTAssertEqual(arrivals, [60, 60])
        router.handle(frame: frame)
        XCTAssertEqual(arrivals, [60, 60], "a source-free preview cannot invent a physical receipt")
    }
}
