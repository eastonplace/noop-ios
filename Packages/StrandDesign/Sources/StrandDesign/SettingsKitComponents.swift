import SwiftUI

// MARK: - Settings Kit

/// A production-bound settings grammar. Values and actions are supplied by the
/// feature so the design package never owns or fabricates settings state.
public struct SettingsDestination {
    private let build: () -> AnyView

    public init(_ build: @escaping () -> AnyView) {
        self.build = build
    }

    public func callAsFunction() -> AnyView {
        build()
    }
}

public enum SettingsRowModel: Identifiable {
    case nav(id: String, icon: String, tint: Color, title: String, value: String?, destination: SettingsDestination)
    case navDetail(id: String, icon: String, tint: Color, title: String, subtitle: String, value: String?, destination: SettingsDestination)
    case toggle(id: String, icon: String, tint: Color, title: String, subtitle: String?, isOn: Binding<Bool>)
    case segmented(id: String, icon: String, tint: Color, title: String, options: [String], selection: Binding<String>)
    case stepper(id: String, icon: String, tint: Color, title: String, unit: String,
                 value: Binding<Double>, step: Double, range: ClosedRange<Double>, format: (Double) -> String)
    case info(id: String, icon: String, tint: Color, title: String, value: String)
    case link(id: String, icon: String, tint: Color, title: String, action: () -> Void)
    case destructive(id: String, icon: String, title: String, action: () -> Void)
    case custom(id: String, view: AnyView)

    public var id: String {
        switch self {
        case .nav(let id, _, _, _, _, _), .navDetail(let id, _, _, _, _, _, _),
             .toggle(let id, _, _, _, _, _), .segmented(let id, _, _, _, _, _),
             .stepper(let id, _, _, _, _, _, _, _, _),
             .info(let id, _, _, _, _), .link(let id, _, _, _, _),
             .destructive(let id, _, _, _), .custom(let id, _):
            return id
        }
    }

    public static func custom<Content: View>(id: String, @ViewBuilder view: () -> Content) -> Self {
        .custom(id: id, view: AnyView(view()))
    }

    public static func nav<Destination: View>(
        id: String, icon: String, tint: Color, title: String, value: String? = nil,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> Self {
        .nav(id: id, icon: icon, tint: tint, title: title, value: value,
             destination: SettingsDestination { AnyView(destination()) })
    }

    public static func navDetail<Destination: View>(
        id: String, icon: String, tint: Color, title: String, subtitle: String,
        value: String? = nil, @ViewBuilder destination: @escaping () -> Destination
    ) -> Self {
        .navDetail(id: id, icon: icon, tint: tint, title: title, subtitle: subtitle,
                   value: value, destination: SettingsDestination { AnyView(destination()) })
    }
}

public struct SettingsSectionModel: Identifiable {
    public let id: String
    public let header: String
    public var footer: String?
    public let rows: [SettingsRowModel]

    public init(id: String, header: String, footer: String? = nil, rows: [SettingsRowModel]) {
        self.id = id
        self.header = header
        self.footer = footer
        self.rows = rows
    }
}

public struct SettingsProfileHeader: View {
    public let initials: String
    public let name: String
    public let subtitle: String
    public var recovery: Double?
    public var action: () -> Void

    public init(initials: String, name: String, subtitle: String, recovery: Double? = nil,
                action: @escaping () -> Void = {}) {
        self.initials = initials
        self.name = name
        self.subtitle = subtitle
        self.recovery = recovery
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(StrandPalette.surfaceInset)
                    Circle().strokeBorder(
                        recovery.map { RecoveryBands.color(for: $0).opacity(0.8) }
                            ?? StrandPalette.hairlineStrong,
                        lineWidth: 2
                    )
                    Text(initials.uppercased())
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .tracking(0.5)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(StrandFont.caption.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(subtitle)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(StrandPalette.surfaceRaised)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(StrandPalette.hairline, lineWidth: 1)
                    }
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(StressModulePressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(subtitle). Opens profile")
    }
}

public struct SettingsSectionCard: View {
    public let section: SettingsSectionModel

    public init(section: SettingsSectionModel) { self.section = section }

