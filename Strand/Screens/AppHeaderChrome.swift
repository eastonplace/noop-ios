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
        let strap: AppStrapState = backfilling ? .syncing : (connected ? .live : .offline)
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
    @EnvironmentObject private var live: LiveState
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var updateStore: UpdateStore
    @EnvironmentObject private var profile: ProfileStore
    @EnvironmentObject private var router: NavRouter

    @State private var transientSyncState: AppSyncState = .idle

    private var chromeState: AppHeaderChromeState {
        AppHeaderChromeMapper.state(connected: live.connected, backfilling: live.backfilling,
                                    error: live.lastSyncError, transient: transientSyncState)
    }

    var body: some View {
        HeaderChromeRow(
            strapState: chromeState.strap,
            battery: live.batteryPct.map { Int($0.rounded()) },
            syncState: chromeState.sync,
            unreadCount: updateStore.unreadCount,
            initials: "",
            profileImage: profileImage,
            recovery: repo.today?.recovery,
            onStrap: router.openDevices,
            onSync: sync,
            onUpdates: router.openUpdates,
            onProfile: router.openSettings
        )
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
            await repo.refresh()
        }
    }
}
#else
enum AppHeaderChromeVisibility: Sendable { case visible, hidden }
extension EnvironmentValues { @Entry var appHeaderChromeVisibility: AppHeaderChromeVisibility = .hidden }
#endif
