import Foundation

/// The REST card's numbers: how long is left and how long this rest was meant to be.
struct LiftRestDisplay: Equatable, Sendable {
  let remainingSeconds: Int
  let totalSeconds: Int
  /// Elapsed over total, 0...1.
  let fraction: Double

  /// nil without a running rest. The total is the gap from the last logged set to the end of the rest when that gap is a
  /// believable rest (1...3600 s), otherwise the default; +30 s grows it because the end moves.
  static func make(
    restTimerEndDate: Date?, lastCompletedAt: Date?, defaultRestSeconds: TimeInterval, now: Date
  ) -> LiftRestDisplay? {
    guard let end = restTimerEndDate else { return nil }
    var total = Int(defaultRestSeconds.rounded())
    if let last = lastCompletedAt {
      let gap = Int(end.timeIntervalSince(last).rounded())
      if (1...3_600).contains(gap) { total = gap }
    }
    total = max(total, 1)
    let remaining = max(0, Int(end.timeIntervalSince(now).rounded()))
    let fraction = min(max(Double(total - remaining) / Double(total), 0), 1)
    return LiftRestDisplay(remainingSeconds: remaining, totalSeconds: total, fraction: fraction)
  }
}
