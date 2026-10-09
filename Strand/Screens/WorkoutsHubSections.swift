import SwiftUI
import ReceiptLiftFeature
import StrandAnalytics
import StrandDesign
import WhoopStore

// MARK: - Workouts hub sections
//
// The flat sections the Workouts hub is made of, each taking plain values: this week, lift, recent sessions, the
// heart-rate zones and the latest pace. The hub owns the data and the sheets; these only draw.

extension WorkoutRow {
    /// A stable identity for a row in a list: the natural key plus where it came from.
    var listID: String { "\(startTs)|\(sport)|\(source)" }
}

// MARK: This week

/// The calendar week at a glance: active time as the hero, a bar per day, then sessions, calories and (when NOOP
/// scored any session) the average Strain, and the two ways to begin a workout.
struct WorkoutsWeekSection<Actions: View>: View {
    let week: WorkoutWeekSummary
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        FlatSection("This week", systemImage: "figure.run", tint: .workout,
                    trailing: .text(WorkoutFormat.weekRange(week.interval))) {
            VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
                hero
                WorkoutWeekBars(days: week.days)
                if week.hasSessions { FactStrip(facts: facts) }
                actions()
            }
        }
    }

    @ViewBuilder private var hero: some View {
        if week.hasSessions {
            HeroValue(value: WorkoutFormat.duration(week.activeSeconds),
                      caption: String(localized: "Active time"), captionPlacement: .below)
        } else {
            HeroValue(value: WidgetMetrics.missingValue,
                      caption: String(localized: "No workouts yet this week"), captionPlacement: .below)
        }
    }

    private var facts: [FactStrip.Fact] {
        var facts: [FactStrip.Fact] = [
            .init("Sessions", value: week.sessionCount.formatted()),
            .init("Calories", value: week.energyKcal > 0 ? WorkoutFormat.grouped(week.energyKcal) : WidgetMetrics.missingValue,
                  unit: week.energyKcal > 0 ? "kcal" : nil),
        ]
        // The average counts NOOP's own scores only; a week of imported WHOOP sessions has none.
        if let average = week.averageStrainStored {
            facts.append(.init("Avg strain", value: StrainScale.formatted(average)))
        }
        return facts
    }
}

// MARK: Lift

/// The Lift entry points and the last lift, in one flat section.
struct WorkoutsLiftSection: View {
    let lastLift: WorkoutLastLift?
    let onOpen: (LiftDestination) -> Void

    var body: some View {
        FlatSection("Lift", systemImage: "dumbbell.fill", tint: .workout) {
            VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
                if let lastLift { lastLiftLine(lastLift) }
                ChipRow {
                    WidgetChipButton(title: "History", systemImage: "list.bullet.rectangle", showsChevron: true,
                                     accessibilityLabel: "Lift history") { onOpen(.history) }
                    WidgetChipButton(title: "Progress", systemImage: "chart.xyaxis.line", showsChevron: true,
                                     accessibilityLabel: "Lift progress") { onOpen(.progress) }
                    WidgetChipButton(title: "Routines", systemImage: "calendar", showsChevron: true,
                                     accessibilityLabel: "Manage routines") { onOpen(.routines) }
                }
            }
        }
    }

    private func lastLiftLine(_ lift: WorkoutLastLift) -> some View {
        var facts = [WorkoutFormat.day(lift.start)]
        if lift.workingSets > 0 { facts.append(String(localized: "\(lift.workingSets) sets")) }
        if let seconds = lift.durationSeconds { facts.append(WorkoutFormat.duration(seconds)) }
        return VStack(alignment: .leading, spacing: 2) {
            Text("Last lift").font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
            Text(verbatim: lift.title ?? String(localized: "Strength training"))
                .font(StrandFont.body.weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: facts.joined(separator: " · "))
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Recent

/// The latest sessions, each a row that opens its detail.
struct WorkoutsRecentSection: View {
    let rows: [WorkoutRow]
    let unitSystem: UnitSystem
    let onOpen: (WorkoutRow) -> Void

    var body: some View {
        // The rows carry their own top padding, so the first one sits a section-gap under the header.
        FlatSection("Recent", systemImage: "clock.arrow.circlepath", tint: .workout, contentSpacing: 0) {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.listID) { index, row in
                    if index > 0 { WorkoutRowSeparator() }
                    Button { onOpen(row) } label: {
                        WorkoutRowContent(
                            presentation: .make(row, unitSystem: unitSystem, when: .day, detail: .compact),
                            showsChevron: true)
                    }
                    .buttonStyle(PaperPressStyle())
                    .accessibilityHint("Opens workout detail")
                }
            }
        }
    }
}

// MARK: Loading

