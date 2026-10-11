import SwiftUI
import UIKit
import XCTest
@testable import NOOP
import StrandDesign
import StrandAnalytics

/// A pushed metric screen names its category beside the title unless that only repeats it.
@MainActor
final class MetricHeaderContextTests: XCTestCase {
    /// A pushed metric screen names its category beside the title, except when the category is the title.
    func testTheMetricHeaderContextIsOmittedWhenItWouldRepeatTheTitle() {
        XCTAssertNil(MetricDetailView.headerContext(category: "Recovery", title: "Recovery"))
        XCTAssertNil(MetricDetailView.headerContext(category: "recovery", title: "Recovery"))
        XCTAssertEqual(MetricDetailView.headerContext(category: "Recovery", title: "HRV"), "Recovery")
    }
}
