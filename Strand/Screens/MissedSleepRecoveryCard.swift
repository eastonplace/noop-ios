import SwiftUI
import Foundation
import StrandDesign

/// Seed carried into the existing SleepTimeEditor. The defaults describe the most
/// likely missed overnight window without claiming those times were measured.
struct MissedSleepWindowSeed: Identifiable, Equatable {
    let id = UUID()
    let start: Date
    let end: Date

    static func lastNight(now: Date = Date(), calendar: Calendar = .current) -> MissedSleepWindowSeed {
        let startOfToday = calendar.startOfDay(for: now)
        let nineAM = calendar.date(byAdding: .hour, value: 9, to: startOfToday) ?? now
        let end = min(now, nineAM)
        let start = calendar.date(byAdding: .hour, value: -8, to: end)
            ?? end.addingTimeInterval(-8 * 3_600)
        return MissedSleepWindowSeed(start: start, end: end)
    }
}

/// Alert payload for retry/manual-window outcomes. Kept separate from the store
/// result so the view owns presentation wording and the backend remains UI-free.
struct SleepRecoveryNotice: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}

/// Recovery-oriented empty state shown when NOOP has no sleep session to display.
/// It gives automatic detection one more chance, then lets the user constrain the
/// search window while making clear that NOOP still analyzes recorded physiology.
/// A flat section in the Sleep language: an eyebrow with a state pill, a line of what to do, the two actions
/// as chips, and the honesty note.
struct MissedSleepRecoveryCard: View {
    let isRetrying: Bool
    /// Guidance for a screen with no night at all; nil when only today's night is missing.
    var emptyDetail: String? = nil
    let onRetry: () -> Void
    let onSetWindow: () -> Void

    var body: some View {
        SleepSection(emptyDetail == nil ? "Today's sleep" : "Your sleep", systemImage: "moon.zzz.fill", tint: .sleep,
                     trailing: .pill(emptyDetail == nil ? "Not recorded yet" : "No nights yet", tone: .neutral)) {
            Text(emptyDetail.map { LocalizedStringKey($0) }
                 ?? "If you've finished sleeping, sync your strap or review the sleep window.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            SleepChipRow {
                SleepChipButton(title: isRetrying ? "Reviewing sleep…" : "Retry detection",
                                systemImage: "arrow.clockwise",
                                accessibilityLabel: "Retry sleep detection", action: onRetry)
                    .disabled(isRetrying)
                SleepChipButton(title: "Set sleep window", systemImage: "moon.stars",
                                accessibilityLabel: "Set sleep window", action: onSetWindow)
                    .disabled(isRetrying)
            }
            .opacity(isRetrying ? 0.55 : 1)
            Text("Missing sensor data stays unknown.")
                .font(StrandFont.micro)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }
}
