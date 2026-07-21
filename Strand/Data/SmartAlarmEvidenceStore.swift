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
}
