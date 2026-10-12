import SwiftUI
import UIKit
import XCTest
@testable import NOOP
import StrandDesign
import StrandAnalytics

/// A pushed metric screen names its category beside the title unless that only repeats it, and always the source.
@MainActor
final class MetricHeaderContextTests: XCTestCase {
    /// The category is left out when it is the title; the source is always there, so two catalog metrics with the
    /// same title (Whoop's and a Mi Band's resting heart rate) are told apart.
    func testTheMetricHeaderContextOmitsACategoryThatRepeatsTheTitleButAlwaysNamesTheSource() {
        XCTAssertEqual(MetricDetailView.headerContext(category: "Recovery", title: "Recovery", source: "Whoop"), "Whoop")
        XCTAssertEqual(MetricDetailView.headerContext(category: "recovery", title: "Recovery", source: "Whoop"), "Whoop")
        XCTAssertEqual(MetricDetailView.headerContext(category: "Recovery", title: "HRV", source: "Whoop"), "Recovery \u{00B7} Whoop")
        XCTAssertNotEqual(
            MetricDetailView.headerContext(category: "Recovery", title: "Resting Heart Rate", source: "Whoop"),
            MetricDetailView.headerContext(category: "Recovery", title: "Resting Heart Rate", source: "Mi Band"))
    }
}
