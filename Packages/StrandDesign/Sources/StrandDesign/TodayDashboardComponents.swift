import SwiftUI

// MARK: - Today hero

public struct TodayPillarModel: Identifiable, Equatable {
    public let id: String
    public let label: String
    public let value: Double?
    public let maximum: Double
    public let valueText: String
    public let state: String
    public let detail: String?
    public let accent: Color
    public let bandTicks: [Double]
    public let targetBand: ClosedRange<Double>?

    public init(id: String, label: String, value: Double?, maximum: Double, valueText: String,
                state: String, detail: String? = nil, accent: Color,
                bandTicks: [Double] = [], targetBand: ClosedRange<Double>? = nil) {
        self.id = id
        self.label = label
        self.value = value
        self.maximum = maximum
        self.valueText = valueText
        self.state = state
        self.detail = detail
        self.accent = accent
        self.bandTicks = bandTicks
        self.targetBand = targetBand
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.value == rhs.value && lhs.maximum == rhs.maximum
            && lhs.valueText == rhs.valueText && lhs.state == rhs.state && lhs.detail == rhs.detail
            && lhs.bandTicks == rhs.bandTicks && lhs.targetBand == rhs.targetBand
    }
}

/// The one hairline Today draws between its sections: the app's `hairline` token at the 1pt weight the flat
/// cards use, across the full column.
struct TodayHairline: View {
    var body: some View {
        Rectangle()
            .fill(StrandPalette.hairline)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

/// The separator between two Today sections. `above` and `below` are layout air in points. They are not equal
/// on purpose: the sections' ink does not end where their layout does (a footer chip's capsule hangs 2pt below
/// its row, a header pill's outline sits half a point outside its row), so the air is chosen per boundary to make
/// the VISIBLE gap above and below every separator the same.
public struct TodaySectionSeparator: View {
    private let above: CGFloat
    private let below: CGFloat

    public init(above: CGFloat, below: CGFloat) {
        self.above = above
        self.below = below
    }

    public var body: some View {
        TodayHairline()
            .padding(.top, above)
            .padding(.bottom, below)
    }
}

/// The surface of a Today section. In the app's flat presentation it draws no hairline of its own (Today draws
/// exactly one separator between each pair of sections) and pads only the sides that have no separator; anywhere
/// else it is the established `PaperCard`.
private struct TodaySectionSurface<Content: View>: View {
    var top: CGFloat = 0
    var bottom: CGFloat = 0
    @ViewBuilder var content: () -> Content
    @Environment(\.contentSurfacePresentation) private var presentation

    @ViewBuilder var body: some View {
        #if os(iOS)
        if presentation == .flat {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, top)
                .padding(.bottom, bottom)
        } else {
            PaperCard(padding: 12, content: content)
        }
        #else
        PaperCard(padding: 12, content: content)
        #endif
    }
}

public struct TodayHeroCard: View {
    public let pillars: [TodayPillarModel]
    public let glance: String
    public let workoutIsActive: Bool
    public let showsWorkoutAction: Bool
    public let onPillar: (String) -> Void
    public let onOpenWorkouts: () -> Void
    public let onWorkoutAction: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .footnote) private var glanceSize: CGFloat = 13

    public init(pillars: [TodayPillarModel], glance: String, workoutIsActive: Bool,
                showsWorkoutAction: Bool = true, onPillar: @escaping (String) -> Void,
                onOpenWorkouts: @escaping () -> Void, onWorkoutAction: @escaping () -> Void) {
        self.pillars = pillars
        self.glance = glance
        self.workoutIsActive = workoutIsActive
        self.showsWorkoutAction = showsWorkoutAction
        self.onPillar = onPillar
        self.onOpenWorkouts = onOpenWorkouts
        self.onWorkoutAction = onWorkoutAction
    }

