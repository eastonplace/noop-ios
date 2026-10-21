import SwiftUI
import StrandDesign

#if os(iOS)
enum AppHeaderChromeVisibility: Sendable { case visible, hidden }

extension EnvironmentValues {
    @Entry var appHeaderChromeVisibility: AppHeaderChromeVisibility = .visible
}

struct AppHeaderChromeState: Equatable {
    let strap: AppStrapState
    let sync: AppSyncState
}

enum AppHeaderChromeMapper {
    static func state(connected: Bool, backfilling: Bool, error: String?,
                      transient: AppSyncState) -> AppHeaderChromeState {
        let strap: AppStrapState = connected ? .live : .offline
        let sync: AppSyncState
        if backfilling { sync = .syncing }
        else if error != nil { sync = .error }
        else { sync = transient }
        return AppHeaderChromeState(strap: strap, sync: sync)
    }
}

/// Leaf observer for the pinned app chrome. LiveState's frequent writes stop here instead of
/// invalidating ScreenScaffold or the content screen beneath it.
struct AppHeaderChrome: View {
    let title: LocalizedStringKey
    /// Only this small, optional accessory is erased; live state stays in the header's leaf observer.
    var titleActions: AnyView? = nil
    /// Inline control after the title (Today's date).
    var titleAccessory: AnyView? = nil
    /// Today opts the status line into the quick-status popover.
    var showsStatusPanel: Bool = false

    @EnvironmentObject private var live: LiveState
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @EnvironmentObject private var router: NavRouter

    @State private var transientSyncState: AppSyncState = .idle
    @State private var statusExpanded = false

    private var chromeState: AppHeaderChromeState {
        AppHeaderChromeMapper.state(connected: live.connected, backfilling: live.backfilling,
                                    error: live.lastSyncError, transient: transientSyncState)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeaderChromeRow(
                title: title,
                strapState: chromeState.strap,
                battery: live.batteryPct.map { Int($0.rounded()) },
                syncState: chromeState.sync,
                syncCompletedUnits: live.backfilling ? live.syncChunksThisSession : nil,
                initials: "",
                profileImage: profileImage,
                recovery: repo.today?.recovery,
                onStrap: { router.openSettings(.whoop) },
                onSync: sync,
                onProfile: { router.openSettings() },
                titleActions: titleActions,
                titleAccessory: titleAccessory,
                statusExpanded: showsStatusPanel ? $statusExpanded : nil
            )
            if showsStatusPanel && statusExpanded {
                DeviceStatusPanel()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipped()
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(StrandPalette.appCanvas)
        .overlay(alignment: .bottom) { Rectangle().fill(StrandPalette.hairline).frame(height: 1) }
        .onChange(of: live.lastSyncedAt) { _, timestamp in
            guard timestamp != nil else { return }
            transientSyncState = .done
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                if transientSyncState == .done { transientSyncState = .idle }
            }
        }
    }

    private var profileImage: Image? {
        guard let data = profile.avatarImageData, let image = UIImage(data: data) else { return nil }
        return Image(uiImage: image)
    }

    private func sync() {
        guard transientSyncState != .syncing else { return }
        transientSyncState = .syncing
        model.ble.syncNow()
        Task {
            _ = await repo.refresh(.currentDay)
        }
    }
}

/// The panel the Today status line expands inline under the header. Every action reuses an existing call:
/// "Test vibration" is the Smart Alarm / Live "Buzz strap" `AppModel.buzzStrapOnce()`, "Sync now" is the
/// Health screen's `BLEManager.syncNow()` , and "Device settings" is the route
/// the header used to open directly.
private struct DeviceStatusPanel: View {
    @EnvironmentObject private var live: LiveState
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var router: NavRouter
    @EnvironmentObject private var repo: Repository

    private var syncValue: String {
        if live.backfilling {
            let n = live.syncChunksThisSession
            return n > 0 ? "Syncing, \(n) chunk\(n == 1 ? "" : "s") pulled" : "Syncing"
        }
        if live.lastSyncError != nil { return "Sync failed" }
        return live.connected ? "Caught up" : "Not syncing"
    }

    private var lastSyncValue: String {
        live.lastSyncedAt.map { relativeAgo($0) } ?? "Never"
    }

    private var batteryValue: String {
        guard let pct = live.batteryPct else { return "--" }
        return "\(Int(pct.rounded()))%" + (live.charging == true ? " charging" : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("Strap", live.connected ? "Connected" : "Disconnected", dot: live.connected)
            row("Battery", batteryValue)
            row("Live heart rate", live.streamingLiveHR ? "Streaming" : "Not streaming")
            row("Sync", syncValue)
            row("Last sync", lastSyncValue)
            Rectangle().fill(StrandPalette.hairline).frame(height: 1).padding(.vertical, 8)
            HStack(spacing: 8) {
                action("Test vibration", "waveform") { model.buzzStrapOnce() }
                    .disabled(!live.connected)
                action(live.backfilling ? "Syncing" : "Sync now", "arrow.triangle.2.circlepath") {
                    model.ble.syncNow()
                    Task { _ = await repo.refresh(.currentDay) }
                }
                    .disabled(!live.connected || live.backfilling)
            }
            Button {
                router.openSettings(.whoop)
            } label: {
                HStack(spacing: 4) {
                    Text("Device settings")
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                }
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 6)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("app.statusPanel")
    }

    private func row(_ title: LocalizedStringKey, _ value: String, dot: Bool? = nil) -> some View {
        HStack(spacing: 8) {
            Text(title).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            Spacer(minLength: 8)
            if let dot {
                Circle().fill(dot ? StrandPalette.statusPositive : StrandPalette.textTertiary)
                    .frame(width: 6, height: 6)
            }
            Text(verbatim: value).font(StrandFont.caption.weight(.medium)).foregroundStyle(StrandPalette.textPrimary)
        }
        .frame(minHeight: 28)
    }

    private func action(_ title: LocalizedStringKey, _ symbol: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: symbol)
                .font(StrandFont.caption.weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(StrandPalette.surfaceInset))
        }
        .buttonStyle(.plain)
    }
}
#else
enum AppHeaderChromeVisibility: Sendable { case visible, hidden }
extension EnvironmentValues { @Entry var appHeaderChromeVisibility: AppHeaderChromeVisibility = .hidden }
#endif
