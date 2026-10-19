import Foundation
import GRDB
import NoopPhase34Core
import StrandAnalytics
import WhoopProtocol
import WhoopStore
import XCTest
@testable import NOOP

/// A4: the primary analysis pass settles Strength Strain in the pass and overlays the settled stored day value onto
/// `IntelligenceEngine.results`, so the readers that run off the results (By-Day cards, the Charge forecast, Smart
/// Alarm) see the same Strain the stored row holds. A transient engine never applies and never overlays.
@MainActor
final class StrengthStrainResultsOverlayTests: XCTestCase {

    private typealias Fixtures = StrengthStrainFixtures

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    /// 2026-03-01T00:00:00Z.
    private let firstDayStart = 1_772_323_200
    private let days = 6
    private let liftDayIndex = 3

    private func dayKey(_ index: Int) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(firstDayStart + index * 86_400)))
    }

    private var reference: Date {
        Date(timeIntervalSince1970: TimeInterval(firstDayStart + (days - 1) * 86_400 + 22 * 3_600))
    }

    /// A strap night (23:00 to 06:00, an hour of R-R) and an awake day with an exercise hour at 17:00 UTC.
    private func seedWear(_ store: WhoopStore) async throws {
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        try registry.add(PairedDevice(
            id: Repository.whoopSource, brand: "WHOOP", model: "WHOOP 4.0", sourceKind: .liveBLE,
            capabilities: [.hr, .hrv, .skinTemp, .sleep], status: .active, addedAt: 0, lastSeenAt: 0))
        try registry.setActive(Repository.whoopSource)
        for k in 0..<days {
            let s = firstDayStart + k * 86_400
            var streams = Streams()
            for ts in stride(from: s - 3_600, to: s + 6 * 3_600, by: 30) {
                streams.hr.append(HRSample(ts: ts, bpm: 52 + k % 3))
                streams.gravity.append(GravitySample(ts: ts, x: 0, y: 0, z: 1))
                if ts % 60 == 0 { streams.skinTemp.append(SkinTempSample(ts: ts, raw: 1_300 + 2 * k + (ts / 60) % 3)) }
            }
            var toggle = false
            let swing = 8 + (k % 4) * 3
            for ts in stride(from: s + 3_600, to: s + 7_200, by: 2) {
                toggle.toggle()
                streams.rr.append(RRInterval(ts: ts, rrMs: 1_150 + (toggle ? swing : -swing)))
            }
            for ts in stride(from: s + 6 * 3_600, to: s + 23 * 3_600, by: 30) {
                let exercising = ts >= s + 17 * 3_600 && ts < s + 18 * 3_600
                streams.hr.append(HRSample(ts: ts, bpm: exercising ? 135 + ts % 11 : 78 + ts % 9))
                let wobble = Double(ts % 11) * 0.2
                streams.gravity.append(GravitySample(ts: ts, x: wobble, y: 0.3 - wobble, z: 0.8))
            }
            _ = try await store.insert(streams, deviceId: Repository.whoopSource)
        }
    }

    private func pass(_ engine: IntelligenceEngine) async -> Bool {
        await engine.analyzeRecent(
            maxDays: days, startOffset: 0, force: true, refreshRepository: false,
            analysisReference: reference, analysisCalendar: utcCalendar)
    }

    private func storedDays(_ store: WhoopStore) async throws -> [String: DailyMetric] {
        let rows = try await store.dailyMetrics(
            deviceId: Fixtures.canonical, from: "0000-01-01", to: "9999-12-31")
        return Dictionary(rows.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func testPrimaryPassOverlaysTheSettledLiftDayAndATransientOneDoesNot() async throws {
        let store = try await WhoopStore.inMemory()
        try await seedWear(store)
        let liftStart = Date(timeIntervalSince1970: TimeInterval(firstDayStart + liftDayIndex * 86_400 + 17 * 3_600))
        let liftDay = Repository.logicalDayKey(liftStart)
        XCTAssertEqual(liftDay, dayKey(liftDayIndex), "the fixture needs the lift on the UTC day it was written for")
        let lift = Fixtures.Lift(start: liftStart, kg: 100, sets: 6)
        let workouts = try await Fixtures.seed(store, lifts: [lift], workoutStrain: nil, dayStrain: nil)
        let startTs = Int(try XCTUnwrap(workouts.first).startedAt.timeIntervalSince1970)

        // Pass 1, heart rate only: a transient engine writes no Strength Strain.
        let (transient, _) = Fixtures.makeEngine(store: store, primary: false)
        let firstOk = await pass(transient)
        XCTAssertTrue(firstOk)
        let hrOnlyDay = try XCTUnwrap(transient.results.first { $0.day == liftDay }?.strain)
        let storedFirst = try await storedDays(store)
        XCTAssertEqual(storedFirst[liftDay]?.strain?.bitPattern, hrOnlyDay.bitPattern)
        let noRows = try await store.registryWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM liftStrain") ?? -1
        }
        XCTAssertEqual(noRows, 0)

        // The workout gets its heart-rate Strain, then the primary engine's backfill adds the sets.
        try await Fixtures.setWorkoutStrain(store, starts: [startTs], strain: 30)
        let (primary, _) = Fixtures.makeEngine(store: store, primary: true)
        await primary.runStrengthStrainBackfillIfNeeded()
        let liftRow = try await Fixtures.liftRow(store, id: lift.id)
        XCTAssertEqual(liftRow?.state, .applied)

        // Pass 2, primary: results carry the settled stored value, not this pass's heart-rate value.
        let secondOk = await pass(primary)
        XCTAssertTrue(secondOk)
        let stored = try await storedDays(store)
        let storedLift = try XCTUnwrap(stored[liftDay]?.strain)
        let shown = try XCTUnwrap(primary.results.first { $0.day == liftDay }?.strain)
        XCTAssertEqual(shown.bitPattern, storedLift.bitPattern)
        XCTAssertGreaterThan(shown, hrOnlyDay, "the day shows its logged sets")

        // Days without a lift keep the pass's own value, which is what is stored for them.
        for item in primary.results where item.day != liftDay {
            XCTAssertEqual(item.strain?.bitPattern, stored[item.day]?.strain?.bitPattern, item.day)
        }

        // A transient engine over the same store neither applies nor overlays: it shows its heart-rate value.
        let (other, _) = Fixtures.makeEngine(store: store, primary: false)
        _ = await pass(other)
        let otherShown = try XCTUnwrap(other.results.first { $0.day == liftDay }?.strain)
        XCTAssertEqual(otherShown.bitPattern, hrOnlyDay.bitPattern)
        XCTAssertNotEqual(otherShown.bitPattern, storedLift.bitPattern)
    }
}
