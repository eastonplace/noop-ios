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

    public init(id: String, label: String, value: String,
                tone: DeviceCommandTone = .neutral, subline: String? = nil) {
        self.id = id; self.label = label; self.value = value; self.tone = tone; self.subline = subline
    }
}

/// Production form of Design Lab component 40's identity card.
public struct DeviceCommandIdentityCard: View {
    public let name: String
    public let firmware: String
    public let deviceID: String
    public let bondLabel: String
    public let bondTone: DeviceCommandTone
    public let batteryFraction: Double?
    public let wristLabel: String
    public let connectionLabel: String
    public let onMenu: () -> Void

    public init(name: String, firmware: String, deviceID: String, bondLabel: String,
                bondTone: DeviceCommandTone, batteryFraction: Double?, wristLabel: String,
                connectionLabel: String, onMenu: @escaping () -> Void) {
        self.name = name; self.firmware = firmware; self.deviceID = deviceID
        self.bondLabel = bondLabel; self.bondTone = bondTone; self.batteryFraction = batteryFraction
        self.wristLabel = wristLabel; self.connectionLabel = connectionLabel; self.onMenu = onMenu
    }

    public var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(StrandPalette.surfaceInset)
                    Capsule(style: .continuous)
                        .fill(StrandPalette.textPrimary.opacity(0.85))
                        .frame(width: 14, height: 30)
                        .overlay(RoundedRectangle(cornerRadius: 2).fill(StrandPalette.surfaceRaised.opacity(0.9)).frame(width: 8, height: 10))
                }
                .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(StrandFont.caption.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Text("\(firmware) · \(deviceID)").font(StrandFont.micro).monospacedDigit()
                        .foregroundStyle(StrandPalette.textTertiary).lineLimit(1).minimumScaleFactor(0.65)
                }
                Spacer(minLength: 8)
                Button(action: onMenu) {
                    HStack(spacing: 5) {
                        Circle().fill(bondTone.color).frame(width: 6, height: 6)
                        Text(bondLabel)
                            .font(StrandFont.micro.weight(.bold))
                            .foregroundStyle(bondTone == .neutral ? StrandPalette.textSecondary : bondTone.color)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Capsule(style: .continuous).fill(bondTone.color.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Device actions, \(bondLabel)")
            }
            Divider().overlay(StrandPalette.hairline)
            GeometryReader { proxy in
                let width = max(1, (proxy.size.width - 2) / 3)
                HStack(spacing: 0) {
                    column("battery.75percent", batteryFraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—", "Battery", batteryTone, .leading).frame(width: width)
                    divider
                    column("applewatch", wristLabel, "Wrist", .neutral, .center).frame(width: width)
                    divider
                    column("clock", connectionLabel, "Connection", .neutral, .trailing).frame(width: width)
                }
            }.frame(height: 40)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(cardShape(radius: 18, highlighted: true))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(firmware), \(bondLabel), battery \(batteryFraction.map { "\(Int(($0 * 100).rounded())) percent" } ?? "unknown"), \(wristLabel), connected \(connectionLabel)")
    }

    private var batteryTone: DeviceCommandTone {
        guard let batteryFraction else { return .neutral }
        return batteryFraction < 0.20 ? .warning : .neutral
    }
    private var divider: some View { Rectangle().fill(StrandPalette.hairline).frame(width: 1, height: 34) }
    private func column(_ icon: String, _ value: String, _ label: String,
                        _ tone: DeviceCommandTone, _ alignment: HorizontalAlignment) -> some View {
        let frameAlignment: Alignment = alignment == .leading ? .leading : alignment == .trailing ? .trailing : .center
        return VStack(alignment: alignment, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(tone == .neutral ? StrandPalette.textTertiary : tone.color)
                Text(value).font(StrandFont.captionNumber).monospacedDigit()
                    .foregroundStyle(tone == .neutral ? StrandPalette.textPrimary : tone.color)
                    .lineLimit(1).minimumScaleFactor(0.65)
            }
            Text(label).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
        }.frame(maxWidth: .infinity, alignment: frameAlignment)
    }
}

