import StrandDesign
import SwiftUI

// MARK: - Live stats and Strain cards
//
// Phone 3's heart rate / Strain so far / Sets strip and the STRAIN SO FAR card. Both read the Strain provider's live
// vitals; with no provider or no strap data they show a dash and say so instead of a made-up number.

enum LiveStrainText {
  static func number(_ value: Double, locale: Locale) -> String {
    value.formatted(.number.precision(.fractionLength(1)).locale(locale))
  }
}

/// HEART RATE (bpm), STRAIN SO FAR and SETS done of planned.
struct LiveStatsStrip: View {
  let vitals: LiftLiveVitals?
  let workingSetsDone: Int
  let workingSetsPlanned: Int?

  @Environment(\.liftFormat) private var format

  var body: some View {
    StrengthStatStrip(items: items, eyebrowLabels: true)
  }

  private var items: [StrengthStatStrip.Item] {
    let bpm = vitals?.bpm
    return [
      .init(
        id: "hr", label: "Heart rate", value: bpm.map { $0.formatted(.number.locale(format.locale)) } ?? LiftFormat.missing,
        unit: bpm == nil ? nil : String(localized: "bpm"),
        caption: bpm == nil ? String(localized: "Strap not connected") : nil,
        valueTint: bpm == nil ? StrandPalette.textTertiary : StrandPalette.liveRed,
        captionTint: StrandPalette.textTertiary,
        spoken: bpm.map { String(localized: "\($0) beats per minute") } ?? String(localized: "Strap not connected")),
      .init(
        id: "strain", label: "Strain so far",
        value: vitals?.combinedDisplay.map { LiveStrainText.number($0, locale: format.locale) } ?? LiftFormat.missing,
        valueTint: vitals?.combinedDisplay == nil ? StrandPalette.textTertiary : StrandPalette.strainAccent,
        spoken: vitals?.combinedDisplay.map { String(localized: "\(LiveStrainText.number($0, locale: format.locale)) of 21") }
          ?? String(localized: "Not available")),
      .init(
        id: "sets", label: "Sets", value: workingSetsDone.formatted(.number.locale(format.locale)),
        unit: workingSetsPlanned.map { "/ \($0.formatted(.number.locale(format.locale)))" },
        spoken: workingSetsPlanned.map { String(localized: "\(workingSetsDone) of \($0) sets") }
          ?? LiftFormat.setCount(workingSetsDone)),
    ]
  }
}

/// STRAIN SO FAR: the live Strain over a split bar of what heart rate has scored and what your sets add.
struct LiveStrainCard: View {
  let vitals: LiftLiveVitals?

  @Environment(\.liftFormat) private var format
  @Environment(\.dynamicTypeSize) private var typeSize
  @ScaledMetric(relativeTo: .title3) private var valueSize: CGFloat = 22
  @ScaledMetric(relativeTo: .caption) private var labelSize: CGFloat = 12

  var body: some View {
    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
      HStack(alignment: .firstTextBaseline) {
        Text("Strain so far")
          .textCase(.uppercase)
          .tracking(1.6)
          .font(StrandFont.sized(labelSize, weight: .bold))
          .foregroundStyle(StrandPalette.textTertiary)
          .lineLimit(2)
        Spacer(minLength: NoopMetrics.space2)
        Text(verbatim: combined.map { LiveStrainText.number($0, locale: format.locale) } ?? LiftFormat.missing)
          .font(StrandFont.sized(valueSize, weight: .bold))
          .monospacedDigit()
          .foregroundStyle(combined == nil ? StrandPalette.textTertiary : StrandPalette.strainAccent)
      }
      if let heartRate, let combined {
        let add = max(combined - heartRate, 0)
        let scale = StrainScale.displayRange.upperBound
        StrengthSplitBar(segments: [
          .init(weight: heartRate / scale, color: StrandPalette.strainAccent),
          .init(weight: add / scale, color: StrandPalette.muscularAccent),
          .init(weight: max(scale - combined, 0) / scale, color: StrandPalette.surfaceInset),
        ])
        legend(heartRate: heartRate, add: add)
      } else {
        Text("Strap not connected")
          .font(StrandFont.caption)
          .foregroundStyle(StrandPalette.textTertiary)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(StrandPalette.card, in: RoundedRectangle(cornerRadius: NoopMetrics.radius2, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: NoopMetrics.radius2, style: .continuous).strokeBorder(StrandPalette.hairline, lineWidth: 1))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Strain so far")
    .accessibilityValue(Text(verbatim: spoken))
  }

  private var heartRate: Double? { vitals?.heartRateDisplay }
  private var combined: Double? { vitals?.combinedDisplay }

  private func legend(heartRate: Double, add: Double) -> some View {
    let hr = LiveStrainText.number(heartRate, locale: format.locale)
    let sets = LiveStrainText.number(add, locale: format.locale)
    return Group {
      if typeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 4) {
          legendItem(StrandPalette.strainAccent, "Heart rate \(hr)")
          legendItem(StrandPalette.muscularAccent, "Your sets add \(sets)")
        }
      } else {
        HStack(spacing: NoopMetrics.space4) {
          legendItem(StrandPalette.strainAccent, "Heart rate \(hr)")
          legendItem(StrandPalette.muscularAccent, "Your sets add \(sets)")
          Spacer(minLength: 0)
        }
      }
    }
  }

  private func legendItem(_ color: Color, _ text: LocalizedStringKey) -> some View {
    HStack(spacing: 6) {
      RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(color).frame(width: 10, height: 10)
      Text(text)
        .font(StrandFont.sized(labelSize, weight: .regular))
        .foregroundStyle(StrandPalette.textSecondary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
  }

  private var spoken: String {
    guard let heartRate, let combined else { return String(localized: "Strap not connected") }
    let n = { (v: Double) in LiveStrainText.number(v, locale: format.locale) }
    return String(localized: "\(n(combined)) of 21; heart rate \(n(heartRate)); your sets add \(n(max(combined - heartRate, 0)))")
  }
}

/// "● RECORDING · PUSH DAY": the live indicator, mint.
struct LiveRecordingEyebrow: View {
  let title: String

  @Environment(\.dynamicTypeSize) private var typeSize
  @ScaledMetric(relativeTo: .caption) private var size: CGFloat = 12

  var body: some View {
    HStack(spacing: 6) {
      Circle().fill(StrandPalette.accent).frame(width: 7, height: 7).accessibilityHidden(true)
      Text(verbatim: String(localized: "Recording") + " · " + title)
        .textCase(.uppercase)
        .tracking(1.2)
        .font(StrandFont.sized(size, weight: .bold))
        .foregroundStyle(StrandPalette.accent)
        .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
        .minimumScaleFactor(typeSize.isAccessibilitySize ? 1 : 0.6)
    }
    .accessibilityElement(children: .combine)
  }
}
