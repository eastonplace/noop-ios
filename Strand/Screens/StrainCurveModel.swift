import Foundation
import StrandAnalytics
import StrandDesign
import WhoopProtocol
import WhoopStore

// The cumulative cardio curve through the day, as the plot draws it. Pure and tested; nothing here reads a repository or
// the clock.

/// What the cardio curve says about the day's score.
enum StrainCurveRelation: Equatable {
    /// No curve, or no hero to compare it with.
    case none
    /// Cardio is the day's score: the curve ends where the hero is.
    case cardioSetsScore
    /// Steps or energy set the score, so the curve ends below it.
    case otherSetsScore(StrainScoreRow.Kind)
    /// The parts do not add up to the hero (another source or moment): the curve is cardio only, and says no more.
    case scoreDiffers

    static func make(components: StrainScorerV2.DayStrainComponents, hero: Double?,
                     liftLoad: Double = 0) -> StrainCurveRelation {
        guard let hero, let parts = StrainScoreParts.make(components, hero: hero, liftLoad: liftLoad)
        else { return .none }
        guard parts.agreesWithHero else { return .scoreDiffers }
        switch StrainScoreParts.dominant(components, liftLoad: liftLoad) {
        case .cardio?: return .cardioSetsScore
        case .steps?: return .otherSetsScore(.steps)
        case .energy?: return .otherSetsScore(.energy)
        case nil: return .scoreDiffers
        }
    }

    /// Whether the curve's end and the hero are far enough apart to draw a connector between them. Only a real gap
    /// gets one: steps or energy setting the score. A hero the parts do not match (another moment or source) is a
    /// passing difference, so it draws nothing.
    static func showsConnector(relation: StrainCurveRelation, hero: Double?, curveEnd: Double?) -> Bool {
        guard let hero, let curveEnd else { return false }
        switch relation {
        case .otherSetsScore: return abs(hero - curveEnd) >= 0.25
        case .none, .cardioSetsScore, .scoreDiffers: return false
        }
    }
}

/// One day's cumulative cardio curve and the parts of its score, from the day's heart-rate readings.
struct StrainDayAnalysis: Equatable, Sendable {
    let components: StrainScorerV2.DayStrainComponents
    let curve: [StrainScorerV2.CumulativeCardioPoint]
    /// When the score's gate opened (20 readings over 10 minutes of coverage), nil while it has not.
    let gateOpenedAt: Date?
    /// The day's muscular load from the logged lifts (Strength Strain), 0 when there are none. When above 0 the curve
    /// already carries it; `components` stay heart-rate only, and the parts and the relation add it back.
    var liftMuscularLoad: Double = 0

    var gateOpen: Bool { gateOpenedAt != nil }

    /// One sort and a handful of linear passes over the readings: about 4 ms for a full 1 Hz day in a release build.
    static func make(samples: [HRSample], maxHR: Double, restingHR: Double,
                     context: StrainScorerV2.DayContext, start: Date, end: Date,
                     bucket: TimeInterval = 300) -> StrainDayAnalysis {
        let components = StrainScorerV2.dayStrainComponents(
            samples, maxHR: maxHR, restingHR: restingHR, context: context)
        let curve = StrainScorerV2.cumulativeCardioStrain(
            samples, maxHR: maxHR, restingHR: restingHR, context: context, start: start, end: end, bucket: bucket)
        return StrainDayAnalysis(
            components: components, curve: curve,
            gateOpenedAt: gateOpenTime(samples: samples, maxHR: maxHR, restingHR: restingHR, context: context))
    }

    /// The reading at which heart-rate load first counts, replaying the readings through the scorer's own accumulator
    /// so the gate is the scorer's, not a copy of it.
    static func gateOpenTime(samples: [HRSample], maxHR: Double, restingHR: Double,
                             context: StrainScorerV2.DayContext) -> Date? {
        var accumulator = StrainScorerV2.PhysiologicalDayAccumulator(
            maxHR: maxHR, restingHR: restingHR, context: context)
        let ordered = samples
            .filter { (30...240).contains($0.bpm) && $0.ts > 0 }
            .sorted { $0.ts == $1.ts ? $0.bpm < $1.bpm : $0.ts < $1.ts }
        for sample in ordered {
            accumulator.append(sample)
            if accumulator.readingCount >= StrainScorerV2.minReadings,
               accumulator.coverageSeconds >= StrainScorerV2.minCoverageSeconds {
                return Date(timeIntervalSince1970: TimeInterval(sample.ts))
            }
        }
        return nil
    }
}

/// The curve as the plot draws it: the span, its points from waking on, where the labels fall.
struct StrainCurveShape: Equatable {
    static let minimumSpan: TimeInterval = 3 * 3600

    let points: [StrainCurvePoint]
    let domain: ClosedRange<Date>
    /// The curve's value where the plot starts: the sleep seed, when sleep contributed.
    let startValue: Double
    let endValue: Double