    public var body: some View {
        TodaySectionSurface(top: 12) {
            // The dials / glance hairline is the same 1pt hairline as the ones between sections, with the air
            // above and below chosen (like theirs) to make the visible gap the same on both sides.
            VStack(spacing: 0) {
                // Side by side at ordinary sizes; one row each (dial, then its words beside it) at the accessibility
                // sizes, where a third of the width cannot hold a caption.
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                        ForEach(pillars) { pillar in
                            TodayPillarGauge(model: pillar) { onPillar(pillar.id) }
                                .accessibilityIdentifier("today.summary.pillar.\(pillar.id)")
                        }
                    }
                } else {
                    HStack(alignment: .top, spacing: 6) {
                        ForEach(pillars) { pillar in
                            TodayPillarGauge(model: pillar) { onPillar(pillar.id) }
                                .accessibilityIdentifier("today.summary.pillar.\(pillar.id)")
                        }
                    }
                }
                TodayHairline().padding(.top, 9.87).padding(.bottom, 11.87)
                if typeSize.isAccessibilitySize {
                    // The words would get a fifth of the row beside the Start pill at these sizes, so the pill sits
                    // under them. Every smaller size is the one row it always was.
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        glanceButton
                        workoutActionButton
                    }
                } else {
                    HStack(spacing: 8) {
                        glanceButton
                        workoutActionButton
                    }
                }
            }
        }
    }

    /// The glance line's font. At an accessibility size it is the same footnote set through `ScaledMetric`: a text
    /// style would hyphenate a long word ("work-out") before it scaled, and this one wraps between words instead.
    private var glanceFont: Font {
        typeSize.isAccessibilitySize ? .system(size: glanceSize, weight: .regular, design: .default) : StrandFont.footnote
    }

    private var glanceButton: some View {
        Button(action: onOpenWorkouts) {
            HStack(spacing: 9) {
                Image(systemName: "figure.run")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StrandPalette.strainAccent)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(DomainTint.strain.accent.opacity(0.14)))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text("Today at a glance", bundle: .module)
                            .font(StrandFont.micro.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: typeSize.isAccessibilitySize)
                        if workoutIsActive {
                            Text("LIVE", bundle: .module)
                                .font(.system(size: 8, weight: .heavy))
                                .foregroundStyle(StrandPalette.liveRed)
                        }
                    }
                    Self.glanceText(glance)
                        .font(glanceFont)
                        .monospacedDigit()
                        .foregroundStyle(StrandPalette.textSecondary)
                        // One line at every size short of an accessibility size, where "1 workout · 6,856 steps ·
                        // 528 cal" would otherwise end in an ellipsis after the first word.
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                        .minimumScaleFactor(0.75)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .foregroundStyle(StrandPalette.textPrimary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var workoutActionButton: some View {
        if showsWorkoutAction {
            Button(workoutIsActive ? String(localized: "Open", bundle: .module)
                                   : String(localized: "Start", bundle: .module),
                   action: onWorkoutAction)
                .buttonStyle(TodayWorkoutPillStyle())
                .accessibilityLabel(workoutIsActive ? "Open active workout" : "Start workout")
        }
    }

    /// The glance line with its values bright and its words muted, by colour alone ("**1** workout ·
    /// **6,856** steps · **528** cal"). Each " · " segment leads with its value; "—" is a value too but reads
    /// tertiary. A line that does not parse into any value renders as plain text in the caller's ink.
    private static func glanceText(_ glance: String) -> Text {
        func run(_ text: String, _ color: Color) -> AttributedString {
            var piece = AttributedString(text)
            piece.foregroundColor = color
            return piece
        }
        let separator = " · "
        var line = AttributedString()
        var foundValue = false
        for (index, segment) in glance.components(separatedBy: separator).enumerated() {
            if index > 0 { line += run(separator, StrandPalette.textSecondary) }
            let token = segment.prefix { $0 != " " }
            let isMissing = token == WidgetMetrics.missingValue
            guard isMissing || token.first?.isNumber == true else {
                line += run(segment, StrandPalette.textSecondary)
                continue
            }
            foundValue = true
            line += run(String(token), isMissing ? StrandPalette.textTertiary : StrandPalette.textPrimary)
            line += run(String(segment.dropFirst(token.count)), StrandPalette.textSecondary)
        }
        return foundValue ? Text(line) : Text(verbatim: glance)
    }
}

/// The Start / Open pill: the solid light primary (`solidFill`, dark label), the same capsule, type size and padding as ever.
/// The whole padded pill is the button (and dips a touch while pressed), not just its label.
private struct TodayWorkoutPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(StrandFont.caption.weight(.semibold))
            .foregroundStyle(StrandPalette.onLightFill)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(StrandPalette.solidFill, in: Capsule())
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

