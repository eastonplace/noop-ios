import SwiftUI
import XCTest
@testable import StrandDesign

final class StrainDayCurveTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private var geometry: StrainCurveGeometry {
        StrainCurveGeometry(size: CGSize(width: 308, height: 164), domain: start...start.addingTimeInterval(36_000))
    }

    func testTheDomainRunsInsideTheHorizontalInsets() {
        XCTAssertEqual(geometry.x(start), StrainCurveGeometry.horizontalInset)
        XCTAssertEqual(geometry.x(start.addingTimeInterval(36_000)), 308 - StrainCurveGeometry.horizontalInset)
        XCTAssertEqual(geometry.x(start.addingTimeInterval(18_000)), 154, accuracy: 0.001)
    }

    func testTimesOutsideTheDomainClampToItsEdges() {
        XCTAssertEqual(geometry.x(start.addingTimeInterval(-3600)), StrainCurveGeometry.horizontalInset)
        XCTAssertEqual(geometry.x(start.addingTimeInterval(99_999)), 308 - StrainCurveGeometry.horizontalInset)
    }

    func testTheValueAxisIsAFixedZeroToTwentyOne() {
        XCTAssertEqual(geometry.y(0), 164 - StrainCurveGeometry.verticalInset)
        XCTAssertEqual(geometry.y(21), StrainCurveGeometry.verticalInset)
        XCTAssertEqual(geometry.y(10.5), 82, accuracy: 0.001)
        XCTAssertEqual(geometry.y(40), geometry.y(21))
        XCTAssertEqual(geometry.y(-3), geometry.y(0))
    }

    func testAPositionMapsBackToATime() {
        let middle = geometry.date(atX: 154)
        XCTAssertEqual(middle.timeIntervalSince(start), 18_000, accuracy: 1)
        XCTAssertEqual(geometry.date(atX: -50), start)
        XCTAssertEqual(geometry.date(atX: 9_999), start.addingTimeInterval(36_000))
    }

    func testScrubbingPicksTheNearestPointInTime() {
        let points = [0.0, 300, 900, 1_200].enumerated().map {
            StrainCurvePoint(t: start.addingTimeInterval($1), value: Double($0))
        }
        func index(_ seconds: Double) -> Int {
            StrainCurveGeometry.nearestIndex(to: start.addingTimeInterval(seconds), in: points)
        }
        XCTAssertEqual(index(-100), 0)
        XCTAssertEqual(index(100), 0)
        XCTAssertEqual(index(200), 1)
        XCTAssertEqual(index(600), 1)      // exactly between 300 and 900: the earlier one
        XCTAssertEqual(index(601), 2)
        XCTAssertEqual(index(5_000), 3)
    }

    func testALayoutIsRememberedUntilTheSizeOrTheDataChange() {
        let cache = StrainCurveLayoutCache()
        var built = 0
        func layout(_ size: CGSize, _ token: Int) {
            _ = cache.layout(size: size, token: token) {
                built += 1
                return StrainCurveLayout(line: Path(), area: Path(), rails: [], targetRect: nil, targetLabelSpot: nil,
                                         segments: [], startPoint: nil, endPoint: nil)
            }
        }
        layout(CGSize(width: 300, height: 164), 1)
        layout(CGSize(width: 300, height: 164), 1)
        XCTAssertEqual(built, 1, "a scrub redraws the plot without rebuilding it")
        layout(CGSize(width: 320, height: 164), 1)
        layout(CGSize(width: 320, height: 164), 2)
        XCTAssertEqual(built, 3)
    }
}
