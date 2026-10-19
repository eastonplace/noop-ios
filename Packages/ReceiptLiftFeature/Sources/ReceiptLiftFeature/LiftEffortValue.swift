import Foundation

/// The RPE value cell's rules: 0.5 steps over 6...10, an untouched cell reading "–", and 8 as the starting point.
enum LiftEffortValue {
  static let range: ClosedRange<Double> = 6...10
  static let step = 0.5
  static let defaultRPE = 8.0

  /// One step up or down. An unrated cell steps from 8; every step rates the set.
  static func stepped(rpe: Double, rated: Bool, up: Bool) -> (rpe: Double, rated: Bool) {
    let base = rated ? rpe : defaultRPE
    let next = up ? base + step : base - step
    return (min(max(next, range.lowerBound), range.upperBound), true)
  }

  /// A tap on the cell: unrated becomes 8 and rated, rated clears back to unrated.
  static func toggled(rpe: Double, rated: Bool) -> (rpe: Double, rated: Bool) {
    rated ? (defaultRPE, false) : (defaultRPE, true)
  }

  /// "8.5", "8" or "–".
  static func text(rpe: Double, rated: Bool, locale: Locale) -> String {
    guard rated else { return "–" }
    return rpe.formatted(.number.precision(.fractionLength(0...1)).locale(locale))
  }

  static func canStep(rpe: Double, rated: Bool, up: Bool) -> Bool {
    guard rated else { return true }
    return up ? rpe < range.upperBound : rpe > range.lowerBound
  }
}
