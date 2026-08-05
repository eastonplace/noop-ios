import SwiftUI
import StrandDesign
import StrandAnalytics   // ConnectionReadout - the #987 clock-latch / RTC-epoch readout parsers
import WhoopStore
import WhoopProtocol
import OuraProtocol

// MARK: - Devices
//
// Pair and manage the bands NOOP reads from. WHOOP-FIRST: the WHOOP is the primary, fully-supported
// device; generic heart-rate straps (Polar / Wahoo / Coospo / Garmin HRM …) are an early, in-development
// addition. The screen is a thin UI over `DeviceRegistry` (the Phase 1A/1B data layer): every mutation
// goes through a registry op, and the `SourceCoordinator` (already wired in AppModel) reacts to the
// active-device change — so this view never touches BLEManager or the WHOOP path directly.
struct DevicesView: View {
    /// The route stores stable command/state identities only. Its compact list is driven by
    /// `DeviceRegistry`; the command centre and summary each opt into live observation in a tiny leaf.
    @State private var appModel: AppModel?
    @State private var liveState: LiveState?
    @State private var registry: DeviceRegistry?
    var onClose: (() -> Void)? = nil

    var body: some View {
        ScreenScaffold(title: "Devices",
                       subtitle: "Manage your straps and devices.",
                       // The day-of-sky liquid backdrop, matching Today / Health / Sleep / Trends: a fixed,
                       // full-bleed time-of-day sky behind the scroll content (it does not scroll).
                       topBackground: nil,
                       trailing: {
                           if let onClose {
                               Button("Done", action: onClose)
                                   .buttonStyle(.plain)
                                   .font(StrandFont.caption.weight(.semibold))
                                   .foregroundStyle(StrandPalette.accent)
                           } else {
                               Image(systemName: "plus")
                                   .font(.system(size: 16, weight: .semibold))
                                   .foregroundStyle(StrandPalette.textPrimary)
                           }
                       }) {
            if let registry, let appModel, let liveState {
                DevicesContent(registry: registry, model: appModel, live: liveState)
            } else {
                // The registry is built once the on-device store opens (a beat after launch). Show a
                // calm pending note rather than an empty screen in that brief window.
                DataPendingNote(
                    title: "Getting your devices ready",
                    message: "NOOP is opening your on-device data. Your paired bands will appear here in a moment.",
                    symbol: "badge.plus.radiowaves.right")
            }
        }
        .background(AppModelReferenceCapture(reference: $appModel))
        .background(LiveStateReferenceCapture(reference: $liveState))
        .background(DeviceRegistryReferenceCapture(reference: $registry))
    }
}

// MARK: - Content (registry resolved)

/// The screen body once `DeviceRegistry` exists. Split out so it can observe the registry's
/// `@Published devices` / `activeDeviceId` directly — the parent only observes `model.deviceRegistry`
/// becoming non-nil.
private struct DevicesContent: View {
    @ObservedObject var registry: DeviceRegistry
    /// Plain references: these do not subscribe the full list to high-frequency app/live publishers.
    let model: AppModel
    let live: LiveState
    @AppStorage(PuffinExperiment.deepDataKey) private var deepDataEnabled = false

    // Sheets / alerts
    @State private var showAddWizard = false
    @State private var switchTarget: PairedDevice?
    @State private var renameTarget: PairedDevice?
    @State private var renameDraft = ""
    @State private var removeTarget: PairedDevice?
    @State private var deleteDataTarget: PairedDevice?
    /// After removing the ACTIVE device with other devices still paired, prompt to pick a new active one.
    @State private var pickNewActive = false
    @State private var commandFeedback: String?
    @State private var showingActiveDeviceActions = false
    @State private var showingCommandCenter = false

    private var activeDevices: [PairedDevice] { registry.devices.filter { $0.status != .archived } }
    private var removedDevices: [PairedDevice] { registry.devices.filter { $0.status == .archived } }
    private var activeDevice: PairedDevice? { activeDevices.first(where: { $0.status == .active }) }
    private var otherDevices: [PairedDevice] { activeDevices.filter { $0.status != .active } }

