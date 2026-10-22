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
            SectionEyebrow(title: words("Coach"), systemImage: "sparkles", tint: .accent)
            if let text, let generatedAt {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(verbatim: evening ? words("Evening brief") : words("Morning brief"))
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                            .lineLimit(1).minimumScaleFactor(0.85)
                        Text(verbatim: text).font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .lineLimit(compact ? 3 : 4)
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
                Text("Open Coach to create today’s brief.", bundle: .module)
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
#endif
