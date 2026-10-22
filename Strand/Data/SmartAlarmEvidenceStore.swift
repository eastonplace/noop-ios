import Foundation
import StrandAnalytics

struct SmartAlarmReadbackRequest: Equatable, Sendable {
    let id: UUID
    let sourceID: String
    let targetEpoch: Int
    let sentAt: Date
}

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
    var requestedWakeAt: Date?
    /// The window's firmware fail-safe endpoint. Dedupe key: one early actuation per endpoint,
    /// even after an earlier re-arm rewrites `requestedWakeAt` to the earlier instant.
    let windowEndpoint: Date?
    /// Strap-armed readback (GET_ALARM_TIME) CORRELATED to this request: set only when the strap's
    /// reported epoch lands within the rejectStreak tolerance (±120 s) of `requestedWakeAt` AND the
    /// readback arrived after this arm was sent. An uncorrelated or stale readback stays nil.
    var strapReportedArmedAt: Date?
    var observedStrapWakeAt: Date?
    var actuation: Actuation
    let evaluatorModelVersion: String
    enum ReadbackStatus: String, Codable, Sendable {
        case pending, confirmed, noAlarm, mismatch, unconfirmed
    }
    // Optional for compatibility with existing local evidence and backups. Legacy evidence cannot
    // confirm a new arm without an owned response from the current physical strap.
    var armRequestID: String? = nil
    var armSourceID: String? = nil
    var armSentAt: Date? = nil
    var readbackStatus: ReadbackStatus? = nil
    // An early wake can buzz successfully even if its separate firmware-alarm readback fails.
    // Keep that attempted action independent from delivery confirmation to prevent another buzz.
    var earlyWakeAttempted: Bool? = nil

    var hasAttemptedEarlyWake: Bool {
        earlyWakeAttempted ?? (mode != .exactTime && decision == .wakeNow
            && actuation == .sentToConnectedStrap)
    }
}

@MainActor
enum SmartAlarmEvidenceStore {
    private static let key = "smartAlarm.lastEvidence.v1"
    static let readbackTimeout: TimeInterval = 10
    static let readbackDidChange = Notification.Name("noop.smartAlarm.readbackDidChange")

    static func beginReadback(_ request: SmartAlarmReadbackRequest) {
        let d = UserDefaults.standard
        guard d.string(forKey: "alarm.lastArmRequestID") != request.id.uuidString else { return }
        d.set(request.id.uuidString, forKey: "alarm.lastArmRequestID")
        d.set(request.sourceID, forKey: "alarm.lastArmDeviceID")
        d.set(request.sentAt.timeIntervalSince1970, forKey: "alarm.lastArmAt")
        d.set(request.targetEpoch, forKey: "alarm.lastArmSentEpoch")
        for key in ["alarm.lastReportedEpoch", "alarm.lastReportedAt",
                    "alarm.lastReportedRequestID", "alarm.lastReportedDeviceID"] {
            d.removeObject(forKey: key)
        }
    }

    static func invalidateReadback(requestID: UUID) {
        let d = UserDefaults.standard
        guard d.string(forKey: "alarm.lastArmRequestID") == requestID.uuidString else { return }
        d.removeObject(forKey: "alarm.lastArmRequestID")
        d.removeObject(forKey: "alarm.lastArmDeviceID")
    }

    @discardableResult
    static func recordReadback(epoch: Int, request: SmartAlarmReadbackRequest,
                               at now: Date = Date()) -> Bool {
        let d = UserDefaults.standard
        guard d.string(forKey: "alarm.lastArmRequestID") == request.id.uuidString,
              d.string(forKey: "alarm.lastArmDeviceID") == request.sourceID,
              now >= request.sentAt else { return false }
        d.set(epoch, forKey: "alarm.lastReportedEpoch")
        d.set(now.timeIntervalSince1970, forKey: "alarm.lastReportedAt")
        d.set(request.id.uuidString, forKey: "alarm.lastReportedRequestID")
        d.set(request.sourceID, forKey: "alarm.lastReportedDeviceID")
        NotificationCenter.default.post(name: readbackDidChange, object: nil)
        return true
    }

