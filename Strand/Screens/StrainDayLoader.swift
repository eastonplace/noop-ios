import Foundation
import StrandAnalytics
import WhoopProtocol
import WhoopStore

// MARK: - Loading the day's curve
//
// The Strain screen's "Through the day" and "What set today's score" sections read the same pass over the day's
// heart-rate readings. The read is bounded (one cycle, 200,000 readings at most), the arithmetic runs off the main
// thread, a screen that goes away cancels it, and the last result per day is kept so reopening the screen paints at
// once and refreshes behind it.

/// One applied lift of the day: when its workout ended and the muscular load Strength Strain stored for it.
struct StrainDayLiftLoad: Equatable, Sendable {
    let endTs: Int
    let muscularLoad: Double
}

/// What one pass needs to know about the day it reads.
struct StrainDayRequest: Equatable, Sendable {
    let dayKey: String
    /// Midnight of the logical day.
    let logicalStart: Date
    let isToday: Bool
    /// The batch's effective maximum for a past day (the override, else the unrounded Tanaka estimate); the live
    /// score's rounded one for today.
    let maxHR: Double
    let restingHR: Double
    /// The calendar day's steps: today's, and a past day's fallback when the day's raw counter is not stored.
    let steps: Int?
    /// The wearer's counter ticks per step, which scales a cycle's raw step count.
    let stepTicksPerStep: Double
    let sleepMinutes: Double?
    /// The hero in tenths. Today's score moves with new readings, so a pass that was read for another value is behind
    /// the screen's hero: it is stale however young it is.
    let heroTenths: Int?
    /// The repository's refresh counter: new data landed.
    let refreshSeq: Int
    /// The day's applied lifts. Part of the request, so a cached pass is behind the moment a lift is applied,
    /// rescored or removed.
    var liftLoads: [StrainDayLiftLoad] = []
}

/// One day's pass: the parts of the score, the curve, and the span it covers.
struct StrainDayResult: Equatable, Sendable {
    let analysis: StrainDayAnalysis
    /// When the main sleep ended; nil when there is none (the plot then starts at the first reading).
    let wake: Date?
    let cycleStart: Date
    let end: Date
    let sampleCount: Int
    /// The step count the pass scored: a past day's cycle total (not the calendar day's), else the request's. The Steps
    /// row shows and speaks this number, so the line under it agrees with the part beside it.
    let steps: Int?
    /// The scored sleep minutes the pass used (the seed under the curve's start).
    let sleepMinutes: Double?

    init(analysis: StrainDayAnalysis, wake: Date?, cycleStart: Date, end: Date, sampleCount: Int,
         steps: Int? = nil, sleepMinutes: Double? = nil) {
        self.analysis = analysis
        self.wake = wake
        self.cycleStart = cycleStart
        self.end = end
        self.sampleCount = sampleCount
        self.steps = steps
        self.sleepMinutes = sleepMinutes
    }
}

/// The last results, a few days deep.
@MainActor
final class StrainDayCache {
    static let shared = StrainDayCache()

    struct Entry {
        let request: StrainDayRequest
        let result: StrainDayResult
        let computedAt: Date
    }

    /// How long today's pass is trusted when nothing else says it is behind (reopening the screen).
    static let todayLifetime: TimeInterval = 60
    static let capacity = 8

    private var entries: [String: Entry] = [:]
    private var recency: [String] = []

    /// The latest pass for a day, fresh or not: a stale one still paints while the new one is read.
    func entry(for dayKey: String) -> Entry? { entries[dayKey] }

    func isFresh(_ entry: Entry, for request: StrainDayRequest, now: Date) -> Bool {
        let sameInputs = entry.request.dayKey == request.dayKey
            && entry.request.logicalStart == request.logicalStart
            && entry.request.isToday == request.isToday
            && entry.request.maxHR == request.maxHR
            && entry.request.restingHR == request.restingHR
            && entry.request.steps == request.steps
            && entry.request.stepTicksPerStep == request.stepTicksPerStep
            && entry.request.sleepMinutes == request.sleepMinutes
            && entry.request.liftLoads == request.liftLoads
        guard sameInputs, entry.request.refreshSeq == request.refreshSeq else { return false }
        // Today's pass is also only as good as the hero it was read for (the live score ticks every 20 s) and as young
        // as the lifetime; a past day has no clock.
        if request.isToday {
            return entry.request.heroTenths == request.heroTenths
                && now.timeIntervalSince(entry.computedAt) < Self.todayLifetime
        }
        return true
    }

