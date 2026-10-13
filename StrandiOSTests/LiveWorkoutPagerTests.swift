import XCTest
import StrandDesign
@testable import NOOP

/// Which pages the live screen has, where it opens, and what it keeps between a Minimize and a return.
@MainActor
final class LiveWorkoutPagerTests: XCTestCase {
    func testARouteWorkoutHasThreePagesAndAnythingElseTwo() {
        XCTAssertEqual(LiveWorkoutPage.pages(tracksRoute: true), [.focus, .heart, .route])
        XCTAssertEqual(LiveWorkoutPage.pages(tracksRoute: false), [.focus, .heart])
    }

    /// The dots are the adjustable "Pages" element of VoiceOver and Switch Control: pausing or ending never takes it away.
    func testThePageDotsStayInEveryStateAndThePreviewSitsAboveThemOnceStill() {
        for (paused, ending) in [(false, false), (true, false), (false, true), (true, true)] {
            XCTAssertTrue(LiveWorkoutPagerFooter.showsPageDots(isPaused: paused, isEnding: ending), "paused \(paused), ending \(ending)")
        }
        XCTAssertFalse(LiveWorkoutPagerFooter.showsSavePreview(isPaused: false, isEnding: false))
        XCTAssertTrue(LiveWorkoutPagerFooter.showsSavePreview(isPaused: true, isEnding: false))
        XCTAssertTrue(LiveWorkoutPagerFooter.showsSavePreview(isPaused: false, isEnding: true))
    }

    func testAPageTheWorkoutNoLongerHasFallsBackToTheFirst() {
        let indoor = LiveWorkoutPage.pages(tracksRoute: false)
        XCTAssertEqual(LiveWorkoutPage.resolve(.route, in: indoor), .focus, "location went off while the route page was showing")
        XCTAssertEqual(LiveWorkoutPage.resolve(.heart, in: indoor), .heart)
        XCTAssertEqual(LiveWorkoutPage.resolve(nil, in: indoor), .focus)
    }

    func testTheDemoFlagNamesAPage() {
        XCTAssertEqual(LiveWorkoutPage.demoPage(arguments: ["app", "--demo-live-page", "heart"]), .heart)
        XCTAssertEqual(LiveWorkoutPage.demoPage(arguments: ["--demo-live-page", "route"]), .route)
        XCTAssertNil(LiveWorkoutPage.demoPage(arguments: ["--demo-live-page", "splits"]))
        XCTAssertNil(LiveWorkoutPage.demoPage(arguments: ["--demo-live-page"]))
        XCTAssertNil(LiveWorkoutPage.demoPage(arguments: []))
    }

    @MainActor func testEachWorkoutKeepsItsOwnPage() {
        let memory = WorkoutPageMemory()
        let first = UUID(), second = UUID()
        XCTAssertNil(memory[first])
        memory[first] = .heart
        memory[second] = .route
        XCTAssertEqual(memory[first], .heart)
        XCTAssertEqual(memory[second], .route)
    }

    @MainActor func testTheRouterOwnsTheMemoryTheJourneyHandsToTheLiveScreen() {
        let router = NavRouter()
        let session = UUID()
        router.workoutPageMemory[session] = .heart
        XCTAssertEqual(router.workoutPageMemory[session], .heart)
    }

    // MARK: What the pages draw

    /// The heart page is the tallest page; at the accessibility sizes its zone row is one line per zone, taller than the three
    /// columns, and the page says so, so the figures are scaled to fit it.
    func testTheHeartPageIsTallerWithoutAStrapAndAtTheAccessibilitySizes() {
        let normal = LiveHeartPage.naturalHeight(accessibilitySize: false, noStrap: false)
        XCTAssertGreaterThan(LiveHeartPage.naturalHeight(accessibilitySize: false, noStrap: true), normal)
        XCTAssertGreaterThan(LiveHeartPage.naturalHeight(accessibilitySize: true, noStrap: false), normal)
        // On the reference screen's 532 pt of page it fits at its designed size.
        XCTAssertEqual(LiveNumeralMetrics.fit(natural: normal, region: 532 - LivePageMetrics.bottomReserve).scale, 1)
    }

    /// The route page's figures give way (to the smallest scale) before the map shrinks below its least height.
    func testTheRoutePageKeepsTheMapBigAndShrinksTheFiguresFirst() {
        let roomy = LiveRoutePage.fit(region: 520, band: LiveNumeralMetrics.noticeBand)
        XCTAssertEqual(roomy.scale, 1)
        XCTAssertGreaterThanOrEqual(roomy.map, 180)
        XCTAssertFalse(roomy.scrolls)
        let tight = LiveRoutePage.fit(region: 340, band: LiveNumeralMetrics.noticeBand)
        XCTAssertLessThan(tight.scale, 1)
        XCTAssertGreaterThan(tight.map, 100)
        let tiny = LiveRoutePage.fit(region: 200, band: LiveNumeralMetrics.noticeBand)
        XCTAssertEqual(tiny.scale, LiveNumeralMetrics.minimumScale)
        XCTAssertTrue(tiny.scrolls, "and then the page scrolls rather than crush the figures further")
    }

    /// The preview line under the figures once paused, in whatever order the language puts its words: the figures are split out
    /// so they can be white and the words grey.
    func testThePausedPreviewSaysWhatEndWouldSaveWithTheFiguresSplitOut() {
        let segments = LiveSavePreview.segments(elapsed: 2_051, distance: ("5.49", "km"), strain: "7.4")
        let figures = segments.filter(\.isFigure).map(\.text)
        XCTAssertEqual(figures, ["34:11", "5.49", "7.4"])
        let text = segments.map(\.text).joined()
        XCTAssertTrue(text.contains("5.49 km"))
        XCTAssertFalse(text.contains("\u{1}"), "the marker never reaches the screen")
    }

    func testThePausedPreviewLeavesOutADistanceThereIsNoneOfAndSaysWhenStrainIsNotScored() {
        let segments = LiveSavePreview.segments(elapsed: 90, distance: nil, strain: nil)
        XCTAssertEqual(segments.filter(\.isFigure).map(\.text), ["1:30"])
        XCTAssertTrue(segments.map(\.text).joined().contains(String(localized: "strain not scored yet")))
    }

    /// When the line does not fit on one row (a long translation, a large type size) it stacks one fact per row, so the "·"
    /// separators go with the break instead of ending up stranded at the end of a line.
    func testThePausedPreviewStacksOneFactPerRowWithoutTheSeparators() {
        let segments = LiveSavePreview.segments(elapsed: 2_051, distance: ("5.49", "km"), strain: "7.4")
        let facts = LiveSavePreview.facts(of: segments)
        XCTAssertEqual(facts.count, 3)
        XCTAssertEqual(facts[1].map(\.text).joined(), "5.49 km")
        XCTAssertFalse(facts.joined().contains { $0.text.contains("·") })
        XCTAssertEqual(LiveSavePreview.facts(of: LiveSavePreview.segments(elapsed: 90, distance: nil, strain: nil)).count, 2)
    }
}
