import Foundation
import StrandDesign
import WhoopProtocol
import StrandAnalytics

/// How long a workout has spent in each of the wearer's three heart-rate zones (rest, steady, push), counted as readings
/// arrive. The live screen's "time in zone" and the heart page read it; a workout restored after the app was killed rebuilds
/// it from its readings and must land on the same numbers, so the live path and `compute` share one rule.
///
/// A reading is credited the time since the one before it, to its own zone, but never more than `maxCreditSeconds`: a strap
/// that went quiet for a minute and came back must not credit that minute to whatever zone the first new reading is in. The
/// first reading of a stretch (the start, and the first after a pause) credits nothing, since there is no interval behind
/// it. A second reading in the same second replaces the first: whatever the first was credited moves to the new reading's
/// zone, so the total matches the one-reading-per-second list a restore works from.
struct PersonalZoneSeconds: Equatable, Codable, Sendable {
    /// Rest, steady, push.
    private(set) var seconds: [Int] = [0, 0, 0]
    private var lastTimestamp: Int?
    private var lastCreditedZone: Int?
    private var lastCreditedSeconds = 0

    /// The most one reading is credited, however long since the one before it.
    static let maxCreditSeconds = 5

    var total: Int { seconds.reduce(0, +) }

    mutating func append(_ sample: HRSample, thresholds: HRZoneStyle.Thresholds) {
        let zone = thresholds.zone(for: Double(sample.bpm))
        defer { lastTimestamp = sample.ts }
        guard let last = lastTimestamp else {
            lastCreditedZone = nil
            lastCreditedSeconds = 0
            return
        }
        if sample.ts == last {
            // The same second again: the reading it replaces had been credited an interval; the new one takes it over.
            if let previous = lastCreditedZone, lastCreditedSeconds > 0, previous != zone {
                seconds[previous] -= lastCreditedSeconds
                seconds[zone] += lastCreditedSeconds
                lastCreditedZone = zone
            }
            return
        }
        guard sample.ts > last else { return }
        let credit = min(sample.ts - last, Self.maxCreditSeconds)
        seconds[zone] += credit
        lastCreditedZone = zone
        lastCreditedSeconds = credit
    }

    /// A pause (or any break in the stream): the next reading starts a new stretch and credits nothing.
    mutating func breakStretch() {
        lastTimestamp = nil
        lastCreditedZone = nil
        lastCreditedSeconds = 0
    }

    /// The readings a workout counts, the way the live path takes them in: in time order, with a timestamp, between 30 and 240
    /// bpm (a strap that reconnects can report a zero, and nothing living reads 255), and one per second, the last of a
    /// repeated second.
    static func canonical(_ samples: [HRSample]) -> [HRSample] {
        var canonical: [HRSample] = []
        for sample in samples.sorted(by: { $0.ts < $1.ts }) where sample.ts > 0 && (30...240).contains(sample.bpm) {
            if canonical.last?.ts == sample.ts { canonical[canonical.count - 1] = sample } else { canonical.append(sample) }
        }
        return canonical
    }

    /// The same numbers rebuilt from a workout's readings and pauses, stretch by stretch, the way the live path builds them.
    /// Whatever readings it is given, they are first taken in as the live path takes them (`canonical`), so the numbers do not
    /// depend on which caller is asking.
    static func compute(samples: [HRSample], pauses: WorkoutPauseLedger, thresholds: HRZoneStyle.Thresholds) -> PersonalZoneSeconds {
        var result = PersonalZoneSeconds()
        for (index, stretch) in pauses.segments(of: canonical(samples)).enumerated() {
            if index > 0 { result.breakStretch() }
            for sample in stretch { result.append(sample, thresholds: thresholds) }
        }
        return result
    }

    /// The seconds shown to the screen, rounded down to a multiple of `step`, so a view that observes them is invalidated
    /// every `step` seconds and not on every reading.
    func quantized(step: Int) -> [Int] {
        seconds.map { $0 / step * step }
    }
}
