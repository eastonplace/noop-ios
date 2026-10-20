import XCTest
import NoopPhase34Core
import WhoopStore
@testable import NOOP

final class ExternalSurfaceProjectionTests: XCTestCase {
    func testExtremeFiniteRecoveryIsOmittedInsteadOfConvertingToInt() {
        XCTAssertNil(ExternalSurfaceProjection.recoveryValue(.greatestFiniteMagnitude))
        XCTAssertNil(ExternalSurfaceProjection.recoveryValue(-.greatestFiniteMagnitude))
        XCTAssertEqual(ExternalSurfaceProjection.recoveryValue(72.6), 73)
    }

    func testRecoveryConversionRejectsUnrepresentableAndOutOfRangeValues() {
        XCTAssertNil(ExternalSurfaceProjection.recoveryValue(Double(Int.max)))
        XCTAssertNil(ExternalSurfaceProjection.recoveryValue(.infinity))
        XCTAssertNil(ExternalSurfaceProjection.recoveryValue(-0.1))
        XCTAssertNil(ExternalSurfaceProjection.recoveryValue(100.1))
        XCTAssertEqual(ExternalSurfaceProjection.recoveryValue(99.6), 100)
    }

    func testEffortConversionRejectsNonFiniteStoredValues() {
        XCTAssertNil(ExternalSurfaceProjection.effortValue(.nan))
        XCTAssertNil(ExternalSurfaceProjection.effortValue(.infinity))
        XCTAssertNil(ExternalSurfaceProjection.effortValue(-.infinity))
    }

    func testPassiveEffortConvertsStoredStrainToTheCanonicalDisplayScale() throws {
        let display = try XCTUnwrap(ExternalSurfaceProjection.effortValue(43.6))
        XCTAssertEqual(display, 9.156, accuracy: 0.000_001)
        XCTAssertEqual(String(format: "%.1f", display), "9.2")
        XCTAssertEqual(ExternalSurfaceProjection.effortValue(0), 0)
        XCTAssertEqual(ExternalSurfaceProjection.effortValue(100), 21)
    }

    func testPassiveEffortUsesTheCanonicalClampingOfFiniteStoredValues() {
        XCTAssertEqual(ExternalSurfaceProjection.effortValue(-.greatestFiniteMagnitude), 0)
        XCTAssertEqual(ExternalSurfaceProjection.effortValue(.greatestFiniteMagnitude), 21)
    }

    @MainActor
    func testCurrentProjectionAndRolloverFallbackMatchWidgetDisplayStrain() throws {
        let ny = newYork()
        let now = at(ny, 9, 4)
        let current = ExternalSurfaceProjection(try projection(day: "2026-08-09", strain: 43.6))
        let previous = ExternalSurfaceProjection(try projection(day: "2026-08-08", strain: 30))
        let widget = WidgetSnapshot.publishing(
            recovery: nil, storedStrain: 43.6, sleepScore: nil, bpm: nil,
            batteryPct: nil, bonded: true, hrv: nil, restingHr: nil, updated: now)
        let expected = try XCTUnwrap(widget.strain)

        XCTAssertEqual(expected, 9.156, accuracy: 0.000_001)
        XCTAssertEqual(current.effort(now: now, calendar: ny, todayStrain: { _ in nil }), expected)
        XCTAssertEqual(previous.effort(now: now, calendar: ny, todayStrain: {
            self.resolved($0, stored: 43.6)
        }), expected)
    }

    // MARK: - The Live Activity's Strain is the current logical day's

    private func newYork() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func at(_ calendar: Calendar, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: day, hour: hour, minute: minute))!
    }

    private func projection(day: String, strain: Double?) throws -> VerifiedHealthProjection {
        var metrics: [HealthMetricKind: VerifiedHealthMetric] = [:]
        if let strain {
            metrics[.strain] = try VerifiedHealthMetric(
                kind: .strain, value: strain, metricDay: CivilDay(key: day), sourceId: "my-whoop-noop",
                algorithmVersion: "v1", generation: 4, freshness: .fresh)
        }
        return try VerifiedHealthProjection(
            contextId: "ctx", deviceId: "my-whoop", generation: 4, logicalDay: CivilDay(key: day), metrics: metrics)
    }

    private func resolved(_ day: String, stored: Double) -> ResolvedStrain {
        ResolvedStrain(day: day, storedValue: stored, version: 2, origin: .liveDayV2, sourceId: "strap")
    }

    /// The heart-rate-mode Live Activity pushed `visibleStrainValue`, which is the projection's own day's, and the
    /// newest projection is still yesterday's until a strap pass mints another: at 07:00 it showed last night's Strain.
    @MainActor
    func testALiveActivityShowsTheProjectionsStrainOnlyOnItsOwnLogicalDay() throws {
        let ny = newYork()
        let surface = ExternalSurfaceProjection(try projection(day: "2026-08-08", strain: 30))
        var asked: [String] = []

        // Its own day, including 00:00 to 04:00 on the next calendar day.
        for now in [at(ny, 8, 15), at(ny, 8, 23, 59), at(ny, 9, 3, 59)] {
            XCTAssertEqual(try XCTUnwrap(surface.effort(now: now, calendar: ny, todayStrain: {
                asked.append($0); return nil
            })), 6.3, accuracy: 0.000_001, "at \(now)")
        }
        XCTAssertTrue(asked.isEmpty, "Today's Strain is not consulted while the projection is current")

        // After the rollover the same held surface is behind: no Strain, and the one Today shows for the 9th is asked.
        XCTAssertNil(surface.effort(now: at(ny, 9, 4), calendar: ny, todayStrain: { asked.append($0); return nil }))
        XCTAssertEqual(asked, ["2026-08-09"])
        XCTAssertEqual(
            try XCTUnwrap(surface.effort(now: at(ny, 9, 10), calendar: ny, todayStrain: {
                self.resolved($0, stored: 12)
            })), 2.52, accuracy: 0.000_001,
            "Today's stored Strain is converted to the Live Activity's display scale")
        XCTAssertNil(
            surface.effort(now: at(ny, 9, 10), calendar: ny, todayStrain: { _ in self.resolved("2026-08-08", stored: 30) }),
            "another day's resolved Strain is not today's")
        XCTAssertNil(
            surface.effort(now: at(ny, 9, 10), calendar: ny, todayStrain: { self.resolved($0, stored: .nan) }))
    }

    @MainActor
    func testAProjectionWithNoStrainOfItsOwnStillGetsTodaysWhenItIsBehind() throws {
        let ny = newYork()
        let bare = ExternalSurfaceProjection(try projection(day: "2026-08-08", strain: nil))
        XCTAssertNil(bare.effort(now: at(ny, 8, 15), calendar: ny, todayStrain: { self.resolved($0, stored: 12) }),
                     "on its own day the projection's Strain is the only one")
        XCTAssertEqual(try XCTUnwrap(bare.effort(now: at(ny, 9, 10), calendar: ny, todayStrain: {
            self.resolved($0, stored: 12)
        })), 2.52, accuracy: 0.000_001)
    }
}