    /// The active+connected strap's explicit clock state. BLEManager writes the correlated value at the
    /// proven decode seam; the strap log is evidence for export, never a state store this heavy screen
    /// has to search during rendering.
    private var strapClockState: (line: String, warning: String?)? {
        guard live.connected else { return nil }
        let deviceClock = live.correlatedDeviceClockUnix
        guard deviceClock != nil || live.strapRange != nil || live.lastFrameAtUnix != nil else { return nil }
        let latched = ConnectionReadout.clockLatchedLabel(deviceClockUnix: deviceClock)
        let frame = ConnectionReadout.lastFrameLabel(lastFrameUnix: live.lastFrameAtUnix,
                                                     nowUnix: Int(Date().timeIntervalSince1970))
        let warning = ConnectionReadout.rtcWarning(deviceClockUnix: deviceClock,
                                                   strapNewestUnix: live.strapRange?.newestUnix)
        return (String(localized: "Clock latched: \(latched) · last frame \(frame)"), warning)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
            if let device = activeDevice {
                DeviceSummaryLiveObservation(live: live) {
                    DeviceCard(
                        device: device,
                        isActive: true,
                        isLiveConnected: live.connected,
                        liveBatteryPct: live.batteryPct.map { Int($0.rounded()) },
                        liveFirmware: live.strapFirmware,
                        liveClockLine: strapClockState?.line,
                        liveClockWarning: strapClockState?.warning,
                        onMakeActive: {},
                        onRename: {
                            renameDraft = device.nickname ?? device.displayName
                            renameTarget = device
                        },
                        onRemove: { removeTarget = device })
                }
                NoopButton("Open command centre", systemImage: "slider.horizontal.3", kind: .secondary,
                           fullWidth: true) {
                    showingCommandCenter = true
                }
            } else {
                DataPendingNote(title: "No active device",
                                message: "Choose a paired device or add one to see connection and sync controls.",
                                symbol: "applewatch.slash")
            }

            if !otherDevices.isEmpty {
                sectionHead("OTHER DEVICES", trailing: String(localized: "\(otherDevices.count) paired"))
            }
            ForEach(Array(otherDevices.enumerated()), id: \.element.id) { idx, device in
                DeviceCard(
                    device: device,
                    isActive: false,
                    isLiveConnected: false,
                    onMakeActive: { switchTarget = device },
                    onRename: { renameDraft = device.nickname ?? device.displayName; renameTarget = device },
                    onRemove: { removeTarget = device })
                    .staggeredAppear(index: idx)
            }

            addButton
                .staggeredAppear(index: activeDevices.count)

            if !removedDevices.isEmpty { removedSection }

            whoopFirstFooter
            privacyFooter
        }
        // Add a device — guided, branching wizard (asks the device TYPE first, then runs the right
        // scan/register path: WHOOP present-scan for WHOOP families, StandardHRSource for HR straps).
        .sheet(isPresented: $showAddWizard) {
            AddDeviceWizard(live: live) { showAddWizard = false }
                .environmentObject(model)
                .environmentObject(live)
        }
        // The rich diagnostics only exist after the user deliberately opens them. This keeps the regular
        // device list fast while streaming and scopes the live subscription to this sheet.
        .sheet(isPresented: $showingCommandCenter) {
            if let device = activeDevice {
                DeviceCommandCenterSnapshotObservation(live: live) { snapshot in
                    commandCenter(device, liveSnapshot: snapshot)
                }
            }
        }
        // Switch confirm
        .alert("Make this your active strap?",
               isPresented: Binding(get: { switchTarget != nil },
                                    set: { if !$0 { switchTarget = nil } }),
               presenting: switchTarget) { device in
            Button("Cancel", role: .cancel) { switchTarget = nil }
            Button("Make active") {
                model.makeActiveDevice(device.id)
                switchTarget = nil
            }
        } message: { device in
            Text("Make \(device.displayName) your active strap? From now on it provides your live data. \(currentActiveName)'s history stays exactly as it is. Only new days come from \(device.displayName).")
        }
        // Rename
        .alert("Rename device",
               isPresented: Binding(get: { renameTarget != nil },
                                    set: { if !$0 { renameTarget = nil } }),
               presenting: renameTarget) { device in
            TextField("Name", text: $renameDraft)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Save") {
                registry.rename(device.id, to: renameDraft)
                renameTarget = nil
            }
        } message: { device in
            Text("Give \(device.brand) \(device.model) a name you'll recognise.")
        }
        // Removal changes presentation only; confirmRemove still owns the BLE forget, archive, and
        // replacement-active prompt effects.
        .sheet(item: $removeTarget) { device in
            destructiveSheet {
                DestructiveGateCard(
                    title: String(localized: "Remove this device?"),
                    message: String(localized: "Remove \(device.displayName)? NOOP will stop connecting to it. Its recorded data is kept and you can re-add it any time."),
                    confirmTitle: String(localized: "Hold to remove"),
                    cancel: { removeTarget = nil },
                    confirm: { confirmRemove(device) }
                )
            }
        }
        // Second, strongly-worded delete-data confirm (reached from the Remove card's secondary control)
        .sheet(item: $deleteDataTarget) { device in
            destructiveSheet {
                DestructiveGateCard(
                    title: String(localized: "Delete all of this device's data?"),
                    message: String(localized: "This permanently deletes all data recorded from \(device.displayName). This can't be undone."),
                    confirmTitle: String(localized: "Hold to delete data"),
                    completedTitle: String(localized: "Deleted"),
                    cancel: { deleteDataTarget = nil },
                    confirm: { confirmDeleteData(device) }
                )
            }
        }
        // After removing the active device, offer to pick a new active one (if any remain).
        .confirmationDialog("Pick a new active strap",
                            isPresented: $pickNewActive,
                            titleVisibility: .visible) {
            ForEach(activeDevices) { device in
                Button(device.displayName) { model.makeActiveDevice(device.id) }
            }
            Button("Leave none active", role: .cancel) { }
        } message: {
            Text("You removed your active strap. Choose which paired band provides your live data, or leave none active and pair one later.")
        }
        .confirmationDialog("Device actions",
                            isPresented: $showingActiveDeviceActions,
                            titleVisibility: .visible) {
            if let device = activeDevice {
                Button("Rename") {
                    renameDraft = device.nickname ?? device.displayName
                    renameTarget = device
                }
                Button("Remove", role: .destructive) { removeTarget = device }
            }
            Button("Cancel", role: .cancel) { }
        }
    }

    // MARK: Pieces

    private func commandCenter(
        _ device: PairedDevice,
        liveSnapshot: DeviceCommandCenterLiveSnapshot.Value
    ) -> some View {
        let isWhoop = SourceCoordinator.isWhoop(device)
        let modelName = device.model.uppercased()
        let supportsR22 = isWhoop && (modelName.contains("5") || modelName.contains("MG"))
        let resolved = DeviceCommandCenterStatusResolver.resolve(.init(
            isWhoop: isWhoop, supportsR22: supportsR22,
            connected: liveSnapshot.connected, encryptedBond: liveSnapshot.encryptedBond,
            bluetoothUnavailableMessage: liveSnapshot.bluetoothUnavailableMessage,
            reconnectGuide: liveSnapshot.reconnectGuide, pairingHint: liveSnapshot.pairingHint,
            rtcWarning: strapClockState(liveSnapshot)?.warning, lastSyncError: liveSnapshot.lastSyncError,
            strapNeedsReboot: liveSnapshot.strapNeedsReboot, batteryPct: liveSnapshot.batteryPct,
            historySyncExperimental: liveSnapshot.historySyncExperimental,
            standardHRMode: liveSnapshot.standardHRMode,
            backfilling: liveSnapshot.backfilling,
            syncChunksThisSession: liveSnapshot.syncChunksThisSession,
            lastSyncedAt: liveSnapshot.lastSyncedAt, deepDataEnabled: deepDataEnabled,
            r22FlagsAccepted: liveSnapshot.r22FlagsAccepted,
            r22FlagCount: Whoop5Config.enableR22Sequence.count,
            now: Date().timeIntervalSince1970))

        return VStack(alignment: .leading, spacing: 18) {
            componentLabel("Identity card · which strap, exactly")
            DeviceCommandIdentityTimerLeaf(
                name: device.displayName,
                firmware: liveSnapshot.strapFirmware.map { "Firmware \($0)" } ?? device.model,
                deviceID: compactDeviceID(device.id),
                bondLabel: identityBondLabel(resolved, liveSnapshot: liveSnapshot),
                bondTone: bondTone(resolved, liveSnapshot: liveSnapshot),
                batteryFraction: liveSnapshot.batteryPct.map { $0 / 100 },
                wristLabel: liveSnapshot.worn ? "On wrist" : "Off wrist",
                connectedAt: liveSnapshot.connectedAt,
                onMenu: { showingActiveDeviceActions = true })

            Divider().overlay(StrandPalette.hairline)
            componentLabel("Command centre · every check has a verdict")
            DeviceCommandStatusTimerLeaf { now in
                statusItems(
                    snapshot: resolved,
                    liveSnapshot: liveSnapshot,
                    isWhoop: isWhoop,
                    now: now)
            }

            Divider().overlay(StrandPalette.hairline)
            componentLabel("Twin cards · one key-value grammar")
            HStack(alignment: .top, spacing: 8) {
                DeviceCommandInfoCard(icon: "arrow.triangle.2.circlepath",
                                      title: "Sync status",
                                      rows: syncRows(resolved, liveSnapshot: liveSnapshot))
                DeviceCommandPowerTimerLeaf { now in
                    powerRows(liveSnapshot: liveSnapshot, now: now)
                }
            }
            if let progress = liveSnapshot.historicalSyncPassProgress {
                DeviceHistoricalSyncProgressLeaf(progress: progress)
            }

            Divider().overlay(StrandPalette.hairline)
            componentLabel("Actions · four common fixes")
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    DeviceCommandActionButton(icon: "arrow.triangle.2.circlepath", title: "Sync now",
                                              enabled: resolved.commands.syncEnabled) {
                        model.syncActiveDevice(); showFeedback("Syncing")
                    }
                    DeviceCommandActionButton(icon: "iphone.radiowaves.left.and.right", title: "Test vibration",
                                              enabled: resolved.commands.vibrationEnabled) {
                        model.testDeviceVibration(); showFeedback("Sent")
                    }
                }
                HStack(spacing: 8) {
                    DeviceCommandActionButton(icon: "battery.75percent", title: "Refresh battery",
                                              enabled: resolved.commands.batteryEnabled) {
                        model.refreshDeviceBattery(); showFeedback("Refreshing")
                    }
                    DeviceCommandActionButton(icon: "link",
                                              title: liveSnapshot.connected ? "Refresh link" : "Reconnect",
                                              prominent: !liveSnapshot.connected,
                                              enabled: resolved.commands.linkEnabled) {
                        model.refreshDeviceLink(); showFeedback("Refreshing")
                    }
                }
            }
            if let commandFeedback {
                Text(commandFeedback).font(StrandFont.micro.weight(.bold))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .transition(.opacity)
            }
        }
    }

    private func componentLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(StrandFont.overline).tracking(1.35)
            .foregroundStyle(StrandPalette.textTertiary)
            .lineLimit(1).minimumScaleFactor(0.7)
    }

    private func identityBondLabel(
        _ snapshot: DeviceCommandCenterSnapshot,
        liveSnapshot: DeviceCommandCenterLiveSnapshot.Value
    ) -> String {
        guard liveSnapshot.connected else { return "Disconnected" }
        if snapshot.bondLabel == "Full bond" { return "Active · Full Bond" }
        if snapshot.bondLabel == "Live HR only" { return "Active · Live HR only" }
        return "Active · Connected"
    }

    private func bondTone(
        _ snapshot: DeviceCommandCenterSnapshot,
        liveSnapshot: DeviceCommandCenterLiveSnapshot.Value
    ) -> DeviceCommandTone {
        guard liveSnapshot.connected else { return .neutral }
        return snapshot.bondLabel == "Live HR only" ? .warning : .good
    }

    private func statusItems(
        snapshot: DeviceCommandCenterSnapshot,
        liveSnapshot: DeviceCommandCenterLiveSnapshot.Value,
        isWhoop: Bool,
        now: Date
    ) -> [DeviceCommandStatusItem] {
        var rows = [DeviceCommandStatusItem(id: "ble", label: "BLE connection", value: snapshot.connectionLabel,
                                           tone: liveSnapshot.connected ? .good : .critical)]
        if let bond = snapshot.bondLabel {
            rows.append(.init(id: "bond", label: "Bond / encrypted link", value: bond,
                              tone: bond == "Full bond" ? .good : .warning))
        }
        if strapClockState(liveSnapshot) != nil {
            let warning = strapClockState(liveSnapshot)?.warning
            rows.append(.init(id: "clock", label: "Clock latched", value: warning == nil ? "Latched" : "Needs attention",
                              tone: warning == nil ? .good : .warning, subline: warning))
        }
        if isWhoop {
            rows.append(.init(id: "sync", label: "Historical sync", value: snapshot.syncLabel,
                              tone: liveSnapshot.lastSyncError == nil
                                  ? (liveSnapshot.backfilling ? .neutral : .good)
                                  : .warning))
        }
        if let r22 = snapshot.r22Label {
            rows.append(.init(id: "r22", label: "R22 configuration", value: r22,
                              tone: r22 == "Requires full bond" ? .warning : .neutral))
        }
        rows.append(.init(id: "packet", label: "Last packet", value: packetAge(now: now),
                          tone: packetTone(now: now)))
        let healthTone = deviceHealthTone(snapshot.health.level)
        rows.append(.init(id: "health", label: "Device health", value: deviceHealthLabel(snapshot.health.level),
                          tone: healthTone))
        rows.append(.init(id: "issues", label: "Issues detected",
                          value: snapshot.health.issueCount == 0 ? "None" : "\(snapshot.health.issueCount)",
                          tone: healthTone, subline: snapshot.health.primaryIssue))
        return rows
    }

    private func deviceHealthTone(_ level: DeviceHealthSummary.Level) -> DeviceCommandTone {
        switch level {
        case .healthy: .good
        case .informational: .neutral
        case .warning: .warning
        case .critical: .critical
        }
    }

    private func deviceHealthLabel(_ level: DeviceHealthSummary.Level) -> String {
        switch level {
        case .healthy: "Healthy"
        case .informational: "Informational"
        case .warning: "Needs attention"
        case .critical: "Critical"
        }
    }

    private func syncRows(
        _ snapshot: DeviceCommandCenterSnapshot,
        liveSnapshot: DeviceCommandCenterLiveSnapshot.Value
    ) -> [DeviceCommandStatusItem] {
        var rows = [DeviceCommandStatusItem(id: "status", label: "Status", value: snapshot.syncLabel,
                                            tone: liveSnapshot.lastSyncError == nil ? .neutral : .warning),
                    .init(id: "completed", label: "Last completed", value: relativeTime(liveSnapshot.lastSyncedAt)),
                    .init(id: "window", label: "History window", value: liveSnapshot.strapRange.map(shortHistoryWindow) ?? "—"),
                    .init(id: "chunks", label: "Chunks", value: "\(liveSnapshot.syncChunksThisSession) received")]
        let rejected = liveSnapshot.rejectedFramesThisSession + liveSnapshot.rejectedFramesUnarchived
        if rejected > 0 {
            rows.append(.init(id: "rejected", label: "Rejected", value: "\(rejected)",
                              tone: liveSnapshot.rejectedFramesUnarchived > 0 ? .warning : .neutral))
        }
        return rows
    }

    private func powerRows(
        liveSnapshot: DeviceCommandCenterLiveSnapshot.Value,
        now: Date
    ) -> [DeviceCommandStatusItem] {
        [.init(id: "battery", label: "Battery", value: liveSnapshot.batteryPct.map { "\(Int($0.rounded()))%" } ?? "—",
               tone: (liveSnapshot.batteryPct ?? 100) <= DeviceCommandCenterStatusResolver.criticalBatteryThreshold
                   ? .warning
                   : .neutral),
         .init(id: "runtime", label: "Estimated", value: liveSnapshot.batteryRuntimeLabel ?? "—"),
         .init(id: "charging", label: "Charging", value: liveSnapshot.charging == true ? "Yes" : liveSnapshot.charging == false ? "No" : "—"),
         .init(id: "uptime", label: "Connection", value: connectionUptime(connectedAt: liveSnapshot.connectedAt, now: now))]
    }

    private func compactDeviceID(_ id: String) -> String {
        id.count > 12 ? "…\(id.suffix(10))" : id
    }

    private func connectionUptime(connectedAt: TimeInterval?, now: Date) -> String {
        guard let connectedAt else { return "—" }
        return compactDuration(max(0, Int(now.timeIntervalSince1970 - connectedAt)))
    }

    private func packetAge(now: Date) -> String {
        guard let timestamp = live.lastFrameAtUnix else { return "Waiting" }
        let seconds = max(0, Int(now.timeIntervalSince1970) - timestamp)
        return seconds < 2 ? "Now" : "\(compactDuration(seconds)) ago"
    }

    private func packetTone(now: Date) -> DeviceCommandTone {
        guard let timestamp = live.lastFrameAtUnix else { return .neutral }
        return Int(now.timeIntervalSince1970) - timestamp > 60 ? .warning : .good
    }

    private func strapClockState(
        _ liveSnapshot: DeviceCommandCenterLiveSnapshot.Value
    ) -> (line: String, warning: String?)? {
        let deviceClock = liveSnapshot.correlatedDeviceClockUnix
        guard deviceClock != nil || liveSnapshot.strapRange != nil || live.lastFrameAtUnix != nil else { return nil }
        let latched = ConnectionReadout.clockLatchedLabel(deviceClockUnix: deviceClock)
        let frame = ConnectionReadout.lastFrameLabel(
            lastFrameUnix: live.lastFrameAtUnix,
            nowUnix: Int(Date().timeIntervalSince1970))
        let warning = ConnectionReadout.rtcWarning(
            deviceClockUnix: deviceClock,
            strapNewestUnix: liveSnapshot.strapRange?.newestUnix)
        return (String(localized: "Clock latched: \(latched) · last frame \(frame)"), warning)
    }

    private func compactDuration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m"
    }

    private func relativeTime(_ timestamp: TimeInterval?) -> String {
        guard let timestamp else { return "Waiting" }
        return packetAgeFrom(timestamp: timestamp, now: Date().timeIntervalSince1970)
    }

    private func packetAgeFrom(timestamp: TimeInterval, now: TimeInterval) -> String {
        let seconds = max(0, Int(now - timestamp))
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3_600)h ago" }
        return "\(seconds / 86_400)d ago"
    }

    private func shortHistoryWindow(_ range: LiveState.StrapRange) -> String {
        let newest = Date(timeIntervalSince1970: TimeInterval(range.newestUnix)).formatted(.dateTime.month(.abbreviated).day())
        guard let oldest = range.oldestUnix else { return newest }
        let oldestText = Date(timeIntervalSince1970: TimeInterval(oldest)).formatted(.dateTime.month(.abbreviated).day())
        return "\(oldestText)–\(newest)"
    }

    private func showFeedback(_ value: String) {
        commandFeedback = value
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if commandFeedback == value { commandFeedback = nil }
        }
    }

    private var addButton: some View {
        NoopButton("Add a device", systemImage: "plus", kind: .primary, fullWidth: true) {
            showAddWizard = true
        }
        .accessibilityLabel("Add a device")
    }

    private var removedSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
            sectionHead("REMOVED", trailing: String(localized: "Data kept"))
            ForEach(removedDevices) { device in
                DeviceCard(
                    device: device,
                    isActive: false,
                    isLiveConnected: false,
                    dimmed: true,
                    onMakeActive: { switchTarget = device },
                    onRename: { renameDraft = device.nickname ?? device.displayName; renameTarget = device },
                    onRemove: nil,
                    onReAdd: { model.makeActiveDevice(device.id) },
                    onDeleteData: { deleteDataTarget = device })
            }
        }
    }

    private var whoopFirstFooter: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
            Text("WHOOP is NOOP's primary, fully-supported band. Other heart-rate straps are an early, in-development addition: they stream live heart rate and HRV, but not WHOOP's deeper sleep and recovery data.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var privacyFooter: some View { DeviceCommandPrivacyFooter() }

    /// UPPERCASE overline section header with tracking + a muted trailing note, matching the liquid Today's
    /// `sectionHead`. Keeps every page's section chrome identical.
    private func sectionHead(_ title: LocalizedStringKey, trailing: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(StrandFont.overline).tracking(1.6).foregroundStyle(StrandPalette.textTertiary)
            Spacer()
            Text(trailing).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.horizontal, 2)
    }

    // MARK: Logic

    private var currentActiveName: String {
        registry.devices.first(where: { $0.status == .active })?.displayName ?? String(localized: "Your current strap")
    }

    /// Archive the device, then — if it was the active one and other non-archived devices remain —
    /// prompt for a new active device. The active row is demoted to `.paired` by the registry's reload,
    /// so the dialog's choices come from the still-paired devices.
    private func confirmRemove(_ device: PairedDevice) {
        let wasActive = device.status == .active
        // #78: actually RELEASE the BLE link, not just archive the registry row — otherwise NOOP keeps
        // re-grabbing the strap (reconnect timer + targeted-connect pin + iOS state restoration), holding
        // it connected so it can never enter pairing mode to be re-paired.
        model.ble.forgetDevice(device.peripheralId)
        model.archiveDevice(device.id)
        removeTarget = nil
        if wasActive {
            Task {
                await model.repo.invalidateTodayHealthSnapshot()
            }
            // Other paired devices left → ask which becomes active; otherwise no active device remains.
            if !activeDevices.isEmpty {
                pickNewActive = true
            }
        }
    }

    /// Keep the original actor-routed 16+-table purge intact behind the shared hold gate.
    private func confirmDeleteData(_ device: PairedDevice) {
        let deviceId = device.id
        Task {
            model.deleteDeviceData(deviceId)
        }
        deleteDataTarget = nil
    }

    private func destructiveSheet<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            StrandPalette.canvas.ignoresSafeArea()
            content().padding(20)
        }
        .presentationDetents([.height(330)])
        .presentationDragIndicator(.hidden)
    }
}

