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
        guard input.connected else { return "Not connected" }
        if input.backfilling {
            return "Syncing · \(input.syncChunksThisSession) chunks received"
        }
        if input.lastSyncError != nil { return "Needs attention · Sync interrupted" }
        if input.historySyncExperimental { return "History sync experimental" }
        if let last = input.lastSyncedAt {
            return "Caught up · \(relativeAgo(last, now: input.now))"
        }
        return "Waiting for first sync"
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
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(seconds / 60) min ago" }
        if seconds < 86_400 { return "\(seconds / 3_600) hr ago" }
        return "\(seconds / 86_400) d ago"
    }
}
