import Foundation
import WhoopProtocol

/// Suppresses isolated counter motion inside detected sleep while retaining awake gaps and sustained
/// walking/running bouts. Sleep detection and the original motion records are never changed here.
public enum SleepAwareStepCounter {
    public static let maxSecondsBetweenGaitDeltas = 3
    public static let minGaitBoutDurationSeconds = 4
    public static let minGaitBoutActiveSamples = 5
    public static let minGaitBoutTicks = 6

    public static func stepsInWindow(_ samples: [StepSample], sleepSessions: [SleepSession]) -> Int? {
        guard !sleepSessions.isEmpty else { return StepsCounter.stepsInWindow(samples) }
        let sessions = sleepSessions.filter { $0.end > $0.start }.sorted {
            $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
        }
        var total = 0
        var boutStart: Int?
        var boutEnd: Int?
        var boutSamples = 0
        var boutTicks = 0
        var boutSession: Int?

        func flush() {
            if let start = boutStart, let end = boutEnd,
               boutSamples >= minGaitBoutActiveSamples,
               let duration = duration(from: start, to: end),
               duration >= minGaitBoutDurationSeconds, boutTicks >= minGaitBoutTicks {
                total += boutTicks
            }
            boutStart = nil; boutEnd = nil; boutSamples = 0; boutTicks = 0; boutSession = nil
        }

        StepsCounter.forEachIncrement(in: samples) { ts, ticks, newRun in
            if newRun { flush() }
            let containing = sessions.indices.filter { ts >= sessions[$0].start && ts < sessions[$0].end }
            guard let sessionIndex = containing.first else {
                flush(); total += ticks; return
            }
            // Source unions retain non-identical overlapping blocks. A broader or unstaged block must
            // not hide explicit awake evidence from another block covering the same second.
            if containing.contains(where: { index in
                sessions[index].stages.contains { ts >= $0.start && ts < $0.end && isWake($0.stage) }
            }) {
                flush(); total += ticks; return
            }
            if let last = boutEnd,
               boutSession != sessionIndex || (duration(from: last, to: ts) ?? Int.max) > maxSecondsBetweenGaitDeltas { flush() }
            if boutStart == nil { boutStart = ts; boutSession = sessionIndex }
            boutEnd = ts; boutSamples += 1; boutTicks += ticks
        }
        flush()
        return total > 0 ? total : nil
    }

    /// Only these sleep inputs affect the counter: in-bed bounds and explicit awake spans. The scan
    /// cache includes this witness when a completed successor night supplies late-evening coverage.
    public static func sleepContextFingerprint(_ sessions: [SleepSession]) -> String {
        sessions.filter { $0.end > $0.start }.map { session in
            let wake = session.stages.filter {
                isWake($0.stage) && $0.end > $0.start && $0.start < session.end && $0.end > session.start
            }.map { "\(max(session.start, $0.start))-\(min(session.end, $0.end))" }.sorted().joined(separator: ",")
            return "\(session.start):\(session.end):\(wake)"
        }.sorted().joined(separator: "|")
    }

    private static func isWake(_ stage: String) -> Bool { stage == "wake" || stage == "awake" }

    private static func duration(from start: Int, to end: Int) -> Int? {
        let (value, overflow) = end.subtractingReportingOverflow(start)
        return !overflow && value >= 0 ? value : nil
    }
}
