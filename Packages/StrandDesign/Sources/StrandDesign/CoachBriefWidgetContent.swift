#if !os(watchOS)
import SwiftUI

/// Uses the same graphite surface, eyebrow and type roles as the app's existing Home Screen widgets.
public struct NOOPCoachBriefWidgetContent: View {
    public let text: String?
    public let generatedAt: Date?
    public let evening: Bool
    public let recovery: Int?
    public let strain: Double?
    public let sleepMinutes: Int?
    public let compact: Bool

    public init(text: String?, generatedAt: Date?, evening: Bool, recovery: Int?,
                strain: Double?, sleepMinutes: Int?, compact: Bool) {
        self.text = text; self.generatedAt = generatedAt; self.evening = evening
        self.recovery = recovery; self.strain = strain; self.sleepMinutes = sleepMinutes; self.compact = compact
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionEyebrow(title: words("Coach"), systemImage: "bubble.left.and.text.bubble.right", tint: .accent)
            if let text, let generatedAt {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(verbatim: evening ? words("Evening brief") : words("Morning brief"))
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                            .lineLimit(1).minimumScaleFactor(0.85)
                        Text(verbatim: text).font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !compact {
                        VStack(alignment: .trailing, spacing: 4) {
                            metric(words("Recovery"), value: recovery.map { "\($0)%" })
                            metric(words("Strain"), value: strain.map { ComponentValueFormat.oneDecimal($0) })
                            metric(words("Sleep"), value: sleepMinutes.map {
                                String(localized: "\($0 / 60)h \($0 % 60)m", bundle: .module)
                            })
                        }
                        .frame(minWidth: 64)
                        .layoutPriority(1)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Text("Generated", bundle: .module)
                    Text(generatedAt, style: .time)
                }
                .font(StrandFont.overline).foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1).accessibilityElement(children: .combine)
            } else {
                Text("Your daily brief", bundle: .module)
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                Text("Open Coach for today’s brief.", bundle: .module)
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .privacySensitive()
    }

    private func words(_ key: String.LocalizationValue) -> String { String(localized: key, bundle: .module) }

    private func metric(_ label: String, value: String?) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(verbatim: value ?? WidgetMetrics.missingValue)
                .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textPrimary)
            Text(verbatim: label).font(StrandFont.overline).foregroundStyle(StrandPalette.textTertiary)
        }
        .lineLimit(1).minimumScaleFactor(0.8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(label), \(value ?? words("Unavailable"))"))
    }
}

#if DEBUG
// The widget draws on a graphite card; this stands in for it so the populated and empty looks can be checked here.
private struct CoachBriefWidgetPreviewCard: View {
    let width: CGFloat
    let populated: Bool
    var body: some View {
        NOOPCoachBriefWidgetContent(
            text: populated
                ? "Recovery is high and you slept well. A solid day to train hard, then keep the evening easy so tomorrow starts fresh."
                : nil,
            generatedAt: populated ? Date() : nil, evening: false,
            recovery: populated ? 82 : nil, strain: populated ? 11.4 : nil, sleepMinutes: populated ? 452 : nil,
            compact: width < 200)
            .padding(16)
            .frame(width: width, height: 158)
            .background(StrandPalette.card)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

#Preview("Small") { CoachBriefWidgetPreviewCard(width: 158, populated: true).padding().background(StrandPalette.canvas) }
#Preview("Medium") { CoachBriefWidgetPreviewCard(width: 338, populated: true).padding().background(StrandPalette.canvas) }
#Preview("Empty, small and medium") {
    VStack(spacing: 12) {
        CoachBriefWidgetPreviewCard(width: 158, populated: false)
        CoachBriefWidgetPreviewCard(width: 338, populated: false)
    }
    .padding().background(StrandPalette.canvas)
}
#endif
#endif
