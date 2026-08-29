import SwiftUI

public enum DeviceCommandTone: Sendable, Equatable {
    case good, warning, critical, neutral

    public var color: Color {
        switch self {
        case .good: StrandPalette.statusPositive
        case .warning: StrandPalette.statusWarning
        case .critical: StrandPalette.metricRose
        case .neutral: StrandPalette.textSecondary
        }
    }
}

public struct DeviceCommandStatusItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let value: String
    public let tone: DeviceCommandTone
    public let subline: String?

    public init(
        id: String,
        label: String,
        value: String,
        tone: DeviceCommandTone = .neutral,
        subline: String? = nil
    ) {
        self.id = id
        self.label = label
        self.value = value
        self.tone = tone
        self.subline = subline
    }
}

/// Compact production translation of the design lab's operational hero.
public struct DeviceCommandCenterHero: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public let name: String
    public let metadata: String
    public let title: String
    public let detail: String
    public let tone: DeviceCommandTone
    public let symbol: String
    public let bondLabel: String
    public let bondTone: DeviceCommandTone
    public let metrics: [DeviceCommandStatusItem]
    public let systemItems: [DeviceCommandStatusItem]
    public let onMenu: () -> Void

    public init(
        name: String,
        metadata: String,
        title: String,
        detail: String,
        tone: DeviceCommandTone,
        symbol: String,
        bondLabel: String,
        bondTone: DeviceCommandTone,
        metrics: [DeviceCommandStatusItem],
        systemItems: [DeviceCommandStatusItem],
        onMenu: @escaping () -> Void
    ) {
        self.name = name
        self.metadata = metadata
        self.title = title
        self.detail = detail
        self.tone = tone
        self.symbol = symbol
        self.bondLabel = bondLabel
        self.bondTone = bondTone
        self.metrics = metrics
        self.systemItems = systemItems
        self.onMenu = onMenu
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(name.uppercased())
                            .font(StrandFont.micro.weight(.bold))
                            .tracking(1)
                            .foregroundStyle(Color.white.opacity(0.66))
                            .lineLimit(1)
                        Circle()
                            .fill(bondTone.color)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                        Text(bondLabel.uppercased())
                            .font(StrandFont.micro.weight(.bold))
                            .foregroundStyle(bondTone == .neutral ? Color.white.opacity(0.58) : bondTone.color)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }
                    Text(title)
                        .font(StrandFont.title1)
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail)
                        .font(StrandFont.footnote)
                        .foregroundStyle(Color.white.opacity(0.66))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(metadata)
                        .font(StrandFont.micro)
                        .monospacedDigit()
                        .foregroundStyle(Color.white.opacity(0.44))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                .accessibilityElement(children: .combine)

                Spacer(minLength: 4)

                VStack(spacing: 4) {
                    ZStack {
                        Circle().fill(tone.color.opacity(0.16))
                        Circle().strokeBorder(tone.color.opacity(0.38), lineWidth: 1)
                        Image(systemName: symbol)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(tone.color)
                    }
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)

                    Button(action: onMenu) {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.white.opacity(0.09), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(StressModulePressStyle())
                    .accessibilityLabel("Device actions, \(bondLabel)")
                }
            }

            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(metrics.prefix(3))) { item in
                        metric(item)
                    }
                }
            } else {
                HStack(spacing: 0) {
                    ForEach(Array(metrics.prefix(3))) { item in
                        if item.id != metrics.first?.id { metricDivider }
                        metric(item)
                    }
                }
            }

            HStack(spacing: 4) {
                ForEach(Array(systemItems.prefix(7))) { item in
                    Capsule(style: .continuous)
                        .fill(item.tone.color.opacity(item.tone == .neutral ? 0.24 : 0.9))
                        .frame(maxWidth: .infinity)
                        .frame(height: 4)
                }
            }
            .accessibilityHidden(true)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(StrandPalette.commandSurface)
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(tone.color.opacity(0.12))
                        .frame(width: 140, height: 140)
                        .offset(x: 60, y: -82)
                        .accessibilityHidden(true)
                }
        )
        .clipShape(.rect(cornerRadius: 20, style: .continuous))
    }

    private func metric(_ item: DeviceCommandStatusItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.label.uppercased())
                .font(StrandFont.micro.weight(.bold))
                .tracking(0.55)
                .foregroundStyle(Color.white.opacity(0.44))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(item.value)
                .font(StrandFont.captionNumber.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(item.tone == .neutral ? Color.white : item.tone.color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var metricDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 1, height: 30)
            .padding(.horizontal, 8)
            .accessibilityHidden(true)
    }
}

