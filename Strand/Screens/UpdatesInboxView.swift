import SwiftUI
import StrandDesign

// MARK: - Updates inbox
//
// A calm, newest-first log shared by the native Settings page and the standalone Updates sheet — release notes,
// "new data arrived" readings, strap heads-ups, and the Today info-cards the user swiped away (which
// can be restored from here). Tapping an actionable row routes via NavRouter; a dismissed-card row
// offers "Restore to Today". Everything is on-device and non-clinical — informational, never a verdict.
//
// Sheet idiom matches WhatsNewView: a FIXED macOS frame (a macOS sheet hosting a ScrollView collapses
// without one) and iOS presentationDetents via `noopSheetPresentation`.
extension EnvironmentValues {
    /// Closes the Settings sheet from any native destination without popping only its detail page.
    @Entry var settingsCloseAction: ScreenScaffoldCloseAction? = nil
}

struct UpdatesInboxView: View {
    enum Presentation {
        case sheet
        case settings
    }

    var presentation: Presentation = .sheet
    @EnvironmentObject var updateStore: UpdateStore
    @EnvironmentObject var router: NavRouter
    let onClose: () -> Void

    private var unread: [UpdateItem] { updateStore.sortedItems.filter { !$0.read } }
    private var read: [UpdateItem] { updateStore.sortedItems.filter { $0.read } }

    var body: some View {
        if presentation == .settings {
            nativeSettingsContent
        } else {
            sheetContent
        }
    }

    private var sheetContent: some View {
        ScreenScaffold(title: "Updates",
                       subtitle: LocalizedStringKey(subtitle),
                       trailing: { NoopIconButton("xmark", accessibilityLabel: "Close", action: onClose) }) {
            content
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !updateStore.items.isEmpty { footer.sheetFooterBar() }
        }
        .sheetScreenScaffoldEnvironment()
        #if os(macOS)
        // A fixed frame is mandatory — a macOS sheet hosting a ScrollView collapses to nothing without
        // one (same reason WhatsNewView pins 560×640).
        .frame(width: 460, height: 640)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .noopSheetPresentation(largeFirst: true)
        #endif
    }

    private var nativeSettingsContent: some View {
        NativeSettingsList {
            if updateStore.items.isEmpty {
                Section { emptyState }
            } else {
                if !unread.isEmpty {
                    nativeSection("NEW", items: unread)
                }
                if !read.isEmpty {
                    nativeSection("EARLIER", items: read)
                }
                Section {
                    Button("Mark all read", action: markAllRead)
                        .disabled(updateStore.unreadCount == 0)
                        .accessibilityIdentifier("settings.updates.markAllRead")
                    Button("Clear all", role: .destructive, action: clearAll)
                        .accessibilityIdentifier("settings.updates.clearAll")
                }
            }
        }
        .navigationTitle("Recent updates")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier("settings.recentUpdates")
    }

    private func nativeSection(_ label: LocalizedStringKey, items: [UpdateItem]) -> some View {
        Section {
            ForEach(items) { item in
                UpdateRow(item: item, native: true, onTap: { handleTap(item) }, onRestore: { restore(item) })
            }
        } header: {
            Text(label)
        }
    }

