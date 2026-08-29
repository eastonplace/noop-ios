import SwiftUI
import StrandDesign

/// Lightweight owner for the persistent Settings tab.
///
/// The tab reads only low-frequency AppStorage values and a deduplicated connection edge.
/// The broad AppModel, LiveState, and ProfileStore subscriptions remain behind a selected
/// destination in SettingsDetailHost.
struct SettingsRootHost: View {
    @State private var connected = false

    @AppStorage(PuffinExperiment.powerSavingKey) private var powerSavingEnabled = false
    @AppStorage(PuffinExperiment.keepRealtimeForDataKey) private var continuousHrvEnabled = false
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(PuffinExperiment.autoDetectWorkoutsKey) private var autoDetectWorkoutsEnabled = false
    @AppStorage(PuffinExperiment.defaultsKey) private var puffinExperiments = false
    @AppStorage(PuffinExperiment.deepDataKey) private var deepDataEnabled = false

    var body: some View {
        SettingsRootView(status: rootStatus)
            .background(SettingsConnectionStatusBridge(connected: $connected))
            .navigationDestination(for: SettingsRouteID.self) { route in
                SettingsDetailHost(destination: route)
            }
    }

    private var rootStatus: SettingsRootStatus {
        var values: [SettingsRouteID: String] = [
            .whoop: connected ? String(localized: "Connected") : String(localized: "Not connected"),
            .syncBattery: powerSavingEnabled
                ? String(localized: "Power saving on")
                : (continuousHrvEnabled
                    ? String(localized: "Continuous HRV on")
                    : String(localized: "Standard")),
            .appearanceUnits: "\(appearanceLabel) · \(unitLabel)",
            .workoutPreferences: autoDetectWorkoutsEnabled
                ? String(localized: "Auto detect on")
                : String(localized: "Defaults"),
            .privacyDeletion: String(localized: "Local"),
            .about: bundleVersionString,
        ]
        if puffinExperiments || deepDataEnabled {
            values[.diagnosticsExperimental] = String(localized: "Experiments on")
        }
        return SettingsRootStatus(values: values)
    }

    private var appearanceLabel: String {
        (AppearanceMode(rawValue: appearanceRaw) ?? .system).label
    }

    private var unitLabel: String {
        UnitSystem(rawValue: unitSystemRaw) == .imperial
            ? String(localized: "US")
            : String(localized: "Metric")
    }

    private var bundleVersionString: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            ?? AppChangelog.currentVersion
    }
}

/// This leaf is intentionally the only Settings-root subscriber to LiveState.
/// It can redraw on a live sample, but it mutates the large parent only when the
/// Boolean connection state changes.
private struct SettingsConnectionStatusBridge: View {
    @EnvironmentObject private var live: LiveState
    @Binding var connected: Bool

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear {
                if connected != live.connected {
                    connected = live.connected
                }
            }
            .onChangeCompat(of: live.connected) { value in
                if connected != value {
                    connected = value
                }
            }
    }
}
