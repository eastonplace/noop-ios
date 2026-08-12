import WidgetKit
import SwiftUI
import StrandDesign

struct NOOPEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct NOOPProvider: TimelineProvider {
    func placeholder(in context: Context) -> NOOPEntry {
        NOOPEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (NOOPEntry) -> Void) {
        completion(NOOPEntry(date: Date(), snapshot: WidgetSnapshot.loadForDisplay() ?? (context.isPreview ? .placeholder : .empty)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NOOPEntry>) -> Void) {
        let snapshot = WidgetSnapshot.loadForDisplay() ?? .empty
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        completion(Timeline(entries: [NOOPEntry(date: Date(), snapshot: snapshot)], policy: .after(next)))
    }
}

/// The production host for Design Lab component 41. Layout lives in StrandDesign so the widget
/// extension and the simulator QA gallery render the same source, not parallel approximations.
struct NOOPWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NOOPEntry

    private var snapshot: WidgetSnapshot { entry.snapshot }

    var body: some View {
        switch family {
        case .accessoryCircular:
            NOOPAccessoryCircularGaugeView(
                value: snapshot.recovery.map(Double.init), maximum: 100,
                accent: recoveryColor, accessibilityName: "Recovery")
        case .accessoryInline:
            NOOPAccessoryInlineView(recovery: snapshot.recovery, strain: snapshot.strain)
        case .accessoryRectangular:
            NOOPAccessoryRectangularView(
                recovery: snapshot.recovery, strain: snapshot.strain,
                hrv: snapshot.hrv, hrvSpark: snapshot.hrvSparkline)
        case .systemLarge:
            NOOPTodayLargeWidgetView(
                date: entry.date, recovery: snapshot.recovery, strain: snapshot.strain,
                sleep: snapshot.rest, bpm: snapshot.bpm, hrSpark: snapshot.hrSparkline,
                stressHours: snapshot.hourlyStress, stressSummary: snapshot.stressSummary,
                batteryPercentage: snapshot.batteryPct, hrv: snapshot.hrv,
                restingHeartRate: snapshot.restingHr, steps: snapshot.steps,
                calories: snapshot.calories)
        case .systemMedium:
            NOOPPillarsMediumWidgetView(
                recovery: snapshot.recovery, strain: snapshot.strain, sleep: snapshot.rest,
                stressHours: snapshot.hourlyStress, batteryPercentage: snapshot.batteryPct,
                hrv: snapshot.hrv, restingHeartRate: snapshot.restingHr, steps: snapshot.steps)
        default:
            NOOPRecoverySmallWidgetView(
                recovery: snapshot.recovery, delta: snapshot.recoveryDelta,
                sleepMinutes: snapshot.sleepMinutes, batteryPercentage: snapshot.batteryPct)
        }
    }

    private var recoveryColor: Color {
        snapshot.recovery.map { RecoveryBands.color(for: Double($0)) } ?? StrandPalette.textTertiary
    }
}

struct NOOPWidget: Widget {
    let kind = "NOOPWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NOOPProvider()) { entry in
            if #available(iOS 17.0, *) {
                NOOPWidgetView(entry: entry)
                    .containerBackground(StrandPalette.surfaceBase, for: .widget)
            } else {
                NOOPWidgetView(entry: entry)
                    .padding()
                    .background(StrandPalette.surfaceBase)
            }
        }
        .configurationDisplayName("NOOP Recovery")
        .description("Recovery, Strain, Sleep, HRV, resting and live heart rate, stress, and strap battery.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryCircular, .accessoryInline, .accessoryRectangular,
        ])
    }
}

/// Separate selectable Lock Screen circle. Recovery remains available in `NOOPWidget`.
struct NOOPStrainAccessoryWidget: Widget {
    let kind = "NOOPStrainAccessoryWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NOOPProvider()) { entry in
            NOOPAccessoryCircularGaugeView(
                value: entry.snapshot.strain, maximum: 21,
                accent: entry.snapshot.strain == nil ? StrandPalette.textTertiary : StrandPalette.strainAccent,
                accessibilityName: "Strain", decimal: true)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("NOOP Strain")
        .description("Current canonical Strain on the 0–21 scale.")
        .supportedFamilies([.accessoryCircular])
    }
}