    private var subtitle: String {
        let n = updateStore.unreadCount
        if updateStore.items.isEmpty { return String(localized: "What's new in the app and your data") }
        return n == 0 ? String(localized: "All caught up") : String(localized: "\(n) unread")
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if updateStore.items.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                if !unread.isEmpty {
                    section("NEW", items: unread)
                }
                if !read.isEmpty {
                    section("EARLIER", items: read)
                }
            }
        }
    }

    private func section(_ label: LocalizedStringKey, items: [UpdateItem]) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            Text(label).strandOverline()
            ForEach(items) { item in
                UpdateRow(item: item, onTap: { handleTap(item) }, onRestore: { restore(item) })
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bell.slash")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
            Text("You're all caught up.")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("New release notes and fresh data will land here.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, NoopMetrics.space12)
        .padding(.horizontal, NoopMetrics.space8)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: NoopMetrics.space3) {
            Button(action: clearAll) {
                Label("Clear all", systemImage: "trash")
            }
            .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
            .disabled(updateStore.items.isEmpty)

            Button(action: markAllRead) {
                Text("Mark all read")
            }
            .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
            .disabled(updateStore.unreadCount == 0)
        }
    }

    // MARK: Actions

    private func clearAll() {
        StrandHaptic.selection.play()
        withAnimation(StrandMotion.interactive) { updateStore.clearAll() }
    }

    private func markAllRead() {
        StrandHaptic.selection.play()
        withAnimation(StrandMotion.interactive) { updateStore.markAllRead() }
    }

    /// Tapping a row marks it read, then routes if it carries a known deep link (else just stays open).
    private func handleTap(_ item: UpdateItem) {
        StrandHaptic.selection.play()
        withAnimation(StrandMotion.interactive) { updateStore.markRead(item.id) }
        guard let key = item.deepLink, let dest = NavRouter.Destination(deepLinkKey: key) else { return }
        router.requestedDestination = dest
        if presentation == .sheet {
            onClose()
        } else {
            // The shell closes Settings and waits for dismissal before presenting another sheet or workout.
            // Tab destinations only change selection, so they also need to release the Settings sheet here.
            switch dest {
            case .trends, .liveSession: onClose()
            default: break
            }
        }
    }

    /// Restore a dismissed Today card: flip its `@AppStorage` flag back (so it reappears), drop the
    /// inbox item, and close so the card is on screen.
    private func restore(_ item: UpdateItem) {
        StrandHaptic.selection.play()
        if let payload = item.restorePayload {
            // Clear the dismissed flag directly using the SAME key TodayView writes, so a Today that's
            // already mounted under the sheet picks the card back up immediately.
            UserDefaults.standard.set(false, forKey: TodayCardDismissal.flagKey(payload))
        }
        updateStore.requestRestore(item)
        onClose()
    }
}

// MARK: - Row

private struct UpdateRow: View {
    let item: UpdateItem
    var native = false
    let onTap: () -> Void
    let onRestore: () -> Void

    var body: some View {
        Group {
            if native {
                rowContent
            } else {
                PaperCard { rowContent }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .strandPressable()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(item.read ? "\(item.title). \(item.message)"
                                       : "Unread. \(item.title). \(item.message)")
    }

    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(StrandFont.headline)
                    .foregroundStyle(tint)
                    .frame(width: 24)
                    .padding(.top, 1)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(StrandFont.headline.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(item.message)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(relativeDate)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .padding(.top, 1)
                }
                Spacer(minLength: 0)
                if !item.read {
                    Circle().fill(StrandPalette.statusCritical)
                        .frame(width: 8, height: 8)
                        .padding(.top, 5)
                        .accessibilityHidden(true)
                }
            }
            if item.kind == .dismissedCard {
                Button(action: onRestore) {
                    Label("Restore to Today", systemImage: "arrow.uturn.up")
                        .font(StrandFont.subhead)
                }
                .buttonStyle(.plain)
                .foregroundStyle(StrandPalette.accent)
            }
        }
    }

    private var symbol: String {
        switch item.kind {
        case .dismissedCard: return "rectangle.on.rectangle"
        case .whatsNew:      return "sparkles"
        case .reading:       return "waveform.path.ecg"
        case .strapAlert:    return "exclamationmark.triangle"
        }
    }

    /// A per-kind tint drawn from the domain palette so each row reads in its own colour world.
    private var tint: Color {
        switch item.kind {
        case .dismissedCard: return StrandPalette.textSecondary
        case .whatsNew:      return StrandPalette.accent
        case .reading:       return StrandPalette.restColor
        case .strapAlert:    return StrandPalette.statusWarning
        }
    }

    private var relativeDate: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: item.date, relativeTo: Date())
    }
}

// MARK: - Today card dismissal keys (shared)
//
// The Today info-cards persist their dismissed state in `@AppStorage` under a stable per-card key. The
// inbox restores a card by clearing that same key, so the key shape lives in ONE place both sides use.
enum TodayCardDismissal {
    /// The `@AppStorage` bool key for a Today info-card's dismissed flag, by stable card id.
    static func flagKey(_ cardID: String) -> String { "noop.todayCard.\(cardID).dismissed" }
}
