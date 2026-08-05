// Add to Strand/Data and replace the days-count-only RepositoryRefreshIntent contract.

import Foundation
import NoopPhase34Core

public enum RepositoryRefreshReason: String, Equatable, Sendable {
    case launch
    case currentDay
    case committedHistoricalAnalysis
    case activeDeviceChanged
    case postImport
    case userRequested
    case fullHistoryMigration
}

public struct RepositoryRefreshRequest: Equatable, Sendable {
    public var exactDays: Set<CivilDay>
    public var recentDashboardDays: Int?
    public var includeHistoryExtent: Bool
    public var fullHistory: Bool
    public var reasons: Set<RepositoryRefreshReason>

    public init(
        exactDays: Set<CivilDay> = [],
        recentDashboardDays: Int? = nil,
        includeHistoryExtent: Bool = false,
        fullHistory: Bool = false,
        reasons: Set<RepositoryRefreshReason>
    ) {
        self.exactDays = exactDays
        self.recentDashboardDays = recentDashboardDays.map { max(1, min($0, 30)) }
        self.includeHistoryExtent = includeHistoryExtent
        self.fullHistory = fullHistory
        self.reasons = reasons
    }

    public mutating func merge(_ other: Self) {
        exactDays.formUnion(other.exactDays)
        if let rhs = other.recentDashboardDays {
            recentDashboardDays = max(recentDashboardDays ?? 0, rhs)
        }
        includeHistoryExtent = includeHistoryExtent || other.includeHistoryExtent
        fullHistory = fullHistory || other.fullHistory
        reasons.formUnion(other.reasons)
    }

    public static func launch(now: Date, calendar: HealthCalendar, recentDays: Int = 30) throws -> Self {
        // Before 04:00, the physiological day is yesterday while a just-finished night can be keyed to the
        // current civil wake day. Load both exact keys so Recovery/Sleep never wait for the recent-window pass.
        let physiological = try calendar.physiologicalDay(containing: now)
        let civil = try calendar.civilDay(containing: now)
        return Self(
            exactDays: [physiological, civil],
            recentDashboardDays: recentDays,
            includeHistoryExtent: true,
            reasons: [.launch]
        )
    }

    public static func committed(days: Set<CivilDay>) -> Self {
        Self(exactDays: days, reasons: [.committedHistoricalAnalysis])
    }

    /// Compatibility constructors for existing UI call sites. They all produce the typed request consumed by
    /// Repository; they do not select a second refresh implementation.
    public static var currentDayRequest: Self {
        let calendar = try! HealthCalendar(timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier)
        let now = Date()
        let physiological = try! calendar.physiologicalDay(containing: now)
        let civil = try! calendar.civilDay(containing: now)
        return Self(exactDays: [physiological, civil], reasons: [.currentDay])
    }

    public static var initialLoadRequest: Self {
        // Today hydrates its durable first-paint snapshot before this bounded dashboard pass. Do not invent
        // an exact publication claim before a verified projection exists.
        return Self(recentDashboardDays: 30, includeHistoryExtent: true, reasons: [.launch])
    }

    public static func recentDashboardRequest(days: Int) -> Self {
        Self(recentDashboardDays: min(30, max(1, days)), reasons: [.userRequested])
    }

    public static var postImportRequest: Self {
        Self(recentDashboardDays: 30, reasons: [.postImport])
    }

    public static var activeDeviceChangedRequest: Self {
        Self(recentDashboardDays: 30, includeHistoryExtent: true, reasons: [.activeDeviceChanged])
    }
}

public enum RepositoryRefreshExecutionStatus: Equatable, Sendable {
    case published(RepositoryRefreshOutcome)
    case deferred
    case failed(code: String)

    public var succeeded: Bool {
        if case .published(let outcome) = self { return outcome.succeeded }
        return false
    }
}

/*
Required Repository changes:

- Replace `refresh(days:) -> Bool` with `refresh(_ request:) -> RepositoryRefreshExecutionStatus`.
- A blocked RepositoryPublicationBarrier returns `.deferred`, not `false`.
- Snapshot persistence is derivative. If exact/recent rows publish successfully, return `.published` even when
  the snapshot save fails; mark the snapshot writer dirty and retry separately.
- Launch sequence:
    1. hydrate durable Today snapshot;
    2. drain high-priority pending current-day work;
    3. publish exact changed days;
    4. load a bounded recent dashboard window and history extent concurrently;
    5. never scan 4,000 days before Today appears.
- Post-backfill and Trends pull-to-refresh must use exact/recent requests, never `.fullHistory`.
*/
