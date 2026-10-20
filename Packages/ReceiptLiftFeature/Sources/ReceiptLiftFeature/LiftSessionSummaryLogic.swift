import Foundation

/// The numbers and words the post-session summary prints, kept apart from the view so they can be tested.
enum LiftSessionSummaryLogic {
  /// The RPE the person picked, over the working sets they picked one for. Untouched sets (rated != true) never count.
  nonisolated static func ratedWorkingEfforts(_ session: LiftSession) -> [Double] {
    session.sets.filter { !$0.isWarmup && $0.effortRated == true }.map(\.rpe)
  }

  nonisolated static func rpeRange(_ efforts: [Double]) -> (low: Double, high: Double)? {
    guard let low = efforts.min(), let high = efforts.max() else { return nil }
    return (low, high)
  }

  nonisolated static func averageEffort(_ efforts: [Double]) -> Double? {
    efforts.isEmpty ? nil : efforts.reduce(0, +) / Double(efforts.count)
  }

  /// A word for an average RPE.
  static func effortWord(_ rpe: Double) -> String {
    switch rpe {
    case ..<7: String(localized: "light")
    case ..<8: String(localized: "moderate")
    case ..<9: String(localized: "hard")
    default: String(localized: "very hard")
    }
  }

  /// "Heart rate alone would score this 6.4. Your 18 working sets at RPE 8–9 bring it to 11.6." The figures are marked
  /// `**bold**`. With one RPE it reads "at RPE 8"; with no rated set the RPE clause is dropped.
  static func lede(
    heartRate: Double, combined: Double, workingSets: Int, rpeRange: (low: Double, high: Double)?, locale: Locale
  ) -> String {
    func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...1)).locale(locale)) }
    func strain(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(1)).locale(locale)) }
    let hr = strain(heartRate)
    let total = strain(combined)
    let sets = LiftFormat.setCountWorking(workingSets)
    if let range = rpeRange {
      let rpe = range.low == range.high ? number(range.low) : "\(number(range.low))–\(number(range.high))"
      return String(localized: "Heart rate alone would score this **\(hr)**. Your **\(sets)** at RPE \(rpe) bring it to **\(total)**.")
    }
    return String(localized: "Heart rate alone would score this **\(hr)**. Your **\(sets)** bring it to **\(total)**.")
  }

  /// The note under a Strain that was scored on the default body weight.
  static func defaultBodyweightNote(kilograms: Double = 75) -> String {
    String(localized: "Using \(Int(kilograms)) kg. Set your weight in Settings.")
  }
}

extension LiftFormat {
  /// "18 working sets".
  static func setCountWorking(_ count: Int) -> String { String(localized: "\(count) working sets") }
}

/// What the summary lists per exercise: the best set by estimated one-rep max, and whether it was a record.
struct LiftSummaryLift: Identifiable, Equatable {
  let id: UUID
  let exercise: LiftExercise?
  let name: String
  let workingSets: Int
  let best: LiftSet
  let isPersonalRecord: Bool
  /// Bodyweight and high-rep moves read reps in place of a one-rep max.
  let showsReps: Bool
}

enum LiftSummaryLifts {
  nonisolated static func make(
    session: LiftSession, exercises: [UUID: LiftExercise], recordSetIDs: Set<UUID>
  ) -> [LiftSummaryLift] {
    var order: [UUID] = []
    var byExercise: [UUID: [LiftSet]] = [:]
    for set in session.sets where !set.isWarmup {
      if byExercise[set.exerciseID] == nil { order.append(set.exerciseID) }
      byExercise[set.exerciseID, default: []].append(set)
    }
    return order.compactMap { id in
      guard let sets = byExercise[id] else { return nil }
      let exercise = exercises[id]
      let usesBodyweight = exercise.map(liftUsesBodyweightLoad) ?? false
      let best = sets.max { lhs, rhs in
        usesBodyweight || lhs.estimatedOneRepMax == rhs.estimatedOneRepMax
          ? lhs.reps < rhs.reps : lhs.estimatedOneRepMax < rhs.estimatedOneRepMax
      } ?? sets[0]
      let showsReps = usesBodyweight || best.weight <= 0 || best.reps > 12
      return LiftSummaryLift(
        id: id, exercise: exercise, name: exercise?.name ?? "Exercise", workingSets: sets.count, best: best,
        isPersonalRecord: sets.contains { recordSetIDs.contains($0.id) }, showsReps: showsReps)
    }
  }
}
