import XCTest
@testable import StrandDesign

final class MetricDetailWindowResolverTests: XCTestCase {
    private enum Window: Int, CaseIterable { case week = 7, month = 30, quarter = 90 }
    private struct Row: Equatable { let age: Int }

    private func slice(_ window: Window, _ rows: [Row]) -> [Row] {
        rows.filter { $0.age < window.rawValue }
    }

    func testSelectedSparseWindowIsKeptWhenItContainsOnePoint() {
        let rows = [Row(age: 6), Row(age: 20), Row(age: 70)]
        let resolved = MetricDetailWindowResolver.resolve(
            selection: Window.week,
            widening: [.week, .month, .quarter],
            rows: rows,
            slice: slice
        )

        XCTAssertEqual(resolved.range, .week)
        XCTAssertEqual(resolved.rows, [Row(age: 6)])
    }

    func testSelectedWindowExpandsOnlyWhenItContainsZeroPoints() {
        let rows = [Row(age: 20), Row(age: 70)]
        let resolved = MetricDetailWindowResolver.resolve(
            selection: Window.week,
            widening: [.week, .month, .quarter],
            rows: rows,
            slice: slice
        )

        XCTAssertEqual(resolved.range, .month)
        XCTAssertEqual(resolved.rows, [Row(age: 20)])
    }

    func testEmptyHistoryReturnsLargestCandidateWithoutInventingRows() {
        let resolved = MetricDetailWindowResolver.resolve(
            selection: Window.week,
            widening: [.week, .month, .quarter],
            rows: [Row](),
            slice: slice
        )

        XCTAssertEqual(resolved.range, .quarter)
        XCTAssertTrue(resolved.rows.isEmpty)
    }
}
