import SwiftUI
import StrandAnalytics
import StrandDesign

// MARK: - Zones on the workout summary
//
// Time in each heart-rate zone as the shared distribution (one bar, one row per zone), and under it the session's heart
// rate: the same curve the Heart Rate tab draws, shorter, and a way into that tab. Choosing a zone marks it in the bar
// and marks where it fell on the curve; choosing it again, or Show all, clears the choice. When there is no curve to
// mark (too few readings), the rows are plain and nothing invites a tap.

struct WorkoutZoneSummary: View {
    let minutes: [Double]
    let timeline: WorkoutZoneTimeline?
    /// The session's heart rate as the curve draws it. nil when there are too few readings for a curve.
    let heartRate: WorkoutHeartRateSeries?
    /// True when the zone totals came from an import rather than from the strap's own readings.
    let imported: Bool
    let start: Int
    /// The zones' bpm bands, from the person's max heart rate. nil leaves the ranges off.
    let zoneSet: HRZoneSet?
    /// What a screen reader calls the curve ("Heart rate during Running").
    let curveName: String
    /// Switches the summary to its Heart Rate tab.
    let onOpenHeartRate: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedZone: Int?

    /// Choosing a zone has something to show only when there is a curve and the readings that mark where each zone fell.
    private var canExplore: Bool { heartRate != nil && timeline?.intervals.isEmpty == false }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            zonesSection
            if let heartRate {
                FlatSectionSeparator()
                heartRateBlock(heartRate)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: selectedZone)
    }

    // MARK: Zones

    private var zonesSection: some View {
        FlatSection("Heart rate zones", systemImage: "heart.fill", tint: .heart) {
            VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
                HRZoneDistribution(
                    zones: WorkoutZoneRows.zones(minutes: minutes, zoneSet: zoneSet),
                    selection: canExplore ? $selectedZone : nil,
                    rowHint: canExplore ? String(localized: "Shows where this zone fell on the timeline") : nil)
                if selectedZone != nil {
                    // The 44pt height and its tap shape are the label's own, so the whole of it answers, not only the words.
                    Button { selectedZone = nil } label: {
                        Text("Show all")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else if canExplore && !imported {
                    footnote("Tap a zone to explore your effort.")
                }
                if imported {
                    footnote("Zone totals were imported. The timeline uses recorded readings and your current zone thresholds; exact imported intervals are unavailable.")
                }
                if let timeline {
                    if timeline.unobservedSeconds > 10 {
                        footnote("\(WorkoutFormat.spokenDuration(timeline.unobservedSeconds)) without readings. Gaps are not counted as time in a zone.")
                    }
                    if timeline.belowZoneMinutes > 0 {
                        footnote("Below Zone 1: \(WorkoutFormat.spokenDuration(timeline.belowZoneMinutes * 60))")
                    }
                }
                if heartRate == nil {
                    footnote("No recorded timeline is available for this workout.")
                }
            }
        }
    }

    private func footnote(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Heart rate

    /// The curve under the same eyebrow the Heart Rate tab uses; the whole block opens that tab.
    private func heartRateBlock(_ series: WorkoutHeartRateSeries) -> some View {
        Button(action: onOpenHeartRate) {
            VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
                SectionEyebrow(
                    "Heart rate", systemImage: "heart.fill", tint: .heart,
                    trailing: selectedZone.map { EyebrowTrailing.text(String(localized: "Zone \($0) on your timeline")) } ?? .none,
                    showsChevron: true)
                WorkoutHeartRateCurve(
                    series: series, start: start, accessibilityName: curveName,
                    isCompact: true, highlight: highlight)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the Heart Rate tab")
    }

    /// Where the chosen zone fell, in seconds from the start of the session.
    private var highlight: WorkoutHeartRateCurve.Highlight? {
        guard let selectedZone, let timeline else { return nil }
        return .init(zone: selectedZone, spans: timeline.spans(inZone: selectedZone, from: start))
    }
}
