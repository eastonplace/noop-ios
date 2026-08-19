import Foundation

struct DeviceHealthSummary: Equatable {
    enum Level: Int, Equatable {
        case healthy
        case informational
        case warning
        case critical
    }

    let level: Level
    let title: String
    let issueCount: Int
    let primaryIssue: String?
}

struct DeviceCommandAvailability: Equatable {
    let syncEnabled: Bool
    let vibrationEnabled: Bool
    let batteryEnabled: Bool
    let linkEnabled: Bool

    let syncReason: String?
    let vibrationReason: String?
    let batteryReason: String?
    let linkReason: String?
}

struct DeviceCommandCenterInput {
    var isWhoop: Bool
    var supportsR22: Bool
    var connected: Bool
    var encryptedBond: Bool
    var bluetoothUnavailableMessage: String?
    var reconnectGuide: String?
    var pairingHint: String?
    var rtcWarning: String?
    var lastSyncError: String?
    var strapNeedsReboot: Bool
    var batteryPct: Double?
    var historySyncExperimental: Bool
    var standardHRMode: String?
    var backfilling: Bool
    var syncChunksThisSession: Int
    var lastSyncedAt: TimeInterval?
    var historicalDataFrontierAt: TimeInterval?
    var historicalSyncSessionState: LiveState.HistoricalSyncSessionState
    var liveHeartRateAvailable: Bool
    var deepDataEnabled: Bool
    var r22FlagsAccepted: Int
    var r22FlagCount: Int
    var now: TimeInterval
}

struct DeviceCommandCenterSnapshot: Equatable {
    let health: DeviceHealthSummary
    let connectionLabel: String
    let bondLabel: String?
    let syncLabel: String
    let r22Label: String?
    let commands: DeviceCommandAvailability
}

enum DeviceCommandCenterStatusResolver {
    static let criticalBatteryThreshold = 15.0

    static func resolve(_ input: DeviceCommandCenterInput) -> DeviceCommandCenterSnapshot {
        DeviceCommandCenterSnapshot(
            health: health(input),
            connectionLabel: input.connected ? "Connected" : "Disconnected",
            bondLabel: bondLabel(input),
            syncLabel: syncLabel(input),
            r22Label: r22Label(input),
            commands: commands(input)
        )
    }

    static func health(_ input: DeviceCommandCenterInput) -> DeviceHealthSummary {
        struct Issue {
            let level: DeviceHealthSummary.Level
            let message: String
        }

        var issues: [Issue] = []
        if let message = nonempty(input.bluetoothUnavailableMessage) {
            issues.append(.init(level: .critical, message: message))
        }
        if let message = nonempty(input.reconnectGuide) {
            issues.append(.init(level: .critical, message: message))
        }
        if let message = nonempty(input.pairingHint) {
            issues.append(.init(level: .warning, message: message))
        } else if input.isWhoop, input.connected, !input.encryptedBond {
            issues.append(.init(level: .warning,
                                message: "Live HR only. History sync, vibration, and alarms require full pairing."))
        }
        if let message = nonempty(input.rtcWarning) {
            issues.append(.init(level: .warning, message: message))
        }
        if let message = nonempty(input.lastSyncError) {
            issues.append(.init(level: .warning, message: message))
        }
        if input.strapNeedsReboot {
            issues.append(.init(level: .warning, message: "The strap may need to be restarted."))
        }
        if let battery = input.batteryPct, battery <= criticalBatteryThreshold {
            issues.append(.init(level: .warning, message: "Battery is critically low."))
        }
        if input.historySyncExperimental {
            issues.append(.init(level: .informational, message: "History sync is experimental for this device."))
        }
        if let mode = nonempty(input.standardHRMode) {
            issues.append(.init(level: .informational, message: mode))
        }

        guard let primary = issues.first else {
            return .init(level: .healthy, title: "Device healthy", issueCount: 0, primaryIssue: nil)
        }
        let level = issues.map(\.level).max(by: { $0.rawValue < $1.rawValue }) ?? primary.level
        return .init(level: level,
                     title: level == .informational ? "Device connected" : "Issues detected",
                     issueCount: issues.count,
                     primaryIssue: primary.message)
    }

    static func syncLabel(_ input: DeviceCommandCenterInput) -> String {
        HistoricalSyncStatusResolver.resolve(
            connected: input.connected,
            liveHeartRateAvailable: input.liveHeartRateAvailable,
            sessionState: input.historicalSyncSessionState,
            lastSuccessfulBackfillAt: input.lastSyncedAt,
            historicalDataFrontierAt: input.historicalDataFrontierAt,
            lastSyncError: input.lastSyncError,
            historySyncExperimental: input.historySyncExperimental,
            chunks: input.syncChunksThisSession,
            now: input.now
        ).primary
    }

    static func bondLabel(_ input: DeviceCommandCenterInput) -> String? {
        guard input.isWhoop else { return nil }
        guard input.connected else { return "Not connected" }
        return input.encryptedBond ? "Full bond" : "Live HR only"
    }

