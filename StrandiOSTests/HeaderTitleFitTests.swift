import SwiftUI
import UIKit
import XCTest
@testable import NOOP
import StrandDesign

/// On a device SwiftUI hyphenates a header title's long word ("ANSTREN-GUNG") when the type is a Dynamic Type text
/// style; the header title instead scales it to fit. Measured through a hosting controller at the largest text size.
@MainActor
final class HeaderTitleFitTests: XCTestCase {
    private func height<V: View>(width: CGFloat, size: DynamicTypeSize = .accessibility5,
                                 @ViewBuilder _ view: () -> V) -> CGFloat {
        UIHostingController(rootView: view().environment(\.dynamicTypeSize, size))
            .sizeThatFits(in: CGSize(width: width, height: 10_000)).height
    }

    /// The view's natural (ideal) width at `size`: what it takes when nothing squeezes it.
    private func naturalWidth<V: View>(size: DynamicTypeSize, @ViewBuilder _ view: () -> V) -> CGFloat {
        UIHostingController(rootView: view().fixedSize(horizontal: true, vertical: false).environment(\.dynamicTypeSize, size))
            .sizeThatFits(in: CGSize(width: 10_000, height: 10_000)).width
    }

    func testALongWordInThePushedRowStaysOnOneScaledLine() {
        let oneLine = height(width: 3000) { NoopDetailTitleRow("Anstrengung", backAction: {}) }
        let narrow = height(width: 300) { NoopDetailTitleRow("Anstrengung", backAction: {}) }
        XCTAssertLessThan(narrow, oneLine * 1.4, "a hyphenated word would stack two title lines")
    }

    func testTwoWordsWrapBetweenThemInThePushedRow() {
        let oneLine = height(width: 3000) { NoopDetailTitleRow("Cycling Summary", backAction: {}) }
        let narrow = height(width: 300) { NoopDetailTitleRow("Cycling Summary", backAction: {}) }
        // Two lines (one per word), never three of split words.
        XCTAssertLessThan(narrow, oneLine * 2.4)
    }

    func testTheCompactSheetHeaderAndTheTabRowDoNotStackSplitWordsEither() {
        let oneLine = height(width: 3000) { NoopTabTitleRow("Anstrengung") }
        let tab = height(width: 300) { NoopTabTitleRow("Anstrengung") }
        XCTAssertLessThan(tab, oneLine * 1.4)
        let headerOneLine = height(width: 3000) { NoopScreenHeader(title: "Anstrengung", style: .compact) }
        let header = height(width: 300) { NoopScreenHeader(title: "Anstrengung", style: .compact) }
        XCTAssertLessThan(header, headerOneLine * 1.4)
    }

    func testASectionEyebrowScalesALongWordInsteadOfHyphenatingIt() {
        let oneLine = height(width: 3000) { SectionEyebrow(title: "Tagesanstrengung") }
        let narrow = height(width: 280) { SectionEyebrow(title: "Tagesanstrengung") }
        XCTAssertLessThan(narrow, oneLine * 1.4, "a hyphenated word would stack two lines")
    }

    func testTheExpandedScreenTitleScalesALongWordInsteadOfHyphenatingIt() {
        let oneLine = height(width: 3000) { NoopScreenHeader(title: "Anstrengung") }
        let narrow = height(width: 320) { NoopScreenHeader(title: "Anstrengung") }
        XCTAssertLessThan(narrow, oneLine * 1.3)
    }

    func testTheCompactHeaderSubtitleWrapsUnderTheTitleInsteadOfTruncating() {
        let subtitle: LocalizedStringKey = "Erholung · Anstrengung · Schlaf · Gesundheit"
        let oneLine = height(width: 3000) { NoopScreenHeader(title: "Wert", subtitle: subtitle, style: .compact) }
        let narrow = height(width: 300) { NoopScreenHeader(title: "Wert", subtitle: subtitle, style: .compact) }
        XCTAssertGreaterThan(narrow, oneLine * 1.3, "the subtitle takes more lines rather than ending in an ellipsis")
    }

