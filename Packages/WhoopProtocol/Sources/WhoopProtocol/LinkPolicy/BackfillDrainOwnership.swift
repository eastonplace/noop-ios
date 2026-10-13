import Foundation

/// BLE-8: which historical session (and physical connection) admitted a queued backfill frame.
public struct BackfillDrainToken: Equatable, Hashable, Sendable {
    public let sessionGeneration: Int
    public let connectGeneration: Int

    public init(sessionGeneration: Int, connectGeneration: Int) {
        self.sessionGeneration = sessionGeneration
        self.connectGeneration = connectGeneration
    }
}

/// BLE-8: ownership of the serial backfill drain.
///
/// The drain used to be guarded by a Bool that `didDisconnect` reset while the drain task was still
/// suspended inside `Backfiller.ingest`, so a reconnect could start a second drainer, and the first one
/// resumed feeding its stale local batch (WHOOP 4 frames carried no session token at all). Now every
/// queued frame carries the token of the session that admitted it, a frame whose token is no longer
/// current is dropped before it reaches the Backfiller (so a stale HISTORY_END can never be ACKed into a
/// newer session), and only the drainer that claimed ownership can release it.
public struct BackfillDrainOwnership: Equatable, Sendable {
    public private(set) var activeDrainID: UInt64?
    private var lastIssuedID: UInt64 = 0

    public init() {}

    /// Returns a fresh drain id when no drainer is running (the caller must start one); nil while a
    /// drainer already owns the queue (it will pick up the newly queued frame itself).
    public mutating func claimIfIdle() -> UInt64? {
        guard activeDrainID == nil else { return nil }
        lastIssuedID &+= 1
        activeDrainID = lastIssuedID
        return lastIssuedID
    }

    /// The drainer `id` finished. Only the current owner can release; a superseded drainer cannot clear a
    /// newer drainer's claim. Returns whether ownership was released.
    @discardableResult
    public mutating func release(_ id: UInt64) -> Bool {
        guard activeDrainID == id else { return false }
        activeDrainID = nil
        return true
    }

    /// Whether a queued frame may still be fed to the Backfiller: only while backfilling, and only when the
    /// session and physical connection that admitted it are still the current ones.
    public static func shouldIngest(frame: BackfillDrainToken, current: BackfillDrainToken?,
                                    backfilling: Bool) -> Bool {
        backfilling && current == frame
    }
}
