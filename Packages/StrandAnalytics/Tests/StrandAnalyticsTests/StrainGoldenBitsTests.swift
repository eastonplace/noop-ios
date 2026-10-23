import XCTest
import Foundation
import WhoopProtocol
@testable import StrandAnalytics

/// Golden bit patterns for the Strain V2 scorer, originally generated at base `a394bb32` (release/236, L1
/// commit 1) before any Strength Strain code existed. The sole reviewed update is the messy-day calorie
/// entry for invalid-HR exclusion, documented beside that entry; no strain bits changed. The test rebuilds
/// the same ordered list of
/// `"<case>=<hex bits|nil>"` lines from today's scorer and requires it to equal ``StrainGoldenBits/lines``
/// exactly, so any change to how the scorer rounds, orders or converts a number fails here, down to the last bit.
///
/// To regenerate (only ever against a base that is meant to define new bits):
/// `NOOP_PRINT_STRAIN_GOLDEN=1 swift test --package-path Packages/StrandAnalytics --filter StrainGoldenBitsTests`
/// prints every line prefixed `GOLDEN|` and passes.
///
/// Values are `Double.bitPattern` as 16 lowercase hex digits, `nil` for an absent value, the case name for
/// `dominant`, and a plain decimal for counts.
final class StrainGoldenBitsTests: XCTestCase {

    private typealias Fixtures = StrainDayFixtures

    private func hex(_ value: Double?) -> String {
        guard let value else { return "nil" }
        let digits = String(value.bitPattern, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }

    private func name(of component: StrainScorerV2.DayStrainComponents.Component?) -> String {
        switch component {
        case .none: return "nil"
        case .cardio: return "cardio"
        case .steps: return "steps"
        case .energy: return "energy"
        }
    }

    /// Every golden line in a fixed order. Pure function of the scorer; no clocks, no randomness.
    private func currentLines() -> [String] {
        var lines: [String] = []
        let maxHR = Fixtures.maxHR
        let restingHR = Fixtures.restingHR
        let profile = UserProfile(weightKg: 80, heightCm: 180, age: 30, sex: "male")
        let start = Date(timeIntervalSince1970: TimeInterval(Fixtures.t0))
        let end = Date(timeIntervalSince1970: TimeInterval(Fixtures.t0 + 86_400))

        for day in Fixtures.days {
            lines.append("strain.activity|\(day.name)=" + hex(StrainScorerV2.strain(
                day.samples, maxHR: maxHR, restingHR: restingHR, mode: .activity)))
            lines.append("activityStrain|\(day.name)=" + hex(StrainScorerV2.activityStrain(
                segments: [day.samples], maxHR: maxHR, restingHR: restingHR)))
            let rescored = ManualWorkoutRescore.scored(
                windowSamples: day.samples, profile: profile, hrMax: maxHR, restingHR: restingHR)
            lines.append("rescore.strain|\(day.name)=" + hex(rescored?.strain))
            lines.append("rescore.kcal|\(day.name)=" + hex(rescored?.kcal))
        }

        for day in Fixtures.days {
            for context in Fixtures.contexts {
                let key = "\(day.name)|\(context.name)"
                lines.append("strain.day|\(key)=" + hex(StrainScorerV2.strain(
                    day.samples, maxHR: maxHR, restingHR: restingHR, mode: .physiologicalDay(context.value))))

                let components = StrainScorerV2.dayStrainComponents(
                    day.samples, maxHR: maxHR, restingHR: restingHR, context: context.value)
                lines.append("components.cardio|\(key)=" + hex(components.cardio))
                lines.append("components.steps|\(key)=" + hex(components.steps))
                lines.append("components.energy|\(key)=" + hex(components.energy))
                lines.append("components.score|\(key)=" + hex(components.score))
                lines.append("components.dominant|\(key)=" + name(of: components.dominant))

                let curve = StrainScorerV2.cumulativeCardioStrain(
                    day.samples, maxHR: maxHR, restingHR: restingHR, context: context.value,
                    start: start, end: end, bucket: 300)
                lines.append("cumulative.count|\(key)=\(curve.count)")
                for index in curve.indices where index % 12 == 0 || index == curve.count - 1 {
                    lines.append("cumulative.\(index)|\(key)=" + hex(curve[index].value))
                }
            }
        }

        for load in [0, 0.5, 1, 5, 11.63, 25.63, 32, 64, 100, 1000] as [Double] {
            lines.append("display|\(load)=" + hex(StrainScorerV2.displayStrain(forEffectiveLoad: load)))
        }
        for display in [0, 4, 9.996, 14, 21, 25] as [Double] {
            lines.append("stored|\(display)=" + hex(StrainScorerV2.storedValue(fromDisplay: display)))
        }
        for stored in [0, 33.3, 47.6, 100, 120] as [Double] {
            lines.append("displayFromStored|\(stored)=" + hex(StrainScorerV2.displayValue(fromStored: stored)))
        }
        return lines
    }

    func testScorerBitsMatchTheGoldenFileGeneratedAtTheBase() {
        let lines = currentLines()

        if ProcessInfo.processInfo.environment["NOOP_PRINT_STRAIN_GOLDEN"] == "1" {
            // One flushed write per line: stdout is a pipe under `swift test`, and a buffer flushed mid-line
            // would interleave with XCTest's own output and corrupt the line.
            for line in lines {
                print("GOLDEN|" + line)
                fflush(stdout)
            }
            return
        }

        XCTAssertFalse(StrainGoldenBits.lines.isEmpty, "the golden file is empty; generate it at the base first")
        XCTAssertEqual(lines.count, StrainGoldenBits.lines.count,
                       "line count changed: now \(lines.count), golden \(StrainGoldenBits.lines.count)")
        for (index, (now, golden)) in zip(lines, StrainGoldenBits.lines).enumerated() where now != golden {
            XCTFail("line \(index) moved:\n  now    \(now)\n  golden \(golden)")
        }
        XCTAssertEqual(lines, StrainGoldenBits.lines)
    }
}
