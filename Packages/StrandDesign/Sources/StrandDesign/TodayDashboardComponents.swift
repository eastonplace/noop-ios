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
        PaperCard(padding: 12) {
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(pillars) { pillar in
                        TodayPillarGauge(model: pillar) { onPillar(pillar.id) }
                    }
                }
                Divider().overlay(StrandPalette.hairline)
                HStack(spacing: 8) {
                    Button(action: onOpenWorkouts) {
                        HStack(spacing: 9) {
                            Image(systemName: "figure.run")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(StrandPalette.strainAccent)
                                .frame(width: 30, height: 30)
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
                                Text(verbatim: glance)
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
                            .font(StrandFont.caption.weight(.semibold))
                            .foregroundStyle(StrandPalette.surfaceRaised)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(StrandPalette.textPrimary, in: Capsule())
                            .buttonStyle(.plain)
                            .accessibilityLabel(workoutIsActive ? "Open active workout" : "Start workout")
                    }
                }
            }
        }
    }
}

private struct TodayPillarGauge: View {
    let model: TodayPillarModel
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    private var fraction: Double {
        guard let value = model.value, model.maximum > 0 else { return 0 }
        return min(max(value / model.maximum, 0), 1)
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                GeometryReader { proxy in
                    let side = min(proxy.size.width, proxy.size.height)
                    let width: CGFloat = 8
                    let radius = side / 2 - width / 2
                    ZStack {
                        Circle().trim(from: 0, to: 2 / 3)
                            .stroke(StrandPalette.surfaceInset,
                                    style: StrokeStyle(lineWidth: width, lineCap: .round,
                                                       dash: model.value == nil ? [1, 5] : []))
                            .rotationEffect(.degrees(150))
                        if let target = model.targetBand {
                            Circle().trim(from: (2 / 3) * target.lowerBound,
                                          to: (2 / 3) * target.upperBound)
                                .stroke(StrandPalette.statusPositive.opacity(0.3),
                                        style: StrokeStyle(lineWidth: width))
                                .rotationEffect(.degrees(150))
                        }
                        ForEach(model.bandTicks, id: \.self) { tick in
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
                Text(verbatim: model.label).font(StrandFont.caption.weight(.semibold)).lineLimit(1)
                Text(verbatim: model.state).font(StrandFont.micro).foregroundStyle(model.accent).lineLimit(1)
                if let detail = model.detail {
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
        .accessibilityLabel("\(model.label), \(model.valueText), \(model.state)")
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
        PaperCard(padding: 12) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Health Monitor", bundle: .module).strandOverline()
                        Text(verbatim: status).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    }
                    Spacer(minLength: 8)
                    Button(action: onCustomize) {
                        Label("CUSTOMISE", systemImage: "slider.horizontal.3")
                            .font(StrandFont.micro.weight(.bold))
                    }
                    .buttonStyle(.plain).foregroundStyle(StrandPalette.accent)
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

public struct HealthDashboardTile: View {
    public let model: HealthDashboardTileModel
    public init(model: HealthDashboardTileModel) { self.model = model }

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
                    .foregroundStyle(model.value == "—" ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.65)
                if let unit = model.unit { Text(verbatim: unit).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary) }
            }
            if model.spark.count > 1 {
                Sparkline(values: model.spark, gradient: Gradient(colors: [model.accent.opacity(0.4), model.accent]),
                          lineWidth: 1.3, showsArea: false, showsHead: false, showsHover: false)
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
            "\(model.label), \(model.value)\(model.unit.map { " \($0)" } ?? "")"
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

// MARK: - Workouts

public struct TodayWorkoutRowModel: Identifiable, Equatable {
    public let id: String
    public let sport: String
    public let subtitle: String
    public let strain: String
    public let heartRate: [Double]
    public let accent: Color

    public init(id: String, sport: String, subtitle: String, strain: String,
                heartRate: [Double] = [], accent: Color = StrandPalette.strainAccent) {
        self.id = id; self.sport = sport; self.subtitle = subtitle; self.strain = strain
        self.heartRate = heartRate; self.accent = accent
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.sport == rhs.sport && lhs.subtitle == rhs.subtitle
            && lhs.strain == rhs.strain && lhs.heartRate == rhs.heartRate
    }
}

public struct TodayWorkoutRow: View {
    public let model: TodayWorkoutRowModel
    public init(model: TodayWorkoutRowModel) { self.model = model }
    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "figure.run").font(.system(size: 15, weight: .semibold)).foregroundStyle(model.accent)
                .frame(width: 28, height: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: model.sport).font(StrandFont.body.weight(.semibold))
                Text(verbatim: model.subtitle).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer(minLength: 4)
            if model.heartRate.count > 1 {
                Sparkline(values: model.heartRate, gradient: Gradient(colors: [StrandPalette.metricCyan, model.accent]),
                          lineWidth: 1.4, showsArea: false, showsHead: false, showsHover: false)
                    .frame(width: 62, height: 28).accessibilityHidden(true)
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: model.strain).font(StrandFont.number(18, weight: .semibold)).foregroundStyle(model.accent)
                Text("STRAIN", bundle: .module).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
            }
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .contentRowSurface(boundedPadding: 13, flatVerticalPadding: 12, cornerRadius: 14)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(model.sport), \(model.subtitle), strain \(model.strain)")
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
        HStack(spacing: 9) {
            Text("NOOP", bundle: .module).font(StrandFont.overline).tracking(4).foregroundStyle(StrandPalette.textPrimary)
            Spacer(minLength: 4)
            Button(action: onStrap) {
                HStack(spacing: 5) {
                    Circle().fill(strapColor).frame(width: 6, height: 6)
                    Text(strapLabel).font(StrandFont.micro.weight(.semibold))
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
            }
            .buttonStyle(.plain).accessibilityLabel("Strap \(strapLabel)")
            if let battery {
                Button(action: onStrap) {
                    HStack(spacing: 4) {
                        Image(systemName: batterySymbol(for: battery))
                            .font(.system(size: 12, weight: .semibold))
                        Text("\(battery)%").font(StrandFont.micro).monospacedDigit()
                    }
                    .foregroundStyle(batteryColor(for: battery))
                    .padding(.horizontal, 7).padding(.vertical, 6)
                }
                .buttonStyle(.plain).accessibilityLabel("Strap battery, \(battery) percent")
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
