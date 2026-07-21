import Foundation
import StrandAnalytics

/// Durable, local audit evidence for the last conditional evaluation and actuation.
/// Values are never inferred: absent upstream data is recorded as nil plus the evaluator reason.
struct SmartAlarmEvidence: Codable, Equatable, Sendable {
    enum Actuation: String, Codable, Sendable {
        case notRequested, sentToConnectedStrap, queuedForReconnect, unsupportedFirmware,
             experimentalDisabled, endpointArmed, failed
    }

    let mode: SmartAlarmEvaluator.Mode
    let trigger: SmartAlarmEvaluator.Trigger
    let decision: SmartAlarmEvaluator.Decision
    let reason: String
    let evaluatedAt: Date
    let inputObservedAt: Date?
    let sleepSource: String?
    let sleepModelVersion: String?
    let forecastSource: String?
    let forecastModelVersion: String?
    let requestedWakeAt: Date?
    /// The window's firmware fail-safe endpoint. Dedupe key: one early actuation per endpoint,
    /// even after an earlier re-arm rewrites `requestedWakeAt` to the earlier instant.
    let windowEndpoint: Date?
    /// Strap-armed readback (GET_ALARM_TIME) CORRELATED to this request: set only when the strap's
    /// reported epoch lands within the rejectStreak tolerance (±120 s) of `requestedWakeAt` AND the
    /// readback arrived after this arm was sent. An uncorrelated or stale readback stays nil.
    let strapReportedArmedAt: Date?
    let observedStrapWakeAt: Date?
    let actuation: Actuation
    let evaluatorModelVersion: String
}

@MainActor
enum SmartAlarmEvidenceStore {
    private static let key = "smartAlarm.lastEvidence.v1"

    static var latest: SmartAlarmEvidence? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SmartAlarmEvidence.self, from: data)
    }

    static func save(_ evidence: SmartAlarmEvidence) {
        guard let data = try? JSONEncoder().encode(evidence) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Fold the strap's asynchronous answers (armed readback, fired event) into the stored record,
    /// correlated against what THIS request actually asked for. Readback lands seconds after the
    /// evidence is saved, so correlation is re-derived here rather than at save time.
    static func refreshCorrelation(now: Date = Date()) {
        guard let e = latest, let requested = e.requestedWakeAt else { return }
        let d = UserDefaults.standard
        var armed = e.strapReportedArmedAt
        if armed == nil,
           let epoch = d.object(forKey: "alarm.lastReportedEpoch") as? Int,
           let reportedAt = d.object(forKey: "alarm.lastReportedAt") as? TimeInterval,
           reportedAt >= e.evaluatedAt.timeIntervalSince1970 {
            let reported = Date(timeIntervalSince1970: TimeInterval(epoch))
            if abs(reported.timeIntervalSince(requested)) <= 120 { armed = reported }
        }
        var fired = e.observedStrapWakeAt
        if fired == nil,
           let firedAt = d.object(forKey: "alarm.lastFiredAt") as? TimeInterval {
            let firedDate = Date(timeIntervalSince1970: firedAt)
            let latestPlausible = (e.windowEndpoint ?? requested).addingTimeInterval(45 * 60)
            if firedDate >= requested.addingTimeInterval(-120), firedDate <= latestPlausible {
                fired = firedDate
            }
        }
        guard armed != e.strapReportedArmedAt || fired != e.observedStrapWakeAt else { return }
        save(.init(mode: e.mode, trigger: e.trigger, decision: e.decision, reason: e.reason,
                   evaluatedAt: e.evaluatedAt, inputObservedAt: e.inputObservedAt,
                   sleepSource: e.sleepSource, sleepModelVersion: e.sleepModelVersion,
                   forecastSource: e.forecastSource, forecastModelVersion: e.forecastModelVersion,
                   requestedWakeAt: e.requestedWakeAt, windowEndpoint: e.windowEndpoint,
                   strapReportedArmedAt: armed, observedStrapWakeAt: fired,
                   actuation: e.actuation, evaluatorModelVersion: e.evaluatorModelVersion))
    }
}
