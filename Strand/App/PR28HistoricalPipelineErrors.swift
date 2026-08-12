import Foundation
import GRDB
import NoopPhase34Core
import WhoopStore

/// Stable failure classes. Validation, incompatible source, unsupported work, and corrupt durable artifacts
/// quarantine immediately. Store protection, busy SQLite, and background expiration remain retryable.
enum PR28HistoricalPipelineError: Error {
    case invalidAnalysisReceipt
    case conflictingSnapshotReplay
    case snapshotUnavailable
    case snapshotReadBackFailed
    case analysisReceiptMissing
    case snapshotReceiptMissing
    case unsupportedFullHistoryRepair
    case databaseChanged
    case protectedDataUnavailable
    case authorizationUnavailable
    case storeUnavailable
}

enum PR28PipelineErrorClassifier {
    static func classify(_ error: any Error) -> PipelineFailureClassification {
        if let error = error as? HealthKitPayloadAdmissionError {
            switch error {
            case .missingImmutablePayload:
                return .init(code: "healthkit_payload_missing", disposition: .permanent)
            case .payloadIdentityMismatch:
                return .init(code: "invalid_healthkit_payload", disposition: .permanent)
            }
        }
        if let error = error as? PR28HistoricalPipelineError {
            switch error {
            case .snapshotUnavailable:
                return .init(code: "snapshot_unavailable", retryable: true)
            case .databaseChanged:
                return .init(code: "database_changed", retryable: false)
            case .invalidAnalysisReceipt:
                return .init(code: "invalid_analysis_receipt", retryable: false)
            case .conflictingSnapshotReplay:
                return .init(code: "conflicting_snapshot_replay", retryable: false)
            case .snapshotReadBackFailed:
                return .init(code: "snapshot_readback_failed", retryable: true)
            case .analysisReceiptMissing:
                return .init(code: "analysis_receipt_missing", retryable: false)
            case .snapshotReceiptMissing:
                return .init(code: "snapshot_receipt_missing", retryable: false)
            case .unsupportedFullHistoryRepair:
                return .init(code: "unsupported_full_history_repair", retryable: false)
            case .protectedDataUnavailable:
                return .init(code: "protected_data_unavailable", disposition: .blocked)
            case .authorizationUnavailable:
                return .init(code: "authorization_unavailable", disposition: .blocked)
            case .storeUnavailable:
                return .init(code: "store_unavailable", disposition: .retryable)
            }
        }
        if let error = error as? HistoricalPipelineArtifactError {
            return .init(code: String(describing: error), retryable: false)
        }
        if let database = error as? DatabaseError {
            switch database.resultCode {
            case .SQLITE_BUSY, .SQLITE_LOCKED, .SQLITE_INTERRUPT:
                return .init(code: "sqlite_\(database.resultCode.rawValue)", retryable: true)
            case .SQLITE_CORRUPT, .SQLITE_NOTADB, .SQLITE_CONSTRAINT:
                return .init(code: "sqlite_\(database.resultCode.rawValue)", retryable: false)
            default:
                return .init(code: "sqlite_\(database.resultCode.rawValue)", retryable: true)
            }
        }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain,
           [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(ns.code) {
            return .init(code: "protected_data_unavailable", retryable: true)
        }
        return .init(code: String(describing: error), retryable: true)
    }
}
