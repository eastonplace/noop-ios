import SwiftUI
import XCTest
@testable import NOOP
import StrandDesign

/// How the catalog looks: one tint per metric, one symbol per category, one word per correlation strength.
final class MetricPresentationTests: XCTestCase {
    private func metric(_ key: String, source: String = "my-whoop") throws -> MetricDescriptor {
        try XCTUnwrap(MetricCatalog.all.first { $0.key == key && $0.source == source }, "no catalog metric \(key)")
    }

    private func accent(_ tint: DomainTint) -> Color { tint.accent }

    func testSleepMetricsWearTheSleepTintNotTheActionAccent() throws {
        for key in ["sleep_performance", "sleep_total_min", "sleep_deep_min", "restorative_pct", "sleep_efficiency"] {
            XCTAssertEqual(accent(try metric(key).domainTint()), DomainTint.sleep.accent, key)
        }
    }

    func testStrainAndHeartMetricsFollowTheirDomains() throws {
        XCTAssertEqual(accent(try metric("strain").domainTint()), DomainTint.strain.accent)
        XCTAssertEqual(accent(try metric("hr_zones45_min").domainTint()), DomainTint.strain.accent)
        XCTAssertEqual(accent(try metric("rhr").domainTint()), DomainTint.heart.accent)
        XCTAssertEqual(accent(try metric("hrv").domainTint()), DomainTint.hrv.accent)
        XCTAssertEqual(accent(try metric("stress").domainTint()), DomainTint.stress.accent)
    }

    func testRecoveryFollowsItsBandOnceItHasAScoreAndNeverReadsAsGrey() throws {
        let recovery = try metric("recovery")
        XCTAssertEqual(accent(recovery.domainTint(latest: 85)), DomainTint.recovery(score: 85).accent)
        XCTAssertEqual(accent(recovery.domainTint(latest: 20)), DomainTint.recovery(score: 20).accent)
        XCTAssertNotEqual(accent(recovery.domainTint()), DomainTint.recovery(score: nil).accent)
    }

    func testEveryMetricResolvesATintAndEveryCategoryASymbol() {
        for metric in MetricCatalog.all { _ = metric.domainTint() }
        for category in MetricCatalog.categories {
            XCTAssertNotEqual(MetricCatalog.categorySymbol(category), "chart.xyaxis.line", category)
        }
    }

    func testEveryCorrelationStrengthHasItsOwnWord() {
        let words = CorrelationStrength.allCases.map(\.word)
        XCTAssertEqual(Set(words).count, CorrelationStrength.allCases.count)
        XCTAssertFalse(words.contains(where: \.isEmpty))
    }

    func testExploreRowsStackFromTheLargestStandardTextSize() {
        XCTAssertFalse(ExploreRowLayout.stacks(.xxLarge))
        XCTAssertTrue(ExploreRowLayout.stacks(.xxxLarge))
        XCTAssertTrue(ExploreRowLayout.stacks(.accessibility5))
    }

    func testRangeTitlesNameTheirWindow() {
        XCTAssertEqual(ExploreRange.all.title, String(localized: "All time"))
        XCTAssertEqual(ExploreRange.week.title, String(localized: "Last \(7) days"))
        XCTAssertEqual(ExploreRange.year.title, String(localized: "Last \(365) days"))
    }
}
