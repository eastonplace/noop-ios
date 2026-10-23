import Foundation
import WhoopProtocol

/// A conservative type suggestion layered over the unchanged auto-detector's time window.
/// Confidence describes evidence strength, not a calibrated probability. Heart rate detects the
/// window; it never identifies a sport. The caller supplies only source-owned, user-confirmed history.
public enum WorkoutTypeSuggestion {
    public enum Confidence: Equatable, Sendable {
        case unclassified
        case possible
        case likely
    }

    public enum Evidence: Equatable, Sendable {
        case walkingMovement
        case runningMovement
        case similarConfirmedWorkouts(count: Int)
        case insufficientTypeEvidence
    }

    public struct Prediction: Equatable, Sendable {
        public let sport: String
        public let confidence: Confidence
        public let evidence: [Evidence]

        public init(sport: String, confidence: Confidence, evidence: [Evidence]) {
            self.sport = sport
            self.confidence = confidence
            self.evidence = evidence
        }

        public static let generic = Prediction(sport: "Workout", confidence: .unclassified,
                                               evidence: [.insufficientTypeEvidence])
    }

    public struct ConfirmedWorkout: Equatable, Sendable {
        public let startSec: Int
        public let endSec: Int
        public let sport: String

        public init(startSec: Int, endSec: Int, sport: String) {
            self.startSec = startSec
            self.endSec = endSec
            self.sport = sport
        }
    }

    public static func classify(workout: DetectedWorkout, steps: [StepSample],
                                confirmedHistory: [ConfirmedWorkout] = [],
                                calendar: Calendar = .current) -> Prediction {
        let (duration, overflow) = workout.endSec.subtractingReportingOverflow(workout.startSec)
        guard !overflow, workout.startSec > 0, workout.endSec < 253_402_300_800,
              duration > 0, duration <= 2 * 86_400 else { return .generic }

        let motion = movementPrediction(workout: workout, duration: duration, steps: steps)
        let history = historyPrediction(workout: workout, duration: duration,
                                        confirmedHistory: confirmedHistory, calendar: calendar)
        if let motion {
            // Gait can support an on-foot family, but cannot identify a treadmill or hiking terrain.
            // Repeated explicit corrections can refine that family, with the lower confidence retained.
            if let history, history.sport != motion.sport,
               movementFamily(history.sport) == motion.sport {
                return Prediction(sport: history.sport, confidence: .possible,
                                  evidence: motion.evidence + history.evidence)
            }
            return motion
        }
        return history ?? .generic
    }

    /// History is deliberately bounded and rebuilt from real manual workout rows on each read.
    /// There is no learned-label cache that could outlive a correction or deletion.
    public static let historyLookbackSeconds = 42 * 86_400

