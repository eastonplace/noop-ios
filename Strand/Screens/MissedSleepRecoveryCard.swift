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
struct MissedSleepRecoveryCard: View {
    let isRetrying: Bool
    let onRetry: () -> Void
    let onSetWindow: () -> Void

    var body: some View {
        PaperCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("No sleep recorded for today yet", systemImage: "moon.stars")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("If you've finished sleeping, sync your strap or review the sleep window.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                VStack(alignment: .leading, spacing: 12) {
                    Button(action: onRetry) {
                        Label(isRetrying ? "Reviewing sleep…" : "Retry detection", systemImage: "arrow.clockwise")
                    }
                    .disabled(isRetrying)
                    Button("Set sleep window", action: onSetWindow)
                        .disabled(isRetrying)
                }
                .buttonStyle(.bordered)
                .font(StrandFont.subhead)
                Text("Missing sensor data stays unknown.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }
}
