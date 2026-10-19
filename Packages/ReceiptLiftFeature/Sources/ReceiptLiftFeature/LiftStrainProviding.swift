import Foundation
import SwiftUI

/// How a finished session's Strain reads on Lift's own screens. The host owns the numbers (they are stored values
/// on NOOP's scale); this package only draws them.
public enum LiftStrainSummaryState: String, Sendable {
    /// Computed, not yet folded into the stored Strain (the host is settling it).
    case pending
    /// The stored Strain includes the logged sets.
    case scored
    /// No heart-rate Strain exists for the workout (yet), so the sets are not added.
    case notScored
    /// The workout has no counted sets: the stored Strain is heart rate alone.
    case noSets
}

/// One finished session's Strain, on the 0...21 display scale.
public struct LiftStrainSnapshot: Equatable, Sendable {
    public let state: LiftStrainSummaryState
    /// Heart rate alone, 0...21.
    public let heartRateDisplay: Double?
    /// The stored workout value, 0...21.
    public let combinedDisplay: Double?
    public let workingSets: Int
    public let warmupSets: Int
    public let countedSets: Int
    /// The body weight behind the score is the 75 kg default, because none was set when the lift was scored.
    public let bodyweightIsDefault: Bool

    /// What the logged sets add to heart rate alone.
    public var setsAddDisplay: Double? {
        guard let c = combinedDisplay, let h = heartRateDisplay else { return nil }
        return c - h
    }

    public init(state: LiftStrainSummaryState, heartRateDisplay: Double?, combinedDisplay: Double?,
                workingSets: Int, warmupSets: Int, countedSets: Int, bodyweightIsDefault: Bool) {
        self.state = state
        self.heartRateDisplay = heartRateDisplay
        self.combinedDisplay = combinedDisplay
        self.workingSets = workingSets
        self.warmupSets = warmupSets
        self.countedSets = countedSets
        self.bodyweightIsDefault = bodyweightIsDefault
    }
}

/// Strain so far during a live session, 0...21.
public struct LiftLiveVitals: Equatable, Sendable {
    public let bpm: Int?
    public let heartRateDisplay: Double?
    public let combinedDisplay: Double?

    public init(bpm: Int?, heartRateDisplay: Double?, combinedDisplay: Double?) {
        self.bpm = bpm
        self.heartRateDisplay = heartRateDisplay
        self.combinedDisplay = combinedDisplay
    }
}

/// What the host gives Lift to show Strain. Every value is read from what the host stored (or, for a live session,
/// from the same formula), so Lift never computes a score of its own.
public protocol LiftStrainProviding: Sendable {
    /// The session's Strain, or nil when the host has none for it.
    func summary(sessionID: String) async -> LiftStrainSnapshot?
    /// Yields whenever stored Strain changed (a lift was scored, settled or rescored).
    func updates() -> AsyncStream<Void>
    /// The stored workout Strain (0...21 display) of each session that has one.
    func recentStrains(sessionIDs: [String]) async -> [String: Double]
    /// Strain so far for a session that started at `start`, with the sets logged so far.
    func liveVitals(start: Date, sets: [ReceiptLiftSet]) async -> LiftLiveVitals?
    /// A live session wants the realtime heart-rate stream; balanced by `endLiveHeartRate`.
    func beginLiveHeartRate() async
    func endLiveHeartRate() async
}

public struct LiftStrainProviderKey: EnvironmentKey {
    public static let defaultValue: (any LiftStrainProviding)? = nil
}

public extension EnvironmentValues {
    var liftStrainProvider: (any LiftStrainProviding)? {
        get { self[LiftStrainProviderKey.self] }
        set { self[LiftStrainProviderKey.self] = newValue }
    }
}
