import SwiftUI
import StrandDesign
#if os(macOS)
import AppKit
#endif

@main
struct StrandApp: App {
    init() {
        #if DEBUG
        DemoDayHarness.applyLaunchArgsIfNeeded()
        #endif
    }

    @StateObject private var model = AppModel()
    @StateObject private var router = NavRouter()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue
    @AppStorage(ChartStyle.storageKey) private var chartStyleRaw = ChartStyle.titanium.rawValue

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.live)
                .environmentObject(model.repo)
                .environmentObject(model.profile)
                .environmentObject(model.behavior)
                .environmentObject(model.intelligence)
                .environmentObject(model.coach)
                .environmentObject(router)
                .environmentObject(UpdateStore.shared)
                .environment(\.stressNudgeCenter, model.stressNudgeCenter)
                .frame(minWidth: 1000, minHeight: 700)
                .preferredColorScheme(AppearanceMode.resolve(appearanceRaw).colorScheme)
                .chartStyle(chartStyleRaw)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { Task { await model.live.flushLogPersistence() } }
                }
                #if os(macOS)
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.willTerminateNotification
                )) { _ in
                    Task { await model.live.flushLogPersistence() }
                }
                #endif
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 820)

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(model)
                .environmentObject(model.repo)
                .environmentObject(model.live)
        } label: {
            MenuBarLabel()
                .environmentObject(model)
                .environmentObject(model.repo)
                .environmentObject(model.live)
        }
        .menuBarExtraStyle(.window)
    }
}
