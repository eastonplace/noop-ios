import SwiftUI

enum LiftPRPresentation {
  nonisolated static func stampText(
    outcome: LiftSetOutcome,
    exercise: LiftExercise,
    enabled: Bool
  ) -> String {
    let set = outcome.set
    let load = liftLoad(set.weight, for: exercise).uppercased()
    let suffix = enabled && outcome.personalRecord != nil ? " \u{00B7} PR" : ""
    return "\(load) \u{00D7} \(set.reps) ADDED TO RECEIPT\(suffix)"
  }

  nonisolated static func label(for record: LiftPersonalRecord) -> String {
    switch record.kind {
    case .estimatedOneRepMax:
      "PR (EST. 1RM)"
    case .reps:
      "PR (REPS)"
    }
  }

  nonisolated static func valueText(for record: LiftPersonalRecord) -> String {
    switch record.kind {
    case .estimatedOneRepMax:
      liftVolume(record.value).uppercased()
    case .reps:
      "\(wholeOrDecimal(record.value)) REPS"
    }
  }

  private nonisolated static func wholeOrDecimal(_ value: Double) -> String {
    if value.rounded() == value {
      return String(Int(value))
    }
    return String(format: "%.1f", value)
  }
}

struct LiftPRBadge: View {
  let record: LiftPersonalRecord

  var body: some View {
    Text(LiftPRPresentation.label(for: record))
      .font(.receipt(9, weight: .black))
      .tracking(0.5)
      .foregroundStyle(LiftTheme.paper)
      .padding(.horizontal, 7)
      .frame(minHeight: 24)
      .background(LiftTheme.ink)
      .accessibilityLabel(LiftPRPresentation.label(for: record))
  }
}

struct LiftPRPayoffView: View {
  let record: LiftPersonalRecord

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: "trophy.fill")
        .font(.system(size: 11, weight: .black))
        .accessibilityHidden(true)
      Text(LiftPRPresentation.label(for: record))
        .font(.receipt(10, weight: .black))
        .tracking(0.4)
      Spacer(minLength: 8)
      Text(LiftPRPresentation.valueText(for: record))
        .font(.receipt(12, weight: .black))
        .monospacedDigit()
    }
    .foregroundStyle(LiftTheme.ink)
    .padding(.vertical, 8)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(LiftTheme.ink)
        .frame(height: 1)
    }
    .accessibilityElement(children: .combine)
  }
}
