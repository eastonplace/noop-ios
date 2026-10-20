import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

// MARK: - The Strain detail's day sections
//
// "Through the day", "What set today's score" and "Activities": flat sections for the Strain pillar detail, each
// opened by an eyebrow like every other drill-in section. They take plain values (the parent loads, these draw), so a
// scrub or a state change in one never re-reads anything.

// MARK: Through the day

struct StrainThroughDaySection: View {
    /// nil while the first pass is being read.
    let result: StrainDayResult?
    let hero: Double?
    let target: ClosedRange<Double>?
    let workouts: [WorkoutRow]
    let sleepMinutes: Double?
    let isToday: Bool

    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
            SectionEyebrow(
                title: String(localized: "Through the day"),
                systemImage: "chart.line.uptrend.xyaxis",
                tint: .strain,
                trailing: wakeText.map { .text($0) } ?? .none
            )
            if let result {
                if let content = StrainCurveContent.make(
                    result: result, hero: hero, workouts: workouts, sleepMinutes: sleepMinutes, live: isToday) {
                    curve(content, result: result)
                } else {
                    Text(emptyMessage(result))
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                // The same height as the plot, so the sections under it do not jump when the pass lands.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(StrandPalette.hairline.opacity(0.35))
                    .frame(height: StrainCurveLayoutMetrics.placeholderHeight)
                    .accessibilityHidden(true)
            }
        }
    }

    private var wakeText: String? {
        result?.wake.map { String(localized: "Since \(AppClock.hourMinute($0))") }
    }

    private func emptyMessage(_ result: StrainDayResult) -> String {
        if result.sampleCount == 0 {
            return isToday
                ? String(localized: "No heart-rate readings yet today.")
                : String(localized: "No heart-rate readings were recorded that day.")
        }
        return String(localized: "Heart-rate load counts after 10 minutes of readings.")
    }

    @ViewBuilder
    private func curve(_ content: StrainCurveContent, result: StrainDayResult) -> some View {
        let marker = content.markerLabel(isToday: isToday)
        // The curve already carries the day's logged lifting when it has any (Strength Strain), so it is named for both.
        let lifting = result.analysis.liftMuscularLoad > 0
        VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
            StrainDayCurve(
                points: content.shape.points,
                domain: content.shape.domain,
                ticks: content.ticks,
                target: target,
                segments: content.segments,
                now: isToday ? result.end : nil,
                seedNote: content.sleepSeed.map {
                    String(localized: "\(DrillInFormat.number($0, fractionDigits: 1)) from sleep")
                },
                scoreMarker: marker.flatMap { label in hero.map { StrainCurveScoreMarker(value: $0, label: label) } },
                targetLabel: String(localized: "Target"),
                valueFormat: { DrillInFormat.number($0, fractionDigits: 1) },
                timeLabel: { StressDayRibbon.hourLabel(Calendar.current.component(.hour, from: $0), locale: locale) },
                readoutCaption: { date in
                    if let date { return AppClock.hourMinute(date) }
                    return StrainCopy.curveReadoutCaption(isToday: isToday, lifting: lifting)
                },
                spokenReading: { point in
                    String(localized: "\(AppClock.hourMinute(point.t)), \(DrillInFormat.number(point.value, fractionDigits: 1)) of 21")
                },
                summary: summary(content, marker: content.markerSentence(isToday: isToday), lifting: lifting),
                hint: String(localized: "Touch and hold, then drag to read a time. With VoiceOver, swipe up or down to move through the day.")
            )
            if !content.gateOpen {
                Text("Heart-rate load counts after 10 minutes of readings.")
                    .font(StrandFont.micro)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The plot's spoken summary: whole sentences, each with its own punctuation, joined through one format key so the
    /// language decides the gap.
    private func summary(_ content: StrainCurveContent, marker: String?, lifting: Bool) -> String {
        let start = DrillInFormat.number(content.shape.startValue, fractionDigits: 1)
        let end = DrillInFormat.number(content.shape.endValue, fractionDigits: 1)
        let time = AppClock.hourMinute(content.shape.points.last?.t ?? content.shape.domain.upperBound)
        var sentences = [StrainCopy.curveSummary(start: start, end: end, time: time, lifting: lifting)]
        if !content.segments.isEmpty {
            sentences.append(String(localized: "\(content.segments.count) workouts marked."))
        }
        if let marker { sentences.append(marker) }
        return sentences.dropFirst().reduce(sentences[0]) { String(localized: "\($0) \($1)") }
    }
}

/// Sizes the sections share with the plot they stand in for.
enum StrainCurveLayoutMetrics {
    /// The readout, the plot and its time axis.
    static let placeholderHeight: CGFloat = 240
}

// MARK: What set the score

struct StrainScorePartsSection: View {
    let parts: StrainScoreParts
    let steps: Int?
    let isToday: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
            SectionEyebrow(
                title: isToday ? String(localized: "What set today's score") : String(localized: "What set that day's score"),
                systemImage: "chart.bar.fill",
                tint: .strain
            )
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                ForEach(parts.rows) { row in
                    StrainScoreRowView(row: row, detail: detail(for: row))
                }
            }
            if parts.isScoredFromCardioAndSteps {
                Text("Scored from cardio and steps.")
                    .font(StrandFont.micro)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !parts.agreesWithHero {
                Text("The parts are worked out from the day's readings and can differ from the score above.")
                    .font(StrandFont.micro)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func detail(for row: StrainScoreRow) -> String {
        switch row.kind {
        case .cardio:
            return String(localized: "Heart rate and sleep")
        case .steps:
            guard let steps else { return String(localized: "No step count") }
            return String(localized: "\(steps) steps")
        case .energy:
            return String(localized: "Active energy")
        case .lifting:
            let add = DrillInFormat.number(parts.rows.first(where: { $0.kind == .lifting })?.value ?? 0, fractionDigits: 1)
            return StrainCopy.liftingRowDetail(add: add)
        }
    }
}

private struct StrainScoreRowView: View {
    let row: StrainScoreRow
    let detail: String

    @Environment(\.dynamicTypeSize) private var typeSize
    /// The symbol's slot scales with its caption-size glyph, so a large symbol stays in its slot and the lines under it
    /// keep lining up with the label.
    @ScaledMetric(relativeTo: .caption) private var scaledIconWidth: CGFloat = WidgetMetrics.metricIconWidth
    private var iconWidth: CGFloat { typeSize.isAccessibilitySize ? scaledIconWidth : WidgetMetrics.metricIconWidth }
    private var tint: Color { DomainTint.strain.accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            titleLine
            Text(detail)
                .font(StrandFont.micro)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, iconWidth + NoopMetrics.space2)
            bar
                .padding(.leading, iconWidth + NoopMetrics.space2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spoken))
    }

    private var label: String {
        switch row.kind {
        case .cardio: return String(localized: "Cardio")
        case .steps: return String(localized: "Steps")
        case .energy: return String(localized: "Active energy")
        case .lifting: return StrainCopy.liftingRowLabel
        }
    }

    private var symbol: String {
        switch row.kind {
        case .cardio: return "heart.fill"
        case .steps: return "figure.walk"
        case .energy: return "bolt.fill"
        case .lifting: return "dumbbell.fill"
        }
    }

    private var valueText: String {
        guard let value = row.value else { return WidgetMetrics.missingValue }
        let number = DrillInFormat.number(value, fractionDigits: 1)
        // The Lifting row is what the sets add to the score, not a part of its own out of 21.
        return row.kind == .lifting ? "+\(number)" : number
    }

    private var pill: some View {
        ValuePill(StrainCopy.decidesScore, tint: tint)
    }

    @ViewBuilder private var titleLine: some View {
        if typeSize.isAccessibilitySize {
            // Label, then the value, then the pill, each on its own line: beside the label the value ("13,8 von 21")
            // and the pill ("Bestimmt den Wert") would be cut off at these sizes.
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                    icon
                    labelText
                }
                valueView.padding(.leading, iconWidth + NoopMetrics.space2)
                if row.setsScore {
                    pill.padding(.leading, iconWidth + NoopMetrics.space2)
                }
            }
        } else {
            fittedTitleLine
        }
    }

    private var fittedTitleLine: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                icon
                labelText
                if row.setsScore { pill }
                Spacer(minLength: NoopMetrics.space1)
                valueView
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                    icon
                    labelText
                    Spacer(minLength: NoopMetrics.space1)
                    valueView
                }
                if row.setsScore {
                    pill.padding(.leading, iconWidth + NoopMetrics.space2)
                }
            }
        }
    }

    private var icon: some View {
        Image(systemName: symbol)
            .font(StrandFont.caption)
            .foregroundStyle(tint)
            .frame(width: iconWidth)
            .accessibilityHidden(true)
    }

    private var labelText: some View {
        Text(label)
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textSecondary)
            .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
    }

    private var valueView: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(valueText)
                .font(StrandFont.bodyNumber)
                .foregroundStyle(row.value == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
            if row.value != nil, row.kind != .lifting {
                Text("of 21").font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .lineLimit(1)
    }

    private var bar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous).fill(tint.opacity(row.value == nil ? 0.07 : 0.14))
                if let value = row.value, value > 0 {
                    Capsule(style: .continuous)
                        .fill(tint.opacity(row.setsScore ? 1 : 0.5))
                        .frame(width: max(proxy.size.width * CGFloat(min(value / 21, 1)), 4))
                }
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }

    /// The label, the value and the line under it ("16,500 steps"), so a VoiceOver user hears what the part is made of.
    private var spoken: String {
        guard let value = row.value else { return String(localized: "\(label), \(detail)") }
        let number = DrillInFormat.number(value, fractionDigits: 1)
        if row.kind == .lifting { return StrainCopy.liftingRowSpoken(label: label, add: number) }
        return row.setsScore
            ? String(localized: "\(label), \(number) of 21, \(detail), sets the score")
            : String(localized: "\(label), \(number) of 21, \(detail)")
    }
}

