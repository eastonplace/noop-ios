import Foundation
import WhoopProtocol
@testable import StrandAnalytics

/// Deterministic synthetic heart-rate days shared by the V2 day-strain tests. Every day is scored with
/// max HR 190 / resting HR 60, so a bpm maps to a fixed percent of heart-rate reserve.
enum StrainDayFixtures {
    static let maxHR = 190.0
    static let restingHR = 60.0
    /// An arbitrary whole second (2023-11-14 22:13:20 UTC) that every fixture hangs off.
    static let t0 = 1_700_000_000

    struct Day {
        let name: String
        let samples: [HRSample]
    }

    struct Context {
        let name: String
        let value: StrainScorerV2.DayContext
    }

    /// The bpm at `hrr` percent of heart-rate reserve.
    static func bpm(atHRR hrr: Double) -> Int {
        Int((restingHR + hrr / 100 * (maxHR - restingHR)).rounded())
    }

    /// Reproducible pseudo-random noise (xorshift64*), so fixtures are identical on every run.
    struct Noise {
        private var state: UInt64
        init(seed: UInt64) { state = seed }

        /// An integer in `-amplitude...amplitude`.
        mutating func next(amplitude: Int) -> Int {
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            let draw = Int((state &* 2_685_821_657_736_338_717) >> 33)
            return draw % (2 * amplitude + 1) - amplitude
        }
    }

    /// `count` readings from `ts`, `cadence` seconds apart, wobbling `wobble` bpm around `center`.
    static func block(from ts: Int, count: Int, cadence: Int = 1, center: Int,
                      wobble: Int = 0, seed: UInt64 = 7) -> [HRSample] {
        var noise = Noise(seed: seed)
        return (0..<count).map {
            HRSample(ts: ts + $0 * cadence, bpm: center + noise.next(amplitude: wobble))
        }
    }

    /// Three hours resting, one hour at ~80 % of reserve, three hours resting.
    static var hardHourSamples: [HRSample] {
        block(from: t0, count: 1_080, cadence: 10, center: bpm(atHRR: 12), wobble: 3, seed: 1)
            + block(from: t0 + 10_800, count: 3_600, center: bpm(atHRR: 80), wobble: 4, seed: 2)
            + block(from: t0 + 14_400, count: 1_080, cadence: 10, center: bpm(atHRR: 12), wobble: 3, seed: 3)
    }

    /// Thirty hard minutes, a three-hour gap, twenty harder minutes, then two stragglers exactly 90 s and
    /// 91 s apart (the first still counts as covered time, the second does not).
    static var gappySamples: [HRSample] {
        let first = block(from: t0, count: 1_800, center: bpm(atHRR: 70), wobble: 4, seed: 4)
        let secondStart = t0 + 1_800 + 3 * 3_600
        let second = block(from: secondStart, count: 1_200, center: bpm(atHRR: 85), wobble: 3, seed: 5)
        let lastTs = secondStart + 1_199
        return first + second + [
            HRSample(ts: lastTs + 90, bpm: bpm(atHRR: 60)),
            HRSample(ts: lastTs + 90 + 91, bpm: bpm(atHRR: 60)),
        ]
    }

    /// An unsorted stream with equal-second duplicates and out-of-range readings, as a defensive
    /// caller might hand over. Every timestamp is positive.
    static var messySamples: [HRSample] {
        let clean = block(from: t0, count: 600, cadence: 5, center: bpm(atHRR: 38), wobble: 6, seed: 6)
            + block(from: t0 + 3_000, count: 900, center: bpm(atHRR: 75), wobble: 5, seed: 8)
        var messy = clean
        for index in stride(from: 0, to: clean.count, by: 50) {
            messy.append(HRSample(ts: clean[index].ts, bpm: clean[index].bpm + 12))
            messy.append(HRSample(ts: clean[index].ts, bpm: clean[index].bpm - 9))
        }
        for (offset, outOfRange) in [0, 29, 241, 400, -7].enumerated() {
            messy.append(HRSample(ts: clean[10 * (offset + 1)].ts, bpm: outOfRange))
        }
        return messy.reversed()
    }

    static let days: [Day] = [
        Day(name: "empty", samples: []),
        Day(name: "19 readings", samples: block(from: t0, count: 19, center: bpm(atHRR: 80))),
        Day(name: "10 readings 90 s apart",
            samples: block(from: t0, count: 10, cadence: 90, center: bpm(atHRR: 80))),
        Day(name: "5 minute burst", samples: block(from: t0, count: 300, center: bpm(atHRR: 80), wobble: 3)),
        Day(name: "resting 6 h",
            samples: block(from: t0, count: 2_160, cadence: 10, center: bpm(atHRR: 12), wobble: 3)),
        Day(name: "light walking 8 h",
            samples: block(from: t0, count: 2_880, cadence: 10, center: bpm(atHRR: 38), wobble: 8)),
        Day(name: "hard hour in a resting day", samples: hardHourSamples),
        Day(name: "gappy day", samples: gappySamples),
        Day(name: "messy day", samples: messySamples),
    ]

    static let contexts: [Context] = [
        Context(name: "bare", value: .init()),
        Context(name: "sleep only", value: .init(validWornSleepMinutes: 480)),
        Context(name: "steps only", value: .init(steps: 9_000)),
        Context(name: "energy only", value: .init(activeEnergyKcal: 600)),
        Context(name: "sleep and steps", value: .init(validWornSleepMinutes: 430, steps: 8_200)),
        Context(name: "all three", value: .init(validWornSleepMinutes: 420, steps: 8_000,
                                                 activeEnergyKcal: 350)),
        Context(name: "big steps", value: .init(validWornSleepMinutes: 300, steps: 25_000)),
        Context(name: "big energy", value: .init(validWornSleepMinutes: 360, steps: 2_000,
                                                  activeEnergyKcal: 2_500)),
        Context(name: "zeros", value: .init(validWornSleepMinutes: 0, steps: 0, activeEnergyKcal: 0)),
        Context(name: "junk inputs", value: .init(validWornSleepMinutes: -30, steps: -5,
                                                   activeEnergyKcal: .nan)),
        Context(name: "no wear coverage", value: .init(validWornSleepMinutes: 420, steps: 8_000,
                                                        activeEnergyKcal: 350, hasWearCoverage: false)),
    ]
}
