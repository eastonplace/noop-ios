import SwiftUI
import StrandDesign

/// "What's New" — a proper in-app changelog, shown automatically after an update and reachable any
/// time from Settings. The release-candidate card is intentionally maintained here, separate from the
/// historical changelog model, so repository release-line names never overwrite the public bundle version.
struct WhatsNewView: View {
    let onClose: () -> Void

    var body: some View {
        // PERF: the changelog grows with every release, so build off-screen cards lazily.
        ScreenScaffold(title: "NOOP \(AppChangelog.currentVersion)",
                       subtitle: "Every release, newest first",
                       lazy: true,
                       trailing: { NoopIconButton("xmark", accessibilityLabel: "Close", action: onClose) }) {
            ForEach(Array(AppChangelog.releases.enumerated()), id: \.element.id) { index, release in
                if release.version == AppChangelog.firstUpstreamVersion {
                    upstreamDivider
                }
                releaseCard(release, isLatest: index == 0)
            }
            expectationsCard
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

    /// Marks where this app's own history ends and the upstream NOOP releases it was forked from begin.
    private var upstreamDivider: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("BEFORE THE FORK").font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textSecondary)
            Text("Releases of the original open-source NOOP, which this app was forked from at 9.0.1.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12)
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
                        // Items carry **bold** lead-ins: render them as Markdown, not literal asterisks.
                        Text((try? AttributedString(markdown: item)) ?? AttributedString(item))
                            .font(StrandFont.subhead)
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
