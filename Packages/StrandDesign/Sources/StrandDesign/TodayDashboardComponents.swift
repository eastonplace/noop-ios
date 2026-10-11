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
                HStack(alignment: .top, spacing: 6) {
                    ForEach(pillars) { pillar in
                        TodayPillarGauge(model: pillar) { onPillar(pillar.id) }
                    }
                }
                TodayHairline().padding(.top, 9.87).padding(.bottom, 11.87)
                HStack(spacing: 8) {
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
                                    if workoutIsActive {
                                        Text("LIVE", bundle: .module)
                                            .font(.system(size: 8, weight: .heavy))
                                            .foregroundStyle(StrandPalette.liveRed)
                                    }
                                }
                                Self.glanceText(glance)
                                    .font(StrandFont.footnote)
                                    .monospacedDigit()
                                    .foregroundStyle(StrandPalette.textSecondary)
                                    .lineLimit(1)
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
                    if showsWorkoutAction {
                        Button(workoutIsActive ? String(localized: "Open", bundle: .module)
                                               : String(localized: "Start", bundle: .module),
                               action: onWorkoutAction)
                            .buttonStyle(TodayWorkoutPillStyle())
                            .accessibilityLabel(workoutIsActive ? "Open active workout" : "Start workout")
                    }
                }
            }
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

/// The Start / Open pill: the brand green with dark ink, the same capsule, type size and padding as ever.
/// The whole padded pill is the button (and dips a touch while pressed), not just its label.
private struct TodayWorkoutPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(StrandFont.caption.weight(.semibold))
            .foregroundStyle(StrandPalette.appCanvas)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(StrandPalette.ink, in: Capsule())
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

private struct TodayPillarGauge: View {
    let model: TodayPillarModel
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
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
    public let status: String
    public let onTile: (String) -> Void
    public let onCustomize: () -> Void
    public let onShowAll: () -> Void
    public let onDataSources: () -> Void

    public init(tiles: [HealthDashboardTileModel], status: String,
                onTile: @escaping (String) -> Void, onCustomize: @escaping () -> Void,
                onShowAll: @escaping () -> Void, onDataSources: @escaping () -> Void) {
        self.tiles = tiles; self.status = status; self.onTile = onTile
        self.onCustomize = onCustomize; self.onShowAll = onShowAll; self.onDataSources = onDataSources
    }

    public var body: some View {
        TodaySectionSurface(bottom: 12) {
            VStack(alignment: .leading, spacing: 9) {
                VStack(alignment: .leading, spacing: 3) {
                    // The widget eyebrow, as on Live HR and Stress: ink symbol, caps title, quiet chip.
                    HStack(spacing: NoopMetrics.space2) {
                        HealthMonitorEyebrowIcon()
                        Text("Health Monitor", bundle: .module).strandOverline()
                        Spacer(minLength: NoopMetrics.space2)
                        Button(action: onCustomize) {
                            WidgetChip("Customise", systemImage: "slider.horizontal.3", showsChevron: false, overhangs: false)
                                .chipHitTarget()
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Customise", bundle: .module))
                    }
                    Text(verbatim: status).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 3), spacing: 0) {
                    ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                        Button { onTile(tile.id) } label: { HealthDashboardTile(model: tile) }
                            .buttonStyle(.plain)
                            .overlay(alignment: .trailing) {
                                if index % 3 != 2 && index + 1 < tiles.count { verticalTileDivider }
                            }
                            .overlay(alignment: .bottom) {
                                if index + 3 < tiles.count { horizontalTileDivider }
                            }
                    }
                }
                HStack {
                    Button("Show all", action: onShowAll)
                        .font(StrandFont.caption.weight(.semibold)).foregroundStyle(StrandPalette.link)
                    Spacer()
                    Button(action: onDataSources) {
                        HStack(spacing: 5) {
                            Text("Data Sources", bundle: .module)
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        }
                    }
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary).buttonStyle(.plain)
                }
            }
        }
    }

    private var verticalTileDivider: some View {
        Rectangle()
            .fill(StrandPalette.hairline)
            .frame(width: 1, height: 52)
            .accessibilityHidden(true)
    }

    private var horizontalTileDivider: some View {
        Rectangle()
            .fill(StrandPalette.hairline)
            .frame(height: 1)
            .padding(.horizontal, 8)
            .accessibilityHidden(true)
    }
}

/// The Health Monitor symbol: ink, in the same `caption` size as the other eyebrow symbols, in a column as
/// wide as the heart / bolt.heart on Live HR and Stress so all three titles start at the same x.
private struct HealthMonitorEyebrowIcon: View {
    @ScaledMetric(relativeTo: .caption) private var column: CGFloat = 14.67

    var body: some View {
        Image(systemName: "heart.text.square")
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.ink)
            .frame(width: column, alignment: .leading)
            .accessibilityHidden(true)
    }
}