public struct DeviceCommandPriorityCard: View {
    public let eyebrow: String
    public let title: String
    public let detail: String
    public let actionTitle: String
    public let icon: String
    public let tone: DeviceCommandTone
    public let enabled: Bool
    public let action: () -> Void

    public init(
        eyebrow: String,
        title: String,
        detail: String,
        actionTitle: String,
        icon: String,
        tone: DeviceCommandTone,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.detail = detail
        self.actionTitle = actionTitle
        self.icon = icon
        self.tone = tone
        self.enabled = enabled
        self.action = action
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 10) {
                priorityCopy
                Spacer(minLength: 6)
                actionButton.fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 10) {
                priorityCopy
                actionButton
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(tone.color.opacity(0.055))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(tone.color.opacity(0.18), lineWidth: 1)
                }
        )
    }

    private var priorityCopy: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(tone.color)
                .frame(width: 32, height: 32)
                .background(tone.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(eyebrow.uppercased())
                    .font(StrandFont.micro.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(StrandPalette.textTertiary)
                Text(title)
                    .font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(detail)
                    .font(StrandFont.micro)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var actionButton: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(actionTitle).lineLimit(1)
                Image(systemName: "arrow.right").accessibilityHidden(true)
            }
            .font(StrandFont.caption.weight(.semibold))
            .foregroundStyle(StrandPalette.surfaceRaised)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(StrandPalette.textPrimary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(StressModulePressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.42)
        .accessibilityLabel(actionTitle)
    }
}

public struct DeviceCommandSystemsSummary: Equatable, Sendable {
    public let total: Int
    public let verified: Int
    public let attention: Int
    public let unknown: Int

    public init(items: [DeviceCommandStatusItem]) {
        total = items.count
        verified = items.filter { $0.tone == .good }.count
        attention = items.filter { $0.tone == .warning || $0.tone == .critical }.count
        unknown = max(0, total - verified - attention)
    }

    public var allVerified: Bool {
        total > 0 && verified == total
    }

    public var statusLabel: String {
        if attention > 0 { return "\(attention) flagged" }
        if unknown > 0 { return "\(unknown) unknown" }
        if allVerified { return "Systems verified" }
        return "No systems"
    }
}

public struct DeviceCommandSystemsMatrix: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public let items: [DeviceCommandStatusItem]

    public init(items: [DeviceCommandStatusItem]) {
        self.items = items
    }

    private var summary: DeviceCommandSystemsSummary {
        DeviceCommandSystemsSummary(items: items)
    }

    private var columns: [GridItem] {
        let count = dynamicTypeSize.isAccessibilitySize ? 1 : 3
        return Array(repeating: GridItem(.flexible(), spacing: 6), count: count)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("SYSTEM MAP")
                        .font(StrandFont.overline)
                        .tracking(1)
                        .foregroundStyle(StrandPalette.textTertiary)
                    Text("\(summary.verified)/\(summary.total)")
                        .font(StrandFont.title2)
                        .monospacedDigit()
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                Spacer(minLength: 6)
                Label(
                    summary.statusLabel,
                    systemImage: summary.attention > 0
                        ? "exclamationmark.triangle.fill"
                        : (summary.unknown > 0
                            ? "questionmark.circle.fill"
                            : (summary.allVerified ? "checkmark.circle.fill" : "circle.dashed")))
                    .font(StrandFont.micro.weight(.bold))
                    .foregroundStyle(
                        summary.attention > 0
                            ? StrandPalette.statusWarning
                            : (summary.unknown > 0
                                ? StrandPalette.textSecondary
                                : (summary.allVerified
                                    ? StrandPalette.statusPositive
                                    : StrandPalette.textTertiary)))
                    .multilineTextAlignment(.trailing)
            }

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(items) { item in
                    DeviceCommandSystemNode(item: item)
                }
            }
        }
        .padding(12)
        .background(commandCardShape(radius: 18, inset: true))
        .accessibilityElement(children: .contain)
    }
}

