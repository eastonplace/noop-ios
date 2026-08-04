import Foundation

public enum DerivativeSnapshotPersistenceStatus: String, Codable, Equatable, Sendable {
    case persisted
    case unchanged
    case deferred
    case rejected
    case failed
}

/// Authoritative repository publication and derivative first-paint persistence are separate outcomes. A
/// snapshot failure must schedule a retry, but it must never make already-published source data look failed.
public struct RepositoryRefreshOutcome: Codable, Equatable, Sendable {
    public let authoritativeDataPublished: Bool
    public let changedDays: Set<CivilDay>
    public let snapshotStatus: DerivativeSnapshotPersistenceStatus

    public init(
        authoritativeDataPublished: Bool,
        changedDays: Set<CivilDay>,
        snapshotStatus: DerivativeSnapshotPersistenceStatus
    ) {
        self.authoritativeDataPublished = authoritativeDataPublished
        self.changedDays = changedDays
        self.snapshotStatus = snapshotStatus
    }

    public var succeeded: Bool { authoritativeDataPublished }
    public var shouldRetrySnapshot: Bool {
        snapshotStatus == .deferred || snapshotStatus == .rejected || snapshotStatus == .failed
    }
}

public struct RepositoryHistoryExtent: Codable, Equatable, Sendable {
    public let earliestDay: CivilDay?
    public let latestDay: CivilDay?
    public let importedDayCount: Int
    public let computedDayCount: Int
    public let appleDayCount: Int

    public init(
        earliestDay: CivilDay?,
        latestDay: CivilDay?,
        importedDayCount: Int,
        computedDayCount: Int,
        appleDayCount: Int
    ) {
        self.earliestDay = earliestDay
        self.latestDay = latestDay
        self.importedDayCount = max(0, importedDayCount)
        self.computedDayCount = max(0, computedDayCount)
        self.appleDayCount = max(0, appleDayCount)
    }

    public var hasHistory: Bool {
        importedDayCount > 0 || computedDayCount > 0 || appleDayCount > 0
    }
}