    /// - Parameters:
    ///   - wake: when the main sleep ended; the plot starts there. nil starts it at the curve's first point.
    ///   - now: the live edge of a day still in progress; nil for a past day, whose plot ends at its last reading.
    static func make(curve: [StrainScorerV2.CumulativeCardioPoint], wake: Date?, now: Date?) -> StrainCurveShape? {
        guard let first = curve.first, let last = curve.last, curve.count >= 2 else { return nil }
        var start = first.t
        if let wake, wake > first.t, wake < last.t { start = wake }
        var points = curve.filter { $0.t >= start }.map { StrainCurvePoint(t: $0.t, value: $0.value) }
        // The curve is a step through its readings: carry the value in force at the start so it begins on the edge.
        if let carried = curve.last(where: { $0.t < start }), points.first.map({ $0.t > start }) ?? true {
            points.insert(StrainCurvePoint(t: start, value: carried.value), at: 0)
        }
        guard points.count >= 2 else { return nil }
        let liveEnd = now.map { max($0, last.t) } ?? last.t
        let end = max(liveEnd, start.addingTimeInterval(minimumSpan))
        return StrainCurveShape(points: points, domain: start...end,
                                startValue: points[0].value, endValue: points[points.count - 1].value)
    }

    /// At most `maxCount` whole-hour labels inside `domain`, on the smallest hour step that fits (every hour, 2, 3, 4,
    /// 6, 8 or 12), so a short morning reads 8, 9, 10 and a whole day 6, 12, 18.
    static func hourTicks(in domain: ClosedRange<Date>, calendar: Calendar = .autoupdatingCurrent,
                          maxCount: Int = 4) -> [Date] {
        guard let firstHour = calendar.dateInterval(of: .hour, for: domain.lowerBound) else { return [] }
        var hours: [(date: Date, hour: Int)] = []
        var cursor = firstHour.start == domain.lowerBound ? firstHour.start : firstHour.end
        while cursor <= domain.upperBound, hours.count < 48 {
            hours.append((cursor, calendar.component(.hour, from: cursor)))
            guard let next = calendar.date(byAdding: .hour, value: 1, to: cursor) else { break }
            cursor = next
        }
        for step in [1, 2, 3, 4, 6, 8, 12] {
            let chosen = hours.filter { $0.hour % step == 0 }.map(\.date)
            if chosen.count <= maxCount { return chosen }
        }
        return []
    }

    /// The workouts that fall inside the plot, as segments of the curve.
    static func segments(for workouts: [WorkoutRow], in domain: ClosedRange<Date>) -> [StrainCurveSegment] {
        workouts.sorted { $0.startTs < $1.startTs }.enumerated().compactMap { index, workout in
            let start = Date(timeIntervalSince1970: TimeInterval(workout.startTs))
            let end = Date(timeIntervalSince1970: TimeInterval(workout.endTs))
            guard end > domain.lowerBound, start < domain.upperBound, end > start else { return nil }
            return StrainCurveSegment(id: index, start: start, end: end, symbol: sportSymbol(workout.sport))
        }
    }
}

/// The main sleep of a logical day and the cycle it starts: the Strain day runs from sleep onset, and the plot from wake.
struct StrainCycleWindow: Equatable {
    struct Sleep: Equatable {
        /// The detected onset, which the filters and the length read.
        let start: Int
        let end: Int
        /// The onset the cycle starts from: the user's correction when there is one, else `start`.
        let effectiveStart: Int
    }

    let cycleStart: Int
    let wake: Int?

    /// The longest sleep that wakes after the logical day starts (and, for a past day, before it ends) and begins
    /// before `windowEnd` (the rule the live score uses), else the logical day's own start.
    static func resolve(logicalStart: Int, logicalEnd: Int, windowEnd: Int, sleeps: [Sleep]) -> StrainCycleWindow {
        let main = sleeps
            .filter { $0.end > logicalStart && $0.end <= logicalEnd && $0.start <= windowEnd }
            .max { ($0.end - $0.start) < ($1.end - $1.start) }
        return StrainCycleWindow(cycleStart: main?.effectiveStart ?? logicalStart, wake: main?.end)
    }
}

/// What the nightly batch scored a past day from. The parts and the curve beside a stored score are worked out from the
/// same inputs, or a steps-led day would never agree with its own hero.
enum StrainBatchCycle {
    /// The cycle starts at the detected onset of the day's main night, picked by the batch's own selector among the
    /// sleeps that ended on the day, else at the day's start (AN-05).
    static func start(sleeps: [StrainCycleWindow.Sleep], dayStart: Int, dayEnd: Int, offsetSec: Int,
                      habitualMidsleepSec: Int?) -> Int {
        let blocks = sleeps.filter { $0.end >= dayStart && $0.end < dayEnd }
            .map { SleepStageTotals.NightBlock(start: $0.start, end: $0.end) }
        return AnalyticsEngine.cycleStart(blocks, offsetSec: offsetSec, habitualMidsleepSec: habitualMidsleepSec)
            ?? dayStart
    }