private struct DeviceCommandSystemNode: View {
    let item: DeviceCommandStatusItem

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(item.tone.color)
                    .accessibilityHidden(true)
                Text(shortLabel)
                    .font(StrandFont.micro.weight(.bold))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Spacer(minLength: 2)
                Circle()
                    .fill(item.tone.color.opacity(item.tone == .neutral ? 0.4 : 1))
                    .frame(width: 5, height: 5)
                    .accessibilityHidden(true)
            }
            Text(item.value)
                .font(StrandFont.micro.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(item.tone == .neutral ? StrandPalette.textPrimary : item.tone.color)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
            if let subline = item.subline, item.tone != .good {
                Text(subline)
                    .font(StrandFont.micro)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 66, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(StrandPalette.surfaceRaised)
                .overlay(alignment: .top) {
                    Capsule(style: .continuous)
                        .fill(item.tone.color.opacity(item.tone == .neutral ? 0.16 : 0.75))
                        .frame(height: 2)
                        .padding(.horizontal, 8)
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.label), \(item.value)\(item.subline.map { ", \($0)" } ?? "")")
    }

    private var icon: String {
        switch item.id {
        case "ble": "antenna.radiowaves.left.and.right"
        case "bond": "lock.shield.fill"
        case "sync": "arrow.triangle.2.circlepath"
        case "r22": "wave.3.right"
        case "packet": "waveform.path.ecg"
        case "clock": "clock.arrow.circlepath"
        case "health": "heart.text.square.fill"
        case "issues": "exclamationmark.bubble.fill"
        default: "circle.dotted"
        }
    }

    private var shortLabel: String {
        switch item.id {
        case "ble": "BLE"
        case "bond": "BOND"
        case "sync": "HISTORY"
        case "r22": "DEEP DATA"
        case "packet": "PACKET"
        case "clock": "CLOCK"
        case "health": "DEVICE"
        case "issues": "ISSUES"
        default: item.label.uppercased()
        }
    }
}