public struct DeviceCommandStatusOverview: View {
    public let items: [DeviceCommandStatusItem]
    public let primaryIssue: String?
    public init(items: [DeviceCommandStatusItem], primaryIssue: String? = nil) {
        self.items = items; self.primaryIssue = primaryIssue
    }
    private var flagged: [DeviceCommandStatusItem] { items.filter { $0.tone == .warning || $0.tone == .critical } }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: flagged.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(flagged.isEmpty ? StrandPalette.statusPositive : StrandPalette.statusWarning)
                Text("Status overview").font(StrandFont.caption.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
                Spacer(minLength: 6)
                Text(flagged.isEmpty ? "ALL CLEAR" : "\(flagged.count) NEED ATTENTION")
                    .font(StrandFont.micro.weight(.bold))
                    .foregroundStyle(flagged.isEmpty ? StrandPalette.textTertiary : StrandPalette.statusWarning)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            if let primaryIssue {
                Text(primaryIssue).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 9) { ForEach(items) { row($0) } }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(cardShape(radius: 18))
        .accessibilityElement(children: .combine)
    }

    private func row(_ item: DeviceCommandStatusItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(item.tone.color.opacity(item.tone == .neutral ? 0.45 : 1)).frame(width: 5, height: 5).offset(y: -1.5)
                Text(item.label).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1).minimumScaleFactor(0.72)
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(item.value).font(StrandFont.captionNumber).monospacedDigit()
                        .foregroundStyle(item.tone == .neutral ? StrandPalette.textPrimary : item.tone.color)
                        .lineLimit(1).minimumScaleFactor(0.68)
                    if item.id != "issues", let subline = item.subline {
                        Text(subline).font(StrandFont.micro).monospacedDigit().foregroundStyle(StrandPalette.textTertiary)
                            .lineLimit(1).minimumScaleFactor(0.65)
                    }
                }
                .layoutPriority(1)
            }
            if item.id == "issues", let subline = item.subline {
                Text(subline)
                    .font(StrandFont.micro)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 13)
            }
        }
    }
}

public struct DeviceCommandInfoCard: View {
    public let icon: String
    public let title: String
    public let rows: [DeviceCommandStatusItem]
    public init(icon: String, title: String, rows: [DeviceCommandStatusItem]) {
        self.icon = icon; self.title = title; self.rows = rows
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(StrandPalette.textSecondary)
                Text(title).font(StrandFont.caption.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            VStack(spacing: 7) {
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(row.label).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
                            .lineLimit(1).minimumScaleFactor(0.65)
                        Spacer(minLength: 3)
                        Text(row.value).font(StrandFont.micro.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(row.tone == .neutral ? StrandPalette.textPrimary : row.tone.color)
                            .lineLimit(1).minimumScaleFactor(0.6)
                    }
                }
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(cardShape(radius: 14))
        .accessibilityElement(children: .combine)
    }
}

public struct DeviceCommandActionButton: View {
    public let icon: String
    public let title: String
    public let tone: DeviceCommandTone
    public let prominent: Bool
    public let enabled: Bool
    public let action: () -> Void

    public init(icon: String, title: String, tone: DeviceCommandTone = .neutral,
                prominent: Bool = false, enabled: Bool = true, action: @escaping () -> Void) {
        self.icon = icon; self.title = title; self.tone = tone; self.prominent = prominent
        self.enabled = enabled; self.action = action
    }
    public var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(prominent ? StrandPalette.surfaceRaised : (tone == .neutral ? StrandPalette.accent : tone.color))
                Text(title).font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(prominent ? StrandPalette.surfaceRaised : StrandPalette.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.65)
            }
            .frame(maxWidth: .infinity).frame(height: 46)
            .background(RoundedRectangle(cornerRadius: 13).fill(prominent ? StrandPalette.textPrimary : StrandPalette.surfaceRaised))
            .overlay { if !prominent { RoundedRectangle(cornerRadius: 13).strokeBorder(StrandPalette.hairline, lineWidth: 1) } }
            .contentShape(RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(StressModulePressStyle()).disabled(!enabled).opacity(enabled ? 1 : 0.42)
        .accessibilityLabel(title)
    }
}

public struct DeviceCommandPrivacyFooter: View {
    public init() {}
    public var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "lock.fill").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary).padding(.top, 1)
            Text("All data is stored locally on this device. Private by design. You're in control.")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12).background(RoundedRectangle(cornerRadius: 13).fill(StrandPalette.surfaceInset.opacity(0.7)))
        .accessibilityElement(children: .combine)
    }
}

private func cardShape(radius: CGFloat, highlighted: Bool = false) -> some View {
    RoundedRectangle(cornerRadius: radius, style: .continuous)
        .fill(StrandPalette.surfaceRaised)
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(highlighted
                ? AnyShapeStyle(LinearGradient(colors: [Color.white.opacity(0.16), StrandPalette.hairline], startPoint: .top, endPoint: .bottom))
                : AnyShapeStyle(StrandPalette.hairline), lineWidth: 1))
}
