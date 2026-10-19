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

/// Keeps live heart rate on for as long as its task runs: begin first, end when the task is cancelled. The pair is
/// always balanced, however quickly the view appears and disappears.
enum LiftLiveHeartRateSession {
  static func run(_ provider: any LiftStrainProviding) async {
    await provider.beginLiveHeartRate()
    await withTaskCancellationHandler {
      while !Task.isCancelled { try? await Task.sleep(for: .seconds(3_600)) }
    } onCancel: {
      Task { await provider.endLiveHeartRate() }
    }
  }
}

/// Maps a live lift's sets to what the provider reads.
enum LiftReceiptSetMapping {
  static func sets(for session: LiftSession, exercise: (UUID) -> LiftExercise?) -> [ReceiptLiftSet] {
    session.sets.map { set in
      let found = exercise(set.exerciseID)
      let metadata = found.flatMap { LiftExerciseCatalog.metadata(for: $0) }
      return ReceiptLiftSet(
        id: set.id.uuidString, exercise: found?.name ?? "Exercise",
        muscleGroup: metadata?.target ?? found?.muscleGroup ?? "",
        secondaryMuscles: metadata?.secondaryMuscles ?? [], setIndex: set.setNumber,
        weightKg: set.weight * LiftWeightUnit.kilogramsPerPound, reps: set.reps, rpe: set.rpe,
        isWarmup: set.isWarmup, completedAt: set.completedAt, note: set.notes.isEmpty ? nil : set.notes,
        equipment: found?.equipment)
    }
  }
}

#if DEBUG
/// DEBUG Strain source for the QA harness. These are mockup values, not formula output.
///
/// - `--noop-lift-strain-demo <scored|pending|not-scored|no-sets|unavailable>`
/// - `--noop-lift-vitals none` makes `liveVitals` return nil.
struct DemoLiftStrainProvider: LiftStrainProviding {
  enum Mode: String { case scored, pending, notScored = "not-scored", noSets = "no-sets", unavailable }

  let mode: Mode
  let vitalsAvailable: Bool

  static var requestedMode: Mode? {
    let arguments = ProcessInfo.processInfo.arguments
    guard let index = arguments.firstIndex(of: "--noop-lift-strain-demo"), arguments.indices.contains(index + 1) else {
      return nil
    }
    return Mode(rawValue: arguments[index + 1].lowercased())
  }

  /// The provider a QA launch asked for, or nil.
  static func fromLaunchArguments() -> DemoLiftStrainProvider? {
    let arguments = ProcessInfo.processInfo.arguments
    let vitalsNone = arguments.firstIndex(of: "--noop-lift-vitals").map {
      arguments.indices.contains($0 + 1) && arguments[$0 + 1].lowercased() == "none"
    } ?? false
    guard let mode = requestedMode else { return vitalsNone ? DemoLiftStrainProvider(mode: .scored, vitalsAvailable: false) : nil }
    return DemoLiftStrainProvider(mode: mode, vitalsAvailable: !vitalsNone)
  }

  func summary(sessionID: String) async -> LiftStrainSnapshot? {
    switch mode {
    case .scored:
      return LiftStrainSnapshot(state: .scored, heartRateDisplay: 6.4, combinedDisplay: 11.6, workingSets: 18,
                                warmupSets: 3, countedSets: 18, bodyweightIsDefault: false)
    case .pending:
      return LiftStrainSnapshot(state: .pending, heartRateDisplay: nil, combinedDisplay: nil, workingSets: 18,
                                warmupSets: 3, countedSets: 18, bodyweightIsDefault: false)
    case .notScored:
      return LiftStrainSnapshot(state: .notScored, heartRateDisplay: nil, combinedDisplay: nil, workingSets: 18,
                                warmupSets: 3, countedSets: 18, bodyweightIsDefault: false)
    case .noSets:
      return LiftStrainSnapshot(state: .noSets, heartRateDisplay: 6.4, combinedDisplay: 6.4, workingSets: 0,
                                warmupSets: 0, countedSets: 0, bodyweightIsDefault: false)
    case .unavailable:
      return nil
    }
  }

  func updates() -> AsyncStream<Void> { AsyncStream { _ in } }

  func recentStrains(sessionIDs: [String]) async -> [String: Double] {
    let fixed = [12.4, 13.1, 11.8]
    return Dictionary(uniqueKeysWithValues: zip(sessionIDs.prefix(fixed.count), fixed).map { ($0, $1) })
  }

  func liveVitals(start: Date, sets: [ReceiptLiftSet]) async -> LiftLiveVitals? {
    guard vitalsAvailable else { return nil }
    return LiftLiveVitals(bpm: 128, heartRateDisplay: 5.0, combinedDisplay: 7.9)
  }

  func beginLiveHeartRate() async {}
  func endLiveHeartRate() async {}
}
#endif
