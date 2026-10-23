import SwiftUI
import StrandDesign

/// The Heads-Up line at the top of Today: one tappable row that opens the Heads-Up page, shown only for a raised read
/// or a logged "feeling sick". The full story lives in the Heads-Up card under Health Monitor and on its page.
/// Observes AppModel in isolation so the ~1 Hz HR stream re-renders only this small view, not the whole screen.
/// Renders nothing when there's nothing to say.
struct HealthAlertBanner: View {
    @EnvironmentObject var model: AppModel
    let onOpen: () -> Void

    var body: some View {
        if let line = HeadsUpPresentation.bannerLine(model.headsUp), let level = model.headsUp?.level {
            let tone = HeadsUpPresentation.tone(level)
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    Image(systemName: level == .alreadyUnwell ? "bed.double.fill" : "exclamationmark.triangle.fill")
                        .font(StrandFont.subhead.weight(.semibold))
                        .foregroundStyle(tone)
                        .accessibilityHidden(true)
                    Text(verbatim: line)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(StrandFont.caption.weight(.semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(tone.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tone.opacity(0.30), lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Opens Heads-Up"))
            .accessibilityIdentifier("today.headsUp.banner")
        }
    }
}
