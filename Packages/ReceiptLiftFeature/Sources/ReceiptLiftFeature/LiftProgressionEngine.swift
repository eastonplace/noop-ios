import Foundation

/// Portable input values keep progression policy separate from storage, formatting, and workout presentation.
enum LiftProgressionUnit: Equatable, Sendable {
  case pounds, kilograms

  func fromPounds(_ value: Double) -> Double { self == .pounds ? value : value * 0.45359237 }
  func toPounds(_ value: Double) -> Double { self == .pounds ? value : value / 0.45359237 }
}

enum LiftProgressionEquipment: Equatable, Sendable {
  case barbell, dumbbell, bodyweight, unknown

  /// Total bar load, or the logged load of one dumbbell. Unknown stacks and implements need a manual choice.
  func loadStep(in unit: LiftProgressionUnit) -> Double? {
    switch (self, unit) {
    case (.barbell, .pounds), (.dumbbell, .pounds): 5
    case (.barbell, .kilograms): 2.5
    case (.dumbbell, .kilograms): 2
    default: nil
    }
  }
}

struct LiftProgressionPlan: Equatable, Sendable {
  var sets: String
  var reps: String
  var targetEffort: String
}

struct LiftProgressionWorkSet: Equatable, Sendable {
  var id: UUID
  var weightPounds: Double
  var reps: Int
  var rpe: Double
  var effortRated: Bool?
  var isWarmup: Bool
  var completedAt: Date
}

struct LiftProgressionSession: Equatable, Sendable {
  var id: UUID
  var startedAt: Date
  var endedAt: Date?
  var sets: [LiftProgressionWorkSet]
}

struct LiftProgressionTarget: Equatable, Sendable {
  let weightPounds: Double
  let reps: Int
  let sets: Int
  var repSuffix = ""

  var repsText: String { "\(reps)\(repSuffix)" }
}

struct LiftProgressionEvidence: Equatable, Sendable {
  let workingSets: Int
  let weightPounds: Double
  let minimumReps: Int
  let maximumReps: Int
  let highestRPE: Double?
}

struct LiftProgressionDecision: Equatable, Sendable {
  enum Reason: Equatable, Sendable {
    case addReps, addSet, addWeight, reduceWeight, reduceReps, repeatWork
    case noHistory, staleHistory, noWorkingSets, unsupportedPrescription
    case missingEffort, invalidHistory, mixedLoads, incompleteSets
    case unknownLoadStep, bodyweightCeiling, loadStepTooLarge
  }

  let reason: Reason
  let target: LiftProgressionTarget?
  let sourceSessionID: UUID?
  let sourceEndedAt: Date?
  let evidence: LiftProgressionEvidence?
}

enum LiftProgressionEngine {
  static let maximumHistoryAge: TimeInterval = 42 * 86_400