// MARK: Activities

struct StrainActivitiesSection: View {
    let workouts: [WorkoutRow]
    let isToday: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
            SectionEyebrow(title: String(localized: "Activities"), systemImage: "figure.run", tint: .workout)
            if workouts.isEmpty {
                Text(isToday ? "No workouts recorded today." : "No workouts recorded that day.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(StrainActivityRow.rows(for: workouts)) { row in
                        NavigationLink {
                            // A pushed screen draws its own header row and ScreenScaffold hides the system bar.
                            WorkoutDetailView(row: row.workout)
                                .environment(\.screenScaffoldNavigationRole, .detail)
                        } label: {
                            StrainActivityRowView(row: row)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private struct StrainActivityRowView: View {
    let row: StrainActivityRow

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .center, spacing: NoopMetrics.space2) {
            Image(systemName: sportSymbol(row.sport))
                .font(StrandFont.caption)
                .foregroundStyle(DomainTint.workout.accent)
                .frame(width: WidgetMetrics.metricIconWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(WorkoutSource.displaySport(row.sport))
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(StrandFont.micro)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: NoopMetrics.space2)
            scoreView
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spoken))
        .accessibilityHint(Text("Opens this workout"))
        .accessibilityAddTraits(.isButton)
    }

    private var time: String { AppClock.hourMinute(unix: row.startTs) }

    private var duration: String {
        Duration.seconds(row.durationSeconds.rounded())
            .formatted(.units(allowed: [.hours, .minutes], width: .narrow))
    }

    /// Time, length and average heart rate on one quiet line. Each part keeps its own words together (a non-breaking
    /// space inside it), so a narrow row wraps between the parts, never inside "avg 102 bpm".
    private var detail: String {
        var parts = [time, duration]
        if let average = row.averageHR { parts.append(String(localized: "avg \(average) bpm")) }
        return parts.map { $0.replacingOccurrences(of: " ", with: "\u{00A0}") }.joined(separator: " · ")
    }

    @ViewBuilder
    private var scoreView: some View {
        switch row.score {
        case .noop(let value):
            Text(DrillInFormat.number(value, fractionDigits: 1))
                .font(StrandFont.bodyNumber)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
        case .whoop(let value):
            VStack(alignment: .trailing, spacing: 1) {
                Text(DrillInFormat.number(value, fractionDigits: 1))
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("WHOOP").font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
            }
            .lineLimit(1)
        case .notScored:
            Text("Not scored")
                .font(StrandFont.micro)
                .foregroundStyle(StrandPalette.textTertiary)
                .multilineTextAlignment(.trailing)
        }
    }

    /// Spoken with whole words ("1 hour, 5 minutes"), never the narrow "1h 5m", and with the average heart rate the line
    /// shows.
    private var spokenDuration: String {
        Duration.seconds(row.durationSeconds.rounded())
            .formatted(.units(allowed: [.hours, .minutes], width: .wide))
    }

    private var spoken: String {
        let sport = WorkoutSource.displaySport(row.sport)
        let base = row.averageHR.map { String(localized: "\(sport), \(time), \(spokenDuration), average \($0) bpm") }
            ?? String(localized: "\(sport), \(time), \(spokenDuration)")
        switch row.score {
        case .noop(let value):
            return String(localized: "\(base), strain \(DrillInFormat.number(value, fractionDigits: 1)) of 21")
        case .whoop(let value):
            return String(localized: "\(base), strain \(DrillInFormat.number(value, fractionDigits: 1)) of 21, from WHOOP")
        case .notScored:
            return String(localized: "\(base), not scored")
        }
    }
}

extension StrainTargetGuidance {
    /// The dot beside the line: quiet short of the target, green on it, amber past it.
    var tint: Color {
        switch self {
        case .below: return StrandPalette.textTertiary
        case .onTarget: return StrandPalette.statusPositive
        case .above: return StrandPalette.statusWarning
        }
    }
}