/// The hub before its rows have been read: the week and the recent list in their real shape, as quiet placeholders.
struct WorkoutsHubSkeleton: View {
    private static let rows = (0..<3).map { _ in
        WorkoutRowPresentation(
            title: "Running", symbol: "figure.run", primary: "5.0 km", lines: [["Yesterday", "30m"]],
            strain: .noop("10.0"), source: .manual)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkoutsWeekSection(week: WorkoutWeekSummary.placeholder(now: Date())) {
                HStack(spacing: NoopMetrics.space2) {
                    Capsule(style: .continuous).fill(StrandPalette.chipFill).frame(width: 150, height: 40)
                    Capsule(style: .continuous).fill(StrandPalette.chipFill).frame(width: 150, height: 40)
                }
            }
            FlatSectionSeparator()
            FlatSection("Recent", systemImage: "clock.arrow.circlepath", tint: .workout, contentSpacing: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(Self.rows.enumerated()), id: \.offset) { index, presentation in
                        if index > 0 { WorkoutRowSeparator() }
                        WorkoutRowContent(presentation: presentation, showsChevron: true)
                    }
                }
            }
        }
        .redacted(reason: .placeholder)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading your sessions…")
    }
}

// MARK: Zones

/// The names of the five heart-rate zones, easiest first. Each is a word of its own in the string catalog, so none
/// borrows a translation written for another screen ("Light" is a sleep stage elsewhere).
enum WorkoutZoneNames {
    static func name(for zone: Int) -> String {
        switch zone {
        case 1: return String(localized: "Warm-up")
        case 2: return String(localized: "Easy")
        case 3: return String(localized: "Moderate")
        case 4: return String(localized: "Hard")
        default: return String(localized: "Maximum")
        }
    }
}

/// Time in each heart-rate zone across the sessions the hub is showing, from the zone split each import carries.
struct WorkoutZonesSection: View {
    let summary: WorkoutZones.Summary?
    let zoneSet: HRZoneSet?
    /// What the zones cover, as the history's range reads ("last 30 days").
    let windowCaption: String

    var body: some View {
        FlatSection("Heart rate zones", systemImage: "heart.fill", tint: .heart, trailing: .text(windowCaption)) {
            if let summary, summary.totalMinutes > 0 {
                VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
                    HRZoneDistribution(zones: (1...5).map { zone in
                        HRZoneDistribution.Zone(
                            number: zone, name: WorkoutZoneNames.name(for: zone),
                            seconds: summary.minutes[zone - 1] * 60,
                            range: zoneSet?.bpmRangeLabel(forZone: zone))
                    })
                    Text("Share of imported zone time, duration-weighted across sessions (approximate).")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("No zone data")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }
}

// MARK: Pace

/// The pace and heart rate of the latest session that has a distance.
struct WorkoutPaceSection: View {
    let row: WorkoutRow
    let pace: String
    let unitSystem: UnitSystem

    var body: some View {
        FlatSection("Latest pace", systemImage: "speedometer", tint: .workout,
                    trailing: .text(WorkoutFormat.day(Date(timeIntervalSince1970: TimeInterval(row.startTs))))) {
            VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
                Text(verbatim: WorkoutSource.displaySport(row.sport))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                FactStrip(facts: facts)
            }
        }
    }

    private var facts: [FactStrip.Fact] {
        var facts: [FactStrip.Fact] = []
        if let distance = row.distanceM, distance > 0 {
            facts.append(.init("Distance", value: UnitFormatter.distanceFromMeters(distance, system: unitSystem)))
        }
        facts.append(.init("Avg pace", value: pace, unit: unitSystem == .imperial ? "/mi" : "/km"))
        if let hr = row.avgHr { facts.append(.init("Avg HR", value: "\(hr)", unit: "bpm")) }
        return facts
    }
}

// MARK: Pace maths

enum WorkoutPace {
    /// "5:52" per kilometre (or mile) for an on-foot session with a distance and a duration, or nil when either is
    /// missing, the sport is not one people pace (a ride is read in speed, a swim per 100 m) or the result is not a
    /// plausible pace.
    static func perUnit(_ row: WorkoutRow, system: UnitSystem) -> String? {
        guard WorkoutCatalog.isOnFoot(WorkoutSource.displaySport(row.sport)) else { return nil }
        guard let distance = row.distanceM, distance > 0 else { return nil }
        let seconds = row.durationS ?? Double(row.endTs - row.startTs)
        guard seconds > 0 else { return nil }
        let unitMeters = system == .imperial ? 1609.344 : 1000
        let paceSeconds = Int((seconds / (distance / unitMeters)).rounded())
        guard paceSeconds > 0, paceSeconds < 60 * 60 else { return nil }
        return String(format: "%d:%02d", paceSeconds / 60, paceSeconds % 60)
    }
}