private struct TodayPillarGauge: View {
    let model: TodayPillarModel
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var revealed = false
    /// One shared icon column, so the three labels start at the same offset whatever symbol precedes them.
    @ScaledMetric(relativeTo: .caption) private var symbolColumn: CGFloat = 14

    private var fraction: Double {
        guard let value = model.value, model.maximum > 0 else { return 0 }
        return min(max(value / model.maximum, 0), 1)
    }

    /// The unfilled part of the dial: the pillar's own accent at a whisper, the way `DomainTint` lays its
    /// wash over a card. A dial with no value has no domain to speak of, so its dashed track stays neutral.
    private var trackColor: Color {
        model.value == nil
            ? StrandPalette.textTertiary.opacity(0.2)
            : model.accent.opacity(0.16)
    }

    /// The pillar's colour for its symbol and state line. With no value there is no domain colour to show,
    /// so a missing dial reads quietly in tertiary ink rather than shouting its accent.
    private var inkColor: Color {
        model.value == nil ? StrandPalette.textTertiary : model.accent
    }

    /// The empty dial's track: distinct round dots, evenly spaced about `dotPitch` apart, with one dot centred
    /// on each end of the 240° arc. The arc's path radius is `side / 2` (the stroke of a filled track straddles
    /// it), so its length is known exactly and the pitch is solved to divide it evenly. The dots are drawn
    /// individually: a dashed stroke can drop the final dash when it lands on the very end of the path.
    @ViewBuilder
    private func dottedTrack(side: CGFloat, width: CGFloat) -> some View {
        let dotPitch: CGFloat = 13.5
        let radius = side / 2
        let arc = 2 * .pi * radius * (2 / 3)
        let intervals = max(1, Int((arc / dotPitch).rounded()))
        ForEach(0...intervals, id: \.self) { index in
            let angle = Angle.degrees(150 + 240 * Double(index) / Double(intervals))
            Circle().fill(trackColor)
                .frame(width: width, height: width)
                .offset(x: cos(angle.radians) * radius, y: sin(angle.radians) * radius)
        }
    }

    /// The domain symbol of a known pillar; an unknown id gets no icon.
    private var symbol: String? {
        switch model.id {
        case "recovery": "heart.fill"
        case "strain": "flame.fill"
        case "sleep": "moon.stars.fill"
        default: nil
        }
    }

    /// The `SectionEyebrow` treatment at the dial label's original size: a domain symbol in the accent, then
    /// the letter-spaced uppercase name in secondary ink. If a large Dynamic Type size leaves no room, the
    /// symbol goes first and only then does the name scale down. Nothing here is height-flexible at normal
    /// sizes (no `minimumScaleFactor` on the common path), so every column's label row is the same height.
    private var eyebrow: some View {
        ViewThatFits(in: .horizontal) {
            eyebrowRow(showsSymbol: true)
            eyebrowRow(showsSymbol: false)
            eyebrowRow(showsSymbol: false).minimumScaleFactor(0.6)
        }
    }

    private func eyebrowRow(showsSymbol: Bool) -> some View {
        HStack(spacing: 6) {
            if showsSymbol, let symbol {
                // Taking no height of its own keeps a tall glyph (the flame) from pushing one column's
                // state line below its neighbours'.
                Image(systemName: symbol)
                    .font(StrandFont.caption)
                    .foregroundStyle(inkColor)
                    .frame(width: symbolColumn, height: 0)
            }
            Text(verbatim: model.label)
                .font(StrandFont.caption.weight(.semibold))
                .tracking(StrandFont.overlineTracking)
                .textCase(.uppercase)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
        }
    }

    /// The detail line, unless the dial is unrated and the line is only the missing-value dash (or empty):
    /// the dial's own dash and its state word already say that, so a lone "—" under them is noise.
    private var visibleDetail: String? {
        guard let detail = model.detail else { return nil }
        if model.value == nil, detail.isEmpty || detail == WidgetMetrics.missingValue { return nil }
        return detail
    }

