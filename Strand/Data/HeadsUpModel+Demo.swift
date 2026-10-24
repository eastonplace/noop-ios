#if DEBUG
import Foundation
import StrandAnalytics

// `--demo-heads-up <state>` (DEBUG only): a fixed Heads-Up read, so the Today card and the detail page can be captured
// in every state without a strap or weeks of nights. States: off, learning, unavailable, clear, mild, raised, explained, unwell.
// The numbers are consistent with the engine (each fired signal's z clears its threshold, the scores follow its
// formula), but they are a QA fixture: production never reads this.
extension HeadsUpSnapshot {
    static var demoOverride: HeadsUpSnapshot? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--demo-heads-up"), flag + 1 < arguments.count else { return nil }
        return demo(arguments[flag + 1])
    }

    static func demo(_ state: String, today: Date = Date()) -> HeadsUpSnapshot? {
        let calendar = Calendar.current
        func dayKey(_ back: Int) -> String {
            Repository.localDayKey(calendar.date(byAdding: .day, value: -back, to: today) ?? today)
        }
        let noise: [[Double]] = [
            [0.3, -0.5, 0.8, 0.1, -0.9, 0.4, -0.2, 0.6, -0.4, 0.2, -0.7, 0.5],
            [-0.4, 0.6, -0.1, 0.9, 0.2, -0.6, 0.5, -0.8, 0.3, -0.2, 0.7, -0.3],
            [0.1, 0.4, -0.6, -0.2, 0.7, 0.0, -0.5, 0.3, 0.8, -0.4, 0.2, -0.1],
            [0.5, -0.2, 0.2, -0.7, 0.1, 0.6, -0.3, -0.1, 0.4, -0.6, 0.3, 0.0],
        ]
        // (kind, usual, one robust SD, illness direction)
        let shapes: [(SignalKind, Double, Double, Double)] = [
            (.restingHR, 52, 1.9, 1), (.hrv, 62, 4.7, -1), (.skinTemp, 0, 0.3, 1), (.respiration, 15.1, 0.42, 1),
        ]
        func signals(_ z: [Double], building: Bool = false) -> [Signal] {
            shapes.enumerated().map { index, shape in
                let (kind, usual, sd, direction) = shape
                let latest = usual + z[index] * sd
                var history: [Double?] = noise[index].map { usual + $0 * sd }
                history.append(usual + z[index] * 0.8 * sd)
                history.append(latest)
                let reach = IllnessSignalEngine.signalZThreshold * sd
                return Signal(kind: kind, latest: latest, usual: building ? nil : usual, z: building ? nil : z[index],
                              fired: !building && z[index] * direction > IllnessSignalEngine.signalZThreshold,
                              normalBand: building ? nil : (usual - reach)...(usual + reach),
                              history: building ? Array(history.suffix(9)) : history)
            }
        }
        func history(_ scores: [Double], last: IllnessSignalEngine.Level? = nil) -> [DayScore] {
            scores.enumerated().map { index, score in
                let level: IllnessSignalEngine.Level = score >= IllnessSignalEngine.raiseThreshold ? .raised
                    : score >= IllnessSignalEngine.mildThreshold ? .mild : .quiet
                let isLast = index == scores.count - 1
                return DayScore(day: dayKey(scores.count - 1 - index), score: score,
                                level: isLast ? (last ?? level) : level)
            }
        }
        func scored(_ level: IllnessSignalEngine.Level, score: Double, z: [Double], scores: [Double],
                    rawScore: Double? = nil, causes: Set<Cause> = [], answeredNo: Set<Cause> = [],
                    confidence: String? = nil, unwellDay: String? = nil) -> HeadsUpSnapshot {
            HeadsUpSnapshot(phase: .scored(level), day: dayKey(0), score: score, rawScore: rawScore,
                            signals: signals(z), causes: causes, answeredNo: answeredNo, confidence: confidence,
                            history: history(scores, last: level), unwellDay: unwellDay)
        }
        switch state {
        case "off":
            return HeadsUpSnapshot.off
        case "learning":
            return HeadsUpSnapshot(phase: .learning(nights: 9), day: dayKey(0), score: 0, rawScore: nil,
                                   signals: signals([0.4, -0.3, 0.6, 0.2], building: true), causes: [],
                                   confidence: nil, history: [], unwellDay: nil)
        case "unavailable":
            return HeadsUpSnapshot(phase: .unavailable, day: dayKey(0), score: 0, rawScore: nil,
                                   signals: signals([4.0, -4.0, 2.7, 0.2], building: true), causes: [],
                                   confidence: nil, history: [], unwellDay: nil)
        case "clear":
            return scored(.quiet, score: 0, z: [0.5, 0.4, 0.3, -0.2],
                          scores: [0, 0, 6, 0, 0, 0, 9, 0, 0, 4, 0, 0, 0, 0])
        case "mild":
            return scored(.mild, score: 29, z: [2.6, -2.4, 1.0, 0.7],
                          scores: [0, 0, 5, 0, 0, 0, 7, 0, 0, 3, 0, 8, 18, 29])
        case "raised":
            return scored(.raised, score: 55, z: [3.2, -3.0, 2.3, 1.2],
                          scores: [0, 0, 4, 0, 0, 0, 8, 0, 0, 5, 0, 12, 34, 55],
                          answeredNo: [.alcohol, .sauna], confidence: "strong")
        case "explained":
            return scored(.suppressed, score: 37, z: [3.6, -3.4, 2.7, 0.5],
                          scores: [0, 0, 4, 0, 0, 0, 7, 0, 0, 3, 0, 0, 9, 37],
                          rawScore: 81, causes: [.alcohol], answeredNo: [.stress])
        case "unwell":
            return scored(.alreadyUnwell, score: 64, z: [2.6, -3.2, 2.7, 2.4],
                          scores: [0, 0, 4, 0, 0, 0, 6, 0, 0, 19, 47, 58, 62, 64], unwellDay: dayKey(1))
        default:
            return nil
        }
    }
}
#endif
