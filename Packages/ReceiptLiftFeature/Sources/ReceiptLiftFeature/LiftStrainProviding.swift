import Foundation
import SwiftUI

// MARK: - The Strain seam
//
// Strength home, live logging and the summary read Strain through this protocol and never from the engine, so the
// screens stay in the package and the host decides where the numbers come from (the stored lift-strain rows). With no
// provider (`nil`, the default) every screen degrades on its own: the live strip reads "—", Recent shows "—", and the
// summary shows "Scoring…" until its timeout and then "Strain isn't ready for this lift yet."

public enum LiftStrainSummaryState: String, Sendable { case pending, scored, notScored, noSets }

/// What the summary shows for one finished lift: heart-rate-only Strain, the stored combined value, and the set counts.
public struct LiftStrainSnapshot: Equatable, Sendable {
  public let state: LiftStrainSummaryState
  /// Heart-rate-only Strain on the 0...21 display scale.
  public let heartRateDisplay: Double?
  /// The stored workout Strain on the 0...21 display scale.
  public let combinedDisplay: Double?
  public let workingSets: Int, warmupSets: Int, countedSets: Int
  public let bodyweightIsDefault: Bool

  /// What the lifted sets added on top of heart rate.
  public var setsAddDisplay: Double? {
    guard let combined = combinedDisplay, let heartRate = heartRateDisplay else { return nil }
    return combined - heartRate
  }

  public init(
    state: LiftStrainSummaryState, heartRateDisplay: Double?, combinedDisplay: Double?,
    workingSets: Int, warmupSets: Int, countedSets: Int, bodyweightIsDefault: Bool
  ) {
    self.state = state; self.heartRateDisplay = heartRateDisplay; self.combinedDisplay = combinedDisplay
    self.workingSets = workingSets; self.warmupSets = warmupSets; self.countedSets = countedSets
    self.bodyweightIsDefault = bodyweightIsDefault
  }
}

/// Strain so far in a lift that is still running.
public struct LiftLiveVitals: Equatable, Sendable {
  public let bpm: Int?
  public let heartRateDisplay: Double?
  public let combinedDisplay: Double?

  public init(bpm: Int?, heartRateDisplay: Double?, combinedDisplay: Double?) {
    self.bpm = bpm; self.heartRateDisplay = heartRateDisplay; self.combinedDisplay = combinedDisplay
  }
}

public protocol LiftStrainProviding: Sendable {
  func summary(sessionID: String) async -> LiftStrainSnapshot?
  /// Yields when stored lift Strain changes, so a summary waiting on heart data can re-resolve.
  func updates() -> AsyncStream<Void>
  /// The stored workout Strain (0...21 display scale) for each session id that has one.
  func recentStrains(sessionIDs: [String]) async -> [String: Double]
  func liveVitals(start: Date, sets: [ReceiptLiftSet]) async -> LiftLiveVitals?
  func beginLiveHeartRate() async
  func endLiveHeartRate() async
}

extension EnvironmentValues {
  /// The host's Strain source; nil until the host provides one.
  @Entry var liftStrainProvider: (any LiftStrainProviding)? = nil
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
