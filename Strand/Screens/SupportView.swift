import SwiftUI
import StrandDesign

/// Support — attribution + optional crypto donations. Never a paywall; the whole app works without it.
struct SupportView: View {
    @State private var copied: String?
    @State private var selected = "BTC"

    var body: some View {
        ScreenScaffold(title: "Support",
                       subtitle: "We're here to help.") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                    SectionHeader("Support the build")
                    donateCard
                }
                .staggeredAppear(index: 0)
                VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                    SectionHeader("Help & Contact")
                    contactCard
                }
                .staggeredAppear(index: 1)
                disclaimerCard
                    .staggeredAppear(index: 2)
            }
        }
    }

    /// One hairline-divided row inside a grouped frosted card: a tinted leading glyph, a title +
    /// detail stack, and a trailing accent chevron when the row taps through to an action.
    @ViewBuilder
    private func groupedRow(icon: String, tint: Color, title: LocalizedStringKey,
                            detail: String, showsChevron: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                Text(detail).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StrandPalette.accent)
                    .accessibilityHidden(true)
            }
        }
    }

    private var contactCard: some View {
        PaperCard(padding: 14) {
            VStack(spacing: 0) {
                supportMailRow(icon: "questionmark.circle", title: "Help Center", subject: "NOOP help")
                Divider().overlay(StrandPalette.hairline)
                supportMailRow(icon: "envelope", title: "Report an Issue", subject: "NOOP issue")
                Divider().overlay(StrandPalette.hairline)
                supportMailRow(icon: "lightbulb", title: "Request a Feature", subject: "NOOP feature request")
            }
        }
    }

    private func supportMailRow(icon: String, title: LocalizedStringKey, subject: String) -> some View {
        Button {
            let encoded = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? subject
            if let url = URL(string: "mailto:\(ProjectInfo.contactEmail)?subject=\(encoded)") {
                PlatformOpen.url(url)
            }
        } label: {
            SettingsRow(icon: icon, title: title)
        }
        .buttonStyle(.plain)
    }

    private var builtOnCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "hands.clap.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(StrandPalette.accent)
                        .frame(width: 28, height: 28)
                        .background(StrandPalette.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityHidden(true)
                    Text("Built on").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                }
                Text("This stands on community reverse-engineering. Huge thanks:")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                ForEach(Array(ProjectInfo.attributions.enumerated()), id: \.element.repo) { index, a in
                    if index > 0 { Divider().overlay(StrandPalette.hairline) }
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(StrandPalette.accent).accessibilityHidden(true)
                        Text(a.repo).font(StrandFont.mono(12)).foregroundStyle(StrandPalette.textPrimary)
                        Text("· \(a.note)").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private var donateCard: some View {
        PaperCard {
            VStack(alignment: .center, spacing: 14) {
                Text("NOOP is independent.\nYour support keeps it going.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                HStack(spacing: NoopMetrics.space2) {
                    ForEach(ProjectInfo.donations) { coin in
                        let on = selected == coin.symbol
                        Button { withAnimation(.easeOut(duration: 0.15)) { selected = coin.symbol } } label: {
                            Text(coin.symbol).font(StrandFont.rounded(12, weight: .bold))
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(Capsule().fill(on ? StrandPalette.accent : StrandPalette.surfaceInset))
                                .foregroundStyle(on ? StrandPalette.surfaceBase : StrandPalette.textSecondary)
                                .overlay(Capsule().strokeBorder(on ? Color.clear : StrandPalette.hairline, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Show \(coin.name) donation address")
                    }
                    Spacer(minLength: 0)
                }

                if let coin = ProjectInfo.donations.first(where: { $0.symbol == selected }) {
                    PrimaryButton("Support NOOP") {
                        PlatformPasteboard.copy(coin.address)
                        withAnimation { copied = coin.symbol }
                    }
                    .accessibilityHint("Copies the selected donation address")
                    qrView(coin.address)
                    Text(copied == coin.symbol ? "Address copied · Thank you! ♥" : "Thank you! ♥")
                        .font(StrandFont.micro)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .multilineTextAlignment(.center)
                    Text(coin.address)
                        .font(StrandFont.mono(10))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                        }
            }
        }
    }

    /// Black-on-white QR so wallet cameras read it cleanly against the dark UI.
    private func qrView(_ address: String) -> some View {
        Group {
            if let img = QRCode.image(for: address) {
                Image(platformImage: img).resizable().interpolation(.none)
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StrandPalette.surfaceInset)
            }
        }
        .frame(width: 150, height: 150)
        .padding(10)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityLabel("Donation QR code")
    }

    private var disclaimerCard: some View {
        NoteCard("NOOP works offline. Your data stays on your device. We respect your privacy.",
                 title: "Privacy First", style: .privacy)
    }
}

/// Hosts ``SupportView`` as a centred panel over a dimmed backdrop. Clicking anywhere
/// outside the panel — or pressing Esc, or the ✕ — closes it. Taps on the panel itself
/// are absorbed (the panel is opaque) so its controls keep working.
struct SupportModalOverlay: View {
    @Binding var isPresented: Bool

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.45))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { isPresented = false }

            SupportView()
                .frame(width: 560, height: 680)
                .background(StrandPalette.surfaceBase,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(StrandPalette.hairline, lineWidth: 1)
                )
                .overlay(alignment: .topTrailing) {
                    Button { isPresented = false } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .padding(12)
                    }
                    .buttonStyle(.plain)
                    .help("Close")
                    .accessibilityLabel("Close Support")
                }
                .shadow(color: Color.black.opacity(0.5), radius: 30, x: 0, y: 14)
        }
        #if os(macOS)
        .onExitCommand { isPresented = false }   // Esc-to-close is a macOS-only command
        #endif
        .transition(.opacity)
    }
}
