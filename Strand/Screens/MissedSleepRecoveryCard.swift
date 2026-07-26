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
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.blue.opacity(0.12))
                        .frame(width: 52, height: 52)
                    Image(systemName: "moon.stars.fill")
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(.blue)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Sleep was not detected")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("A short night, elevated heart rate, or incomplete sensor coverage can make automatic detection uncertain.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 10) {
                recoveryStep(icon: "arrow.clockwise", label: "Retry detection")
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
                recoveryStep(icon: "slider.horizontal.3", label: "Set a window")
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
                recoveryStep(icon: "waveform.path.ecg", label: "Reprocess data")
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Retry detection, set a sleep window, then reprocess recorded data")

            VStack(spacing: 10) {
                Button(action: onRetry) {
                    HStack(spacing: 9) {
                        if isRetrying {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(isRetrying ? "Reviewing last night…" : "Retry automatic detection")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isRetrying)

                Button(action: onSetWindow) {
                    Label("Set the sleep window", systemImage: "clock.badge.checkmark")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isRetrying)
            }

            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                    .padding(.top, 1)
                Text("Your times only narrow the search. NOOP still derives sleep stages, resting heart rate, HRV, Rest, and Charge from the data actually recorded inside that window. Missing signals stay missing.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private func recoveryStep(icon: String, label: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.blue)
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(StrandPalette.textTertiary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
    }
}
