import Foundation
import SwiftUI
import WidgetKit
import StrandDesign
import NoopPhase34Core

struct NOOPCoachBriefEntry: TimelineEntry {
    let date: Date
    let brief: CoachBriefWidgetPayload?
}

struct NOOPCoachBriefProvider: TimelineProvider {
    func placeholder(in context: Context) -> NOOPCoachBriefEntry { .init(date: Date(), brief: nil) }
    func getSnapshot(in context: Context, completion: @escaping (NOOPCoachBriefEntry) -> Void) {
        let now = Date()
        completion(.init(date: now, brief: context.isPreview ? nil : load(now: now)))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<NOOPCoachBriefEntry>) -> Void) {
        let now = Date()
        let brief = load(now: now)
        // A scheduled empty entry removes yesterday's prose at the app's 04:00 rollover even if the
        // app is closed. Timeline reads never generate a model response or query the health database.
        let entries = WidgetLogicalDay.timelineDates(from: now).map { date in
            NOOPCoachBriefEntry(date: date, brief: date == now ? brief : nil)
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(3_600))))
    }
    private func load(now: Date) -> CoachBriefWidgetPayload? {
        guard let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName) else { return nil }
        return CoachBriefWidgetStore.load(defaults: defaults, now: now)
    }
}

struct NOOPCoachBriefWidget: Widget {
    let kind = WidgetKinds.coachBrief
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NOOPCoachBriefProvider()) { entry in
            NOOPCoachBriefWidgetView(entry: entry)
                .containerBackground(for: .widget) { NOOPWidgetBackground(.accent) }
        }
        .configurationDisplayName("NOOP Coach Brief")
        .description("Your completed morning or evening brief from the on-device Coach.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct NOOPCoachBriefWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NOOPCoachBriefEntry
    var body: some View {
        NOOPCoachBriefWidgetContent(text: entry.brief?.text, generatedAt: entry.brief?.generatedAt,
            evening: entry.brief?.kind == .evening, recovery: entry.brief?.recovery,
            strain: entry.brief?.strain, sleepMinutes: entry.brief?.sleepMinutes,
            compact: family == .systemSmall)
            .widgetURL(URL(string: "noop://coach"))
    }
}