    func store(_ result: StrainDayResult, for request: StrainDayRequest, now: Date) {
        entries[request.dayKey] = Entry(request: request, result: result, computedAt: now)
        recency.removeAll { $0 == request.dayKey }
        recency.append(request.dayKey)
        while recency.count > Self.capacity {
            entries[recency.removeFirst()] = nil
        }
    }

    func removeAll() {
        entries.removeAll()
        recency.removeAll()
    }
}

@MainActor
enum StrainDayLoader {
    /// The pass for `request`, from the cache when it is fresh. nil when the repository has not loaded, or when the
    /// calling task is cancelled before the work finishes (nothing is cached then). `useCache: false` neither reads
    /// nor writes the screen's cache: Strength Strain's settle reads a day's parts this way, so its passes (made
    /// without the day's lift loads) never stand in for the screen's.
    static func load(_ request: StrainDayRequest, repo: Repository, now: Date = Date(),
                     useCache: Bool = true) async -> StrainDayResult? {
        let cache = StrainDayCache.shared
        if useCache, let hit = cache.entry(for: request.dayKey), cache.isFresh(hit, for: request, now: now) {
            return hit.result
        }
        guard repo.loaded else { return nil }

        let calendar = Calendar.current
        #if DEBUG
        let began = DispatchTime.now()
        var checkpoints: [DispatchTime] = []
        #endif
        let logicalStart = Int(request.logicalStart.timeIntervalSince1970)
        let nextStart = Int((calendar.date(byAdding: .day, value: 1, to: request.logicalStart)
            ?? request.logicalStart.addingTimeInterval(86_400)).timeIntervalSince1970)
        let afterNext = Int((calendar.date(byAdding: .day, value: 2, to: request.logicalStart)
            ?? request.logicalStart.addingTimeInterval(172_800)).timeIntervalSince1970)
        let nowTs = Int(now.timeIntervalSince1970)

        // Today follows the live score's own rule, which reads the sleeps the app shows (the imported/live namespace). A
        // past day is the nightly batch's, and the batch detected its sleeps on this device and stored them under the
        // computed source; reading the imported namespace there would find none for a strap-only wearer and start the
        // cycle at midnight. A day with no computed sleep falls back to the imported one.
        let sleepFrom = logicalStart - 12 * 3_600
        var rows: [CachedSleepSession] = []
        if !request.isToday {
            rows = await repo.computedSleepSessions(from: sleepFrom, to: afterNext, limit: 50)
            guard !Task.isCancelled else { return nil }
        }
        if rows.isEmpty {
            rows = await repo.sleepSessions(from: sleepFrom, to: afterNext, limit: 50)
            guard !Task.isCancelled else { return nil }
        }
        let sleeps = rows.map {
            StrainCycleWindow.Sleep(start: $0.startTs, end: $0.endTs, effectiveStart: $0.effectiveStartTs)
        }
        let stepSleepSessions = rows.map { row in
            let stages = row.stagesJSON.flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode([StageSegment].self, from: $0) } ?? []
            return SleepSession(start: row.effectiveStartTs, end: row.endTs,
                                efficiency: row.efficiency ?? 0, stages: stages,
                                restingHR: row.restingHr, avgHRV: row.avgHrv)
        }

