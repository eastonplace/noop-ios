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

        runner.tick(receivedBPM: 140, now: runner.startTs + 1)
        XCTAssertEqual(runner.output?.sampleArrived, true)
        runner.tick(now: runner.startTs + 2)
        XCTAssertEqual(runner.output?.sampleArrived, false)
        runner.tick(now: runner.startTs + 1 + LiveSessionEngine.staleAfterSec + 1)
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

    func testNewEqualValuedReadingsRemainFreshAndUseTheEmittedValue() {
        let model = AppModel(startRuntimeTasks: false)
        let runner = LiveSessionRunner()
        runner.start(model: model, repo: model.repo, ble: model.ble, profile: model.profile)
        defer { runner.end() }

        // The real parser emits arrivals after updating the display, including repeated equal readings.
        model.ble.parseStandardHR([0, 141])
        XCTAssertEqual(runner.output?.smoothedBpm, 141)
        XCTAssertEqual(runner.output?.sampleArrived, true)
        model.ble.parseStandardHR([0, 141])
        XCTAssertEqual(runner.output?.sampleArrived, true)
        XCTAssertNotEqual(runner.output?.status, .stale)
    }

    func testSteadyStandardHeartRateRemainsFreshWithoutRepeatedDisplayPublication() {
        let model = AppModel(startRuntimeTasks: false)
        var engine = LiveSessionEngine(config: .init(restingHR: 60, hrMax: 190, charge: 50), startTs: 1_000)
        var now = 1_000
        var output: LiveSessionEngine.Output?
        var displayPublications = 0
        let display = model.live.$heartRate.dropFirst().sink { _ in displayPublications += 1 }
        let arrivals = model.live.heartRateArrivals.sink { bpm in
            output = engine.update(now: now, bpm: bpm)
        }
        defer { display.cancel(); arrivals.cancel() }

        for second in 0...30 {
            now = 1_000 + second
            model.ble.parseStandardHR([0, 141])
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
        let router = FrameRouter(state: live)
        var arrivals: [Int] = []
        let subscription = live.heartRateArrivals.sink { arrivals.append($0) }
        defer { subscription.cancel() }
        router.handle(frame: frame)
        router.handle(frame: frame)
        XCTAssertEqual(arrivals, [60, 60])
    }
}
