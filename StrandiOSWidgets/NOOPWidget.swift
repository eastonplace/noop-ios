import WidgetKit
import SwiftUI
import StrandDesign

/// Timeline entry backed by the latest `WidgetSnapshot` the app published into the App Group.
struct NOOPEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct NOOPProvider: TimelineProvider {
    func placeholder(in context: Context) -> NOOPEntry {
        NOOPEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (NOOPEntry) -> Void) {
        completion(NOOPEntry(date: Date(), snapshot: WidgetSnapshot.load() ?? (context.isPreview ? .placeholder : .empty)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NOOPEntry>) -> Void) {
        let snap = WidgetSnapshot.load() ?? .empty
        // Refresh roughly every 15 minutes; the app also forces a reload when it publishes fresh data.
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        completion(Timeline(entries: [NOOPEntry(date: Date(), snapshot: snap)], policy: .after(next)))
    }
}

/// The glanceable widget — the iOS analogue of the macOS menu-bar extra. Recovery, live/last HR,
/// and strap battery.
struct NOOPWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NOOPEntry

    private var snap: WidgetSnapshot { entry.snapshot }

    var body: some View {
        switch family {
        case .accessoryCircular:
            recoveryGauge
        case .accessoryInline:
            Text(inlineText)
        case .accessoryRectangular:
            rectangular
        case .systemLarge:
            large
        case .systemMedium:
            medium
        default:
            small
        }
    }

    private var recoveryColor: Color {
        guard let r = snap.recovery else { return StrandPalette.textTertiary }
        return RecoveryBands.color(for: Double(r))
    }

    private var effortColor: Color {
        snap.strain == nil ? StrandPalette.textTertiary : StrandPalette.strainAccent
    }

    private var strainText: String? {
        snap.strain.map { String(format: "%.1f", $0) }
    }

    private var restColor: Color {
        snap.rest == nil ? StrandPalette.textTertiary : StrandPalette.sleepAccent
    }

    private var inlineText: String {
        "Recovery \(snap.recovery.map(String.init) ?? "—") · Strain \(strainText ?? "—")"
    }

    private var recoveryGauge: some View {
        Gauge(value: Double(snap.recovery ?? 0), in: 0...100) {
            Image(systemName: "heart.fill")
        } currentValueLabel: {
            Text(snap.recovery.map { "\($0)" } ?? "–")
        }
        .gaugeStyle(.accessoryCircular)
        .tint(recoveryColor)
    }

