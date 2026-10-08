import StrandDesign
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

/// The tonal "PR" tag beside a record set in chrome lists.
struct LiftPRBadge: View {
  let record: LiftPersonalRecord

  var body: some View {
    LiftBadge(text: LiftPRPresentation.label(for: record))
      .accessibilityLabel(LiftPRPresentation.label(for: record))
  }
}

/// A personal-record line. Chrome screens show it in the canonical tonal style; the receipt artifact
/// passes `artifact: true` to keep its monospaced ink-on-paper rule.
struct LiftPRPayoffView: View {
  let record: LiftPersonalRecord
  var artifact = false

  var body: some View {
    if artifact {
      artifactBody
    } else {
      chromeBody
    }
  }

  private var chromeBody: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: "trophy.fill")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(StrandPalette.accent)
        .accessibilityHidden(true)
      Text(LiftPRPresentation.label(for: record))
        .font(StrandFont.caption.weight(.semibold))
        .foregroundStyle(StrandPalette.textPrimary)
      Spacer(minLength: 8)
      Text(LiftPRPresentation.valueText(for: record).lowercased())
        .font(StrandFont.number(14))
        .foregroundStyle(StrandPalette.textPrimary)
    }
    .padding(.vertical, 8)
    .accessibilityElement(children: .combine)
  }

  private var artifactBody: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: "trophy.fill")
        .font(.system(size: 11, weight: .black))
        .accessibilityHidden(true)
      Text(LiftPRPresentation.label(for: record))
        .font(.receiptArtifact(10, weight: .black))
        .tracking(0.4)
      Spacer(minLength: 8)
      Text(LiftPRPresentation.valueText(for: record))
        .font(.receiptArtifact(12, weight: .black))
        .monospacedDigit()
    }
    .foregroundStyle(LiftTheme.Receipt.ink)
    .padding(.vertical, 8)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(LiftTheme.Receipt.ink)
        .frame(height: 1)
    }
    .accessibilityElement(children: .combine)
  }
}
