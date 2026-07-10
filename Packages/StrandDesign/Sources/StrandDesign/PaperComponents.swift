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
        VStack(alignment: .leading, spacing: 8) {
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
            .frame(maxWidth: .infinity, minHeight: 32)

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
    case connected, live, paused, beta, experimental, imported, upToDate, ready, notConnected

    fileprivate var color: Color {
        switch self {
        case .connected, .live, .upToDate, .ready: StrandPalette.success
        case .paused: StrandPalette.destructive
        case .experimental: StrandPalette.journalAccent
        case .imported: StrandPalette.link
        case .beta, .notConnected: StrandPalette.textSecondary
        }
    }

    fileprivate var showsDot: Bool {
        switch self {
        case .connected, .live, .paused, .ready, .notConnected: true
        case .beta, .experimental, .imported, .upToDate: false
        }
    }
}

public struct StatusBadge: View {
    private let text: LocalizedStringKey
    private let style: StatusBadgeStyle
    private let customColor: Color?

    public init(_ text: LocalizedStringKey, style: StatusBadgeStyle, tint: Color? = nil) {
        self.text = text
        self.style = style
        self.customColor = tint
    }

    private var color: Color { customColor ?? style.color }

    public var body: some View {
        HStack(spacing: 5) {
            if style.showsDot {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            Text(text)
                .font(StrandFont.micro.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(color.opacity(0.10), in: Capsule(style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

public struct SettingsRow<Trailing: View>: View {
    private let icon: String?
    private let title: LocalizedStringKey
    private let subtitle: LocalizedStringKey?
    private let showsChevron: Bool
    @ViewBuilder private let trailing: () -> Trailing

    public init(
        icon: String? = nil,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        showsChevron: Bool = false,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.showsChevron = showsChevron
        self.trailing = trailing
    }

    public var body: some View {
        HStack(spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(width: 36, height: 36)
                    .background(StrandPalette.inset, in: Circle())
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                if let subtitle {
                    Text(subtitle).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
            }
            Spacer(minLength: 8)
            trailing()
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .tint(StrandPalette.success)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }
}

public extension SettingsRow where Trailing == EmptyView {
    init(icon: String? = nil, title: LocalizedStringKey,
         subtitle: LocalizedStringKey? = nil, showsChevron: Bool = true) {
        self.init(icon: icon, title: title, subtitle: subtitle, showsChevron: showsChevron) {
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

public enum NoteCardStyle: Sendable { case privacy, warning, info }

public struct NoteCard: View {
    private let title: LocalizedStringKey?
    private let text: LocalizedStringKey
    private let style: NoteCardStyle

    public init(_ text: LocalizedStringKey, title: LocalizedStringKey? = nil,
                style: NoteCardStyle) {
        self.text = text
        self.title = title
        self.style = style
    }

    private var color: Color {
        switch style {
        case .privacy: StrandPalette.textSecondary
        case .warning: StrandPalette.warning
        case .info: StrandPalette.link
        }
    }

    private var fill: Color {
        switch style {
        case .privacy: StrandPalette.inset
        case .warning: StrandPalette.warningBg
        case .info: StrandPalette.link.opacity(0.08)
        }
    }

    private var symbol: String {
        switch style {
        case .privacy: "lock.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                if let title {
                    Text(title).font(StrandFont.caption.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
                }
                Text(text).font(StrandFont.caption).foregroundStyle(style == .warning ? color : StrandPalette.textSecondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                    .font(.system(size: NoopMetrics.healthTileIconSize, weight: .semibold))
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
            #if !os(watchOS)
            if let spark, spark.count > 1 {
                Sparkline(values: spark, gradient: Gradient(colors: [accent, accent]),
                          lineWidth: NoopMetrics.chartLineWidth,
                          showsArea: false, showsHead: false, showsHover: false)
                    .frame(width: 52, height: NoopMetrics.healthTileSparklineHeight,
                           alignment: .leading)
            }
            #endif
        }
        .frame(maxWidth: .infinity, minHeight: NoopMetrics.healthTileMinHeight,
               alignment: .topLeading)
    }
}

public struct ZoneBarItem {
    public let zone: Int
    public let fraction: Double
    public let duration: String
    public init(zone: Int, fraction: Double, duration: String) {
        self.zone = zone; self.fraction = fraction; self.duration = duration
    }
}

public struct ZoneBars: View {
    private let items: [ZoneBarItem]
    public init(_ items: [ZoneBarItem]) { self.items = items.sorted { $0.zone > $1.zone } }

    public var body: some View {
        VStack(spacing: 9) {
            ForEach(items, id: \.zone) { item in
                HStack(spacing: 8) {
                    Text("Z\(item.zone)").font(StrandFont.micro.weight(.semibold)).frame(width: 20, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(StrandPalette.inset)
                            Capsule().fill(StrandPalette.hrZoneColor(item.zone))
                                .frame(width: geo.size.width * min(max(item.fraction, 0), 1))
                        }
                    }
                    .frame(height: 8)
                    Text("\(Int((item.fraction * 100).rounded()))%")
                        .font(StrandFont.micro).frame(width: 30, alignment: .trailing)
                    Text(item.duration).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
                        .frame(width: 42, alignment: .trailing)
                }
                .foregroundStyle(StrandPalette.textSecondary)
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

public struct StressTimelineBar: View {
    private let values: [Double]
    public init(values: [Double]) { self.values = values }

    public var body: some View {
        VStack(spacing: 6) {
            GeometryReader { _ in
                HStack(spacing: 1) {
                    ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                        Rectangle().fill(color(for: value))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .background(StrandPalette.inset, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .frame(height: NoopMetrics.stressTimelineHeight)
            HStack(spacing: 0) {
                ForEach(Array(["12AM", "6AM", "12PM", "6PM", "12AM"].enumerated()), id: \.offset) { index, label in
                    Text(label).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
                    if index < 4 { Spacer(minLength: 0) }
                }
            }
        }
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