  /// A deliberately conservative double-progression policy, not an estimate of strength or training readiness.
  /// Every increase requires complete, explicitly rated work from the latest completed occurrence of the routine.
  static func recommendation(
    plan: LiftProgressionPlan,
    equipment: LiftProgressionEquipment,
    unit: LiftProgressionUnit,
    history: [LiftProgressionSession],
    now: Date
  ) -> LiftProgressionDecision {
    guard let setRange = integerRange(plan.sets, maximum: 20),
          let reps = repPrescription(plan.reps),
          let effortCeiling = effortCeiling(plan.targetEffort)
    else {
      return LiftProgressionDecision(
        reason: .unsupportedPrescription, target: nil, sourceSessionID: nil, sourceEndedAt: nil, evidence: nil
      )
    }

    let latest = history.filter { session in
      guard let end = session.endedAt else { return false }
      return now.timeIntervalSinceReferenceDate.isFinite
        && session.startedAt.timeIntervalSinceReferenceDate.isFinite
        && end.timeIntervalSinceReferenceDate.isFinite
        && session.startedAt <= end && end <= now
    }.max { left, right in
      if left.endedAt != right.endedAt { return left.endedAt! < right.endedAt! }
      if left.startedAt != right.startedAt { return left.startedAt < right.startedAt }
      return left.id.uuidString < right.id.uuidString
    }
    guard let latest, let end = latest.endedAt else {
      return LiftProgressionDecision(reason: .noHistory, target: nil, sourceSessionID: nil, sourceEndedAt: nil, evidence: nil)
    }

    var evidence: LiftProgressionEvidence?
    func result(_ reason: LiftProgressionDecision.Reason, _ target: LiftProgressionTarget? = nil) -> LiftProgressionDecision {
      LiftProgressionDecision(
        reason: reason, target: target, sourceSessionID: latest.id, sourceEndedAt: end, evidence: evidence
      )
    }
    guard now.timeIntervalSince(end) <= maximumHistoryAge else { return result(.staleHistory) }
    let work = latest.sets.filter { !$0.isWarmup }
    guard let first = work.first else { return result(.noWorkingSets) }
    guard Set(work.map(\.id)).count == work.count,
          work.allSatisfy({ set in
            set.weightPounds.isFinite && (0...10_000).contains(set.weightPounds)
              && (1...1_000).contains(set.reps)
              && set.completedAt.timeIntervalSinceReferenceDate.isFinite
              && set.completedAt >= latest.startedAt && set.completedAt <= end
              && (set.effortRated != true || (set.rpe.isFinite && (6...10).contains(set.rpe)))
          })
    else { return result(.invalidHistory) }
    guard work.allSatisfy({ abs($0.weightPounds - first.weightPounds) < 0.000_1 }) else {
      return result(.mixedLoads)
    }

    let allRated = work.allSatisfy { $0.effortRated == true }
    let minimumReps = work.map(\.reps).min() ?? first.reps
    let maximumReps = work.map(\.reps).max() ?? first.reps
    let highestRPE = allRated ? work.map(\.rpe).max() : nil
    evidence = LiftProgressionEvidence(
      workingSets: work.count, weightPounds: first.weightPounds,
      minimumReps: minimumReps, maximumReps: maximumReps, highestRPE: highestRPE
    )
    guard work.count >= setRange.lowerBound else { return result(.incompleteSets) }
    guard let highestRPE else { return result(.missingEffort) }

    let currentSets = min(work.count, setRange.upperBound)
    let currentReps = min(max(minimumReps, reps.range.lowerBound), reps.range.upperBound)
    func target(weight: Double = first.weightPounds, count: Int = currentSets, repCount: Int = currentReps) -> LiftProgressionTarget {
      LiftProgressionTarget(weightPounds: weight, reps: repCount, sets: count, repSuffix: reps.suffix)
    }

    if highestRPE >= 9.5 || minimumReps < reps.range.lowerBound {
      if let lower = steppedLoad(first.weightPounds, equipment: equipment, unit: unit, up: false) {
        return result(.reduceWeight, target(weight: lower, count: setRange.lowerBound, repCount: reps.range.lowerBound))
      }
      if currentReps > reps.range.lowerBound {
        return result(.reduceReps, target(count: setRange.lowerBound, repCount: currentReps - 1))
      }
      // Do not prescribe more repetitions than were completed when no defensible load reduction is available.
      return result(.repeatWork, minimumReps < reps.range.lowerBound ? nil : target())
    }
    guard highestRPE <= effortCeiling else { return result(.repeatWork, target()) }
    if minimumReps < reps.range.upperBound {
      return result(.addReps, target(repCount: minimumReps + 1))
    }
    if currentSets < setRange.upperBound {
      guard highestRPE <= min(effortCeiling, 7) else { return result(.repeatWork, target()) }
      return result(.addSet, target(count: currentSets + 1))
    }
    guard equipment != .bodyweight else { return result(.bodyweightCeiling, target()) }
    guard equipment.loadStep(in: unit) != nil else { return result(.unknownLoadStep, target()) }
    guard let higher = steppedLoad(first.weightPounds, equipment: equipment, unit: unit, up: true),
          first.weightPounds > 0,
          higher <= first.weightPounds * 1.1 + 0.000_001
    else { return result(.loadStepTooLarge, target()) }
    return result(.addWeight, target(weight: higher, repCount: reps.range.lowerBound))
  }

  static func prescribedReps(_ text: String) -> Int? {
    repPrescription(text)?.range.lowerBound
  }

  private static func steppedLoad(
    _ pounds: Double,
    equipment: LiftProgressionEquipment,
    unit: LiftProgressionUnit,
    up: Bool
  ) -> Double? {
    guard let step = equipment.loadStep(in: unit), pounds > 0 else { return nil }
    let quotient = unit.fromPounds(pounds) / step
    let steps = up ? (quotient + 1e-9).rounded(.down) + 1 : (quotient - 1e-9).rounded(.up) - 1
    let next = unit.toPounds(steps * step)
    guard next.isFinite, next > 0, next <= 10_000,
          up ? next > pounds : next < pounds else { return nil }
    return next
  }

  private static func repPrescription(_ text: String) -> (range: ClosedRange<Int>, suffix: String)? {
    var numeric = normalized(text)
    var suffix = ""
    for candidate in ["/leg", "/side", " total"] where numeric.hasSuffix(candidate) {
      suffix = candidate
      numeric = String(numeric.dropLast(candidate.count))
      break
    }
    guard let range = integerRange(numeric, maximum: 100) else { return nil }
    return (range, suffix)
  }

  private static func integerRange(_ text: String, maximum: Int) -> ClosedRange<Int>? {
    let pieces = normalized(text).replacingOccurrences(of: " ", with: "").split(separator: "-", omittingEmptySubsequences: false)
    guard (1...2).contains(pieces.count),
          pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0 >= "0" && $0 <= "9" } }),
          let lower = Int(pieces[0]), let upper = Int(pieces.last!),
          lower > 0, upper >= lower, upper <= maximum else { return nil }
    return lower...upper
  }

  private static func effortCeiling(_ text: String) -> Double? {
    var numeric = normalized(text).replacingOccurrences(of: " ", with: "")
    let isRIR = numeric.hasSuffix("rir")
    if isRIR { numeric = String(numeric.dropLast(3)) }
    else if numeric.hasPrefix("rpe") { numeric = String(numeric.dropFirst(3)) }
    let pieces = numeric.split(separator: "-", omittingEmptySubsequences: false)
    guard (1...2).contains(pieces.count),
          let lower = Double(pieces[0]), let upper = Double(pieces.last!),
          lower.isFinite, upper.isFinite, lower <= upper else { return nil }
    if isRIR {
      guard lower >= 0, upper <= 4 else { return nil }
      return min(8, 10 - upper)
    }
    guard lower >= 6, upper <= 10 else { return nil }
    return min(8, lower)
  }

  private static func normalized(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      .replacingOccurrences(of: "–", with: "-")
      .replacingOccurrences(of: "—", with: "-")
  }
}