    static var latest: SmartAlarmEvidence? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SmartAlarmEvidence.self, from: data)
    }

    static func isCurrentArm(_ evidence: SmartAlarmEvidence) -> Bool {
        let d = UserDefaults.standard
        return evidence.armRequestID != nil && evidence.armSourceID != nil
            && evidence.armRequestID == d.string(forKey: "alarm.lastArmRequestID")
            && evidence.armSourceID == d.string(forKey: "alarm.lastArmDeviceID")
    }

    static func save(_ evidence: SmartAlarmEvidence) {
        var evidence = evidence
        let d = UserDefaults.standard
        let previous = latest
        if evidence.hasAttemptedEarlyWake { evidence.earlyWakeAttempted = true }
        if evidence.actuation == .notRequested,
           let previous, previous.windowEndpoint != nil,
           previous.windowEndpoint == evidence.windowEndpoint, previous.mode == evidence.mode,
           isCurrentArm(previous) {
            // A new evaluation updates its provenance, not the current physical delivery operation.
            evidence.requestedWakeAt = previous.requestedWakeAt
            evidence.strapReportedArmedAt = previous.strapReportedArmedAt
            evidence.observedStrapWakeAt = previous.observedStrapWakeAt
            evidence.actuation = previous.actuation
            evidence.armRequestID = previous.armRequestID
            evidence.armSourceID = previous.armSourceID
            evidence.armSentAt = previous.armSentAt
            evidence.readbackStatus = previous.readbackStatus
            evidence.earlyWakeAttempted = previous.hasAttemptedEarlyWake ? true : nil
        }
        if evidence.armRequestID == nil,
           evidence.actuation == .endpointArmed || evidence.actuation == .sentToConnectedStrap,
           let requested = evidence.requestedWakeAt,
           let sentAt = d.object(forKey: "alarm.lastArmAt") as? TimeInterval,
           d.integer(forKey: "alarm.lastArmSentEpoch") == Int(requested.timeIntervalSince1970) {
            // Evaluation precedes the BLE actuation in adaptive mode. Its timestamp is provenance,
            // not an ordering fence for the exact-target request that is active when evidence is saved.
            evidence.armRequestID = d.string(forKey: "alarm.lastArmRequestID")
            evidence.armSourceID = d.string(forKey: "alarm.lastArmDeviceID")
            evidence.armSentAt = Date(timeIntervalSince1970: sentAt)
        }
        if let previous, previous.hasAttemptedEarlyWake,
           previous.windowEndpoint != nil, previous.windowEndpoint == evidence.windowEndpoint,
           previous.mode == evidence.mode, previous.armSourceID == evidence.armSourceID,
           isCurrentArm(evidence) {
            // A same-strap reconnect starts a new delivery request. Only the once-per-window attempt
            // survives that replacement; its old confirmation and readback stay with the old request.
            evidence.earlyWakeAttempted = true
        }
        guard let data = try? JSONEncoder().encode(evidence) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Fold the strap's asynchronous answers (armed readback, fired event) into the stored record,
    /// correlated against what THIS request actually asked for. Readback lands seconds after the
    /// evidence is saved, so correlation is re-derived here rather than at save time.
    static func refreshCorrelation(now: Date = Date()) {
        guard let e = latest, let requested = e.requestedWakeAt else { return }
        let d = UserDefaults.standard
        let scopeMatches = isCurrentArm(e)
        let sentAt = e.armSentAt ?? e.evaluatedAt
        var armed = scopeMatches ? e.strapReportedArmedAt : nil
        var status = scopeMatches ? (e.readbackStatus ?? .pending) : .pending
        if scopeMatches,
           let epoch = d.object(forKey: "alarm.lastReportedEpoch") as? Int,
           let reportedAt = d.object(forKey: "alarm.lastReportedAt") as? TimeInterval,
           reportedAt >= sentAt.timeIntervalSince1970,
           d.string(forKey: "alarm.lastReportedRequestID") == e.armRequestID,
           d.string(forKey: "alarm.lastReportedDeviceID") == e.armSourceID {
            let reported = Date(timeIntervalSince1970: TimeInterval(epoch))
            if epoch > 0, abs(reported.timeIntervalSince(requested)) <= 120 {
                armed = reported
                status = .confirmed
            } else {
                armed = nil
                status = epoch == 0 ? .noAlarm : .mismatch
            }
        } else if armed == nil, now.timeIntervalSince(sentAt) >= readbackTimeout {
            status = .unconfirmed
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
        let armRelated = e.actuation == .endpointArmed || e.actuation == .sentToConnectedStrap
            || e.readbackStatus != nil
        guard armRelated || fired != e.observedStrapWakeAt else { return }
        let failed = status == .noAlarm || status == .mismatch || status == .unconfirmed
        let confirmedActuation: SmartAlarmEvidence.Actuation =
            e.hasAttemptedEarlyWake && e.requestedWakeAt != e.windowEndpoint
                ? .sentToConnectedStrap : .endpointArmed
        let actuation: SmartAlarmEvidence.Actuation = armRelated && failed ? .failed
            : (status == .confirmed && e.actuation == .failed ? confirmedActuation : e.actuation)
        var updated = SmartAlarmEvidence(mode: e.mode, trigger: e.trigger, decision: e.decision, reason: e.reason,
                   evaluatedAt: e.evaluatedAt, inputObservedAt: e.inputObservedAt,
                   sleepSource: e.sleepSource, sleepModelVersion: e.sleepModelVersion,
                   forecastSource: e.forecastSource, forecastModelVersion: e.forecastModelVersion,
                   requestedWakeAt: e.requestedWakeAt, windowEndpoint: e.windowEndpoint,
                   strapReportedArmedAt: armed, observedStrapWakeAt: fired,
                   actuation: actuation,
                   evaluatorModelVersion: e.evaluatorModelVersion)
        updated.armRequestID = e.armRequestID
        updated.armSourceID = e.armSourceID
        updated.armSentAt = e.armSentAt
        updated.readbackStatus = armRelated ? status : e.readbackStatus
        updated.earlyWakeAttempted = e.hasAttemptedEarlyWake ? true : e.earlyWakeAttempted
        guard updated != e else { return }
        save(updated)
    }
}
