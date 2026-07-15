import SwiftUI

/// Canonical Paper screen chrome: one compact row with an optional inline back affordance,
/// geometrically centered wordmark, and trailing controls. Screen context sits immediately below.
public struct PaperHeaderBar<Trailing: View>: View {
    private let title: LocalizedStringKey?
    private let subtitle: LocalizedStringKey?
    private let backAction: (() -> Void)?
    private let onDark: Bool
    @ViewBuilder private let trailing: () -> Trailing

    public init(
        title: LocalizedStringKey? = nil,
        subtitle: LocalizedStringKey? = nil,
        backAction: (() -> Void)? = nil,
        onDark: Bool = false,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.backAction = backAction
        self.onDark = onDark
        self.trailing = trailing
    }

    public var body: some View {
        let primary = onDark ? StrandPalette.onDarkPrimary : StrandPalette.textPrimary
        let secondary = onDark ? StrandPalette.onDarkSecondary : StrandPalette.textSecondary
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Text("N O O P")
                    .font(StrandFont.wordmark)
                    .tracking(StrandFont.wordmarkTracking)
                    .foregroundStyle(primary)
                HStack(spacing: 8) {
                    if let backAction {
                        Button(action: backAction) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Back")
                    }
                    Spacer(minLength: 0)
                    trailing()
                }
                .foregroundStyle(primary)
            }
            .frame(maxWidth: .infinity, minHeight: 28)