    func testATabLabelStaysOnOneLineAtTheLargestTextSize() {
        let word = height(width: 3000) { PaperTabLabel(title: "Einstellungen", isActive: false) }
        let slot = height(width: 60) { PaperTabLabel(title: "Einstellungen", isActive: true) }
        // Scaled down to fit the slot it is shorter than the full-size line; wrapped or hyphenated it would be taller.
        XCTAssertLessThanOrEqual(slot, word + 1, "a label that did not fit would wrap or hyphenate onto a second line")
    }

    func testAWidgetLabelScalesALongWordInsteadOfHyphenatingIt() {
        let oneLine = height(width: 3000) { Text("Effizienzbewertung").microLabelFit() }
        let narrow = height(width: 110) { Text("Effizienzbewertung").microLabelFit() }
        XCTAssertLessThan(narrow, oneLine * 1.4, "a hyphenated word would stack two lines")
        let caption = height(width: 3000) { Text("Effizienzbewertung").captionLabelFit() }
        let captionNarrow = height(width: 110) { Text("Effizienzbewertung").captionLabelFit() }
        XCTAssertLessThan(captionNarrow, caption * 1.4)
    }

    func testTheH2HeaderKeepsEveryPageTitleAndStatusWithinANarrowPhone() {
        let titles: [LocalizedStringKey] = ["Today", "Trends", "Coach", "Sleep"]
        for title in titles {
            func chrome() -> HeaderChromeRow {
                HeaderChromeRow(title: title, strapState: .offline, battery: 68, syncState: .idle,
                                initials: "", recovery: 72,
                                onStrap: {}, onSync: {}, onProfile: {})
            }
            let regular = height(width: 288, size: .large) { chrome() }
            let accessible = height(width: 288) { chrome() }
            XCTAssertGreaterThanOrEqual(regular, 44, "the action row keeps its minimum touch height")
            XCTAssertGreaterThan(accessible, regular + 44, "large text moves account actions below the full title and status")
            let wide = height(width: 3000) { chrome() }
            XCTAssertLessThan(accessible, wide * 1.8, "a narrow phone may wrap status words, but never stack individual title letters")
        }
    }

    func testTheHeaderBatteryStaysOnOneLineAtPhoneWidthsAndAccessibilitySizes() {
        func chrome(_ battery: Int?) -> HeaderChromeRow {
            HeaderChromeRow(title: "Today", strapState: .offline, battery: battery, syncState: .idle,
                            initials: "", recovery: 72, onStrap: {}, onSync: {}, onProfile: {})
        }
        let phoneWidths: [CGFloat] = [320, 375, 402]
        let typeSizes: [DynamicTypeSize] = [.large, .accessibility5]
        let batteryLevels: [Int?] = [nil, 0, 15, 100]
        for phoneWidth in phoneWidths {
            let contentWidth = phoneWidth - 32 // AppHeaderChrome's horizontal padding.
            for size in typeSizes {
                let reference = height(width: contentWidth, size: size) { chrome(68) }
                for battery in batteryLevels {
                    let measured = height(width: contentWidth, size: size) { chrome(battery) }
                    XCTAssertEqual(measured, reference, accuracy: 0.5,
                                   "battery values stay horizontal without adding a line at \(phoneWidth) pt and \(size)")
                    XCTAssertGreaterThanOrEqual(measured, 44, "header actions keep their minimum touch height")
                }
            }
        }
    }

    func testTheHeaderBatterySymbolsExistOnTheSupportedPlatform() {
        let symbols = ["battery.0percent", "battery.25percent", "battery.50percent",
                       "battery.75percent", "battery.100percent"]
        for symbol in symbols {
            XCTAssertNotNil(UIImage(systemName: symbol), "header battery symbol must resolve: \(symbol)")
        }
    }

