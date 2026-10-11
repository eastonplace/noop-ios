import SwiftUI

/// The two production presentations of NOOP's shared screen header.
///
/// Expanded headers live in the scroll content. Compact headers are used only by the pinned
/// replacement after the expanded header has left the viewport.
public enum NoopScreenHeaderStyle: Sendable {
    case expanded
    case compact
}

/// Canonical NOOP screen chrome shared by the component library and the production app.
/// Navigation and trailing actions are injected so this presentation primitive never owns routing.
public struct NoopScreenHeader<Trailing: View>: View {
    private let title: LocalizedStringKey?
    private let subtitle: LocalizedStringKey?
    private let backAction: (() -> Void)?
    private let onDark: Bool
    private let style: NoopScreenHeaderStyle
    @ViewBuilder private let trailing: () -> Trailing

    public init(
        title: LocalizedStringKey? = nil,
        subtitle: LocalizedStringKey? = nil,
        backAction: (() -> Void)? = nil,
        onDark: Bool = false,
        style: NoopScreenHeaderStyle = .expanded,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.backAction = backAction
        self.onDark = onDark
        self.style = style
        self.trailing = trailing
    }

    public var body: some View {
        let primary = onDark ? StrandPalette.onDarkPrimary : StrandPalette.textPrimary
        let secondary = onDark ? StrandPalette.onDarkSecondary : StrandPalette.textSecondary
        VStack(alignment: .leading, spacing: style == .expanded ? 14 : 6) {
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
                                .frame(width: controlSize, height: controlSize)
                                .background {
                                    if style == .expanded {
                                        Circle().fill(primary.opacity(0.07))
                                    }
                                }
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
            .frame(maxWidth: .infinity, minHeight: style == .expanded ? 38 : 28)

            if title != nil || subtitle != nil {
                if style == .expanded {
                    VStack(alignment: .leading, spacing: 4) {
                        if let title {
                            Text(title)
                                .foregroundStyle(primary)
                                .expandedTitleFit()
                        }
                        if let subtitle {
                            // Wraps between words under the title rather than ending in an ellipsis ("Erholung · Anstre…"),
                            // and a word wider than the line scales down instead of hyphenating.
                            Text(subtitle)
                                .foregroundStyle(secondary)
                                .captionLabelFit(lines: 3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    // One row while it fits; at accessibility sizes the subtitle drops under the title, which wraps
                    // only between words (see `headerTitleFit`).
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            compactTitle(primary: primary, lines: 1)
                            Spacer(minLength: 8)
                            compactSubtitle(secondary: secondary)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            compactTitle(primary: primary, lines: 2)
                            compactSubtitle(secondary: secondary, wraps: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private var controlSize: CGFloat { style == .expanded ? 38 : 32 }

    @ViewBuilder
    private func compactTitle(primary: Color, lines: Int) -> some View {
        if let title {
            Text(title)
                .tracking(StrandFont.screenOverlineTracking)
                .textCase(.uppercase)
                .foregroundStyle(primary)
                .headerTitleFit(lines: lines)
        }
    }

    @ViewBuilder
    private func compactSubtitle(secondary: Color, wraps: Bool = false) -> some View {
        if let subtitle {
            // One line beside the title; under it (accessibility sizes) it wraps between words rather than ending in an
            // ellipsis, and a long word scales down instead of hyphenating.
            Text(subtitle)
                .foregroundStyle(secondary)
                .captionLabelFit(lines: wraps ? 3 : 1)
                .fixedSize(horizontal: false, vertical: wraps)
        }
    }
}

public extension NoopScreenHeader where Trailing == EmptyView {
    init(title: LocalizedStringKey? = nil, subtitle: LocalizedStringKey? = nil,
         backAction: (() -> Void)? = nil, onDark: Bool = false,
         style: NoopScreenHeaderStyle = .expanded) {
        self.init(title: title, subtitle: subtitle, backAction: backAction, onDark: onDark,
                  style: style) {
            EmptyView()
        }
    }
}

/// The one title row of a tab root. The pinned app chrome above it already carries the wordmark, so a tab
/// root adds only this compact row: the screen's caps overline title (Today's "TODAY" row, same type and
/// height) with optional trailing controls, such as a `WidgetChip`, pinned to the right.
public struct NoopTabTitleRow<Trailing: View>: View {
    private let title: LocalizedStringKey
    @ViewBuilder private let trailing: () -> Trailing

    public init(_ title: LocalizedStringKey, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.trailing = trailing
    }

    @Environment(\.dynamicTypeSize) private var typeSize

    public var body: some View {
        if typeSize.isAccessibilitySize, Trailing.self != EmptyView.self {
            // The controls beside the title take most of the row at these sizes and squeeze a word of it ("TREND" and
            // "S"), so they drop under the title.
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                titleText
                HStack(spacing: NoopMetrics.space2) {
                    Spacer(minLength: 0)
                    trailing()
                }
            }
        } else {
            HStack(spacing: NoopMetrics.space2) {
                titleText
                Spacer(minLength: NoopMetrics.space2)
                trailing()
            }
            .frame(minHeight: 24)
        }
    }

    // Today's row takes its baseline from its caption-size date, so the invisible caption below keeps
    // every tab's title on exactly the same line as "TODAY".
    private var titleText: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(title)
                .tracking(StrandFont.screenOverlineTracking)
                .textCase(.uppercase)
                .foregroundStyle(StrandPalette.textPrimary)
                .headerTitleFit()
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: "0").font(StrandFont.caption).hidden().frame(width: 0).accessibilityHidden(true)
        }
    }
}

public extension NoopTabTitleRow where Trailing == EmptyView {
    init(_ title: LocalizedStringKey) {
        self.init(title) { EmptyView() }
    }
}

/// Compatibility wrapper for existing non-scaffold call sites. New screen chrome should use
/// `NoopScreenHeader` and choose an explicit expanded or compact presentation.
public struct PaperHeaderBar<Trailing: View>: View {
    private let title: LocalizedStringKey?
    private let subtitle: LocalizedStringKey?
    private let backAction: (() -> Void)?
    private let onDark: Bool
    @ViewBuilder private let trailing: () -> Trailing

    public init(title: LocalizedStringKey? = nil, subtitle: LocalizedStringKey? = nil,
                backAction: (() -> Void)? = nil, onDark: Bool = false,
                @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.backAction = backAction
        self.onDark = onDark
        self.trailing = trailing
    }

    public var body: some View {
        NoopScreenHeader(title: title, subtitle: subtitle, backAction: backAction,
                         onDark: onDark, style: .compact, trailing: trailing)
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
                    Text(item.value).font(StrandFont.statValue)
                        .foregroundStyle(item.value == WidgetMetrics.missingValue ? StrandPalette.textTertiary : StrandPalette.textPrimary)
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
                    .foregroundStyle(value == WidgetMetrics.missingValue ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                if let unit, value != WidgetMetrics.missingValue {
                    Text(unit).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: NoopMetrics.healthTileMinHeight,
               alignment: .topLeading)
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
