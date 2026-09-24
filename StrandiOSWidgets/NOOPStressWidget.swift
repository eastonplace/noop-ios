import SwiftUI
import WidgetKit
import StrandDesign

/// Reuses the verified app snapshot; never opens the health database in the extension.
struct NOOPStressWidget: Widget {
    let kind = "NOOPStressWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NOOPStressProvider()) { entry in
            NOOPStressWidgetView(snapshot: entry.snapshot, date: entry.date)
                .containerBackground(StrandPalette.surfaceBase, for: .widget)
        }
        .configurationDisplayName("NOOP Stress")
        .description("Your recorded daily stress and the time it was last updated.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct NOOPStressWidgetView: View {
    let snapshot: WidgetSnapshot
    let date: Date
    private var isCurrent: Bool {
        Calendar.current.isDate(snapshot.updated, inSameDayAs: date)
            && (0..<3600).contains(date.timeIntervalSince(snapshot.updated))
    }
    private var hours: [Double?]? { isCurrent ? snapshot.hourlyStress : nil }
    private var hasData: Bool { hours?.contains(where: { $0?.isFinite == true }) == true }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("STRESS", systemImage: "waveform.path")
                .font(.caption.weight(.semibold)).foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 0)
            Text(hasData ? (snapshot.stressSummary ?? "Today's pattern") : "No recent data")
                .font(.headline).foregroundStyle(StrandPalette.textPrimary)
            NOOPWidgetStressStrip(values: hours)
            if hasData {
                Text(snapshot.updated, style: .time).font(.caption2)
                    .foregroundStyle(StrandPalette.textSecondary)
            } else {
                Text("Open NOOP to refresh").font(.caption2).foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Stress freshness follows the immutable health core, never a fresh live-HR overlay.
struct NOOPStressProvider: TimelineProvider {
    func placeholder(in context: Context) -> NOOPEntry { .init(date: Date(), snapshot: .placeholder) }
    func getSnapshot(in context: Context, completion: @escaping (NOOPEntry) -> Void) {
        completion(.init(date: Date(), snapshot: context.isPreview ? .placeholder : load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<NOOPEntry>) -> Void) {
        let now = Date()
        completion(Timeline(entries: [.init(date: now, snapshot: load())], policy: .after(now.addingTimeInterval(900))))
    }
    private func load() -> WidgetSnapshot {
        guard let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName) else { return .empty }
        return VerifiedWidgetEnvelopeStore.rawActiveEnvelope(defaults: defaults)?.snapshot ?? .empty
    }
}
