import Foundation
import StrandAnalytics
import WhoopStore

/// The body-clock estimate's expensive input: the pooled local hour-of-day HR profile over the last 14 days.
/// Building it reads 14 days of heart rate (hourly means over about 1.2 M rows), and it ran on every 15-minute
/// cadence tick and after every backfill burst, in the background, where it once hit the CPU limit.
struct CircadianPhaseInputs: Equatable {
    let bins: [CircadianEngine.ActivityBin]
    let daysObserved: Int

    /// Pool HR by LOCAL hour-of-day → mean bpm per hour as the activity proxy (higher HR ≈ more active). Nil
    /// when there isn't enough to read: fewer than 24 hourly buckets, or fewer than 6 populated hours.
    static func make(from buckets: [HRBucket], timeZoneOffsetSeconds tz: Int) -> CircadianPhaseInputs? {
        guard buckets.count >= 24 else { return nil }
        var sums = [Double](repeating: 0, count: 24)
        var counts = [Int](repeating: 0, count: 24)
        var daySet = Set<Int>()
        for b in buckets {
            let local = b.ts + tz
            let hour = (local % 86_400 + 86_400) % 86_400 / 3_600
            sums[hour] += b.bpm; counts[hour] += 1
            daySet.insert(local / 86_400)
        }
        let bins: [CircadianEngine.ActivityBin] = (0..<24).compactMap { h in
            counts[h] > 0 ? CircadianEngine.ActivityBin(hour: Double(h), activity: sums[h] / Double(counts[h])) : nil
        }
        guard bins.count >= 6 else { return nil }
        return CircadianPhaseInputs(bins: bins, daysObserved: daySet.count)
    }
}

/// What the last body-clock read was computed from, and when it may be reused. The profile is a slow 14-day
/// summary, so it is rebuilt at most once an hour, and then only when newer heart rate has arrived since the read
/// (or the logical day, or the time zone, changed). The cheap cosinor fit and the habitual wake hour are not
/// cached: they run on every call, so a new night's wake time still moves the estimate immediately.
struct CircadianInputsCache: Equatable {
    static let minimumRecomputeInterval = 3_600

    let logicalDay: String
    let timeZoneOffsetSeconds: Int
    /// The raw-HR sources the read covered (`Repository.importedReadIds`): a strap swap rebuilds at once.
    let sourceIds: [String]
    let computedAt: Int
    /// The newest heart-rate timestamp when the read began, so rows landing mid-read still count as newer.
    let newestHeartRateTs: Int?
    let inputs: CircadianPhaseInputs?

    enum Verdict: Equatable {
        /// Same logical day and zone, less than an hour old: reuse without touching the store.
        case reuse
        /// Different logical day, zone or source set, or the clock moved backwards: rebuild.
        case rebuild
        /// An hour or more old: rebuild only if heart rate newer than `newestHeartRateTs` exists.
        case rebuildIfNewerHeartRate
    }

    func verdict(logicalDay: String, timeZoneOffsetSeconds: Int, sourceIds: [String], now: Int) -> Verdict {
        guard logicalDay == self.logicalDay, timeZoneOffsetSeconds == self.timeZoneOffsetSeconds,
              sourceIds == self.sourceIds else {
            return .rebuild
        }
        let age = now - computedAt
        guard age >= 0 else { return .rebuild }
        return age < Self.minimumRecomputeInterval ? .reuse : .rebuildIfNewerHeartRate
    }

    func hasNewerHeartRate(_ newest: Int?) -> Bool {
        guard let newest else { return false }
        return newest > (newestHeartRateTs ?? Int.min)
    }
}