    /// Lock-Screen rectangular accessory. Two lines (#446): line 1 the Charge headline, line 2 the live
    /// HR alongside Strain so the at-a-glance pair the users asked for both fit the tinted accessory.
    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "heart.fill").foregroundStyle(recoveryColor)
                Text(snap.recovery.map { "Recovery \($0)%" } ?? "Recovery —").font(.headline)
            }
            Text("Strain \(strainText ?? "—") · HRV \(snap.hrv.map(String.init) ?? "—") ms")
                .font(.caption)
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("NOOP").font(.system(size: 13, weight: .bold))
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                Circle().fill(snap.bonded ? StrandPalette.statusPositive : StrandPalette.statusCritical)
                    .frame(width: 8, height: 8)
            }
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(snap.recovery.map(String.init) ?? "–")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(recoveryColor)
                Text("%").font(.headline).foregroundStyle(StrandPalette.textTertiary)
            }
            Text("Recovery").font(.caption).foregroundStyle(StrandPalette.textTertiary)
            if let delta = snap.recoveryDelta {
                Text("\(delta >= 0 ? "+" : "")\(delta) vs yesterday")
                    .font(.caption2).foregroundStyle(delta >= 0 ? StrandPalette.statusPositive : StrandPalette.statusCritical)
            }
            Spacer(minLength: 0)
            HStack {
                Label(sleepDuration, systemImage: "moon.fill")
                Spacer()
                Label("\(snap.batteryPct.map { "\($0)%" } ?? "—")", systemImage: "battery.50")
            }
            .font(.caption2).foregroundStyle(StrandPalette.textSecondary)
        }
        .padding(12)
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                pillar("Recovery", snap.recovery.map(String.init), recoveryColor)
                pillar("Strain", strainText, effortColor)
                pillar("Sleep", snap.rest.map(String.init), restColor)
            }
            stressStrip
            HStack {
                compactMetric("HRV", snap.hrv.map { "\($0) ms" })
                Spacer()
                compactMetric("RHR", snap.restingHr.map { "\($0) bpm" })
                Spacer()
                compactMetric("Steps", snap.steps.map(Self.compactNumber))
            }
        }
        .padding(14)
    }

    /// The rich `systemLarge` layout (#446): the Charge headline plus a stat grid of Strain, Sleep, HRV,
    /// Resting HR, live HR and strap battery — the "show me more" the issue asked for.
    private var large: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("NOOP").font(.system(size: 13, weight: .bold))
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                Circle().fill(snap.bonded ? StrandPalette.statusPositive : StrandPalette.statusCritical)
                    .frame(width: 8, height: 8)
            }
            HStack {
                pillar("Recovery", snap.recovery.map(String.init), recoveryColor)
                pillar("Strain", strainText, effortColor)
                pillar("Sleep", snap.rest.map(String.init), restColor)
            }
            sparkline
            Divider()
            // Two-by-three stat grid of the richer scores. Each cell is a value + label pairing, tinted to
            // match its Today tile where a token exists (Strain, Sleep); raw vitals stay neutral.
            HStack(alignment: .top, spacing: 0) {
                statCell("Strain", value: strainText, tint: effortColor)
                statCell("Sleep", value: snap.rest.map { "\($0)%" }, tint: restColor)
                statCell("HRV", value: snap.hrv.map { "\($0)" }, unit: "ms")
            }
            HStack(alignment: .top, spacing: 0) {
                statCell("Sleep HR", value: snap.restingHr.map { "\($0)" }, unit: "bpm")
                statCell("Steps", value: snap.steps.map(Self.compactNumber))
                statCell("Calories", value: snap.calories.map { "\($0)" }, unit: "kcal")
                statCell("Battery", value: snap.batteryPct.map { "\($0)%" })
            }
            stressStrip
            if let summary = snap.stressSummary {
                Text("Stress · \(summary)").font(.caption2).foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    /// One labelled stat in the large grid — value over a caption, equal-width so the three columns align.
    private func statCell(_ label: String, value: String?, unit: String? = nil,
                          tint: Color = StrandPalette.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value ?? "–")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(value == nil ? StrandPalette.textTertiary : tint)
                if let unit, value != nil {
                    Text(unit).font(.caption2).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            Text(label).font(.caption2).foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sleepDuration: String {
        guard let minutes = snap.sleepMinutes else { return "—" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    private func pillar(_ label: String, _ value: String?, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value ?? "—").font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(value == nil ? StrandPalette.textTertiary : tint)
            Text(label).font(.caption2).foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func compactMetric(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value ?? "—").font(.caption.weight(.semibold))
            Text(label).font(.caption2).foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private var stressStrip: some View {
        HStack(spacing: 2) {
            ForEach(Array((snap.hourlyStress ?? []).enumerated()), id: \.offset) { _, value in
                Capsule().fill(stressColor(value)).frame(maxWidth: .infinity, minHeight: 5, maxHeight: 5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snap.stressSummary.map { "Stress \($0)" } ?? "Stress unavailable")
    }

    private var sparkline: some View {
        GeometryReader { geometry in
            let values = snap.hrSparkline ?? []
            if values.count > 1, let low = values.min(), let high = values.max() {
                Path { path in
                    for (index, value) in values.enumerated() {
                        let x = geometry.size.width * CGFloat(index) / CGFloat(values.count - 1)
                        let fraction = CGFloat(value - low) / CGFloat(max(1, high - low))
                        let y = geometry.size.height * (1 - fraction)
                        index == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                .stroke(StrandPalette.statusCritical, style: .init(lineWidth: 2, lineCap: .round, lineJoin: .round))
            } else {
                Text("Heart-rate trace unavailable").font(.caption2).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .frame(height: 34)
    }

    private func stressColor(_ value: Double?) -> Color {
        guard let value else { return StrandPalette.hairline }
        if value >= 2 { return StrandPalette.statusCritical }
        if value >= 1 { return StrandPalette.statusWarning }
        return StrandPalette.statusPositive
    }

    private static func compactNumber(_ value: Int) -> String {
        value >= 1_000 ? String(format: "%.1fk", Double(value) / 1_000) : String(value)
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
        .description("Recovery, Strain, Sleep, HRV, resting and live heart rate, and strap battery at a glance.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryCircular, .accessoryInline, .accessoryRectangular
        ])
    }
}

/// Separate selectable Lock Screen circle. Recovery remains available in `NOOPWidget`.
struct NOOPStrainAccessoryWidget: Widget {
    let kind = "NOOPStrainAccessoryWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NOOPProvider()) { entry in
            Gauge(value: entry.snapshot.strain ?? 0, in: 0...21) {
                Image(systemName: "bolt.fill")
            } currentValueLabel: {
                Text(entry.snapshot.strain.map { String(format: "%.1f", $0) } ?? "—")
            }
            .gaugeStyle(.accessoryCircular)
            .tint(entry.snapshot.strain == nil ? StrandPalette.textTertiary : StrandPalette.strainAccent)
            .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("NOOP Strain")
        .description("Current canonical Strain on the 0–21 scale.")
        .supportedFamilies([.accessoryCircular])
    }
}