    static func r22Label(_ input: DeviceCommandCenterInput) -> String? {
        guard input.isWhoop, input.supportsR22 else { return nil }
        guard input.deepDataEnabled else { return "Off" }
        guard input.connected, input.encryptedBond else { return "Requires full bond" }
        let total = max(1, input.r22FlagCount)
        if input.r22FlagsAccepted >= total { return "Accepted \(total)/\(total)" }
        if input.r22FlagsAccepted > 0 { return "Applying \(input.r22FlagsAccepted)/\(total)" }
        return "Configured · Monitoring"
    }

    static func commands(_ input: DeviceCommandCenterInput) -> DeviceCommandAvailability {
        let radioAvailable = input.bluetoothUnavailableMessage == nil
        let fullBond = input.connected && (!input.isWhoop || input.encryptedBond)
        return .init(
            syncEnabled: fullBond && !input.backfilling,
            vibrationEnabled: input.isWhoop && input.connected && input.encryptedBond,
            batteryEnabled: input.connected,
            linkEnabled: radioAvailable,
            syncReason: input.backfilling ? "A sync is already running." : (!fullBond ? "Connect and complete full pairing first." : nil),
            vibrationReason: !(input.isWhoop && input.connected && input.encryptedBond) ? "Vibration requires a fully paired WHOOP." : nil,
            batteryReason: !input.connected ? "Connect the device first." : nil,
            linkReason: !radioAvailable ? "Bluetooth is unavailable." : nil
        )
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func relativeAgo(_ timestamp: TimeInterval, now: TimeInterval) -> String {
        let seconds = max(0, Int(now - timestamp))
        let elapsedDaySeconds = 24 * 60 * 60
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(seconds / 60) min ago" }
        if seconds < elapsedDaySeconds { return "\(seconds / 3_600) hr ago" }
        return "\(seconds / elapsedDaySeconds) d ago"
    }
}

struct HistoricalSyncStatus: Equatable {
    let primary: String
    let savedHistory: String?
    let isCurrentSuccess: Bool
    let isFailure: Bool
}

enum HistoricalSyncStatusResolver {
    static func resolve(
        connected: Bool,
        liveHeartRateAvailable: Bool,
        sessionState: LiveState.HistoricalSyncSessionState,
        lastSuccessfulBackfillAt: TimeInterval?,
        historicalDataFrontierAt: TimeInterval?,
        lastSyncError: String?,
        historySyncExperimental: Bool,
        chunks: Int,
        now: TimeInterval
    ) -> HistoricalSyncStatus {
        let saved = savedHistoryLabel(
            frontier: historicalDataFrontierAt,
            lastSuccessfulBackfillAt: lastSuccessfulBackfillAt,
            now: now)

        guard connected else {
            return .init(primary: saved ?? "Not connected", savedHistory: saved,
                         isCurrentSuccess: false, isFailure: false)
        }
        if historySyncExperimental {
            return .init(primary: "History sync experimental", savedHistory: saved,
                         isCurrentSuccess: false, isFailure: false)
        }
        switch sessionState {
        case .disconnected:
            return .init(primary: saved ?? "Not connected", savedHistory: saved,
                         isCurrentSuccess: false, isFailure: false)
        case .waitingForSecureHandshake:
            return .init(
                primary: liveHeartRateAvailable
                    ? "Live HR only · History sync waiting for secure link"
                    : "History sync waiting for secure link",
                savedHistory: saved,
                isCurrentSuccess: false,
                isFailure: false)
        case .ready:
            return .init(primary: "Secure link ready · Waiting for history sync", savedHistory: saved,
                         isCurrentSuccess: false, isFailure: false)
        case .syncing:
            return .init(primary: "Syncing history · \(chunks) chunks received", savedHistory: saved,
                         isCurrentSuccess: false, isFailure: false)
        case .completed:
            if lastSyncError != nil {
                return .init(primary: "History sync completed with issues", savedHistory: saved,
                             isCurrentSuccess: false, isFailure: true)
            }
            let suffix = lastSuccessfulBackfillAt.map { " · \(relativeAgo($0, now: now))" } ?? ""
            return .init(primary: "History synced\(suffix)", savedHistory: saved,
                         isCurrentSuccess: true, isFailure: false)
        case .failed:
            return .init(primary: lastSyncError ?? "History sync failed", savedHistory: saved,
                         isCurrentSuccess: false, isFailure: true)
        }
    }

    private static func savedHistoryLabel(
        frontier: TimeInterval?,
        lastSuccessfulBackfillAt: TimeInterval?,
        now: TimeInterval
    ) -> String? {
        if let frontier {
            let date = Date(timeIntervalSince1970: frontier)
            let formatter = DateFormatter()
            formatter.dateStyle = Calendar.current.isDateInToday(date) ? .none : .medium
            formatter.timeStyle = .short
            return "Showing saved history through \(formatter.string(from: date))"
        }
        if let lastSuccessfulBackfillAt {
            return "Showing saved history from \(relativeAgo(lastSuccessfulBackfillAt, now: now))"
        }
        return nil
    }

    private static func relativeAgo(_ timestamp: TimeInterval, now: TimeInterval) -> String {
        let seconds = max(0, Int(now - timestamp))
        let elapsedDaySeconds = 24 * 60 * 60
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(seconds / 60) min ago" }
        if seconds < elapsedDaySeconds { return "\(seconds / 3_600) hr ago" }
        return "\(seconds / elapsedDaySeconds) d ago"
    }
}