    /// The dial itself: the arc, its target band and ticks, the value in the middle.
    private var dial: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let width: CGFloat = 8
            let radius = side / 2 - width / 2
            ZStack {
                if model.value == nil {
                    dottedTrack(side: side, width: width)
                } else {
                    Circle().trim(from: 0, to: 2 / 3)
                        .stroke(trackColor, style: StrokeStyle(lineWidth: width, lineCap: .round))
                        .rotationEffect(.degrees(150))
                }
                if let target = model.targetBand {
                    Circle().trim(from: (2 / 3) * target.lowerBound,
                                  to: (2 / 3) * target.upperBound)
                        .stroke(StrandPalette.statusPositive.opacity(0.3),
                                style: StrokeStyle(lineWidth: width))
                        .rotationEffect(.degrees(150))
                }
                // An empty dial has no scale to mark, and the ticks would cut through its dots.
                ForEach(model.value == nil ? [] : model.bandTicks, id: \.self) { tick in
                    let angle = Angle.degrees(150 + 240 * tick)
                    Capsule().fill(StrandPalette.hairlineStrong)
                        .frame(width: 1.5, height: width + 4)
                        .rotationEffect(angle + .degrees(90))
                        .offset(x: cos(angle.radians) * radius, y: sin(angle.radians) * radius)
                }
                if model.value != nil {
                    Circle().trim(from: 0, to: (2 / 3) * (revealed ? fraction : 0))
                        .stroke(model.accent, style: StrokeStyle(lineWidth: width, lineCap: .round))
                        .rotationEffect(.degrees(150))
                }
                Text(verbatim: model.valueText)
                    .font(StrandFont.number(25, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(model.value == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                    .minimumScaleFactor(0.55)
                    .offset(y: 3)
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity)
        }
        .frame(height: 100)
    }

    var body: some View {
        if typeSize.isAccessibilitySize {
            rowBody
        } else {
            stackedBody
        }
    }

    /// At the accessibility sizes three dials side by side leave each caption about a third of the width ("RECOV…",
    /// "Prim…"), so each pillar is a row of its own: the dial, then its name, state word and detail beside it, free to
    /// wrap between words and, for a word wider than the line, to scale down (never hyphenate).
    private var rowBody: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: NoopMetrics.space4) {
                dial.frame(width: 100)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let symbol {
                            Image(systemName: symbol)
                                .font(StrandFont.caption)
                                .foregroundStyle(inkColor)
                                .accessibilityHidden(true)
                        }
                        Text(verbatim: model.label)
                            .tracking(StrandFont.overlineTracking)
                            .textCase(.uppercase)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .captionLabelFit(lines: 2, weight: .semibold)
                    }
                    Text(verbatim: model.state).foregroundStyle(inkColor).captionLabelFit(lines: 2)
                    if let detail = visibleDetail {
                        Text(verbatim: detail).foregroundStyle(StrandPalette.textTertiary).microLabelFit(lines: 3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onAppear { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.65)) { revealed = true } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(model.label), \(model.valueText), \(model.state)"
                            + (visibleDetail.map { ", \($0)" } ?? ""))
    }

    private var stackedBody: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                dial
                eyebrow
                Text(verbatim: model.state).font(StrandFont.micro).foregroundStyle(inkColor).lineLimit(1)
                if let detail = visibleDetail {
                    Text(verbatim: detail).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onAppear { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.65)) { revealed = true } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(model.label), \(model.valueText), \(model.state)"
                            + (visibleDetail.map { ", \($0)" } ?? ""))
    }
}

// MARK: - Health dashboard

public enum HealthTileRail: Equatable {
    case none
    case typical(position: Double, range: ClosedRange<Double>, inRange: Bool)
    case progress(Double)
}

public struct HealthDashboardTileModel: Identifiable, Equatable {
    public let id: String
    public let icon: String
    public let label: String
    public let value: String
    public let unit: String?
    public let detail: String?
    public let spark: [Double]
    public let rail: HealthTileRail
    public let accent: Color

    public init(id: String, icon: String, label: String, value: String, unit: String? = nil,
                detail: String? = nil, spark: [Double] = [],
                rail: HealthTileRail = .none, accent: Color) {
        self.id = id; self.icon = icon; self.label = label; self.value = value; self.unit = unit
        self.detail = detail; self.spark = spark; self.rail = rail; self.accent = accent
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.label == rhs.label && lhs.value == rhs.value && lhs.unit == rhs.unit
            && lhs.detail == rhs.detail && lhs.spark == rhs.spark && lhs.rail == rhs.rail
    }
}