/// A deliberately small observation boundary for the active-device summary.
/// `DevicesContent` keeps a stable LiveState reference but never subscribes to HR/R-R/log churn itself.
private struct DeviceSummaryLiveObservation<Content: View>: View {
    @ObservedObject var live: LiveState
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
    }
}

/// Owns the command centre's narrow adapter. The sheet no longer observes monolithic `LiveState`.
private struct DeviceCommandCenterSnapshotObservation<Content: View>: View {
    @StateObject private var snapshot: DeviceCommandCenterLiveSnapshot
    @ViewBuilder let content: (DeviceCommandCenterLiveSnapshot.Value) -> Content

    init(
        live: LiveState,
        @ViewBuilder content: @escaping (DeviceCommandCenterLiveSnapshot.Value) -> Content
    ) {
        _snapshot = StateObject(wrappedValue: DeviceCommandCenterLiveSnapshot(live: live))
        self.content = content
    }

    var body: some View {
        content(snapshot.value)
    }
}

/// Keeps the one-second uptime clock below the command-centre observation root.
private struct DeviceCommandIdentityTimerLeaf: View {
    let name: String
    let firmware: String
    let deviceID: String
    let bondLabel: String
    let bondTone: DeviceCommandTone
    let batteryFraction: Double?
    let wristLabel: String
    let connectedAt: TimeInterval?
    let onMenu: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            DeviceCommandIdentityCard(
                name: name,
                firmware: firmware,
                deviceID: deviceID,
                bondLabel: bondLabel,
                bondTone: bondTone,
                batteryFraction: batteryFraction,
                wristLabel: wristLabel,
                connectionLabel: connectionUptime(now: context.date),
                onMenu: onMenu)
        }
    }

    private func connectionUptime(now: Date) -> String {
        guard let connectedAt else { return "—" }
        return compactDuration(max(0, Int(now.timeIntervalSince1970 - connectedAt)))
    }

    private func compactDuration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m"
    }
}

