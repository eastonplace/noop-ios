import StrandDesign
import SwiftUI

enum LiftPRPresentation {
  nonisolated static func stampText(
    outcome: LiftSetOutcome,
    exercise: LiftExercise,
    enabled: Bool,
    format: LiftFormat
  ) -> String {
    let set = outcome.set
    let load = format.load(pounds: set.weight, for: exercise)
    let base = String(localized: "\(load) × \(set.reps) added to receipt").uppercased()
    guard enabled, outcome.personalRecord != nil else { return base }
    return LiftFormat.facts([base, String(localized: "PR")])
  }

  nonisolated static func label(for record: LiftPersonalRecord) -> String {
    switch record.kind {
    case .estimatedOneRepMax:
      String(localized: "PR (est. 1RM)")
    case .reps:
      String(localized: "PR (reps)")
    }
  }

  nonisolated static func valueText(for record: LiftPersonalRecord, format: LiftFormat) -> String {
    switch record.kind {
    case .estimatedOneRepMax:
      format.volume(pounds: record.value)
    case .reps:
      String(localized: "\(format.number(inUnit: record.value)) reps")
    }
  }
}

/// The tonal "PR" tag beside a record set in chrome lists.
struct LiftPRBadge: View {
  let record: LiftPersonalRecord

  var body: some View {
    LiftTag(text: LocalizedStringKey(LiftPRPresentation.label(for: record)))
      .accessibilityLabel(LiftPRPresentation.label(for: record))
  }
}

/// A personal-record line. Chrome screens show it in the canonical tonal style; the receipt artifact
/// passes `artifact: true` to keep its monospaced ink-on-paper rule.
struct LiftPRPayoffView: View {
  let record: LiftPersonalRecord
  var artifact = false

  @Environment(\.liftFormat) private var format

  var body: some View {
    if artifact {
      artifactBody
    } else {
      chromeBody
    }
  }

  private var chromeBody: some View {
    HStack(alignment: .center, spacing: NoopMetrics.space3) {
      Image(systemName: "trophy.fill")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(DomainTint.workout.accent)
        .frame(width: 32, height: 32)
        .background(Circle().fill(DomainTint.workout.accent.opacity(0.14)))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: LiftPRPresentation.label(for: record))
          .font(StrandFont.caption.weight(.semibold))
          .foregroundStyle(StrandPalette.textSecondary)
        UnitValueText(value: LiftPRPresentation.valueText(for: record, format: format), size: 17)
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(LiftPRPresentation.label(for: record))
    .accessibilityValue(LiftPRPresentation.valueText(for: record, format: format))
  }

  private var artifactBody: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: "trophy.fill")
        .font(.system(size: 11, weight: .black))
        .accessibilityHidden(true)
      Text(LiftPRPresentation.label(for: record).uppercased())
        .font(.receiptArtifact(10, weight: .black))
        .tracking(0.4)
      Spacer(minLength: 8)
      Text(LiftPRPresentation.valueText(for: record, format: format).uppercased())
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
