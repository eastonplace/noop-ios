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

/// What one pass needs to know about the day it reads.
struct StrainDayRequest: Equatable, Sendable {
    let dayKey: String
    /// Midnight of the logical day.
    let logicalStart: Date
    let isToday: Bool
    let maxHR: Double
    let restingHR: Double
    let steps: Int?
    let sleepMinutes: Double?
    /// The repository's refresh counter. A past day re-reads when it moves; today re-reads on a short clock instead,
    /// because the counter moves with every sync.
    let refreshSeq: Int
}

/// One day's pass: the parts of the score, the curve, and the span it covers.
struct StrainDayResult: Equatable, Sendable {
    let analysis: StrainDayAnalysis
    /// When the main sleep ended; nil when there is none (the plot then starts at the first reading).
    let wake: Date?
    let cycleStart: Date
    let end: Date
    let sampleCount: Int
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

    /// How long today's pass is trusted before the next screen visit reads again.
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
            && entry.request.sleepMinutes == request.sleepMinutes
        guard sameInputs else { return false }
        if request.isToday { return now.timeIntervalSince(entry.computedAt) < Self.todayLifetime }
        return entry.request.refreshSeq == request.refreshSeq
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
    /// calling task is cancelled before the work finishes (nothing is cached then).
    static func load(_ request: StrainDayRequest, repo: Repository, now: Date = Date()) async -> StrainDayResult? {
        let cache = StrainDayCache.shared
        if let hit = cache.entry(for: request.dayKey), cache.isFresh(hit, for: request, now: now) {
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

        let rows = await repo.sleepSessions(from: logicalStart - 12 * 3_600, to: afterNext, limit: 50)
        guard !Task.isCancelled else { return nil }
        let sleeps = rows.map {
            StrainCycleWindow.Sleep(start: $0.startTs, end: $0.endTs, effectiveStart: $0.effectiveStartTs)
        }

        // Today follows the live score's own rule (the longest sleep that has begun and woke after the day started);
        // a past day wakes inside its own day and runs until the next day's sleep begins.
        let window = StrainCycleWindow.resolve(
            logicalStart: logicalStart,
            logicalEnd: request.isToday ? Int.max : nextStart,
            windowEnd: request.isToday ? nowTs : nextStart,
            sleeps: sleeps)
        var endTs = nowTs
        if !request.isToday {
            let next = StrainCycleWindow.resolve(
                logicalStart: nextStart, logicalEnd: afterNext, windowEnd: afterNext, sleeps: sleeps)
            endTs = next.cycleStart > window.cycleStart ? next.cycleStart : nextStart
        }
        guard endTs > window.cycleStart else { return nil }

        #if DEBUG
        checkpoints.append(DispatchTime.now())
        #endif
        let samples = await repo.hrSamples(from: window.cycleStart, to: endTs, limit: 200_000)
        guard !Task.isCancelled else { return nil }
        #if DEBUG
        checkpoints.append(DispatchTime.now())
        #endif

        let context = StrainScorerV2.DayContext(
            validWornSleepMinutes: request.sleepMinutes,
            steps: request.steps,
            activeEnergyKcal: nil,
            hasWearCoverage: window.wake != nil || !samples.isEmpty)
        let start = Date(timeIntervalSince1970: TimeInterval(window.cycleStart))
        let end = Date(timeIntervalSince1970: TimeInterval(endTs))
        let maxHR = request.maxHR
        let restingHR = request.restingHR

        let work = Task.detached(priority: .userInitiated) {
            StrainDayAnalysis.make(samples: samples, maxHR: maxHR, restingHR: restingHR,
                                   context: context, start: start, end: end)
        }
        let analysis = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        guard !Task.isCancelled else { return nil }

        let result = StrainDayResult(
            analysis: analysis,
            wake: window.wake.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            cycleStart: start, end: end, sampleCount: samples.count)
        cache.store(result, for: request, now: now)
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