public struct DeviceCommandTelemetryDeck: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public let connected: Bool
    public let batteryFraction: Double?
    public let syncRows: [DeviceCommandStatusItem]
    public let powerRows: [DeviceCommandStatusItem]

    public init(
        connected: Bool,
        batteryFraction: Double?,
        syncRows: [DeviceCommandStatusItem],
        powerRows: [DeviceCommandStatusItem]
    ) {
        self.connected = connected
        self.batteryFraction = batteryFraction
        self.syncRows = syncRows
        self.powerRows = powerRows
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("TELEMETRY", systemImage: "dot.radiowaves.left.and.right")
                    .font(StrandFont.micro.weight(.bold))
                    .tracking(0.9)
                    .foregroundStyle(Color.white.opacity(0.5))
                Spacer()
                Text(connected ? "LIVE" : "HOLDING")
                    .font(StrandFont.micro.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(connected ? StrandPalette.statusPositive : Color.white.opacity(0.5))
            }

            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    historyReadout
                    powerReadout
                }
            } else {
                HStack(alignment: .center, spacing: 14) {
                    historyReadout
                    Rectangle()
                        .fill(Color.white.opacity(0.1))
                        .frame(width: 1, height: 72)
                        .accessibilityHidden(true)
                    powerReadout
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(StrandPalette.commandSurface)
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill((connected ? StrandPalette.statusPositive : StrandPalette.textSecondary).opacity(0.09))
                        .frame(width: 120, height: 120)
                        .offset(x: 48, y: 66)
                        .accessibilityHidden(true)
                }
        )
        .clipShape(.rect(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var historyReadout: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("HISTORY")
                .font(StrandFont.micro.weight(.bold))
                .tracking(0.7)
                .foregroundStyle(Color.white.opacity(0.42))
            Text(value("status", in: syncRows))
                .font(StrandFont.title2)
                .foregroundStyle(syncTone.color)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
            Text("\(value("completed", in: syncRows)) · \(value("window", in: syncRows))")
                .font(StrandFont.micro)
                .monospacedDigit()
                .foregroundStyle(Color.white.opacity(0.5))
                .lineLimit(2)
                .minimumScaleFactor(0.72)
            Text(value("chunks", in: syncRows))
                .font(StrandFont.micro.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.68))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var powerReadout: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.1), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: max(0, min(batteryFraction ?? 0, 1)))
                    .stroke(batteryTone.color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(value("battery", in: powerRows))
                    .font(StrandFont.captionNumber.weight(.semibold))
                    .foregroundStyle(batteryTone.color)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: 58, height: 58)
            .accessibilityHidden(true)

            VStack(spacing: 5) {
                telemetryRow("EST.", value("runtime", in: powerRows), tone: batteryTone)
                telemetryRow("CHARGE", value("charging", in: powerRows), tone: .neutral)
                telemetryRow("LINK", value("uptime", in: powerRows), tone: connected ? .good : .neutral)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery \(value("battery", in: powerRows)), estimated \(value("runtime", in: powerRows)), charging \(value("charging", in: powerRows)), connection \(value("uptime", in: powerRows))")
    }

    private var syncTone: DeviceCommandTone {
        syncRows.first(where: { $0.id == "status" })?.tone ?? .neutral
    }

    private var batteryTone: DeviceCommandTone {
        powerRows.first(where: { $0.id == "battery" })?.tone ?? .neutral
    }

    private func telemetryRow(_ label: String, _ value: String, tone: DeviceCommandTone) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(label)
                .font(StrandFont.micro.weight(.bold))
                .foregroundStyle(Color.white.opacity(0.4))
            Spacer(minLength: 4)
            Text(value)
                .font(StrandFont.micro.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tone == .neutral ? Color.white : tone.color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private func value(_ id: String, in rows: [DeviceCommandStatusItem]) -> String {
        rows.first(where: { $0.id == id })?.value ?? "—"
    }
}

public struct DeviceCommandDeck: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public let connected: Bool
    public let syncEnabled: Bool
    public let vibrationEnabled: Bool
    public let batteryEnabled: Bool
    public let linkEnabled: Bool
    public let onSync: () -> Void
    public let onVibration: () -> Void
    public let onBattery: () -> Void
    public let onLink: () -> Void

    public init(
        connected: Bool,
        syncEnabled: Bool,
        vibrationEnabled: Bool,
        batteryEnabled: Bool,
        linkEnabled: Bool,
        onSync: @escaping () -> Void,
        onVibration: @escaping () -> Void,
        onBattery: @escaping () -> Void,
        onLink: @escaping () -> Void
    ) {
        self.connected = connected
        self.syncEnabled = syncEnabled
        self.vibrationEnabled = vibrationEnabled
        self.batteryEnabled = batteryEnabled
        self.linkEnabled = linkEnabled
        self.onSync = onSync
        self.onVibration = onVibration
        self.onBattery = onBattery
        self.onLink = onLink
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("COMMAND DECK")
                        .font(StrandFont.overline)
                        .tracking(1)
                        .foregroundStyle(StrandPalette.textTertiary)
                    Text("Direct controls")
                        .font(StrandFont.micro)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer(minLength: 6)
                Text("04")
                    .font(StrandFont.title2)
                    .monospacedDigit()
                    .foregroundStyle(StrandPalette.textPrimary)
            }

            primaryButton

            LazyVGrid(columns: commandColumns, spacing: 6) {
                ForEach(secondaryCommands) { command in
                    DeviceCommandTile(command: command)
                }
            }
        }
        .padding(12)
        .background(commandCardShape(radius: 18, inset: true))
    }

    private var commandColumns: [GridItem] {
        let count = dynamicTypeSize.isAccessibilitySize ? 1 : 3
        return Array(repeating: GridItem(.flexible(), spacing: 6), count: count)
    }

    private var primaryButton: some View {
        let title = connected ? "Sync now" : "Reconnect"
        let detail = connected ? "Fetch history on demand" : "Search for the remembered link"
        let icon = connected ? "arrow.triangle.2.circlepath" : "link"
        let enabled = connected ? syncEnabled : linkEnabled
        let action = connected ? onSync : onLink

        return Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(StrandFont.caption.weight(.semibold))
                    Text(detail)
                        .font(StrandFont.micro)
                        .foregroundStyle(Color.white.opacity(0.56))
                }
                Spacer(minLength: 6)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.62))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(StrandPalette.surfaceRaised)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(StrandPalette.textPrimary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(StressModulePressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.42)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }

    private var secondaryCommands: [DeviceCommandDefinition] {
        let sync = DeviceCommandDefinition(
            id: "sync", icon: "arrow.triangle.2.circlepath", title: "Sync", detail: "Now",
            accessibilityLabel: "Sync now", tone: .neutral, enabled: syncEnabled, action: onSync)
        let vibration = DeviceCommandDefinition(
            id: "vibration", icon: "iphone.radiowaves.left.and.right", title: "Vibration", detail: "Test",
            accessibilityLabel: "Test vibration", tone: .neutral, enabled: vibrationEnabled, action: onVibration)
        let battery = DeviceCommandDefinition(
            id: "battery", icon: "battery.75percent", title: "Battery", detail: "Refresh",
            accessibilityLabel: "Refresh battery", tone: .warning, enabled: batteryEnabled, action: onBattery)
        let link = DeviceCommandDefinition(
            id: "link", icon: "link", title: "Link", detail: connected ? "Refresh" : "Reconnect",
            accessibilityLabel: connected ? "Refresh link" : "Reconnect", tone: connected ? .neutral : .good,
            enabled: linkEnabled, action: onLink)
        return connected ? [vibration, battery, link] : [sync, vibration, battery]
    }
}

