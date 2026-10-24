import SwiftUI
import StrandDesign
import StrandAnalytics

/// The Heads-Up line at the top of Today: one tappable flat row (icon, line, chevron, a hairline below) that opens
/// the Heads-Up page, shown only for a raised read or a logged "feeling sick". The full story lives in the Heads-Up card under Health Monitor and on its page.
/// Observes AppModel in isolation so the ~1 Hz HR stream re-renders only this small view, not the whole screen.
/// Renders nothing when there's nothing to say.
struct HealthAlertBanner: View {
    @EnvironmentObject var model: AppModel
    let onOpen: () -> Void

    var body: some View {
        if let line = HeadsUpPresentation.bannerLine(model.headsUp), let level = model.headsUp?.level {
            let tone = HeadsUpPresentation.tone(level)
            Button(action: onOpen) {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Image(systemName: level == .alreadyUnwell ? "bed.double.fill" : "exclamationmark.triangle.fill")
                            .font(StrandFont.subhead.weight(.semibold))
                            .foregroundStyle(tone)
                            .accessibilityHidden(true)
                        Text(verbatim: line)
                            .font(StrandFont.subhead.weight(.medium))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(StrandFont.caption.weight(.semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 44)
                    // Flat like the rest of Today: a bare row closed by a hairline, no box and no border.
                    Rectangle().fill(StrandPalette.hairline)
                        .frame(height: 1)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Opens Heads-Up"))
            .accessibilityIdentifier("today.headsUp.banner")
        }
    }
}