    private func trendsHeaderWithTools(_ battery: Int? = 68, syncState: AppSyncState = .error) -> HeaderChromeRow {
        HeaderChromeRow(title: "Trends", strapState: .offline, battery: battery, syncState: syncState,
                        initials: "", recovery: 72, onStrap: {}, onSync: {}, onProfile: {},
                        titleActions: AnyView(HStack(spacing: 8) {
                            Button {} label: {
                                WidgetChip(appTitle: "Explore", systemImage: "square.grid.2x2",
                                           showsChevron: false, overhangs: false)
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Button {} label: {
                                WidgetChip(systemImage: "square.and.arrow.up", showsChevron: false, overhangs: false)
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }))
    }

    func testTrendsToolsFitBesideTheTitleOnA402PointPhone() {
        let idle = height(width: 370, size: .large) { trendsHeaderWithTools(syncState: .idle) }
        XCTAssertLessThan(idle, 88, "with a short status the page tools sit beside the account controls in one row")
        for battery in [nil, 0, 68, 100] as [Int?] {
            let withTools = height(width: 370, size: .large) { trendsHeaderWithTools(battery) }
            XCTAssertEqual(withTools, idle + 44, accuracy: 0.5,
                           "a long offline/error status keeps its row and the page tools take one 44 pt row below")
        }
    }

    func testTrendsToolsReflowAtNarrowWidthsAndAccessibilitySizes() {
        let compact = height(width: 370, size: .large) { trendsHeaderWithTools() }
        let narrow = height(width: 288, size: .large) { trendsHeaderWithTools() }
        let accessible = height(width: 288) { trendsHeaderWithTools() }
        XCTAssertGreaterThanOrEqual(narrow, compact, "narrow phones retain both 44 pt header rows")
        XCTAssertLessThanOrEqual(narrow, compact + 44, "a narrow status/tools fallback adds at most one touch row")
        XCTAssertGreaterThan(accessible, narrow + 44, "accessibility text stacks tools and account controls")
    }

    private func pillar(_ id: String, _ label: String, _ state: String) -> TodayPillarModel {
        TodayPillarModel(id: id, label: label, value: 72, maximum: 100, valueText: "72", state: state, accent: .green)
    }

    private func heroCard(_ pillars: [TodayPillarModel]) -> TodayHeroCard {
        TodayHeroCard(pillars: pillars, glance: "", workoutIsActive: false, showsWorkoutAction: false,
                      onPillar: { _ in }, onOpenWorkouts: {}, onWorkoutAction: {})
    }

    func testTheHeroCardStacksItsPillarsOneRowEachAtTheLargestTextSize() {
        let all = [pillar("a", "Erholung", "Bereit"), pillar("b", "Anstrengung", "Moderat"), pillar("c", "Schlaf", "Gut")]
        let two = height(width: 370) { heroCard(Array(all.prefix(2))) }
        let three = height(width: 370) { heroCard(all) }
        XCTAssertGreaterThan(three - two, 90, "each pillar is a row of its own: side by side a third pillar adds nothing")
        // Side by side at every size short of the accessibility sizes, exactly as before.
        let twoLarge = height(width: 370, size: .large) { heroCard(Array(all.prefix(2))) }
        let threeLarge = height(width: 370, size: .large) { heroCard(all) }
        XCTAssertLessThan(threeLarge - twoLarge, 40, "a third pillar goes beside the others, not under them")
    }

    func testAPillarRowKeepsALongGermanLabelOnOneScaledLine() {
        let short = height(width: 370) { heroCard([pillar("b", "Schlaf", "Gut")]) }
        let long = height(width: 370) { heroCard([pillar("b", "Anstrengungsbelastung", "Gut")]) }
        XCTAssertLessThan(long, short * 1.25, "a hyphenated or wrapped label would make the row taller")
    }

    // MARK: Sizes short of the accessibility sizes are not changed

    func testAHeaderSubtitleStaysOneLineAtEverySizeShortOfAccessibility() {
        let long: LocalizedStringKey = "Tippe eine Zahl aus deinem eigenen Befund ein. Sie bleibt auf diesem iPhone."
        for size in [DynamicTypeSize.large, .xxxLarge] {
            let caption = height(width: 3000, size: size) { Text(verbatim: "Ag").font(StrandFont.caption) }
            // Expanded: a long subtitle takes the one line a short one does.
            let short = height(width: 300, size: size) { NoopScreenHeader(title: "Wert", subtitle: "Kurz") }
            let longer = height(width: 300, size: size) { NoopScreenHeader(title: "Wert", subtitle: long) }
            XCTAssertEqual(longer, short, accuracy: 0.5, "expanded subtitle at \(size)")
            // Compact: the stacked fallback shows the subtitle on one truncated line, not a wrapped block.
            let titleOnly = height(width: 300, size: size) { NoopScreenHeader(title: "Wert", style: .compact) }
            let compact = height(width: 300, size: size) { NoopScreenHeader(title: "Wert", subtitle: long, style: .compact) }
            XCTAssertLessThan(compact, titleOnly + 2 * caption, "compact subtitle at \(size)")
        }
        // At an accessibility size it wraps instead: the long one is taller than a short one that takes a single line.
        let caption = height(width: 3000) { Text(verbatim: "Ag").font(StrandFont.caption) }
        let shortAX = height(width: 300) { NoopScreenHeader(title: "Wert", subtitle: "Kurz", style: .compact) }
        let longAX = height(width: 300) { NoopScreenHeader(title: "Wert", subtitle: long, style: .compact) }
        XCTAssertGreaterThan(longAX, shortAX + caption)
    }

    func testAMetricRowLabelStaysOneLineShortOfAccessibilitySizes() {
        let label = "A label long enough to run out of the row it is in"
        let row = { (text: String) in MetricValueRow(systemImage: "heart", label: text, value: "12", unit: "bpm") }
        let short = height(width: 220, size: .large) { row("Short") }
        let long = height(width: 220, size: .large) { row(label) }
        XCTAssertEqual(long, short, accuracy: 0.5)
        let shortAX = height(width: 220) { row("Short") }
        let longAX = height(width: 220) { row(label) }
        XCTAssertGreaterThan(longAX, shortAX, "at an accessibility size the label takes a second line")
    }

    func testTheTabLabelIsThePlainTextStyleShortOfAccessibilitySizes() {
        // At xxxLarge the label is the plain `.caption2` text, as it always was; the 15 pt ceiling is for the
        // accessibility sizes, where the large content viewer shows the full-size label.
        let label = height(width: 3000, size: .xxxLarge) { PaperTabLabel(title: "Settings", isActive: false) }
        let plain = height(width: 3000, size: .xxxLarge) { Text("Settings").font(StrandFont.micro.weight(.regular)) }
        XCTAssertEqual(label, plain, accuracy: 0.5)
        let uncapped = { Text("Settings").microLabelFit(lines: 1, weight: .regular) }
        let labelAX = height(width: 3000) { PaperTabLabel(title: "Settings", isActive: false) }
        XCTAssertLessThan(labelAX, height(width: 3000) { uncapped() })
    }

    func testTheH2HeaderLetsTheActualSyncErrorWrapAtAccessibilitySizes() {
        func chrome(_ state: AppSyncState) -> HeaderChromeRow {
            HeaderChromeRow(title: "Today", strapState: .offline, battery: 68, syncState: state,
                            initials: "", recovery: 72,
                            onStrap: {}, onSync: {}, onProfile: {})
        }
        let offline = height(width: 288) { chrome(.idle) }
        let error = height(width: 288) { chrome(.error) }
        XCTAssertGreaterThan(error, offline, "the real sync error takes more lines instead of being clipped or condensed away")
        // Extra state changes the status text, never the stable pair of account action targets.
        XCTAssertGreaterThanOrEqual(height(width: 288, size: .large) { chrome(.syncing) }, 44)
    }
}
