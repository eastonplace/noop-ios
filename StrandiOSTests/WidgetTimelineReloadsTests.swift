import XCTest
@testable import NOOP

/// UIP-10 / CORE-07: each publication lane reloads only the widget kinds its change can reach, and a verified
/// commit WidgetKit was already asked to read isn't requested again.
@MainActor
final class WidgetTimelineReloadsTests: XCTestCase {
    private var recorded: [[String]] = []
    private var originalReload: (([String]) -> Void)?

    override func setUp() async throws {
        recorded = []
        originalReload = WidgetTimelineReloads.reload
        WidgetTimelineReloads.resetForTesting()
        WidgetTimelineReloads.reload = { [weak self] kinds in self?.recorded.append(kinds) }
    }

    override func tearDown() async throws {
        if let originalReload { WidgetTimelineReloads.reload = originalReload }
        WidgetTimelineReloads.resetForTesting()
    }

    private func snapshot(bpm: Int?, strain: Double?) -> WidgetSnapshot {
        WidgetSnapshot(recovery: 70, bpm: bpm, batteryPct: 80, bonded: true, updated: Date(), effort: strain)
    }

    func testLivePublishReloadsOnlyTheMainWidget() {
        WidgetTimelineReloads.afterLivePublish(
            previous: snapshot(bpm: 60, strain: 8.4), next: snapshot(bpm: 72, strain: 8.4))
        XCTAssertEqual(recorded, [[WidgetKinds.main]])
    }

    func testLivePublishAddsTheStrainCircleOnlyWhenStrainMoved() {
        WidgetTimelineReloads.afterLivePublish(
            previous: snapshot(bpm: 60, strain: 8.4), next: snapshot(bpm: 60, strain: 8.6))
        WidgetTimelineReloads.afterLivePublish(previous: nil, next: snapshot(bpm: 60, strain: 8.6))
        XCTAssertEqual(recorded, [
            [WidgetKinds.main, WidgetKinds.strainAccessory],
            [WidgetKinds.main, WidgetKinds.strainAccessory],
        ])
        XCTAssertFalse(recorded.flatMap { $0 }.contains(WidgetKinds.stress), "stress ignores the live overlay")
    }

    func testVerifiedCommitsReloadEveryKindAndAnAlreadyCurrentGenerationOnlyOnce() {
        let first = WidgetEnrichmentKey(epoch: 1, contextId: "ctx", generation: 7)
        let next = WidgetEnrichmentKey(epoch: 1, contextId: "ctx", generation: 8)

        WidgetTimelineReloads.afterVerifiedCommit(.published, key: first)
        WidgetTimelineReloads.afterVerifiedCommit(.alreadyCurrent, key: first)
        XCTAssertEqual(recorded, [WidgetKinds.all], "an already-requested generation was reloaded again")

        // A relaunch, or a generation this process never requested, still gets one read.
        WidgetTimelineReloads.afterVerifiedCommit(.alreadyCurrent, key: next)
        WidgetTimelineReloads.afterVerifiedCommit(.superseded, key: first)
        WidgetTimelineReloads.afterVerifiedCommit(.failed, key: first)
        XCTAssertEqual(recorded, [WidgetKinds.all, WidgetKinds.all])

        // Enrichment that changed content always reloads.
        WidgetTimelineReloads.afterVerifiedCommit(.published, key: next)
        XCTAssertEqual(recorded.count, 3)
    }

    func testEveryKindIsDistinctAndIncludesStress() {
        XCTAssertEqual(Set(WidgetKinds.all).count, 4)
        XCTAssertTrue(WidgetKinds.all.contains(WidgetKinds.stress))
        XCTAssertTrue(WidgetKinds.all.contains(WidgetKinds.coachBrief))
    }

    func testBriefPublicationReloadsOnlyCoachWidget() {
        var recorded: [[String]] = []
        let previous = WidgetTimelineReloads.reload
        defer { WidgetTimelineReloads.reload = previous }
        WidgetTimelineReloads.reload = { recorded.append($0) }
        WidgetTimelineReloads.afterCoachBriefChange()
        XCTAssertEqual(recorded, [[WidgetKinds.coachBrief]])
    }
}