public struct HealthDashboardCard: View {
    public let tiles: [HealthDashboardTileModel]
    public let onTile: (String) -> Void
    public let onShowAll: () -> Void
    public let onDataSources: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .headline) private var titleSize: CGFloat = 16

    // Retain the earlier initializer labels for gallery clients. Configuration now lives in native Settings.
    public init(tiles: [HealthDashboardTileModel], status: String = "",
                onTile: @escaping (String) -> Void, onCustomize: @escaping () -> Void = {},
                onShowAll: @escaping () -> Void, onDataSources: @escaping () -> Void) {
        self.tiles = tiles; self.onTile = onTile
        self.onShowAll = onShowAll; self.onDataSources = onDataSources
    }

    private var columnCount: Int {
        if typeSize >= .accessibility3 { return 1 }
        return typeSize.isAccessibilitySize ? 2 : 3
    }

    public var body: some View {
        TodaySectionSurface(bottom: 12) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Health Monitor", bundle: .module)
                    .font(.system(size: titleSize, weight: .semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("today.health.title")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: columnCount),
                          alignment: .leading, spacing: 0) {
                    ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                        Button { onTile(tile.id) } label: { HealthDashboardTile(model: tile) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("today.health.tile.\(tile.id)")
                            .overlay(alignment: .trailing) {
                                if index % columnCount != columnCount - 1 && index + 1 < tiles.count {
                                    Rectangle().fill(StrandPalette.hairline)
                                        .frame(width: 1).padding(.vertical, 16).accessibilityHidden(true)
                                }
                            }
                            .overlay(alignment: .bottom) {
                                if index / columnCount < (tiles.count - 1) / columnCount {
                                    Rectangle().fill(StrandPalette.hairline).frame(height: 1)
                                        .padding(.horizontal, 8).accessibilityHidden(true)
                                }
                            }
                    }
                }
                TodayHairline()
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 0) { allMetricsButton; dataSourcesButton }
                } else {
                    HStack { allMetricsButton; Spacer(); dataSourcesButton }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today.health.monitor")
    }

    private var allMetricsButton: some View {
        Button(action: onShowAll) {
            HStack(spacing: 6) {
                Text("All metrics", bundle: .module)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .font(StrandFont.caption.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
        .buttonStyle(.plain)
        .accessibilityIdentifier("today.health.allMetrics")
    }

    private var dataSourcesButton: some View {
        Button(action: onDataSources) {
            HStack(spacing: 6) {
                Text("Data Sources", bundle: .module)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary).buttonStyle(.plain)
        .accessibilityIdentifier("today.health.dataSources")
    }
}

public struct HealthDashboardTile: View {
    public let model: HealthDashboardTileModel
    public init(model: HealthDashboardTileModel) { self.model = model }
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title3) private var valueSize: CGFloat = 20
    @ScaledMetric(relativeTo: .caption) private var labelSize: CGFloat = 11

    private var valueInk: Color {
        if model.value == WidgetMetrics.missingValue { return StrandPalette.textTertiary }
        return model.value.contains(where: \.isNumber) ? StrandPalette.textPrimary : StrandPalette.textSecondary
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: model.icon)
                    .font(.system(size: labelSize, weight: .medium)).foregroundStyle(model.accent)
                Text(verbatim: model.label)
                    .font(.system(size: labelSize)).foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                if case .typical(_, _, false) = model.rail {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: labelSize, weight: .bold))
                        .foregroundStyle(StrandPalette.statusWarning)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 3) { valueText; unitText }
                VStack(alignment: .leading, spacing: 2) { valueText; unitText }
            }
            if let detail = model.detail {
                Text(verbatim: detail).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Only real history is drawn. A metric with none keeps the same row height with a dim dashed baseline.
            if model.spark.count > 1 {
                Sparkline(values: model.spark, gradient: Gradient(colors: [model.accent.opacity(0.7), model.accent]),
                          lineWidth: 1.5, showsArea: false, showsHead: false, showsHover: false)
                    .frame(height: 18).accessibilityHidden(true)
            } else {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 9)); path.addLine(to: CGPoint(x: 400, y: 9))
                }
                .stroke(StrandPalette.hairlineStrong, style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                .frame(height: 18).clipped().accessibilityHidden(true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(model.label), \(model.value)\(model.value == WidgetMetrics.missingValue ? "" : (model.unit.map { " \($0)" } ?? ""))"
                + (model.detail.map { ", \($0)" } ?? "")
        )
        .accessibilityHint("Opens details")
    }

    private var valueText: some View {
        Text(verbatim: model.value).font(StrandFont.number(valueSize, weight: .semibold)).monospacedDigit()
            .foregroundStyle(valueInk)
            .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            .minimumScaleFactor(typeSize.isAccessibilitySize ? 1 : 0.85)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var unitText: some View {
        if let unit = model.unit, model.value != WidgetMetrics.missingValue {
            Text(verbatim: unit).font(.system(size: labelSize))
                .foregroundStyle(StrandPalette.textTertiary).fixedSize()
        }
    }
}