    /// The cycle runs to the next day's cycle start, so a stored day and the next one meet and never overlap.
    static func end(sleeps: [StrainCycleWindow.Sleep], dayEnd: Int, nextDayEnd: Int, nextOffsetSec: Int,
                    habitualMidsleepSec: Int?) -> Int {
        start(sleeps: sleeps, dayStart: dayEnd, dayEnd: nextDayEnd, offsetSec: nextOffsetSec,
              habitualMidsleepSec: habitualMidsleepSec)
    }

    /// Store range reads include their end; the batch's physiological cycle is half-open.
    static func stepRows(_ rows: [StepSample], from: Int, to: Int) -> [StepSample] {
        rows.filter { $0.ts >= from && $0.ts < to }
    }

    /// The cycle's step total, scaled by the wearer's counter ticks per step as the batch scales it; nil without any.
    static func steps(_ rows: [StepSample], ticksPerStep: Double, sleepSessions: [SleepSession] = []) -> Int? {
        guard let ticks = SleepAwareStepCounter.stepsInWindow(rows, sleepSessions: sleepSessions) else { return nil }
        let scaled = Int((Double(ticks) / max(ticksPerStep, 0.5)).rounded())
        return scaled > 0 ? scaled : nil
    }
}

/// Everything the "Through the day" plot needs from one pass, apart from words.
struct StrainCurveContent: Equatable {
    let shape: StrainCurveShape
    let ticks: [Date]
    let segments: [StrainCurveSegment]
    /// What the curve starts from when sleep alone accounts for it (before the heart-rate gate opens); nil otherwise.
    let sleepSeed: Double?
    let relation: StrainCurveRelation
    /// Whether a dashed connector runs from the curve's end to the day's score.
    let showsConnector: Bool
    let gateOpen: Bool

    /// - Parameters:
    ///   - hero: the day's score as the hero shows it (0...21).
    ///   - sleepMinutes: the scored sleep behind the seed.
    ///   - live: whether the day is in progress, so the plot reaches to the end of the pass.
    static func make(result: StrainDayResult, hero: Double?, workouts: [WorkoutRow], sleepMinutes: Double?,
                     live: Bool, calendar: Calendar = .autoupdatingCurrent) -> StrainCurveContent? {
        let analysis = result.analysis
        guard let shape = StrainCurveShape.make(
            curve: analysis.curve, wake: result.wake, now: live ? result.end : nil) else { return nil }
        let relation = StrainCurveRelation.make(
            components: analysis.components, hero: hero, liftLoad: analysis.liftMuscularLoad)
        var seed: Double?
        if let first = analysis.curve.first, (sleepMinutes ?? 0) > 0, first.value > 0,
           abs(shape.startValue - first.value) < 0.2 {
            seed = first.value
        }
        return StrainCurveContent(
            shape: shape,
            ticks: StrainCurveShape.hourTicks(in: shape.domain, calendar: calendar),
            segments: StrainCurveShape.segments(for: workouts, in: shape.domain),
            sleepSeed: seed,
            relation: relation,
            showsConnector: StrainCurveRelation.showsConnector(
                relation: relation, hero: hero, curveEnd: shape.endValue),
            gateOpen: analysis.gateOpen)
    }
}

extension StrainCurveContent {
    /// The words beside the dashed connector from the curve's end to the day's score, or nil when there is no
    /// connector: steps (or active energy) set the score.
    func markerLabel(isToday: Bool) -> String? {
        guard showsConnector else { return nil }
        switch relation {
        case .otherSetsScore(.steps):
            return isToday ? String(localized: "Today's score comes from steps")
                           : String(localized: "That day's score came from steps")
        case .otherSetsScore(.energy):
            return isToday ? String(localized: "Today's score comes from active energy")
                           : String(localized: "That day's score came from active energy")
        case .otherSetsScore(.cardio), .otherSetsScore(.lifting), .scoreDiffers, .cardioSetsScore, .none:
            return nil
        }
    }

    /// The same words as a full spoken sentence, with its own punctuation, for the plot's VoiceOver summary.
    func markerSentence(isToday: Bool) -> String? {
        guard showsConnector else { return nil }
        switch relation {
        case .otherSetsScore(.steps):
            return isToday ? String(localized: "Today's score comes from steps.")
                           : String(localized: "That day's score came from steps.")
        case .otherSetsScore(.energy):
            return isToday ? String(localized: "Today's score comes from active energy.")
                           : String(localized: "That day's score came from active energy.")
        case .otherSetsScore(.cardio), .otherSetsScore(.lifting), .scoreDiffers, .cardioSetsScore, .none:
            return nil
        }
    }
}
