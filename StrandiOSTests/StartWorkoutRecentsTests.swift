import XCTest
import WhoopStore
@testable import NOOP

/// The start sheet's "Last time" route is found once, from the stored map, never while the page draws.
final class StartWorkoutRecentsTests: XCTestCase {
    private func row(_ start: Int, sport: String = "Running") -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: start + 1_800, sport: sport, source: "manual", durationS: 1_800,
                   energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil, distanceM: nil, zonesJSON: nil, notes: nil)
    }

    private func route(points: [RouteMath.LatLng]) -> WorkoutRoute {
        WorkoutRoute(polyline: RouteMath.encode(points), distanceM: RouteMath.totalMeters(points))
    }

    private let loop = [RouteMath.LatLng(40.0, -73.0), RouteMath.LatLng(40.001, -73.001), RouteMath.LatLng(40.002, -73.0)]

    private func key(_ row: WorkoutRow) -> String { RouteStore.key(startTs: row.startTs, sport: row.sport) }

    func testTheNewestWorkoutWithADrawableRouteIsChosen() throws {
        let newest = row(3_000), middle = row(2_000), oldest = row(1_000)
        let routes = [key(middle): route(points: loop), key(oldest): route(points: loop)]
        let found = try XCTUnwrap(StartWorkoutRecents.latestRoute(in: [newest, middle, oldest], routes: routes))
        XCTAssertEqual(found.row.startTs, 2_000)
        XCTAssertEqual(found.segments.count, 1)
        XCTAssertEqual(found.segments[0].count, 3)
    }

    func testARouteWithNothingToDrawIsSkipped() throws {
        let newest = row(3_000), older = row(2_000)
        let single = route(points: [RouteMath.LatLng(40.0, -73.0)])
        let routes = [key(newest): single, key(older): route(points: loop)]
        XCTAssertEqual(StartWorkoutRecents.latestRoute(in: [newest, older], routes: routes)?.row.startTs, 2_000)
    }

    func testNoRoutesAndNoWorkoutsGiveNothing() {
        XCTAssertNil(StartWorkoutRecents.latestRoute(in: [row(1_000)], routes: [:]))
        XCTAssertNil(StartWorkoutRecents.latestRoute(in: [], routes: [key(row(1_000)): route(points: loop)]))
    }

    func testARouteBelongsToTheSportItWasRecordedFor() {
        let cycling = row(1_000, sport: "Cycling")
        let routes = [key(row(1_000, sport: "Running")): route(points: loop)]
        XCTAssertNil(StartWorkoutRecents.latestRoute(in: [cycling], routes: routes))
    }
}