    public var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(section.header.uppercased())
                .font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textSecondary)
                .padding(.horizontal, 4)
            VStack(spacing: 0) {
                ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                    SettingsRowView(row: row)
                    if index < section.rows.count - 1 {
                        Divider().overlay(StrandPalette.hairline)
                            .padding(.leading, row.isCustom ? 0 : 47)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(StrandPalette.surfaceRaised)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(StrandPalette.hairline, lineWidth: 1)
                    }
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            if let footer = section.footer {
                Text(footer)
                    .font(StrandFont.micro)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private extension SettingsRowModel {
    var isCustom: Bool { if case .custom = self { return true }; return false }
}

public struct SettingsRowView: View {
    public let row: SettingsRowModel
    public init(row: SettingsRowModel) { self.row = row }

    public var body: some View {
        switch row {
        case .nav(_, let icon, let tint, let title, let value, let destination):
            NavigationLink {
                destination()
            } label: {
                rowChrome(icon: icon, tint: tint, title: title) {
                    if let value {
                        Text(value).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .buttonStyle(StressModulePressStyle())
            .accessibilityLabel(value.map { "\(title), \($0)" } ?? title)

        case .navDetail(_, let icon, let tint, let title, let subtitle, let value, let destination):
            NavigationLink {
                destination()
            } label: {
                rowChrome(icon: icon, tint: tint, title: title, subtitle: subtitle) {
                    if let value {
                        Text(value).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .buttonStyle(StressModulePressStyle())
            .accessibilityLabel(value.map { "\(title), \($0). \(subtitle)" } ?? "\(title). \(subtitle)")

        case .toggle(_, let icon, let tint, let title, let subtitle, let isOn):
            rowChrome(icon: icon, tint: tint, title: title, subtitle: subtitle) {
                Toggle("", isOn: isOn).labelsHidden().tint(StrandPalette.textPrimary)
                    .scaleEffect(0.82, anchor: .trailing)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title), \(isOn.wrappedValue ? "on" : "off")")
            .accessibilityAction { isOn.wrappedValue.toggle() }

        case .segmented(_, let icon, let tint, let title, let options, let selection):
            rowChrome(icon: icon, tint: tint, title: title) {
                HStack(spacing: 4) {
                    ForEach(options, id: \.self) { option in
                        let selected = selection.wrappedValue == option
                        Button {
                            withAnimation(StrandMotion.interactive) { selection.wrappedValue = option }
                            StrandHaptic.selection.play()
                        } label: {
                            Text(option)
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                .lineLimit(1).fixedSize()
                                .foregroundStyle(selected ? StrandPalette.surfaceRaised : StrandPalette.textSecondary)
                                .padding(.horizontal, 9).padding(.vertical, 5.5)
                                .background(Capsule(style: .continuous)
                                    .fill(selected ? StrandPalette.textPrimary : StrandPalette.surfaceInset))
                        }
                        .buttonStyle(StressModulePressStyle())
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title), \(selection.wrappedValue), options \(options.joined(separator: ", "))")

        case .stepper(_, let icon, let tint, let title, let unit, let value, let step, let range, let format):
            rowChrome(icon: icon, tint: tint, title: title) {
                HStack(spacing: 7) {
                    stepButton("minus", enabled: value.wrappedValue > range.lowerBound) {
                        value.wrappedValue = max(range.lowerBound, value.wrappedValue - step)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(format(value.wrappedValue)).font(StrandFont.captionNumber).monospacedDigit()
                            .foregroundStyle(StrandPalette.textPrimary).contentTransition(.numericText())
                        if !unit.isEmpty { Text(unit).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary) }
                    }
                    .frame(minWidth: 52)
                    stepButton("plus", enabled: value.wrappedValue < range.upperBound) {
                        value.wrappedValue = min(range.upperBound, value.wrappedValue + step)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title), \(format(value.wrappedValue)) \(unit)")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: value.wrappedValue = min(range.upperBound, value.wrappedValue + step)
                case .decrement: value.wrappedValue = max(range.lowerBound, value.wrappedValue - step)
                @unknown default: break
                }
            }

        case .info(_, let icon, let tint, let title, let value):
            rowChrome(icon: icon, tint: tint, title: title) {
                Text(value).font(StrandFont.footnote).monospacedDigit().foregroundStyle(StrandPalette.textTertiary)
            }
            .accessibilityElement(children: .combine)

        case .link(_, let icon, let tint, let title, let action):
            Button(action: action) {
                rowChrome(icon: icon, tint: tint, title: title) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .buttonStyle(StressModulePressStyle())
            .accessibilityLabel("\(title), opens outside the app")

        case .destructive(_, let icon, let title, let action):
            Button(action: action) {
                HStack(spacing: 11) {
                    Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StrandPalette.metricRose).frame(width: 30, height: 30)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(StrandPalette.metricRose.opacity(0.1)))
                    Text(title).font(StrandFont.caption.weight(.semibold)).foregroundStyle(StrandPalette.metricRose)
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 13).padding(.vertical, 10).contentShape(Rectangle())
            }
            .buttonStyle(StressModulePressStyle()).accessibilityLabel(title)

        case .custom(_, let view): view
        }
    }

    private func stepButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(StrandMotion.interactive) { action() }
            StrandHaptic.selection.play()
        } label: {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold))
                .foregroundStyle(enabled ? StrandPalette.textPrimary : StrandPalette.textTertiary.opacity(0.5))
                .frame(width: 26, height: 26).background(Circle().fill(StrandPalette.surfaceInset))
        }
        .buttonStyle(StressModulePressStyle()).disabled(!enabled).accessibilityHidden(true)
    }

    @ViewBuilder private func rowChrome<Trailing: View>(
        icon: String, tint: Color, title: String, subtitle: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.12)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(StrandFont.caption.weight(.medium)).foregroundStyle(StrandPalette.textPrimary)
                if let subtitle { Text(subtitle).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary) }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 13).padding(.vertical, 10).contentShape(Rectangle())
    }
}

public struct SettingsScreenTemplate: View {
    public var profile: SettingsProfileHeader?
    public let sections: [SettingsSectionModel]
    public var versionLine: String?

    public init(profile: SettingsProfileHeader? = nil, sections: [SettingsSectionModel], versionLine: String? = nil) {
        self.profile = profile
        self.sections = sections
        self.versionLine = versionLine
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            profile
            ForEach(sections) { SettingsSectionCard(section: $0) }
            if let versionLine {
                Text(versionLine).font(StrandFont.micro).monospacedDigit()
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.top, 2)
            }
        }
    }
}
