import SwiftUI
import StrandDesign

/// "What's New" — shown automatically after an update and reachable any time from Settings → About.
///
/// A showcase, not a changelog page: the current version large, its changes as glanceable icon rows that rise in
/// one after another, then earlier releases folded away (tap to open), with the original NOOP's history in one
/// fold at the end.
struct WhatsNewView: View {
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false
    @State private var expanded: Set<String> = []

    private var forkReleases: [AppChangelog.Release] { AppChangelog.releases.filter { !$0.features.isEmpty } }
    private var upstreamReleases: [AppChangelog.Release] { AppChangelog.releases.filter { $0.features.isEmpty } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let current = forkReleases.first {
                    hero(current)
                        .padding(.bottom, 28)
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(Array(current.features.enumerated()), id: \.element.id) { index, feature in
                            featureRow(feature, size: 42)
                                .opacity(revealed ? 1 : 0)
                                .offset(y: revealed ? 0 : 14)
                                .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.85)
                                    .delay(0.08 + Double(index) * 0.05), value: revealed)
                        }
                    }
                }

                if forkReleases.count > 1 || !upstreamReleases.isEmpty {
                    Text("EARLIER")
                        .font(StrandFont.overline)
                        .tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .padding(.top, 40)
                        .padding(.bottom, 6)
                    ForEach(forkReleases.dropFirst()) { release in
                        fold(id: release.id, version: release.version, title: release.title, date: release.date) {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(release.features) { featureRow($0, size: 30) }
                            }
                        }
                    }
                    if !upstreamReleases.isEmpty {
                        fold(id: "upstream", version: "≤ 9.0.1", title: "Original NOOP", date: "Before the fork") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(upstreamReleases) { release in
                                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                                        Text(verbatim: release.version)
                                            .font(StrandFont.caption.monospacedDigit())
                                            .foregroundStyle(StrandPalette.textTertiary)
                                            .frame(width: 44, alignment: .leading)
                                        Text(release.title)
                                            .font(StrandFont.subhead)
                                            .foregroundStyle(StrandPalette.textSecondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 56)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(StrandPalette.appCanvas.ignoresSafeArea())
        .overlay(alignment: .topTrailing) {
            NoopIconButton("xmark", accessibilityLabel: "Close", action: onClose)
                .padding(16)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button(action: onClose) { Text("Continue") }
                .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
                .keyboardShortcut(.defaultAction)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(alignment: .top) {
                    // Rows fade out under the button instead of showing through it.
                    VStack(spacing: 0) {
                        LinearGradient(colors: [StrandPalette.appCanvas.opacity(0), StrandPalette.appCanvas],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: 28)
                            .offset(y: -28)
                        StrandPalette.appCanvas
                    }
                    .ignoresSafeArea()
                }
        }
        .onAppear { revealed = true }
        #if os(macOS)
        .frame(width: 560, height: 640)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .noopSheetPresentation(largeFirst: true)
        #endif
    }

    // MARK: Pieces

    private func hero(_ release: AppChangelog.Release) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("WHAT'S NEW")
                .font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.accent)
            Text(verbatim: release.version)
                .font(StrandFont.number(64, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(StrandPalette.textPrimary)
            Text(release.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
            Text(release.date)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("whatsNew.hero")
    }

    private func featureRow(_ feature: AppChangelog.Feature, size: CGFloat) -> some View {
        let tint = color(feature.tint)
        return HStack(alignment: .center, spacing: 14) {
            Image(systemName: feature.symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(Circle().fill(tint.opacity(0.16)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(feature.title)
                    .font(size > 36 ? .body.weight(.semibold) : .subheadline.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(feature.detail)
                    .font(size > 36 ? StrandFont.subhead : StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// One folded release: a row of version, title and date that opens to show what changed.
    private func fold<Content: View>(id: String, version: String, title: String, date: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        let isOpen = expanded.contains(id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.28)) {
                    if isOpen { expanded.remove(id) } else { expanded.insert(id) }
                }
            } label: {
                HStack(spacing: 12) {
                    Text(verbatim: version)
                        .font(StrandFont.number(15, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(StrandPalette.textPrimary)
                        .frame(minWidth: 52, alignment: .leading)
                    Text(title)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(date)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isOpen ? Text("Expanded") : Text("Collapsed"))
            if isOpen {
                content()
                    .padding(.bottom, 16)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            Rectangle()
                .fill(StrandPalette.hairline)
                .frame(height: 1)
        }
    }

    private func color(_ tint: AppChangelog.Feature.Tint) -> Color {
        switch tint {
        case .accent: DomainTint.accent.accent
        case .heart: DomainTint.heart.accent
        case .strain: DomainTint.strain.accent
        case .sleep: DomainTint.sleep.accent
        case .stress: DomainTint.stress.accent
        case .journal: DomainTint.journal.accent
        case .hrv: DomainTint.hrv.accent
        }
    }
}
