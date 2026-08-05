import Foundation
import NoopPhase34Core

/// Only environmental failures may be rearmed automatically. Structural
/// payload/schema failures remain visible for repair and must not loop.
public enum PR28BlockedRearmPolicy {
    public static let environmentalCodes: Set<String> = [
        "authorization_unavailable",
        "healthkit_authorization_required",
        "protected_data_unavailable",
        "healthkit_protected_data_unavailable",
        "device_locked",
        "background_protected_data_unavailable",
    ]

    public static let structuralCodes: Set<String> = [
        "legacy_healthkit_payload_requires_repair",
        "healthkit_payload_missing",
        "invalid_healthkit_payload",
        "conflicting_snapshot_replay",
        "invalid_snapshot_receipt",
    ]

    public static func mayRearm(code: String?) -> Bool {
        guard let code else { return false }
        return environmentalCodes.contains(code) && !structuralCodes.contains(code)
    }
}

public enum HealthKitPayloadAdmissionError: Error, Equatable, Sendable {
    case missingImmutablePayload
    case payloadIdentityMismatch
}

public enum HealthKitPayloadAdmissionGuard {
    public static func validate(
        destination: DownstreamDestination,
        snapshot: SnapshotCommitReceipt
    ) throws {
        guard destination == .healthKit else { return }
        guard let payload = snapshot.healthKitPayload else {
            throw HealthKitPayloadAdmissionError.missingImmutablePayload
        }
        guard payload.validates(
            contextId: snapshot.projection.contextId,
            deviceId: snapshot.projection.deviceId,
            analysisGeneration: snapshot.analysisGeneration,
            changedDays: snapshot.analyzedDays,
            recordedTimeZoneIdentifier: snapshot.recordedTimeZoneIdentifier
        ) else {
            throw HealthKitPayloadAdmissionError.payloadIdentityMismatch
        }
    }
}
