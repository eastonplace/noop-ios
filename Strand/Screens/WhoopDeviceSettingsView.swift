import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopProtocol
import WhoopStore

/// WHOOP's live status and commands use the same native rows as the Settings root.
/// Capturing references here keeps the route out of LiveState's high-frequency observation.
struct WhoopDeviceSettingsView: View {
    @State private var model: AppModel?
    @State private var live: LiveState?
    @State private var registry: DeviceRegistry?

    var body: some View {
        Group {
            if let model, let live, let registry {
                WhoopDeviceSettingsContent(model: model, live: live, registry: registry)
            } else {
                NativeSettingsList {
                    Section("Connection") {
                        LabeledContent("Status", value: "Getting devices ready")
                    }
                }
            }
        }
        .navigationTitle("WHOOP")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .tint(.blue)
        .background(AppModelReferenceCapture(reference: $model))
        .background(LiveStateReferenceCapture(reference: $live))
        .background(DeviceRegistryReferenceCapture(reference: $registry))
    }
}

private struct WhoopDeviceSettingsContent: View {
    let model: AppModel
    let live: LiveState
    @ObservedObject var registry: DeviceRegistry
    @StateObject private var observation: DeviceCommandCenterLiveSnapshot
    @AppStorage(PuffinExperiment.deepDataKey) private var deepDataEnabled = false
    @AppStorage("selectedWhoopModel") private var selectedWhoopModelRaw = WhoopModel.whoop4.rawValue
    @State private var strapNameDraft = ""
    @State private var commandFeedback: String?

    init(model: AppModel, live: LiveState, registry: DeviceRegistry) {
        self.model = model
        self.live = live
        self.registry = registry
        _observation = StateObject(wrappedValue: DeviceCommandCenterLiveSnapshot(live: live))
    }

    private var activeDevice: PairedDevice? {
        registry.devices.first { $0.status == .active }
    }

    private var isWhoop: Bool { activeDevice.map(SourceCoordinator.isWhoop) ?? false }
    private var canScanWhoop: Bool { activeDevice == nil || isWhoop }
    private var supportsR22: Bool {
        guard isWhoop, let device = activeDevice else { return false }
        let name = device.model.uppercased()
        return name.contains("5") || name.contains("MG")
    }

    private var isConfirmedWhoop4: Bool {
        guard isWhoop, let device = activeDevice else { return false }
        return DeviceCapabilityProfile.make(for: device).displayModel == WhoopModel.whoop4.rawValue
    }