public struct MetricCatalogRowModel: Identifiable, Equatable {
    public let id: String
    public let icon: String
    public let title: String
    public let subtitle: String
    public let value: String
    public let spark: [Double]
    public let accent: Color

    public init(id: String, icon: String, title: String, subtitle: String, value: String,
                spark: [Double] = [], accent: Color) {
        self.id = id; self.icon = icon; self.title = title; self.subtitle = subtitle
        self.value = value; self.spark = spark; self.accent = accent
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.subtitle == rhs.subtitle
            && lhs.value == rhs.value && lhs.spark == rhs.spark
    }
}

public struct MetricCatalogRow: View {
    public let model: MetricCatalogRowModel
    public init(model: MetricCatalogRowModel) { self.model = model }

    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: model.icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(model.accent)
                .frame(width: 26, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: model.title).font(StrandFont.body.weight(.semibold))
                Text(verbatim: model.subtitle).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: 6)
            if model.spark.count > 1 {
                Sparkline(values: model.spark, gradient: Gradient(colors: [model.accent.opacity(0.4), model.accent]),
                          lineWidth: 1.2, showsArea: false, showsHead: false, showsHover: false)
                    .frame(width: 52, height: 22).accessibilityHidden(true)
            }
            Text(verbatim: model.value).font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textPrimary)
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .contentRowSurface(boundedPadding: 13, flatVerticalPadding: 12, cornerRadius: 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(model.title), \(model.value), \(model.subtitle)")
    }
}

// MARK: - Header chrome

public enum AppStrapState: Equatable { case live, syncing, offline }
public enum AppSyncState: Equatable { case idle, syncing, done, error }