            if title != nil || subtitle != nil {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if let title {
                        Text(title)
                            .font(StrandFont.screenOverline)
                            .tracking(StrandFont.screenOverlineTracking)
                            .textCase(.uppercase)
                            .foregroundStyle(primary)
                    }
                    Spacer(minLength: 8)
                    if let subtitle {
                        Text(subtitle)
                            .font(StrandFont.caption)
                            .foregroundStyle(secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}

public extension PaperHeaderBar where Trailing == EmptyView {
    init(title: LocalizedStringKey? = nil, subtitle: LocalizedStringKey? = nil,
         backAction: (() -> Void)? = nil, onDark: Bool = false) {
        self.init(title: title, subtitle: subtitle, backAction: backAction, onDark: onDark) {
            EmptyView()
        }
    }
}

public struct PaperCard<Content: View>: View {
    private let padding: CGFloat
    @ViewBuilder private let content: () -> Content

    public init(padding: CGFloat = NoopMetrics.cardPadding,
                @ViewBuilder content: @escaping () -> Content) {
        self.padding = padding
        self.content = content
    }

    public var body: some View {
        StrandCard(padding: padding, content: content)
    }
}

// MARK: - Paper status and list primitives

public enum StatusBadgeStyle: Sendable {
    case connected, queued, success, blocked, live, paused, beta, experimental, imported, upToDate, ready, notConnected

    fileprivate var color: Color {
        switch self {
        case .connected, .success, .live, .upToDate, .ready: StrandPalette.success
        case .queued: StrandPalette.warning
        case .blocked, .paused: StrandPalette.error
        case .experimental: StrandPalette.journalAccent
        case .imported: StrandPalette.link
        case .beta, .notConnected: StrandPalette.textSecondary
        }
    }

    fileprivate var showsDot: Bool {
        switch self {
        case .connected, .queued, .success, .blocked, .live, .paused, .ready, .notConnected: true
        case .beta, .experimental, .imported, .upToDate: false
        }
    }
}

public struct StatusBadge: View {
    private let text: LocalizedStringKey
    private let style: StatusBadgeStyle
    private let customColor: Color?
    private let pulsing: Bool

    public init(
        _ text: LocalizedStringKey,
        style: StatusBadgeStyle,
        tint: Color? = nil,
        pulsing: Bool = false
    ) {
        self.text = text
        self.style = style
        self.customColor = tint
        self.pulsing = pulsing
    }

    private var color: Color { customColor ?? style.color }

    public var body: some View {
        HStack(spacing: 5) {
            if style.showsDot {
                if pulsing {
                    MicroStatusDot(color: color, isActive: true, diameter: 6)
                } else {
                    Circle().fill(color).frame(width: 6, height: 6)
                }
            }
            Text(text)
                .font(StrandFont.micro.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(StrandPalette.textPrimary)
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(color.opacity(0.10), in: Capsule(style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

public enum SettingsRowRole: Sendable { case standard, destructive }

public struct SettingsRow<Trailing: View>: View {
    private let icon: String?
    private let title: LocalizedStringKey
    private let subtitle: LocalizedStringKey?
    private let showsChevron: Bool
    private let role: SettingsRowRole
    @ViewBuilder private let trailing: () -> Trailing

    public init(
        icon: String? = nil,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        showsChevron: Bool = false,
        role: SettingsRowRole = .standard,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.showsChevron = showsChevron
        self.role = role
        self.trailing = trailing
    }

    public var body: some View {
        HStack(spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(role == .destructive ? StrandPalette.error : StrandPalette.textPrimary)
                    .frame(width: 36, height: 36)
                    .background(StrandPalette.inset, in: Circle())
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(StrandFont.body)
                    .foregroundStyle(role == .destructive ? StrandPalette.error : StrandPalette.textPrimary)
                if let subtitle {
                    Text(subtitle).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
            }
            Spacer(minLength: 8)
            trailing()
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .tint(StrandPalette.ink)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .frame(minHeight: NoopMetrics.rowHeight)
        .contentShape(Rectangle())
    }
}

public extension SettingsRow where Trailing == EmptyView {
    init(icon: String? = nil, title: LocalizedStringKey,
         subtitle: LocalizedStringKey? = nil, showsChevron: Bool = true,
         role: SettingsRowRole = .standard) {
        self.init(icon: icon, title: title, subtitle: subtitle, showsChevron: showsChevron, role: role) {
            EmptyView()
        }
    }
}

public struct DeviceRow<Trailing: View>: View {
    private let symbol: String
    private let name: LocalizedStringKey
    private let detail: LocalizedStringKey?
    private let statusText: LocalizedStringKey
    private let status: StatusBadgeStyle
    private let battery: Int?
    @ViewBuilder private let trailing: () -> Trailing

    public init(
        symbol: String,
        name: LocalizedStringKey,
        detail: LocalizedStringKey? = nil,
        statusText: LocalizedStringKey,
        status: StatusBadgeStyle,
        battery: Int? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.symbol = symbol
        self.name = name
        self.detail = detail
        self.statusText = statusText
        self.status = status
        self.battery = battery
        self.trailing = trailing
    }

    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 40, height: 40)
                .background(StrandPalette.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                HStack(spacing: 7) {
                    StatusBadge(statusText, style: status)
                    if let detail {
                        Text(detail).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
            Spacer(minLength: 8)
            if let battery {
                HStack(spacing: 4) {
                    Image(systemName: "battery.75percent")
                        .foregroundStyle(StrandPalette.success)
                    Text("\(battery)%").font(StrandFont.captionNumber)
                }
                .foregroundStyle(StrandPalette.textSecondary)
            }
            trailing()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(minHeight: 64)
        .contentShape(Rectangle())
    }
}

public extension DeviceRow where Trailing == EmptyView {
    init(symbol: String, name: LocalizedStringKey, detail: LocalizedStringKey? = nil,
         statusText: LocalizedStringKey, status: StatusBadgeStyle, battery: Int? = nil) {
        self.init(symbol: symbol, name: name, detail: detail, statusText: statusText,
                  status: status, battery: battery) { EmptyView() }
    }
}

public enum NoteCardStyle: Sendable { case privacy, warning, info, success, error }

public struct NoteCard: View {
    private let title: LocalizedStringKey?
    private let text: LocalizedStringKey
    private let style: NoteCardStyle
    private let onDismiss: (() -> Void)?

    public init(_ text: LocalizedStringKey, title: LocalizedStringKey? = nil,
                style: NoteCardStyle, onDismiss: (() -> Void)? = nil) {
        self.text = text
        self.title = title
        self.style = style
        self.onDismiss = onDismiss
    }

    private var color: Color {
        switch style {
        case .privacy: StrandPalette.textSecondary
        case .warning: StrandPalette.warning
        case .info: StrandPalette.info
        case .success: StrandPalette.success
        case .error: StrandPalette.error
        }
    }

    private var fill: Color {
        switch style {
        case .privacy: StrandPalette.inset
        case .warning: StrandPalette.warning.opacity(0.10)
        case .info: StrandPalette.info.opacity(0.10)
        case .success: StrandPalette.success.opacity(0.10)
        case .error: StrandPalette.error.opacity(0.10)
        }
    }

    private var symbol: String {
        switch style {
        case .privacy: "lock.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                if let title {
                    Text(title).font(StrandFont.caption.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
                }
                Text(text).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer(minLength: 8)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Canonical controls and feedback

public extension View {
    /// Component-library switch treatment: native behavior and accessibility, black selected chrome.
    func noopToggle() -> some View {
        self.toggleStyle(.switch).tint(StrandPalette.ink)
    }
}

public struct NoopIconButton: View {
    private let systemImage: String
    private let accessibilityLabel: LocalizedStringKey
    private let action: () -> Void

    public init(_ systemImage: String, accessibilityLabel: LocalizedStringKey,
                action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 40, height: 40)
                .background(StrandPalette.surfaceRaised,
                            in: RoundedRectangle(cornerRadius: NoopMetrics.radius2, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: NoopMetrics.radius2, style: .continuous)
                    .strokeBorder(StrandPalette.cardBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

public struct InlineAlertRow: View {
    private let text: LocalizedStringKey
    private let style: NoteCardStyle

    public init(_ text: LocalizedStringKey, style: NoteCardStyle) {
        self.text = text
        self.style = style
    }

    private var color: Color {
        switch style {
        case .privacy: StrandPalette.textSecondary
        case .warning: StrandPalette.warning
        case .info: StrandPalette.info
        case .success: StrandPalette.success
        case .error: StrandPalette.error
        }
    }

    public var body: some View {
        HStack(spacing: NoopMetrics.space2) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(StrandFont.caption).foregroundStyle(StrandPalette.textPrimary)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 36)
        .padding(.horizontal, NoopMetrics.space3)
        .background(color.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: NoopMetrics.radius2, style: .continuous))
    }
}

public struct NotificationBadge: View {
    private let count: Int
    public init(_ count: Int) { self.count = count }

    public var body: some View {
        Text("\(max(0, count))")
            .font(StrandFont.micro.weight(.semibold))
            .foregroundStyle(StrandPalette.textPrimary)
            .padding(.horizontal, 6)
            .frame(minWidth: 20, minHeight: 20)
            .background(StrandPalette.error.opacity(0.16), in: Capsule(style: .continuous))
            .accessibilityLabel("\(count) notifications")
    }
}

public struct TinyMetricBadge: View {
    private let text: String
    private let tint: Color
    public init(_ text: String, tint: Color) { self.text = text; self.tint = tint }

    public var body: some View {
        Text(text)
            .font(StrandFont.captionNumber)
            .foregroundStyle(StrandPalette.textPrimary)
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(tint.opacity(0.14), in: Capsule(style: .continuous))
    }
}

public struct CompactFormField: View {
    private let title: LocalizedStringKey
    @Binding private var text: String

    public init(_ title: LocalizedStringKey, text: Binding<String>) {
        self.title = title
        self._text = text
    }

    public var body: some View {
        TextField(title, text: $text)
            .font(StrandFont.body)
            .padding(.horizontal, NoopMetrics.space4)
            .frame(height: NoopMetrics.controlHeight)
            .background(StrandPalette.surfaceRaised,
                        in: RoundedRectangle(cornerRadius: NoopMetrics.radius3, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: NoopMetrics.radius3, style: .continuous)
                .strokeBorder(StrandPalette.cardBorder, lineWidth: 1))
    }
}

public struct NoopDropdown<Option: Hashable>: View {
    private let title: LocalizedStringKey
    private let options: [Option]
    private let label: (Option) -> String
    @Binding private var selection: Option

    public init(_ title: LocalizedStringKey, options: [Option], selection: Binding<Option>,
                label: @escaping (Option) -> String) {
        self.title = title
        self.options = options
        self._selection = selection
        self.label = label
    }

    public var body: some View {
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button {
                    selection = option
                } label: {
                    if option == selection {
                        Label(label(option), systemImage: "checkmark")
                    } else {
                        Text(label(option))
                    }
                }
            }
        } label: {
            HStack(spacing: NoopMetrics.space2) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    Text(label(selection)).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            .padding(.horizontal, NoopMetrics.space4)
            .frame(height: NoopMetrics.controlHeight)
            .background(StrandPalette.surfaceRaised,
                        in: RoundedRectangle(cornerRadius: NoopMetrics.radius3, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: NoopMetrics.radius3, style: .continuous)
                .strokeBorder(StrandPalette.cardBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Paper metric primitives

public struct StatTripletItem {
    public let label: LocalizedStringKey
    public let value: String
    public init(_ label: LocalizedStringKey, value: String) { self.label = label; self.value = value }
}

public struct StatTriplet: View {
    private let items: [StatTripletItem]
    public init(_ items: [StatTripletItem]) { self.items = Array(items.prefix(3)) }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Rectangle().fill(StrandPalette.hairline).frame(width: 1, height: 32)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.label).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
                    Text(item.value).font(StrandFont.statValue).foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, index == 0 ? 0 : 8)
            }
        }
        .frame(minHeight: 36)
    }
}

public struct MetricTile: View {
    private let icon: String
    private let label: LocalizedStringKey
    private let value: String
    private let unit: String?
    private let spark: [Double]?
    private let accent: Color

    public init(icon: String, label: LocalizedStringKey, value: String, unit: String? = nil,
                spark: [Double]? = nil, accent: Color = StrandPalette.link) {
        self.icon = icon; self.label = label; self.value = value; self.unit = unit
        self.spark = spark; self.accent = accent
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: NoopMetrics.healthTileIconSize, weight: .medium))
                    // D17 (Easton): per-metric accent icons like the reference sheet —
                    // small colored glyphs, still line variants, still no sparklines.
                    .foregroundStyle(accent)
                Text(label)
                    .font(.system(size: NoopMetrics.healthTileLabelSize))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(StrandFont.number(NoopMetrics.healthTileValueSize, weight: .bold))
                    .foregroundStyle(StrandPalette.textPrimary)
                if let unit {
                    Text(unit).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: NoopMetrics.healthTileMinHeight,
               alignment: .topLeading)
    }
}

public struct ZoneBarItem {
    public let zone: Int
    public let fraction: Double
    public let duration: String
    /// Exact engine-derived bpm range when max HR is known; nil keeps the honest
    /// fixed %-of-max fallback for callers without a usable profile boundary.
    public let bpmRange: String?
    public init(zone: Int, fraction: Double, duration: String, bpmRange: String? = nil) {
        self.zone = zone; self.fraction = fraction; self.duration = duration
        self.bpmRange = bpmRange
    }
}

public struct ZoneBars: View {
    private let items: [ZoneBarItem]
    public init(_ items: [ZoneBarItem]) { self.items = items.sorted { $0.zone > $1.zone } }

    /// WHOOP's fixed %-of-max bands per zone (C14).
    private static let bandLabel: [Int: String] = [5: "90–100%", 4: "80–90%", 3: "70–80%",
                                                   2: "60–70%", 1: "50–60%"]

    public var body: some View {
        // C14 + D14: each zone reads like WHOOP's row — "Z5 (161+ bpm)" when
        // the zones engine supplied real boundaries, otherwise "Z5 (90–100%)".
        // The bar carries the zone colour; the numeric share remains readable ink (F4).
        VStack(spacing: 12) {
            ForEach(items, id: \.zone) { item in
                VStack(spacing: 5) {
                    HStack(spacing: 6) {
                        Text("Z\(item.zone) (\(item.bpmRange ?? Self.bandLabel[item.zone] ?? ""))")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(StrandPalette.textSecondary)
                        Text("\(Int((item.fraction * 100).rounded()))%")
                            .font(StrandFont.micro.weight(.semibold))
                            .foregroundStyle(StrandPalette.textSecondary)
                        Spacer(minLength: 8)
                        Text(item.duration)
                            .font(StrandFont.captionNumber.weight(.semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(StrandPalette.inset)
                            Capsule().fill(StrandPalette.hrZoneColor(item.zone))
                                .frame(width: geo.size.width * min(max(item.fraction, 0), 1))
                        }
                    }
                    .frame(height: 8)
                }
            }
        }
    }
}

public struct SplitRow {
    public let mile: String
    public let pace: String
    public let fraction: Double
    public let heartRate: String
    public init(mile: String, pace: String, fraction: Double, heartRate: String) {
        self.mile = mile; self.pace = pace; self.fraction = fraction; self.heartRate = heartRate
    }
}

public struct SplitsTable: View {
    private let rows: [SplitRow]
    private let accent: Color
    public init(_ rows: [SplitRow], accent: Color = StrandPalette.effortAccent) {
        self.rows = rows; self.accent = accent
    }

    public var body: some View {
        VStack(spacing: 0) {
            splitRow(mile: "MI", pace: "PACE", fraction: nil, heartRate: "HR", header: true)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Divider().overlay(StrandPalette.hairline)
                splitRow(mile: row.mile, pace: row.pace, fraction: row.fraction,
                         heartRate: row.heartRate, header: false)
            }
        }
    }

    private func splitRow(mile: String, pace: String, fraction: Double?,
                          heartRate: String, header: Bool) -> some View {
        HStack(spacing: 10) {
            Text(mile).frame(width: 28, alignment: .leading)
            Text(pace).frame(width: 48, alignment: .leading)
            GeometryReader { geo in
                Capsule().fill(StrandPalette.inset)
                    .overlay(alignment: .leading) {
                        if let fraction {
                            Capsule().fill(accent).frame(width: geo.size.width * min(max(fraction, 0), 1))
                        }
                    }
            }
            .frame(height: 6)
            Text(heartRate).frame(width: 36, alignment: .trailing)
        }
        .font(header ? StrandFont.micro.weight(.semibold) : StrandFont.captionNumber)
        .foregroundStyle(header ? StrandPalette.textTertiary : StrandPalette.textPrimary)
        .frame(minHeight: 38)
    }
}

/// Maps measured hour/value pairs onto the fixed 24-hour visual rail. This is a
/// rendering helper, not stress math: absent and explicitly unscored hours stay
/// nil so callers cannot accidentally manufacture a full-day history from a
/// daily rollup.
public enum StressTimelineSlots {
    public static func map(_ hourLevels: [(hour: Int, level: Double?)]) -> [Double?] {
        var slots = [Double?](repeating: nil, count: 24)
        for point in hourLevels where point.hour >= 0 && point.hour < 24 {
            slots[point.hour] = point.level
        }
        return slots
    }
}

public struct StressTimelineBar: View {
    private struct HourSlot: Identifiable {
        let id: Int
        let value: Double?
    }

    private struct RulerLabel: Identifiable {
        let id: Int
        let title: LocalizedStringKey
    }

    private let values: [Double?]
    public init(values: [Double?]) { self.values = values }
    public init(values: [Double]) { self.values = values.map(Optional.some) }

    private var hourSlots: [HourSlot] {
        values.enumerated().map { HourSlot(id: $0.offset, value: $0.element) }
    }

    private let rulerLabels: [RulerLabel] = [
        RulerLabel(id: 0, title: "12AM"),
        RulerLabel(id: 1, title: "6AM"),
        RulerLabel(id: 2, title: "12PM"),
        RulerLabel(id: 3, title: "6PM"),
        RulerLabel(id: 4, title: "12AM"),
    ]

    public var body: some View {
        VStack(spacing: 6) {
            GeometryReader { _ in
                HStack(spacing: 0) {
                    ForEach(hourSlots) { slot in
                        // nil = hour with no scorable signal: the inset track shows through.
                        Rectangle().fill(slot.value.map { value in
                            color(for: value).opacity(bandOpacity(for: value))
                        } ?? Color.clear)
                    }
                }
                .clipShape(Capsule(style: .continuous))
                .background(StrandPalette.inset, in: Capsule(style: .continuous))
            }
            .frame(height: NoopMetrics.stressTimelineHeight)
            HStack(spacing: 0) {
                ForEach(rulerLabels) { label in
                    Text(label.title).font(.system(size: 9)).foregroundStyle(StrandPalette.textTertiary)
                    if label.id < 4 { Spacer(minLength: 0) }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hourly stress across the day")
    }

    private func bandOpacity(for value: Double) -> Double {
        0.28 + min(max(value / 3, 0), 1) * 0.72
    }

    private func color(for value: Double) -> Color {
        switch value {
        case ..<0.75: StrandPalette.stressRestful
        case ..<1.5: StrandPalette.stressLow
        case ..<2.25: StrandPalette.stressMedium
        default: StrandPalette.stressHigh
        }
    }
}
