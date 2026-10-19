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

/// Owns the body-clock profile cache and decides when a call may use it. The hourly reuse is for the 15-minute
/// cadence tick only; every other trigger rebuilds, and anything that changes the heart rate the profile covers
/// without moving the newest timestamp (a source delete, archive or select, a restore, a backfill, an import)
/// invalidates it. A build already in flight when that happens does not repopulate the cache.
@MainActor
final class BodyClockProfileProvider {
    /// What a build reads. The store reads are injected so a test counts them.
    struct Reads {
        /// The raw-HR sources the profile covers (`Repository.importedReadIds`).
        var sourceIds: @MainActor () -> [String]
        /// The newest HR timestamp at or before `bound`: the frontier of the window the buckets read, so a record
        /// stamped in the future cannot pin it.
        var newestHeartRate: @MainActor (_ bound: Int) async -> Int?
        /// Hourly mean HR over `[from, to]`.
        var buckets: @MainActor (_ from: Int, _ to: Int) async -> [HRBucket]
    }

    private var cache: CircadianInputsCache?
    private var generation = 0

    /// Drop the cached profile and any build in flight.
    func invalidate() {
        cache = nil
        generation &+= 1
    }

    /// - Parameter reuseWithinTheHour: true only for the cadence tick. Anything else (a backfill burst, a user
    ///   refresh) rebuilds from the store.
    func inputs(now: Int, timeZoneOffsetSeconds tz: Int, logicalDay: String, reuseWithinTheHour: Bool,
                reads: Reads) async -> CircadianPhaseInputs? {
        if !reuseWithinTheHour { invalidate() }
        let generation = self.generation
        let sourceIds = reads.sourceIds()
        if let cache, await fits(cache, logicalDay: logicalDay, tz: tz, sourceIds: sourceIds, now: now, reads: reads),
           generation == self.generation {
            return cache.inputs
        }
        // The newest timestamp is read BEFORE the buckets, so a row that lands mid-read counts as newer next time.
        let newest = await reads.newestHeartRate(now)
        let buckets = await reads.buckets(now - 14 * 86_400, now)
        let inputs = CircadianPhaseInputs.make(from: buckets, timeZoneOffsetSeconds: tz)
        // A build that started before an invalidation is stale; an empty or short read is not cached (the store may
        // not be open yet, and a short history is cheap to read).
        if generation == self.generation {
            cache = buckets.count >= 24
                ? CircadianInputsCache(logicalDay: logicalDay, timeZoneOffsetSeconds: tz, sourceIds: sourceIds,
                                       computedAt: now, newestHeartRateTs: newest, inputs: inputs)
                : nil
        }
        return inputs
    }

    private func fits(_ cache: CircadianInputsCache, logicalDay: String, tz: Int, sourceIds: [String], now: Int,
                      reads: Reads) async -> Bool {
        switch cache.verdict(logicalDay: logicalDay, timeZoneOffsetSeconds: tz, sourceIds: sourceIds, now: now) {
        case .reuse: return true
        case .rebuild: return false
        case .rebuildIfNewerHeartRate: return !cache.hasNewerHeartRate(await reads.newestHeartRate(now))
        }
    }
}