/// H2: the current page leads; the strap subtitle opens its device Settings.
public struct HeaderChromeRow: View {
    public let title: LocalizedStringKey
    public let strapState: AppStrapState
    public let battery: Int?
    public let syncState: AppSyncState
    public let syncCompletedUnits: Int?
    public let initials: String
    public let profileImage: Image?
    public let recovery: Double?
    public let onStrap: () -> Void
    public let onSync: () -> Void
    public let onProfile: () -> Void
    /// Optional page tools. Erasing only this accessory preserves the existing non-generic header API.
    public let titleActions: AnyView?
    /// Small tappable accessory set inline right after the page title (Today's date).
    public let titleAccessory: AnyView?
    /// When set, tapping the status line toggles this flag (the chevron turns down while true) instead of
    /// calling `onStrap`. The owner renders the expanded panel inline under the row.
    public let statusExpanded: Binding<Bool>?
    private var statusOpen: Bool { statusExpanded?.wrappedValue ?? false }
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title) private var titleSize: CGFloat = 26
    @ScaledMetric(relativeTo: .body) private var chromeGlyph: CGFloat = 21
    @ScaledMetric(relativeTo: .caption) private var batteryTextSize: CGFloat = 12
    @ScaledMetric(relativeTo: .caption) private var batteryGlyphSize: CGFloat = 16

    public init(title: LocalizedStringKey = "Today", strapState: AppStrapState, battery: Int?, syncState: AppSyncState,
                syncCompletedUnits: Int? = nil,
                initials: String, profileImage: Image? = nil, recovery: Double?,
                onStrap: @escaping () -> Void, onSync: @escaping () -> Void,
                onProfile: @escaping () -> Void, titleActions: AnyView? = nil,
                titleAccessory: AnyView? = nil, statusExpanded: Binding<Bool>? = nil) {
        self.title = title
        self.strapState = strapState; self.battery = battery; self.syncState = syncState
        self.syncCompletedUnits = syncCompletedUnits
        self.initials = initials; self.profileImage = profileImage
        self.recovery = recovery
        self.onStrap = onStrap; self.onSync = onSync; self.onProfile = onProfile
        self.titleActions = titleActions
        self.titleAccessory = titleAccessory
        self.statusExpanded = statusExpanded
    }

    public var body: some View {
        Group {
            if let titleActions {
                headerWithTitleActions(titleActions)
            } else if typeSize.isAccessibilitySize {
                // Let the page and full status grow vertically; no condensed symbols or clipped words.
                VStack(alignment: .leading, spacing: 8) {
                    deviceTitle
                    if let titleAccessory { titleAccessory }
                    HStack {
                        Spacer(minLength: 0)
                        accountActions
                    }
                }
            } else {
                HStack(alignment: .center, spacing: 12) {
                    deviceTitle
                    Spacer(minLength: 0)
                    accountActions
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func headerWithTitleActions(_ actions: AnyView) -> some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                deviceTitle
                actions
                HStack {
                    Spacer(minLength: 0)
                    accountActions
                }
            }
        } else {
            // Same title/status block and row height as the plain header, with the page tools beside the account controls.
            HStack(alignment: .center, spacing: 8) {
                deviceTitle
                Spacer(minLength: 0)
                actions.fixedSize(horizontal: true, vertical: true)
                accountActions
            }
        }
    }

    private var deviceTitle: some View {
        Button(action: statusTapped) {
            VStack(alignment: .leading, spacing: 3) {
                pageTitle
                deviceStatus
            }
            .frame(minWidth: 44, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The accessory sits inline after the title, above the button, so it keeps its own tap target.
        // A hidden copy of the title reserves exactly the title's width.
        .overlay(alignment: .topLeading) {
            if let titleAccessory, !typeSize.isAccessibilitySize {
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    pageTitle.hidden()
                    titleAccessory
                }
                .fixedSize()
            }
        }
        .accessibilityValue(deviceAccessibilityValue)
        .accessibilityHint(statusExpanded == nil ? "Opens device Settings, battery and sync controls"
                                                 : "Shows strap status and quick actions")
        .accessibilityValue(statusExpanded == nil ? "" : (statusOpen ? "Expanded" : "Collapsed"))
        .accessibilityIdentifier("app.deviceStatus")
    }

    private func statusTapped() {
        if let statusExpanded {
            withAnimation(.spring(duration: 0.38, bounce: 0.12)) { statusExpanded.wrappedValue.toggle() }
        } else {
            onStrap()
        }
    }

    private var pageTitle: some View {
        Text(title)
            .font(StrandFont.sized(titleSize, weight: .semibold))
            .foregroundStyle(StrandPalette.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("app.header.title")
    }

    private var deviceStatus: some View {
        HStack(alignment: .center, spacing: 6) {
            strapDot
                .frame(width: 8, height: 8)
            Text(statusLabel)
                .font(StrandFont.caption)
                .foregroundStyle(syncState == .error ? StrandPalette.statusWarning : StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Image(systemName: "chevron.right")
                .font(StrandFont.micro.weight(.semibold))
                .foregroundStyle(StrandPalette.textTertiary)
                .rotationEffect(.degrees(statusOpen ? 90 : 0))
                .animation(.spring(duration: 0.38, bounce: 0.12), value: statusOpen)
                .accessibilityHidden(true)
        }
    }

    private var accountActions: some View {
        HStack(spacing: 8) {
            if syncState == .syncing {
                SyncProgressBadge(count: syncCompletedUnits)
            }
            batteryAction
            Button(action: onProfile) {
                ZStack {
                    Circle().stroke(recovery.map { RecoveryBands.color(for: $0) } ?? StrandPalette.hairlineStrong, lineWidth: 2)
                    if let profileImage {
                        profileImage.resizable().scaledToFill()
                            .frame(width: 30, height: 30).clipShape(Circle())
                    } else if initials.isEmpty {
                        Image(systemName: "person.fill")
                            .font(StrandFont.sized(min(chromeGlyph, 24), weight: .semibold))
                            .foregroundStyle(StrandPalette.textSecondary)
                    } else {
                        Text(verbatim: initials).font(StrandFont.micro.weight(.bold))
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                }
                .frame(width: 36, height: 36)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Profile and settings")
            .accessibilityIdentifier("app.settings")
        }
    }

    private var batteryAction: some View {
        Button(action: onStrap) {
            HStack(spacing: 4) {
                Image(systemName: batterySymbol)
                    .font(StrandFont.sized(batteryGlyphSize, weight: .regular))
                Text(verbatim: validBattery.map { "\($0)%" } ?? "--%")
                    .font(StrandFont.mono(batteryTextSize, weight: .medium))
            }
            .foregroundStyle(validBattery.map { $0 <= 15 } == true
                             ? StrandPalette.statusWarning : StrandPalette.textSecondary)
            .fixedSize(horizontal: true, vertical: false)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: validBattery.map {
            String(localized: "Strap battery \($0) percent", bundle: .module)
        } ?? String(localized: "Strap battery unavailable", bundle: .module)))
        .accessibilityHint("Opens device Settings")
        .accessibilityIdentifier("app.battery")
    }

    private var validBattery: Int? {
        guard let battery, (0...100).contains(battery) else { return nil }
        return battery
    }

    private var batterySymbol: String {
        guard let battery = validBattery else { return "battery.0percent" }
        switch battery {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private var strapColor: Color {
        switch strapState { case .live: StrandPalette.statusPositive; case .syncing: StrandPalette.accent; case .offline: StrandPalette.textTertiary }
    }
    private var strapLabel: String {
        switch strapState {
        case .live: String(localized: "Strap connected", bundle: .module)
        case .syncing: String(localized: "Strap syncing", bundle: .module)
        case .offline: String(localized: "Strap offline", bundle: .module)
        }
    }
    private var statusLabel: String {
        switch syncState {
        case .error: "\(strapLabel) · \(String(localized: "Sync failed", bundle: .module))"
        case .syncing: "\(strapLabel) · \(String(localized: "Syncing", bundle: .module))"
        case .idle, .done: strapLabel
        }
    }
    /// State is encoded by shape as well as colour.
    @ViewBuilder private var strapDot: some View {
        switch strapState {
        case .live:
            Circle().fill(strapColor).frame(width: 5, height: 5)
        case .syncing:
            Circle().fill(strapColor).frame(width: 4, height: 4)
                .overlay(Circle().strokeBorder(strapColor, lineWidth: 1).frame(width: 8, height: 8))
                .frame(width: 8, height: 8)
        case .offline:
            Circle().strokeBorder(strapColor, lineWidth: 1.5).frame(width: 6, height: 6)
        }
    }
    private var deviceAccessibilityValue: String {
        var details: [String] = []
        if let battery = validBattery { details.append(String(localized: "Battery, \(battery) percent", bundle: .module)) }
        switch syncState {
        case .idle: break
        case .syncing:
            if let units = syncCompletedUnits, units > 0 {
                details.append(String(localized: "\(units) history chunks transferred", bundle: .module))
            }
        case .done: details.append(String(localized: "Sync complete", bundle: .module))
        case .error: details.append(String(localized: "Open device Settings to retry sync", bundle: .module))
        }
        return details.joined(separator: ". ")
    }
}

/// A tiny spinner and chunk count shown beside the battery while history syncs.
struct SyncProgressBadge: View {
    let count: Int?
    @State private var spinning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption) private var textSize: CGFloat = 12

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .trim(from: 0.12, to: 0.82)
                .stroke(StrandPalette.textSecondary, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .frame(width: 11, height: 11)
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(reduceMotion ? nil : .linear(duration: 0.9).repeatForever(autoreverses: false),
                           value: spinning)
            if let count, count > 0 {
                Text(verbatim: "\(count)")
                    .font(StrandFont.mono(textSize, weight: .medium))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .monospacedDigit()
            }
        }
        .fixedSize()
        .onAppear { spinning = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Syncing", bundle: .module))
        .accessibilityValue(Text(verbatim: count.map { $0 > 0 ? "\($0)" : "" } ?? ""))
        .accessibilityIdentifier("app.syncProgress")
    }
}