private struct DeviceCommandDefinition: Identifiable {
    let id: String
    let icon: String
    let title: String
    let detail: String
    let accessibilityLabel: String
    let tone: DeviceCommandTone
    let enabled: Bool
    let action: () -> Void
}

private struct DeviceCommandTile: View {
    let command: DeviceCommandDefinition

    var body: some View {
        Button(action: command.action) {
            VStack(alignment: .leading, spacing: 5) {
                Image(systemName: command.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(command.tone == .neutral ? StrandPalette.accent : command.tone.color)
                    .frame(width: 28, height: 28)
                    .background(
                        (command.tone == .neutral ? StrandPalette.accent : command.tone.color).opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
                Text(command.title)
                    .font(StrandFont.micro.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(command.detail.uppercased())
                    .font(StrandFont.micro.weight(.bold))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(StressModulePressStyle())
        .disabled(!command.enabled)
        .opacity(command.enabled ? 1 : 0.42)
        .accessibilityLabel(command.accessibilityLabel)
    }
}

public struct DeviceCommandNavigationRow: View {
    public let title: String
    public let detail: String
    public let icon: String
    public let status: String?
    public let statusTone: DeviceCommandTone

    public init(
        title: String,
        detail: String,
        icon: String,
        status: String? = nil,
        statusTone: DeviceCommandTone = .neutral
    ) {
        self.title = title
        self.detail = detail
        self.icon = icon
        self.status = status
        self.statusTone = statusTone
    }

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(StrandPalette.accent)
                .frame(width: 32, height: 32)
                .background(StrandPalette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(detail)
                    .font(StrandFont.micro)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
            if let status {
                MicroBadge(
                    LocalizedStringKey(status),
                    systemImage: statusTone == .good ? "record.circle.fill" : "circle",
                    tint: statusTone.color
                )
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(commandCardShape(radius: 13))
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

public struct DeviceCommandPrivacyFooter: View {
    public init() {}

    public var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary)
                .padding(.top, 1)
            Text("All data is stored locally on this device. Private by design. You're in control.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 13).fill(StrandPalette.surfaceInset.opacity(0.7)))
        .accessibilityElement(children: .combine)
    }
}

private func commandCardShape(radius: CGFloat, inset: Bool = false) -> some View {
    RoundedRectangle(cornerRadius: radius, style: .continuous)
        .fill(inset ? StrandPalette.surfaceInset.opacity(0.42) : StrandPalette.surfaceRaised)
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(StrandPalette.hairline, lineWidth: 1)
        }
}