    private static func movementPrediction(workout: DetectedWorkout, duration: Int,
                                           steps: [StepSample]) -> Prediction? {
        var byTimestamp: [Int: StepSample] = [:]
        var contradictions = Set<Int>()
        for sample in steps where sample.ts >= workout.startSec && sample.ts <= workout.endSec {
            guard (0...65_535).contains(sample.counter) else { continue }
            if let existing = byTimestamp[sample.ts], existing != sample {
                contradictions.insert(sample.ts)
            } else {
                byTimestamp[sample.ts] = sample
            }
        }
        let sorted = byTimestamp.values.filter { !contradictions.contains($0.ts) }.sorted { $0.ts < $1.ts }
        guard sorted.count >= 2 else { return nil }
        var coveredSeconds = 0
        var secondsByClass: [Int: Int] = [:]
        var movingMinutes: [Int: Set<Int>] = [:]
        for index in 1..<sorted.count {
            let previous = sorted[index - 1], current = sorted[index]
            let elapsed = current.ts - previous.ts
            // A single class every minute must not masquerade as continuous evidence. Count only
            // short, same-class intervals; do not interpolate across offload gaps or class changes.
            guard elapsed > 0, elapsed <= 10,
                  let activityClass = current.activityClass,
                  (0...2).contains(activityClass), previous.activityClass == activityClass else { continue }
            coveredSeconds += elapsed
            secondsByClass[activityClass, default: 0] += elapsed
            let ticks = (current.counter - previous.counter) & 0xFFFF
            // The counter is motion ticks, not calibrated footfalls. Require movement without
            // deriving cadence from it, and reject reset-sized jumps (a real u16 wrap stays small).
            if ticks > 0, ticks <= 32 * elapsed {
                movingMinutes[activityClass, default: []].insert(current.ts / 60)
            }
        }
        guard Double(coveredSeconds) / Double(duration) >= 0.7 else { return nil }
        let activityClass = (secondsByClass[2] ?? 0) > (secondsByClass[1] ?? 0) ? 2 : 1
        let matchingSeconds = secondsByClass[activityClass] ?? 0
        let requiredMovingMinutes = max(6, Int(ceil(Double(duration) / 120)))
        guard Double(matchingSeconds) / Double(coveredSeconds) >= 0.8,
              (movingMinutes[activityClass]?.count ?? 0) >= requiredMovingMinutes else { return nil }
        let confidence: Confidence = Double(matchingSeconds) / Double(duration) >= 0.8 ? .likely : .possible
        return Prediction(sport: activityClass == 2 ? "Running" : "Walking", confidence: confidence,
                          evidence: [activityClass == 2 ? .runningMovement : .walkingMovement])
    }

    private static func historyPrediction(workout: DetectedWorkout, duration: Int,
                                          confirmedHistory: [ConfirmedWorkout],
                                          calendar: Calendar) -> Prediction? {
        let targetDate = Date(timeIntervalSince1970: TimeInterval(workout.startSec))
        let targetMinute = minuteOfDay(targetDate, calendar: calendar)
        let cutoff = max(0, workout.startSec - historyLookbackSeconds)
        var labelsByDay: [Date: [String: String]] = [:]
        for prior in confirmedHistory.sorted(by: { $0.startSec > $1.startSec }) {
            let (priorDuration, overflow) = prior.endSec.subtractingReportingOverflow(prior.startSec)
            let label = prior.sport.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = label.lowercased()
            guard !overflow, prior.startSec >= cutoff, prior.endSec < workout.startSec,
                  priorDuration >= 5 * 60, priorDuration <= 12 * 3_600,
                  !label.isEmpty, label.count <= 80,
                  !["workout", "activity", "detected", "other"].contains(key) else { continue }
            let durationRatio = Double(priorDuration) / Double(duration)
            guard (0.7...1.3).contains(durationRatio) else { continue }
            let date = Date(timeIntervalSince1970: TimeInterval(prior.startSec))
            let clockDistance = abs(minuteOfDay(date, calendar: calendar) - targetMinute)
            guard min(clockDistance, 24 * 60 - clockDistance) <= 90 else { continue }
            // Three duplicates or three edits on one date are not three independent confirmations.
            let day = calendar.startOfDay(for: date)
            if labelsByDay[day]?[key] == nil { labelsByDay[day, default: [:]][key] = label }
        }
        var counts: [String: Int] = [:]
        var labels: [String: String] = [:]
        for date in labelsByDay.keys.sorted(by: >) {
            guard let day = labelsByDay[date], day.count == 1 else { continue }
            guard let (key, label) = day.first else { continue }
            counts[key, default: 0] += 1
            if labels[key] == nil { labels[key] = label }
        }
        guard let top = counts.max(by: { $0.value < $1.value }), top.value >= 3,
              Double(top.value) / Double(labelsByDay.count) >= 0.8,
              let label = labels[top.key] else { return nil }
        return Prediction(sport: label, confidence: .possible,
                          evidence: [.similarConfirmedWorkouts(count: top.value)])
    }

    private static func minuteOfDay(_ date: Date, calendar: Calendar) -> Int {
        calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
    }

    private static func movementFamily(_ sport: String) -> String? {
        switch sport.lowercased() {
        case "running", "treadmill run": return "Running"
        case "walking", "treadmill walk", "hiking": return "Walking"
        default: return nil
        }
    }
}
