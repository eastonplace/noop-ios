import SwiftUI
import StrandDesign

/// "What's New" — a proper in-app changelog, shown automatically after an update and reachable any
/// time from Settings. The release-candidate card is intentionally maintained here, separate from the
/// historical changelog model, so repository release-line names never overwrite the public bundle version.
struct WhatsNewView: View {
    let onClose: () -> Void

    private let ios21Highlights = [
        "Recover a missed night by retrying automatic detection or setting an approximate sleep window. NOOP reprocesses recorded physiology instead of inventing stages or vitals.",
        "Improved WHOOP 5/MG compatibility, device identification, raw-frame validation, and fail-closed handling for unsupported protocol families.",
        "A clearly separated SpO₂ Candidate (Beta) surface for experimental WHOOP 5/MG evidence. It never feeds Blood Oxygen, Apple Health, Charge, illness detection, or medical claims.",
        "Additional local-data integrity, privacy deletion, persistence, accessibility, and performance hardening across sleep, imports, widgets, and background processing."
    ]

    var body: some View {
        // PERF: the changelog grows with every release, so build off-screen cards lazily.
        ScreenScaffold(title: "NOOP \(AppChangelog.currentVersion)",
                       subtitle: "iOS 2.1 release candidate",
                       lazy: true,
                       trailing: { NoopIconButton("xmark", accessibilityLabel: "Close", action: onClose) }) {
            ios21ReleaseCard
            expectationsCard
            ForEach(Array(AppChangelog.releases.enumerated()), id: \.element.id) { index, release in
                releaseCard(release, isLatest: index == 0)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer.sheetFooterBar() }
        .sheetScreenScaffoldEnvironment()
        #if os(macOS)
        .frame(width: 560, height: 640)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .noopSheetPresentation(largeFirst: true)
        #endif
    }

    private var ios21ReleaseCard: some View {
        PaperCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    SourceBadge("iOS 2.1")
                    Text("More reliable sleep and WHOOP data")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    Text("Release candidate")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }

                Text("This update combines the live WHOOP compatibility work and missed-sleep recovery into one local-first iPhone release.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(Array(ios21Highlights.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(StrandPalette.accent)
                            .padding(.top, 2)
                        Text(item)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Text("Experimental features remain opt-in and clearly labelled. NOOP is not a medical device, and this build should complete simulator and physical-device QA before release.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var expectationsCard: some View {
        PaperCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("WHAT TO EXPECT").font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                ForEach(AppChangelog.expectations) { expectation in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: expectation.icon)
                            .foregroundStyle(StrandPalette.accent)
                            .frame(width: 22)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(expectation.title).font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text(expectation.body).font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func releaseCard(_ release: AppChangelog.Release, isLatest: Bool = false) -> some View {
        PaperCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    SourceBadge("v\(release.version)")
                    Text(release.title).font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    Text(release.date).font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                ForEach(Array(release.items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(StrandPalette.accent).frame(width: 5, height: 5)
                            .padding(.top, 7)
                        Text(item).font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        Button(action: onClose) {
            Text("Got it")
        }
        .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
        .keyboardShortcut(.defaultAction)
    }
}