/// Keeps the packet-age clock below the command-centre observation root.
private struct DeviceCommandStatusTimerLeaf: View {
    let items: (Date) -> [DeviceCommandStatusItem]

    init(items: @escaping (Date) -> [DeviceCommandStatusItem]) {
        self.items = items
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            DeviceCommandStatusOverview(items: items(context.date))
        }
    }
}

/// Keeps the duplicate uptime readout below the command-centre observation root.
private struct DeviceCommandPowerTimerLeaf: View {
    let rows: (Date) -> [DeviceCommandStatusItem]

    init(rows: @escaping (Date) -> [DeviceCommandStatusItem]) {
        self.rows = rows
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            DeviceCommandInfoCard(
                icon: "battery.75percent",
                title: "Power status",
                rows: rows(context.date))
        }
    }
}

/// A compact durable-pass receipt. It updates only when the narrow snapshot receives new sync progress.
private struct DeviceHistoricalSyncProgressLeaf: View {
    let progress: HistoricalSyncPassProgress

    private var label: String {
        let rowLabel = progress.rowsPersisted == 1 ? "row" : "rows"
        let frontier = progress.latestFrontierUnix.map {
            " · through \(Date(timeIntervalSince1970: TimeInterval($0)).formatted(date: .omitted, time: .shortened))"
        } ?? ""
        return "Pass \(progress.passNumber) · \(progress.rowsPersisted) \(rowLabel) saved\(frontier)"
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(StrandPalette.statusPositive)
            Text(label)
                .font(StrandFont.micro.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(StrandPalette.surfaceInset.opacity(0.7)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

// MARK: - Device card

/// One paired device as a card: name, brand/model, capabilities line, a state pill, last-seen, and a
/// per-device actions menu. The active device is tinted with the accent (WHOOP blue) and carries an "Active" pill.
private struct DeviceCard: View {
    let device: PairedDevice
    let isActive: Bool
    let isLiveConnected: Bool
    /// The active+connected device's live battery percent (0–100), surfaced on the card the same way
    /// for WHOOP, a generic strap, or an FTMS machine. nil when not the active/connected device or
    /// the source hasn't reported a battery (e.g. a strap/machine without the 0x180F service).
    var liveBatteryPct: Int? = nil
    /// The active+connected strap's firmware version (from the connect handshake). nil when not the
    /// active/connected device, or for a source that reports no firmware (e.g. a non-WHOOP strap).
    var liveFirmware: String? = nil
    /// #987: the active+connected strap's clock-state line ("Clock latched: yes · last frame 12s ago"),
    /// nil for every other card. Built by the parent off the same pure ConnectionReadout parsers the
    /// Test Centre Connection panel binds, so the two readouts can never disagree.
    var liveClockLine: String? = nil
    /// #987: the plain-words warning when the strap RTC reads ~1970/71 (never set, so it banks no
    /// history) - the single most common "no history" root cause, surfaced where the user looks first.
    var liveClockWarning: String? = nil
    var dimmed: Bool = false
    var onMakeActive: () -> Void
    var onRename: () -> Void
    var onRemove: (() -> Void)?
    /// Removed-section affordances (re-add as active / delete its data).
    var onReAdd: (() -> Void)? = nil
    var onDeleteData: (() -> Void)? = nil
    @State private var showsDetails = false

    /// The card's visible content. The required `body` wraps this in the whole-card liquid press button +
    /// the ⋮ menu overlay.
    private var cardContent: some View {
        Group {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: NoopMetrics.space3) {
                    Image(systemName: icon)
                        .font(StrandFont.headline)
                        .foregroundStyle(isActive ? StrandPalette.accent : StrandPalette.textSecondary)
                        .frame(width: 42, height: 42)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(device.displayName)
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(profile.displayModel)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    Spacer()
                    statePill
                }

                HStack(spacing: 14) {
                    if let pct = liveBatteryPct {
                        compactStatus(symbol: batterySymbol(pct), text: "Battery \(pct)%",
                                      tint: batteryTint(pct))
                    } else {
                        compactStatus(symbol: "clock", text: lastSeenLine,
                                      tint: StrandPalette.textTertiary)
                    }
                    compactStatus(symbol: "chart.bar.fill",
                                  text: isLiveConnected ? "Signal live" : "Signal —",
                                  tint: isLiveConnected ? StrandPalette.statusPositive : StrandPalette.textTertiary)
                    Spacer(minLength: 24)
                }

                Button { withAnimation(.easeInOut(duration: 0.2)) { showsDetails.toggle() } } label: {
                    HStack(spacing: 6) {
                        Text("Device details")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                        if device.sourceKind == .oura {
                            StatePill("Beta", tone: .warning, showsDot: false)
                        }
                        Spacer(minLength: 44)
                        Image(systemName: "chevron.down")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .rotationEffect(.degrees(showsDetails ? 180 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showsDetails {
                    VStack(alignment: .leading, spacing: 7) {
                        if device.sourceKind == .oura && !isLiveConnected && device.status == .paired {
                            ouraLocalStateNote
                        }
                        capabilityRow(symbol: "waveform.path.ecg", text: profile.captures,
                                      tint: StrandPalette.textSecondary)
                        capabilityRow(symbol: "bolt.fill", text: profile.powers,
                                      tint: StrandPalette.textSecondary)
                        if !profile.footnote.isEmpty {
                            Text(profile.footnote)
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let clockLine = liveClockLine {
                            Text(clockLine).font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        if let warning = liveClockWarning {
                            Text(warning).font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textPrimary)
                        }
                        if let fw = liveFirmware {
                            Text("Firmware \(fw)").font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if let action = primaryAction {
                    Button(action: action) {
                        HStack(spacing: 6) {
                            Text(primaryActionHint ?? String(localized: "Make active"))
                            Image(systemName: "chevron.right")
                        }
                        .font(StrandFont.footnote.weight(.semibold))
                        .foregroundStyle(StrandPalette.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { Divider().overlay(StrandPalette.hairline) }
        .opacity(dimmed ? 0.6 : 1)
        .accessibilityElement(children: .contain)
    }

    /// The whole-card liquid press wrapper: tapping the card performs its PRIMARY action (make active for a
    /// paired band, re-add for a removed one), with the settle-in `PaperPressStyle`. The ⋮ menu is layered
    /// on top as an overlay so it captures its own taps; cards with no primary action (the active one, or a
    /// removed one whose re-add is menu-only) fall back to a plain container so nothing taps by accident.
    var body: some View {
        cardContent
        .overlay(alignment: .bottomTrailing) {
            actionsMenu
                .padding(14)
        }
    }

    private func compactStatus(symbol: String, text: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(text)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .font(StrandFont.footnote)
    }

    /// The card's primary tap action, or nil when there isn't one. A paired-but-not-active band → make it
    /// active; a removed band → re-add it as active. The active band and any card without those callbacks
    /// have no whole-card tap (their controls live entirely in the ⋮ menu).
    private var primaryAction: (() -> Void)? {
        if device.status == .archived { return onReAdd }
        if !isActive { return onMakeActive }
        return nil
    }

    /// Short accent hint mirroring the primary tap, shown in the footer row. nil when the card has no
    /// whole-card action (active band / menu-only removed band).
    private var primaryActionHint: String? {
        if device.status == .archived { return onReAdd == nil ? nil : String(localized: "Make active") }
        if !isActive { return String(localized: "Make active") }
        return nil
    }

    /// The live battery as a liquid tube (fills to the charge, coloured by band) with a trailing percent.
    /// Static-posed so it costs nothing per frame — one of many small liquid elements on the screen.
    private func batteryTube(_ pct: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: batterySymbol(pct))
                .font(StrandFont.caption)
                .foregroundStyle(batteryTint(pct))
                .frame(width: 18)
                .accessibilityHidden(true)
            GeometryReader { geo in
                Capsule().fill(StrandPalette.inset)
                    .overlay(alignment: .leading) {
                        Capsule().fill(batteryTint(pct))
                            .frame(width: geo.size.width * min(max(Double(pct) / 100, 0), 1))
                    }
            }
            .frame(height: 8)
            Text("\(pct)%")
                .font(StrandFont.captionNumber)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery \(pct) percent")
    }

    /// The charge-band colour for the battery tube/icon (mirrors the menu-bar battery buckets).
    private func batteryTint(_ pct: Int) -> Color {
        pct < 15 ? StrandPalette.statusCritical : pct < 35 ? StrandPalette.statusWarning : StrandPalette.chargeColor
    }

    private var statePill: some View {
        Group {
            if device.status == .archived {
                StatePill("Removed", tone: .neutral, showsDot: false)
            } else if isActive {
                StatePill(isLiveConnected ? "Active · Live" : "Active",
                          tone: .positive, pulsing: isLiveConnected)
            } else {
                StatePill("Paired", tone: .neutral)
            }
        }
    }

    private var actionsMenu: some View {
        Menu {
            if device.status == .archived {
                if let onReAdd {
                    Button { onReAdd() } label: { Label("Make active", systemImage: "bolt.fill") }
                }
                Button { onRename() } label: { Label("Rename", systemImage: "pencil") }
                if let onDeleteData {
                    Divider()
                    Button(role: .destructive) { onDeleteData() } label: {
                        Label("Delete this device's data…", systemImage: "trash")
                    }
                }
            } else {
                if !isActive {
                    Button { onMakeActive() } label: { Label("Make active", systemImage: "bolt.fill") }
                }
                Button { onRename() } label: { Label("Rename", systemImage: "pencil") }
                if let onRemove {
                    Divider()
                    Button(role: .destructive) { onRemove() } label: {
                        Label("Remove", systemImage: "minus.circle")
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Device actions for \(device.displayName)")
    }

    /// SF Symbol for the device: WHOOP keeps the band glyph; an FTMS machine reads as gym equipment;
    /// an Apple Watch reads as a watch; generic straps read as a heart-rate strap.
    private var icon: String {
        if device.sourceKind == .ftms { return "figure.run.treadmill" }
        if device.sourceKind == .huami { return "waveform.path.ecg.rectangle" }
        if device.sourceKind == .liveAppleWatch { return "applewatch" }
        if device.sourceKind == .oura { return "circle.circle" }
        return SourceCoordinator.isWhoop(device) ? "applewatch.side.right" : "heart.circle"
    }

    /// The honest, per-model capability + function summary for this device's card.
    private var profile: DeviceCapabilityProfile { .make(for: device) }

    /// One icon-prefixed info row (captures / powers), matching the card's caption style.
    private func capabilityRow(symbol: String, text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(text)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var lastSeenLine: String {
        if device.status == .archived { return String(localized: "Removed · data kept") }
        if isLiveConnected { return String(localized: "Connected now") }
        return String(localized: "Last seen \(relativeAgo(TimeInterval(device.lastSeenAt)))")
    }

    /// Honest paired-but-not-connected note for a locally-adopted Oura ring. Amber heads-up, no fabricated
    /// reading: re-states the single-owner reality so the user understands why a re-reset / Oura re-claim
    /// would break NOOP's ownership.
    private var ouraLocalStateNote: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.statusWarning)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text("Paired locally. NOOP owns this ring while it holds the key. If you reset it again or set it up in the Oura app, NOOP no longer owns it and you would re-add it to take it over.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A battery SF Symbol matching the charge band (mirrors the menu-bar battery glyph buckets).
    private func batterySymbol(_ pct: Int) -> String {
        switch pct {
        case ..<13:  return "battery.0"
        case ..<38:  return "battery.25"
        case ..<63:  return "battery.50"
        case ..<88:  return "battery.75"
        default:     return "battery.100"
        }
    }
}

// MARK: - Capability profile

/// Honest, per-model summary of what a device captures and what NOOP uses it for — shown on its card.
///
/// Derived from brand/model/sourceKind, NOT from the stored capability `Set`. The stored set is generic
/// across WHOOP models (it would render an identical "Heart rate · HRV · Blood oxygen · Skin temp · …"
/// line for a 4.0 and a 5/MG alike) and it mislabels: no SpO₂ **percentage** ever comes off any WHOOP
/// strap (raw red/IR only — a real % exists only from a WHOOP CSV / Apple Health import), skin temp is a
/// nightly ±°C sleep deviation rather than a live reading, steps are 5/MG-only and a raw motion count,
/// and Charge/Strain/Sleep are NOOP-derived scores. Verdicts are source-verified against the decode +
/// scoring paths (the device-capability audit). `*` in a label = an on-device estimate, not a raw sensor.
struct DeviceCapabilityProfile {
    let displayModel: String   // clean card subtitle (replaces the redundant "WHOOP · WHOOP")
    let captures: String       // "·"-joined honest capture labels for THIS model
    let powers: String         // the NOOP scores / screens this device drives
    let footnote: String       // one short honest caveat line ("*" estimates + the SpO₂/steps notes)

    static func make(for d: PairedDevice) -> DeviceCapabilityProfile {
        // FTMS gym machine: a live machine + (when reported) HR session, recorded via the existing
        // live-workout path. Honest — we surface the machine's metrics + HR live; the session is
        // Strain-scored only when the machine actually reports heart rate.
        if d.sourceKind == .ftms {
            return DeviceCapabilityProfile(
                displayModel: String(localized: "Gym equipment (FTMS)"),
                captures: String(localized: "Speed · Cadence · Power · Distance · Energy · Heart rate (if the machine sends it)"),
                powers: String(localized: "Records a live machine workout, Strain-scored from HR when the machine reports it"),
                footnote: String(localized: "Live machine data over Bluetooth FTMS. No sleep, recovery, skin temp or SpO₂. Strain needs the machine's heart rate; without it the session logs the machine metrics only."))
        }
        // EXPERIMENTAL Huami device (Amazfit / Zepp / Mi Band): best-effort live HR only, honest about it.
        if d.sourceKind == .huami {
            return DeviceCapabilityProfile(
                displayModel: String(localized: "\(d.brand) (experimental)"),
                captures: String(localized: "Heart rate (live, best-effort)"),
                powers: String(localized: "Powers the live console + Strain. No Recovery or Sleep"),
                footnote: String(localized: "Experimental: live heart rate where the band exposes it. Some bands need a pairing we can't do yet. NOOP will say so honestly and never show a made-up number. No sleep, recovery, skin temp, SpO₂ or steps."))
        }
        // EXPERIMENTAL locally-adopted Oura ring (gen 3/4/5). The gen is carried on `model` ("Oura Ring
        // 3/4/5") and recovered with OuraRingGen.from(model:). NOOP reads the ring's OWN raw signals + open
        // HRV/sleep-phase tags and computes its own Charge/Strain/Sleep; it NEVER reads Oura's encrypted
        // Readiness/Sleep scores, and claims NO absolute SpO₂ %. Estimates carry "*"; a signal it can't read
        // stays "-". Per-gen copy and the canonical Beta caveat (spec
        // docs/superpowers/specs/2026-06-29-oura-onboarding-ux.md s3/s4).
        if d.sourceKind == .oura {
            let gen = OuraRingGen.from(model: d.model)
            // gen3/4 are verified-shape; gen5 ("newer") carries the least-proven caveat.
            let newer = (gen == .gen5)
            let captures = newer
                ? String(localized: "Heart rate* · HRV* · Sleep* · Resting HR* · Skin temp* · Battery*")
                : String(localized: "Heart rate · HRV* · Sleep · Resting HR · Skin temp* · Battery")
            let powers = newer
                ? String(localized: "Powers Strain now; Recovery and Sleep once enough nights and decode are confirmed")
                : String(localized: "Powers Recovery, Strain, Sleep and Sleep")
            return DeviceCapabilityProfile(
                displayModel: String(localized: "\(gen.displayName) (Beta)"),
                captures: captures,
                powers: powers,
                footnote: String(localized: "Beta. * is an on-device estimate. Skin temp is a trend versus your own baseline, and HRV needs you to be still. No Oura Readiness or SpO₂ percentage comes off the ring (import an Oura file for those)."))
        }
        // Apple Watch (live HealthKit source). UNLIKE the WHOOP/strap branches, the watch's stored
        // capability `Set` is already the honest per-model trim (AppleWatchDevice only adds a metric
        // once real data for it arrives), so we read the labels straight off it. An older watch with
        // no SpO₂/wrist-temp samples simply won't list them. Recovery is the calibrating-by-design
        // score (~a week of nights), so the footnote sets that expectation rather than over-promising.
        if d.sourceKind == .liveAppleWatch {
            let labels: [(Metric, String)] = [
                (.hr, String(localized: "Heart rate")), (.hrv, "HRV"), (.sleep, String(localized: "Sleep")),
                (.steps, String(localized: "Steps")), (.spo2, String(localized: "Blood oxygen")), (.skinTemp, String(localized: "Wrist temp")),
            ]
            let captures = labels.filter { d.capabilities.contains($0.0) }.map { $0.1 }.joined(separator: " · ")
            return DeviceCapabilityProfile(
                displayModel: "Apple Watch",
                captures: captures.isEmpty ? String(localized: "Calibrating, no data yet") : captures,
                powers: String(localized: "Powers Sleep, Strain, Fitness Age and steps, plus Recovery once it calibrates"),
                footnote: String(localized: "Computed live from your Apple Watch via Health. Recovery needs about a week of nights to calibrate, and every watch-derived score is labelled with its confidence. Only the metrics your watch actually records are listed above."))
        }
        // Generic heart-rate strap: live HR + R-R only; drives the live console + Strain, nothing nightly.
        // (Same WHOOP test as SourceCoordinator.isWhoop, inlined so this stays nonisolated.)
        let isWhoop = d.id == "my-whoop" || d.brand.caseInsensitiveCompare("WHOOP") == .orderedSame
        guard isWhoop else {
            return DeviceCapabilityProfile(
                displayModel: String(localized: "Heart-rate strap"),
                captures: String(localized: "Heart rate · HRV (live)* · Strain"),
                powers: String(localized: "Powers the live console + Strain. No Recovery or Sleep"),
                footnote: String(localized: "Live HR + R-R only · no sleep, recovery, skin temp, SpO₂, steps or battery (those are WHOOP-only)."))
        }
        let whoopPowers = String(localized: "Powers Recovery, Strain, Sleep + Health Monitor")
        let model = d.model.lowercased()
        // WHOOP 5.0 / MG — adds a (raw) step count the 4.0 can't read over BLE.
        if model.contains("5") || model.contains("mg") {
            return DeviceCapabilityProfile(
                displayModel: "WHOOP 5.0 / MG",
                captures: String(localized: "Heart rate · HRV · Skin temp* · Resp rate* · Steps* · Sleep · Strain · Battery"),
                powers: whoopPowers,
                footnote: String(localized: "* on-device estimate: skin temp is a nightly ±°C deviation, steps are a raw motion count (#78). No SpO₂ % off the strap; import a WHOOP CSV for a real %."))
        }
        // WHOOP 4.0 — NOOP's primary band; no steps over BLE.
        if model.contains("4") {
            return DeviceCapabilityProfile(
                displayModel: "WHOOP 4.0",
                captures: String(localized: "Heart rate · HRV · Skin temp* · Resp rate* · Sleep · Strain · Battery"),
                powers: whoopPowers,
                footnote: String(localized: "* on-device estimate: skin temp is a nightly ±°C deviation (firmware-dependent); no steps over BLE on a 4.0. No SpO₂ % off the strap; import a WHOOP CSV for a real %."))
        }
        // Legacy / unknown WHOOP (the seeded device, model just "WHOOP") — show only the common-to-all set.
        return DeviceCapabilityProfile(
            displayModel: "WHOOP",
            captures: String(localized: "Heart rate · HRV · Skin temp* · Resp rate* · Sleep · Strain · Battery"),
            powers: whoopPowers,
            footnote: String(localized: "Exact model unknown. Shows what every WHOOP can do. * on-device estimate · no SpO₂ % off the strap (import a WHOOP CSV for that)."))
    }
}

// MARK: - Signal indicator

/// A four-bar Wi-Fi-style signal indicator derived from RSSI. RSSI is negative dBm: closer to 0 is
/// stronger. Buckets are coarse on purpose — a precise dBm readout would be noise to the user.
/// Internal (not private) so the Add-a-device wizard reuses the same indicator.
struct SignalBars: View {
    let rssi: Int

    static func level(for rssi: Int) -> Int {
        switch rssi {
        case (-55)...:    return 4   // very strong
        case (-67)...:    return 3
        case (-80)...:    return 2
        case (-90)...:    return 1
        default:          return 0
        }
    }

    var body: some View {
        let level = Self.level(for: rssi)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(i < level ? StrandPalette.accent : StrandPalette.hairlineStrong)
                    .frame(width: 3, height: 6 + CGFloat(i) * 3)
            }
        }
        .frame(width: 22, height: 18, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

// MARK: - Capability catalog (DEBUG render harness)

#if DEBUG
/// DEBUG-only: one DeviceCard per capability-profile kind so the honest per-model display can be
/// screenshotted deterministically (`--demo-screen devicescatalog`). Same file as `DeviceCard` /
/// `DeviceCapabilityProfile` so it can reach them. Stripped from Release.
struct DeviceCardCatalog: View {
    private static let whoopCaps: Set<Metric> = [.hr, .hrv, .spo2, .skinTemp, .sleep, .strainLoad]

    private static func dev(_ id: String, _ brand: String, _ model: String,
                            _ caps: Set<Metric>) -> PairedDevice {
        PairedDevice(id: id, brand: brand, model: model, nickname: nil, peripheralId: nil,
                     sourceKind: .liveBLE, capabilities: caps, status: .paired,
                     addedAt: 0, lastSeenAt: 0)
    }

    private static func watch(_ caps: Set<Metric>) -> PairedDevice {
        PairedDevice(id: "apple-health", brand: "Apple", model: "Apple Watch", nickname: nil,
                     peripheralId: nil, sourceKind: .liveAppleWatch, capabilities: caps,
                     status: .paired, addedAt: 0, lastSeenAt: 0)
    }

    /// A locally-adopted Oura ring (sourceKind `.oura`), built with mock data so the honest per-gen Beta
    /// card renders deterministically WITHOUT a ring. `model` carries the gen ("Oura Ring 3/4/5").
    static func oura(_ model: String, status: DeviceStatus = .paired) -> PairedDevice {
        PairedDevice(id: "oura-demo-\(model)", brand: "Oura", model: model, nickname: nil,
                     peripheralId: "00000000-0000-0000-0000-0000000000aa", sourceKind: .oura,
                     capabilities: [.hr, .hrv, .spo2, .skinTemp, .sleep],
                     status: status, addedAt: 0, lastSeenAt: 0)
    }

    var body: some View {
        ScreenScaffold(title: "Devices",
                       subtitle: "What each band captures (and what NOOP uses it for).",
                       topBackground: nil) {
            VStack(spacing: NoopMetrics.gap) {
                DeviceCard(device: Self.dev("whoop-4d", "WHOOP", "4.0", Self.whoopCaps),
                           isActive: true, isLiveConnected: true,
                           onMakeActive: {}, onRename: {}, onRemove: nil)
                DeviceCard(device: Self.dev("whoop-5d", "WHOOP", "5.0 MG",
                                            Self.whoopCaps.union([.steps])),
                           isActive: false, isLiveConnected: false,
                           onMakeActive: {}, onRename: {}, onRemove: {})
                DeviceCard(device: Self.dev("strap-d", "Polar", "H10", [.hr, .hrv]),
                           isActive: false, isLiveConnected: false,
                           onMakeActive: {}, onRename: {}, onRemove: {})
                // Apple Watch, with an older-model trimmed set (no SpO₂ / wrist temp) so the honest
                // capability read renders deterministically alongside the straps.
                DeviceCard(device: Self.watch([.hr, .hrv, .sleep, .steps]),
                           isActive: false, isLiveConnected: false,
                           onMakeActive: {}, onRename: {}, onRemove: {})
                // Locally-adopted Oura ring (Beta): per-gen honest capability copy + the Beta chip + the
                // paired-but-not-connected local-state note, all without a ring on-wrist.
                DeviceCard(device: Self.oura("Oura Ring 3"),
                           isActive: false, isLiveConnected: false,
                           onMakeActive: {}, onRename: {}, onRemove: {})
            }
        }
    }
}

/// DEBUG-only: just the locally-adopted Oura device card, active + connected, so `--demo-screen ouradevice`
/// can screenshot the Beta Oura card (battery + "Active · Live") WITHOUT a ring. Same file as `DeviceCard`
/// so it can reach it. Stripped from Release.
struct OuraDeviceDemoScreen: View {
    var body: some View {
        ScreenScaffold(title: "Devices",
                       subtitle: "A locally-adopted Oura ring, in beta.",
                       topBackground: nil) {
            VStack(spacing: NoopMetrics.gap) {
                // Active + connected so the card shows "Active · Live" + a live battery readout.
                DeviceCard(device: DeviceCardCatalog.oura("Oura Ring 3"),
                           isActive: true, isLiveConnected: true, liveBatteryPct: 71,
                           onMakeActive: {}, onRename: {}, onRemove: {})
                // A second, paired-but-not-connected gen-4 ring so the honest local-state note + per-gen
                // copy render in the same shot.
                DeviceCard(device: DeviceCardCatalog.oura("Oura Ring 4"),
                           isActive: false, isLiveConnected: false,
                           onMakeActive: {}, onRename: {}, onRemove: {})
            }
        }
    }
}
#endif

// MARK: - Preview

#if DEBUG
#Preview("Devices") {
    let model = AppModel()
    return DevicesView()
        .environmentObject(model)
        .environmentObject(model.live)
        .frame(width: 480, height: 760)
        .background(StrandPalette.surfaceBase)
        .preferredColorScheme(.dark)
}
#endif