        // Today follows the live score's own rule (the longest sleep that has begun and woke after the day started);
        // a past day wakes inside its own day. A past day's cycle is the nightly batch's (see `StrainBatchCycle`), so
        // the curve and the parts are worked out from what the stored score was.
        let window = StrainCycleWindow.resolve(
            logicalStart: logicalStart,
            logicalEnd: request.isToday ? Int.max : nextStart,
            windowEnd: request.isToday ? nowTs : nextStart,
            sleeps: sleeps)
        let cycleStartTs: Int
        let endTs: Int
        if request.isToday {
            cycleStartTs = window.cycleStart
            endTs = nowTs
        } else {
            // The batch's sleep-to-sleep cycle (AN-05): the same selector, offsets and habitual midsleep.
            let habitual = await repo.habitualMidsleepSec(days: 30)
            guard !Task.isCancelled else { return nil }
            let timeZone = calendar.timeZone
            cycleStartTs = StrainBatchCycle.start(
                sleeps: sleeps, dayStart: logicalStart, dayEnd: nextStart,
                offsetSec: AnalyticsEngine.civilDayClockOffset(logicalStart..<nextStart, timeZone: timeZone),
                habitualMidsleepSec: habitual)
            endTs = min(nowTs, StrainBatchCycle.end(
                sleeps: sleeps, dayEnd: nextStart, nextDayEnd: afterNext,
                nextOffsetSec: AnalyticsEngine.civilDayClockOffset(nextStart..<afterNext, timeZone: timeZone),
                habitualMidsleepSec: habitual))
        }
        guard endTs > cycleStartTs else { return nil }

        #if DEBUG
        checkpoints.append(DispatchTime.now())
        #endif
        let samples = await repo.hrSamples(from: cycleStartTs, to: endTs, limit: 200_000)
        guard !Task.isCancelled else { return nil }
        // The batch scores a past day on its cycle's step total, not the calendar day's.
        var steps = request.steps
        if !request.isToday {
            let readRows = await repo.stepSamples(from: cycleStartTs, to: endTs, limit: 200_000)
            guard !Task.isCancelled else { return nil }
            let rows = StrainBatchCycle.stepRows(readRows, from: cycleStartTs, to: endTs)
            // Fall back only when this cycle has no records, not when its motion was all excluded.
            steps = rows.isEmpty ? request.steps : StrainBatchCycle.steps(
                rows, ticksPerStep: request.stepTicksPerStep, sleepSessions: stepSleepSessions)
        }
        #if DEBUG
        checkpoints.append(DispatchTime.now())
        #endif

        let context = StrainScorerV2.DayContext(
            validWornSleepMinutes: request.sleepMinutes,
            steps: steps,
            activeEnergyKcal: nil,
            hasWearCoverage: window.wake != nil || !samples.isEmpty)
        let start = Date(timeIntervalSince1970: TimeInterval(cycleStartTs))
        let end = Date(timeIntervalSince1970: TimeInterval(endTs))
        let maxHR = request.maxHR
        let restingHR = request.restingHR

        let work = Task.detached(priority: .userInitiated) {
            StrainDayAnalysis.make(samples: samples, maxHR: maxHR, restingHR: restingHR,
                                   context: context, start: start, end: end)
        }
        let heartRateAnalysis = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        guard !Task.isCancelled else { return nil }
        // Strength Strain: the day's logged sets join the cardio curve at the moment each lift ended.
        let analysis = StrainDayLiftTransform.apply(heartRateAnalysis, loads: request.liftLoads)

        let result = StrainDayResult(
            analysis: analysis,
            wake: window.wake.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            cycleStart: start, end: end, sampleCount: samples.count,
            steps: steps, sleepMinutes: request.sleepMinutes)
        if useCache { cache.store(result, for: request, now: now) }
        #if DEBUG
        func ms(_ from: DispatchTime, _ to: DispatchTime) -> Double {
            Double(to.uptimeNanoseconds - from.uptimeNanoseconds) / 1_000_000
        }
        let finished = DispatchTime.now()
        if checkpoints.count == 2 {
            NSLog("[strain-curve] day=%@ samples=%d points=%d gate=%@ total=%.1fms (sleep read %.1f, HR read %.1f, compute %.1f)",
                  request.dayKey, samples.count, analysis.curve.count, analysis.gateOpen ? "open" : "closed",
                  ms(began, finished), ms(began, checkpoints[0]), ms(checkpoints[0], checkpoints[1]),
                  ms(checkpoints[1], finished))
        }
        #endif
        return result
    }
}
