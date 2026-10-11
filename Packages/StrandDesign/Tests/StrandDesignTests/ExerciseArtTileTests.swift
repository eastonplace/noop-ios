import XCTest
import SwiftUI
@testable import StrandDesign

/// The calm exercise tile scales its mat and corner with its size, and never draws a hairline-thin mat or a pill.
final class ExerciseArtTileTests: XCTestCase {
    func testMatIsSixPercentOfTheTileAndNeverUnderTwoPoints() {
        XCTAssertEqual(ExerciseArtTile<Color>.mat(for: 20), 2)
        XCTAssertEqual(ExerciseArtTile<Color>.mat(for: 52), 3)
        XCTAssertEqual(ExerciseArtTile<Color>.mat(for: 220), 13)
    }

    func testRadiusIsAQuarterOfTheSideWithinSixAndTheCardRadius() {
        XCTAssertEqual(ExerciseArtTile<Color>.radius(for: 10), 6)
        XCTAssertEqual(ExerciseArtTile<Color>.radius(for: 44), min(NoopMetrics.radius3, 10))
        XCTAssertEqual(ExerciseArtTile<Color>.radius(for: 400), NoopMetrics.radius3)
    }

    func testTheMatNeverSwallowsTheInnerCorner() {
        for size in stride(from: CGFloat(16), through: 240, by: 8) {
            let inner = ExerciseArtTile<Color>.radius(for: size) - ExerciseArtTile<Color>.mat(for: size)
            XCTAssertGreaterThan(inner, 0, "size \(size)")
        }
    }
}