public struct HealthDashboardTile: View {
    public let model: HealthDashboardTileModel
    public init(model: HealthDashboardTileModel) { self.model = model }

    /// A number reads in the primary ink and the missing dash in the tertiary. A value with no digit in it
    /// (a word such as "Calibrating") is a status, not a measurement, so it reads in the secondary ink.
    private var valueInk: Color {
        if model.value == WidgetMetrics.missingValue { return StrandPalette.textTertiary }
        return model.value.contains(where: \.isNumber) ? StrandPalette.textPrimary : StrandPalette.textSecondary
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: model.icon).font(.system(size: 10, weight: .semibold)).foregroundStyle(model.accent)
                Text(verbatim: model.label).font(StrandFont.micro).foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                if let detail = model.detail {
                    Text(verbatim: detail)
                        .font(StrandFont.micro)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                if case .typical(_, _, false) = model.rail {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(StrandPalette.statusWarning)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(verbatim: model.value).font(StrandFont.number(17, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(valueInk)
                    .lineLimit(1).minimumScaleFactor(0.65)
                if let unit = model.unit, model.value != WidgetMetrics.missingValue {
                    Text(verbatim: unit).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            if model.spark.count > 1 {
                Sparkline(values: model.spark, gradient: Gradient(colors: [model.accent.opacity(0.4), model.accent]),
                          lineWidth: 1.3, showsArea: true, showsHead: false, showsHover: false)
                    .frame(height: 12).accessibilityHidden(true)
            } else {
                Color.clear.frame(height: 12)
            }
            HealthTileRailView(rail: model.rail, accent: model.accent)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(model.label), \(model.value)\(model.value == WidgetMetrics.missingValue ? "" : (model.unit.map { " \($0)" } ?? ""))"
                + (model.detail.map { ", \($0)" } ?? "")
        )
        .accessibilityHint("Opens details")
    }
}

private struct HealthTileRailView: View {
    let rail: HealthTileRail
    let accent: Color
    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(StrandPalette.hairline)
                switch rail {
                case .none: EmptyView()
                case .progress(let progress):
                    Capsule().fill(accent).frame(width: max(3, width * min(max(progress, 0), 1)))
                case .typical(let position, let range, let inRange):
                    Capsule().fill((inRange ? accent : StrandPalette.statusWarning).opacity(0.35))
                        .frame(width: width * max(0, min(range.upperBound, 1) - max(range.lowerBound, 0)))
                        .offset(x: width * min(max(range.lowerBound, 0), 1))
                    Circle().fill(inRange ? accent : StrandPalette.statusWarning).frame(width: 5, height: 5)
                        .position(x: width * min(max(position, 0), 1), y: 1.5)
                }
            }
        }
        .frame(height: 3)
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

public struct HeaderChromeRow: View {
    public let strapState: AppStrapState
    public let battery: Int?
    public let syncState: AppSyncState
    public let syncCompletedUnits: Int?
    public let unreadCount: Int
    public let initials: String
    public let profileImage: Image?
    public let recovery: Double?
    public let onStrap: () -> Void
    public let onSync: () -> Void
    public let onUpdates: () -> Void
    public let onProfile: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The wordmark's size: `.caption2` bold, scaled like `.caption2` but never past `wordmarkCeiling`, so it stays
    /// one line at every text size.
    @ScaledMetric(relativeTo: .caption2) private var wordmarkSize: CGFloat = 11

    private static let wordmarkCeiling: CGFloat = 17

    public init(strapState: AppStrapState, battery: Int?, syncState: AppSyncState,
                syncCompletedUnits: Int? = nil,
                unreadCount: Int, initials: String, profileImage: Image? = nil, recovery: Double?,
                onStrap: @escaping () -> Void, onSync: @escaping () -> Void,
                onUpdates: @escaping () -> Void, onProfile: @escaping () -> Void) {
        self.strapState = strapState; self.battery = battery; self.syncState = syncState
        self.syncCompletedUnits = syncCompletedUnits
        self.unreadCount = unreadCount; self.initials = initials; self.profileImage = profileImage
        self.recovery = recovery
        self.onStrap = onStrap; self.onSync = onSync; self.onUpdates = onUpdates; self.onProfile = onProfile
    }

    public var body: some View {
        // From the extra-extra-large sizes the status would not fit beside the wordmark ("Offline" and "68%" broke
        // letter by letter), so it shrinks to its two symbols (the strap's dot, the battery glyph). The words and the
        // number are what VoiceOver says and what the large content viewer shows on a press and hold.
        let condensed = typeSize >= .xxxLarge
        HStack(spacing: 9) {
            Text("NOOP", bundle: .module)
                .font(.system(size: min(wordmarkSize, Self.wordmarkCeiling), weight: .bold))
                .tracking(4).foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 4)
            Button(action: onStrap) {
                HStack(spacing: 5) {
                    Circle().fill(strapColor).frame(width: condensed ? 10 : 6, height: condensed ? 10 : 6)
                    if !condensed {
                        Text(strapLabel).font(StrandFont.micro.weight(.semibold)).lineLimit(1)
                    }
                }
                .padding(.horizontal, condensed ? 6 : 8).padding(.vertical, 6)
                .frame(minWidth: condensed ? 30 : 0, minHeight: condensed ? 30 : 0)
            }
            .buttonStyle(.plain).accessibilityLabel("Strap \(strapLabel)")
            .accessibilityShowsLargeContentViewer { Text("Strap \(strapLabel)") }
            if let battery {
                Button(action: onStrap) {
                    HStack(spacing: 4) {
                        Image(systemName: batterySymbol(for: battery))
                            .font(.system(size: condensed ? 15 : 12, weight: .semibold))
                        if !condensed {
                            Text("\(battery)%").font(StrandFont.micro).monospacedDigit().lineLimit(1)
                        }
                    }
                    .foregroundStyle(batteryColor(for: battery))
                    .padding(.horizontal, condensed ? 4 : 7).padding(.vertical, 6)
                    .frame(minWidth: condensed ? 30 : 0, minHeight: condensed ? 30 : 0)
                }
                .buttonStyle(.plain).accessibilityLabel("Strap battery, \(battery) percent")
                .accessibilityShowsLargeContentViewer {
                    Label("\(battery)%", systemImage: batterySymbol(for: battery))
                }
            }
            Button(action: onSync) {
                HStack(spacing: 4) {
                    Image(systemName: syncSymbol).font(.system(size: 13, weight: .semibold))
                    if syncState == .syncing, let units = syncCompletedUnits, units > 0 {
                        Text("\(units)").font(StrandFont.micro).monospacedDigit()
                    }
                }
                .foregroundStyle(syncState == .error ? StrandPalette.statusWarning : StrandPalette.textSecondary)
                .frame(minWidth: 30, minHeight: 30)
                .padding(.horizontal, syncState == .syncing && (syncCompletedUnits ?? 0) > 0 ? 5 : 0)
            }
            .buttonStyle(.plain).accessibilityLabel(syncAccessibility)
            Button(action: onUpdates) {
                Image(systemName: "bell").font(.system(size: 13, weight: .semibold)).frame(width: 30, height: 30)
                    .overlay(alignment: .topTrailing) {
                        if unreadCount > 0 {
                            Text("\(min(unreadCount, 9))").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 14, height: 14).background(StrandPalette.liveRed, in: Circle())
                        }
                    }
            }
            .buttonStyle(.plain).accessibilityLabel(unreadCount > 0 ? "Updates, \(unreadCount) unread" : "Updates")
            Button(action: onProfile) {
                ZStack {
                    Circle().stroke(recovery.map { RecoveryBands.color(for: $0) } ?? StrandPalette.hairlineStrong, lineWidth: 2)
                    if let profileImage {
                        profileImage.resizable().scaledToFill().clipShape(Circle()).padding(3)
                    } else if initials.isEmpty {
                        Image(systemName: "person.fill").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(StrandPalette.textSecondary)
                    } else {
                        Text(verbatim: initials).font(StrandFont.micro.weight(.bold)).foregroundStyle(StrandPalette.textPrimary)
                    }
                }.frame(width: 31, height: 31)
            }
            .buttonStyle(.plain).accessibilityLabel("Profile and settings")
        }
        .frame(minHeight: 38)
    }