    var body: some View {
        // Packet time is intentionally sampled: it is not a published high-frequency dependency.
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let value = observation.value
            let now = context.date
            let resolved = status(value, now: now)
            NativeSettingsList {
                connectionSection(value, resolved: resolved, now: now)
                historySection(value, now: now)
                controlsSection(value, resolved: resolved)
                diagnosticsSection(value, resolved: resolved)
            }
        }
    }

    private func status(_ value: DeviceCommandCenterLiveSnapshot.Value, now: Date) -> DeviceCommandCenterSnapshot {
        DeviceCommandCenterStatusResolver.resolve(.init(
            isWhoop: isWhoop, supportsR22: supportsR22,
            connected: isWhoop && value.connected, encryptedBond: isWhoop && value.encryptedBond,
            bluetoothUnavailableMessage: value.bluetoothUnavailableMessage,
            reconnectGuide: isWhoop ? value.reconnectGuide : nil,
            pairingHint: isWhoop ? value.pairingHint : nil,
            rtcWarning: isWhoop ? clockWarning(value) : nil,
            lastSyncError: isWhoop && !value.backfilling ? value.lastSyncError : nil,
            strapNeedsReboot: isWhoop && value.strapNeedsReboot,
            batteryPct: isWhoop ? value.batteryPct : nil,
            historySyncExperimental: isWhoop && value.historySyncExperimental,
            standardHRMode: isWhoop ? value.standardHRMode : nil,
            backfilling: value.backfilling,
            syncChunksThisSession: value.syncChunksThisSession,
            lastSyncedAt: isWhoop ? value.lastSyncedAt : nil,
            historicalDataFrontierAt: isWhoop ? value.historicalDataFrontierAt : nil,
            historicalSyncSessionState: isWhoop ? value.historicalSyncSessionState : .disconnected,
            liveHeartRateAvailable: isWhoop && value.liveHeartRateAvailable,
            deepDataEnabled: deepDataEnabled, r22FlagsAccepted: value.r22FlagsAccepted,
            r22FlagCount: Whoop5Config.enableR22Sequence.count,
            now: now.timeIntervalSince1970))
    }

    private func connectionSection(
        _ value: DeviceCommandCenterLiveSnapshot.Value,
        resolved: DeviceCommandCenterSnapshot,
        now: Date
    ) -> some View {
        Section {
            row("Status", isWhoop ? resolved.connectionLabel : "No active WHOOP", id: "connection")
            row("Battery", isWhoop ? value.batteryPct.map { "\(Int($0.rounded()))%" } ?? "Unknown" : "Unknown", id: "battery")
            row("Live heart rate", isWhoop && value.connected
                ? (value.liveHeartRateAvailable ? "Streaming" : "Waiting for data") : "Not streaming", id: "liveHR")
            row("Last packet", isWhoop ? ConnectionReadout.lastFrameLabel(
                lastFrameUnix: live.lastFrameAtUnix,
                nowUnix: Int(now.timeIntervalSince1970)) : "Unknown", id: "packet")
            DisclosureGroup {
                if let device = activeDevice, isWhoop {
                    row("Device", device.displayName, id: "device")
                    row("Model", DeviceCapabilityProfile.make(for: device).displayModel, id: "model")
                }
                row("Encrypted link", isWhoop ? (resolved.bondLabel ?? "Unknown") : "Unknown", id: "bond")
                row("Clock latched", isWhoop ? clockLabel(value) : "Unknown", id: "clock")
                row("Wrist", isWhoop && value.connected && value.wearStateKnown
                    ? (value.worn ? "On wrist" : "Off wrist") : "Unknown", id: "wrist")
                row("Charging", isWhoop ? value.charging.map { $0 ? "Yes" : "No" } ?? "Unknown" : "Unknown", id: "charging")
                row("Estimated runtime", isWhoop ? runtime(value, now: now) : "Unknown", id: "runtime")
                if isWhoop && value.connected, let start = value.connectedAt {
                    row("Connected for", duration(max(0, Int(now.timeIntervalSince1970 - start))), id: "uptime")
                }
            } label: {
                Text("Device details")
                    .accessibilityIdentifier("settings.whoop.deviceDetails")
            }
            if !isWhoop {
                Text("Choose a WHOOP in Manage Devices to view its status and use its controls.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(warnings(value), id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.subheadline).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Connection")
        } footer: {
            Text("NOOP pairs directly with your WHOOP over Bluetooth. It does not require the WHOOP app or cloud.")
        }
    }

    private func historySection(_ value: DeviceCommandCenterLiveSnapshot.Value, now: Date) -> some View {
        let history = HistoricalSyncStatusResolver.resolve(
            connected: isWhoop && value.connected,
            liveHeartRateAvailable: isWhoop && value.liveHeartRateAvailable,
            sessionState: isWhoop ? value.historicalSyncSessionState : .disconnected,
            lastSuccessfulBackfillAt: isWhoop ? value.lastSyncedAt : nil,
            historicalDataFrontierAt: isWhoop ? value.historicalDataFrontierAt : nil,
            lastSyncError: value.backfilling ? nil : value.lastSyncError,
            historySyncExperimental: isWhoop && value.historySyncExperimental,
            chunks: value.syncChunksThisSession, now: now.timeIntervalSince1970)
        return Section {
            row("Current session", currentHistoryLabel(value, resolved: history), id: "history")
            row("Last completed sync", isWhoop ? timestamp(value.lastSyncedAt) : "Unknown", id: "lastSync")
            DisclosureGroup {
                row("Saved through", isWhoop ? timestamp(value.historicalDataFrontierAt) : "Unknown", id: "frontier")
                row("Chunks this session", isWhoop ? "\(value.syncChunksThisSession) received" : "Unknown", id: "chunks")
                row("History window", isWhoop ? historyWindow(value.strapRange) : "Unknown", id: "window")
                if isWhoop, let progress = value.historicalSyncPassProgress {
                    row("Latest saved pass", "\(progress.passNumber) · \(progress.rowsPersisted) rows", id: "pass")
                }
                if isWhoop && value.rejectedFramesThisSession + value.rejectedFramesUnarchived > 0 {
                    row("Rejected records", "\(value.rejectedFramesThisSession + value.rejectedFramesUnarchived)", id: "rejected")
                }
            } label: {
                Text("History details")
                    .accessibilityIdentifier("settings.whoop.historyDetails")
            }
        } header: {
            Text("History")
        } footer: {
            Text("Connection, live heart rate and saved history are separate states. Chunk counts show data received during this session; they do not measure completion.")
        }
    }

    private func controlsSection(
        _ value: DeviceCommandCenterLiveSnapshot.Value,
        resolved: DeviceCommandCenterSnapshot
    ) -> some View {
        Section {
            command("Sync Now", enabled: isWhoop && resolved.commands.syncEnabled, id: "sync") {
                model.syncActiveDevice(); commandFeedback = "History sync requested"
            }
            command("Test Vibration", enabled: isWhoop && resolved.commands.vibrationEnabled, id: "vibration") {
                model.testDeviceVibration(); commandFeedback = "Vibration requested"
            }
            command("Refresh Battery", enabled: isWhoop && resolved.commands.batteryEnabled, id: "refreshBattery") {
                model.refreshDeviceBattery(); commandFeedback = "Battery refresh requested"
            }
            command("Re-scan", enabled: canScanWhoop && resolved.commands.linkEnabled, id: "rescan") {
                model.refreshDeviceLink(); commandFeedback = "Scan requested"
            }
            command("Disconnect", enabled: isWhoop && (value.connected || value.bonded), id: "disconnect") {
                model.disconnect(); commandFeedback = "Disconnect requested"
            }
            if let commandFeedback {
                Text(commandFeedback).font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.whoop.feedback")
            }
            NavigationLink("Manage Devices") {
                DevicesView().environment(\.screenScaffoldNavigationRole, .detail)
            }
            .accessibilityIdentifier("settings.whoop.manageDevices")
        } header: {
            Text("Controls")
        } footer: {
            Text(isWhoop
                ? "History sync and vibration require a connected WHOOP with a full encrypted bond. A request does not confirm that the strap completed it."
                : "WHOOP commands are unavailable while another device is active.")
        }
    }

    private func diagnosticsSection(
        _ value: DeviceCommandCenterLiveSnapshot.Value,
        resolved: DeviceCommandCenterSnapshot
    ) -> some View {
        Section {
            if isWhoop {
                row("Firmware", value.strapFirmware ?? "Unknown", id: "firmware")
                if let device = activeDevice { row("Device ID", device.id, id: "deviceID") }
                if let r22 = resolved.r22Label { row("R22 configuration", r22, id: "r22") }
            }
            Button("Copy Strap Log") { PlatformPasteboard.copy(live.exportableLogText()) }
                .accessibilityIdentifier("settings.whoop.copyLog")
            Button("Save Strap Log…") {
                FileExport.exportText(live.exportableLogText(),
                    suggestedName: FileExport.timestampedName("noop-strap-log", ext: "txt"))
            }
            .accessibilityIdentifier("settings.whoop.saveLog")
            NavigationLink(value: SettingsRouteID.testCentre) { Text("Test Centre") }
                .accessibilityIdentifier("settings.whoop.testCentre")
            if isConfirmedWhoop4 && value.connected && selectedWhoopModelRaw == WhoopModel.whoop4.rawValue {
                row("Current strap name", value.advertisingName ?? "Unknown", id: "strapName")
                TextField("New strap name", text: $strapNameDraft)
                    #if os(iOS)
                    .textInputAutocapitalization(.words)
                    #endif
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("settings.whoop.renameDraft")
                Button("Rename Strap") { model.ble.renameStrap(strapNameDraft) }
                    .disabled(strapNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("settings.whoop.rename")
                if let status = value.renameStatus {
                    Text(status).font(.subheadline).foregroundStyle(.secondary)
                }
                Text("WHOOP 4.0 restarts after a rename. The new Bluetooth name appears on the next connection.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("The strap log records what NOOP saw and is useful when reporting a connection problem.")
        }
    }

    private func row(_ title: String, _ value: String, id: String) -> some View {
        LabeledContent {
            Text(value).multilineTextAlignment(.trailing).foregroundStyle(.secondary)
        } label: {
            Text(LocalizedStringKey(title))
        }
        .accessibilityIdentifier("settings.whoop.\(id)")
    }

    private func command(_ title: String, enabled: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(LocalizedStringKey(title)) { guard enabled else { return }; action() }
            .disabled(!enabled)
            .accessibilityIdentifier("settings.whoop.\(id)")
    }

    private func currentHistoryLabel(
        _ value: DeviceCommandCenterLiveSnapshot.Value,
        resolved: HistoricalSyncStatus
    ) -> String {
        guard isWhoop else { return "No active WHOOP" }
        guard value.connected else { return "Not connected" }
        if value.historicalSyncSessionState == .disconnected { return "Waiting for history session" }
        return resolved.primary
    }

    private func clockLabel(_ value: DeviceCommandCenterLiveSnapshot.Value) -> String {
        let clock = value.correlatedDeviceClockUnix.flatMap { $0 > 0 ? $0 : nil }
        let newest = (value.strapRange?.newestUnix).flatMap { $0 > 0 ? $0 : nil }
        guard clock != nil || newest != nil else { return "Unknown" }
        return ConnectionReadout.clockLatchedLabel(deviceClockUnix: clock, strapNewestUnix: newest)
    }

    private func clockWarning(_ value: DeviceCommandCenterLiveSnapshot.Value) -> String? {
        ConnectionReadout.rtcWarning(deviceClockUnix: value.correlatedDeviceClockUnix,
                                     strapNewestUnix: value.strapRange?.newestUnix)
    }

    private func warnings(_ value: DeviceCommandCenterLiveSnapshot.Value) -> [String] {
        var messages = [value.bluetoothUnavailableMessage]
        if isWhoop {
            messages += [value.reconnectGuide, value.pairingHint, clockWarning(value),
                         value.backfilling ? nil : value.lastSyncError,
                         value.strapNeedsReboot ? "The strap may need to be restarted." : nil,
                         value.batteryPct.map { $0 <= DeviceCommandCenterStatusResolver.criticalBatteryThreshold }
                            == true ? "Battery is critically low." : nil,
                         value.historySyncExperimental ? "History sync is experimental for this device." : nil,
                         value.standardHRMode]
            if value.connected && !value.encryptedBond && value.pairingHint == nil {
                messages.append("Live HR only. History sync, vibration, and alarms require full pairing.")
            }
        }
        var seen = Set<String>()
        return messages.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func runtime(_ value: DeviceCommandCenterLiveSnapshot.Value, now: Date) -> String {
        if value.charging == true { return "Charging" }
        guard let runtime = value.batteryRuntime else { return value.batteryPct == nil ? "Unknown" : "Learning" }
        let remaining = BatteryEstimator.projectedRemainingHours(
            estimate: runtime.estimate, anchoredAt: runtime.anchoredAt,
            asOf: Int(now.timeIntervalSince1970),
            activelyDischarging: value.connected && value.charging == false && runtime.sessionStartedAt != nil,
            sessionStartedAt: runtime.sessionStartedAt)
        return BatteryEstimator.liveLabel(hours: remaining)
    }

    private func timestamp(_ unix: TimeInterval?) -> String {
        unix.map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened) } ?? "Not recorded"
    }

    private func historyWindow(_ range: LiveState.StrapRange?) -> String {
        guard let range, range.newestUnix > 0 else { return "Unknown" }
        let newest = timestamp(TimeInterval(range.newestUnix))
        guard let oldest = range.oldestUnix else { return "Through \(newest)" }
        return "\(timestamp(TimeInterval(oldest))) to \(newest)"
    }

    private func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m"
    }
}
