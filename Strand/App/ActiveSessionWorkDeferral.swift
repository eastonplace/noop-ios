import Foundation

/// Heavy background processing must not run while a workout or lift is active. iOS terminates a background
/// app that holds more than 80% CPU for 60 s (`NOOP.cpu_resource_fatal`), and a backgrounded run or lift with
/// the strap syncing history is exactly when the post-sync refresh used to fire: `Repository.hrBuckets` and
/// `WhoopStore.gravitySamples` bulk reads, both synchronous SQLite aggregation. The work is durable, so
/// parking it until the session ends loses nothing.
enum ActiveSessionWorkPolicy {
    /// A run (`AppModel.activeWorkout`) or a lift (`hasActiveReceiptLift`) is in flight.
    static func isSessionActive(hasActiveWorkout: Bool, hasActiveLift: Bool) -> Bool {
        hasActiveWorkout || hasActiveLift
    }

    /// Work that is cheap to skip and is re-driven when the app next comes to the foreground (a HealthKit
    /// observer wake, for example) only needs to wait while the app is off screen. On screen the user is
    /// watching the workout, and a pending journal drains at the next foreground anyway.
    static func shouldDeferWhileOffScreen(sessionActive: Bool, appIsActive: Bool) -> Bool {
        sessionActive && !appIsActive
    }
}

/// A watermark that can absorb a newer one from the same burst chain without losing a source scope.
protocol MergeableWatermark: Equatable, Sendable {
    func merged(with newer: Self) -> Self
}

/// Parks post-sync refresh work while a session is active and hands it back, coalesced, once it ends.
///
/// - Burst finalizations coalesce. `refreshAfterBackfillBurst` uses its watermark only to log the scopes and to
///   tell a receipt-bearing burst from a timestamp-heal-only one, and the durable pipeline it signals is the
///   source of truth, so one receipt watermark (the union, newest generation per scope) plus one heal-only
///   flag replay everything that was parked. The two stay separate because they take different recovery
///   routes.
/// - A lifecycle pipeline signal only matters if no burst refresh is replayed (a burst refresh signals the
///   pipeline itself).
struct DeferredSessionWork<Watermark: MergeableWatermark>: Equatable {
    enum Job: Equatable {
        /// nil watermark = a timestamp-heal-only publication.
        case burstRefresh(Watermark?)
        case pipelineSignal
    }

    private var receiptWatermark: Watermark?
    private var healOnlyPending = false
    private var pipelineSignalPending = false

    var hasPending: Bool { receiptWatermark != nil || healOnlyPending || pipelineSignalPending }

    /// Offer a finalized burst. True = run it now; false = it was parked for `drain`.
    mutating func admitBurst(_ watermark: Watermark?, sessionActive: Bool) -> Bool {
        guard sessionActive else { return true }
        if let watermark {
            receiptWatermark = receiptWatermark.map { $0.merged(with: watermark) } ?? watermark
        } else {
            healOnlyPending = true
        }
        return false
    }

    /// Offer a lifecycle pipeline signal (a scene edge). True = run it now; false = parked.
    mutating func admitPipelineSignal(sessionActive: Bool) -> Bool {
        guard sessionActive else { return true }
        pipelineSignalPending = true
        return false
    }

    /// Everything parked, in replay order, or nothing while a session is still active. Clears the parked state.
    mutating func drain(sessionActive: Bool) -> [Job] {
        guard !sessionActive, hasPending else { return [] }
        var jobs: [Job] = []
        if let receiptWatermark { jobs.append(.burstRefresh(receiptWatermark)) }
        if healOnlyPending { jobs.append(.burstRefresh(nil)) }
        if jobs.isEmpty, pipelineSignalPending { jobs.append(.pipelineSignal) }
        receiptWatermark = nil
        healOnlyPending = false
        pipelineSignalPending = false
        return jobs
    }
}