    private var strapColor: Color {
        switch strapState { case .live: StrandPalette.statusPositive; case .syncing: StrandPalette.accent; case .offline: StrandPalette.textTertiary }
    }
    private var strapLabel: String {
        switch strapState { case .live: String(localized: "Live", bundle: .module); case .syncing: String(localized: "Syncing", bundle: .module); case .offline: String(localized: "Offline", bundle: .module) }
    }
    private func batterySymbol(for percentage: Int) -> String {
        switch percentage { case ..<13: "battery.0"; case ..<38: "battery.25"; case ..<63: "battery.50"; case ..<88: "battery.75"; default: "battery.100" }
    }
    private func batteryColor(for percentage: Int) -> Color {
        percentage < 15 ? StrandPalette.statusCritical : (percentage < 30 ? StrandPalette.statusWarning : StrandPalette.textSecondary)
    }
    private var syncSymbol: String {
        switch syncState { case .idle: "arrow.triangle.2.circlepath"; case .syncing: "arrow.triangle.2.circlepath"; case .done: "checkmark"; case .error: "exclamationmark" }
    }
    private var syncAccessibility: String {
        switch syncState {
        case .idle: "Sync now"
        case .syncing:
            if let units = syncCompletedUnits, units > 0 { "Syncing, \(units) history chunks transferred" }
            else { "Syncing" }
        case .done: "Sync complete"
        case .error: "Sync failed, retry"
        }
    }
}
