import Foundation

/// What the summary's Strain block shows, resolved from the provider's snapshot and how long the screen has waited.
enum LiftSummaryStrainState: Equatable, Sendable {
  case scoring, waiting, scored(LiftStrainSnapshot), notScoredYet, noSets(heartRateDisplay: Double?), unavailable

  static let defaultTimeout: TimeInterval = 20

  static func resolve(snapshot: LiftStrainSnapshot?, elapsed: TimeInterval, timeout: TimeInterval) -> Self {
    guard let snapshot else { return elapsed < timeout ? .scoring : .unavailable }
    switch snapshot.state {
    case .pending: return elapsed < timeout ? .scoring : .waiting
    case .scored: return .scored(snapshot)
    case .notScored: return .notScoredYet
    case .noSets: return .noSets(heartRateDisplay: snapshot.heartRateDisplay)
    }
  }

  /// DEBUG `--noop-lift-strain-timeout <seconds>` overrides the wait; release always waits the default.
  static var timeout: TimeInterval {
    #if DEBUG
    let arguments = ProcessInfo.processInfo.arguments
    if let index = arguments.firstIndex(of: "--noop-lift-strain-timeout"), arguments.indices.contains(index + 1),
       let seconds = TimeInterval(arguments[index + 1]), seconds > 0 {
      return seconds
    }
    #endif
    return defaultTimeout
  }
}
