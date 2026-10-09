#if os(iOS)
import SwiftUI
import StrandDesign

// MARK: - Coach page building blocks
//
// The four Coach pages (Overview, Conversation, Your plan, About you) are flat sections on the canvas in the
// same language as Today, Trends, Sleep and the Coach cards: a `SectionEyebrow` header (domain symbol plus a
// tracked caps title), values bright with their units muted, one hairline between sections and one
// `DomainTint` per subject. These are the few pieces that language needs which the shared design system does
// not ship: a flat section, a primary pill sized like Today's Start pill, a glance-style row, a fact strip and
// a flat notice. They take plain values and never see the engine.

// MARK: Page rhythm

enum CoachRhythm {
    /// Layout air above and below the hairline between two flat sections, in points. The same recipe Today and
    /// Sleep use, so the visible gap on both sides is about 12.5pt (checked with `gaps.py`).
    static let airAbove: CGFloat = 12.5
    static let airBelow: CGFloat = 11.5
    /// Air between the pinned header's hairline and a page's first section.
    static let pageTop: CGFloat = 11
    /// Scroll room under a page's last section.
    static let pageBottom: CGFloat = NoopMetrics.space6
}

/// The one hairline between two Coach sections (Today's own separator, so weight and colour cannot drift).
struct CoachSectionSeparator: View {
    var above: CGFloat = CoachRhythm.airAbove
    var below: CGFloat = CoachRhythm.airBelow

    var body: some View {
        TodaySectionSeparator(above: above, below: below)
    }
}

/// A flat section: eyebrow header over free-form content, spaced like the Coach cards' interiors.
struct CoachSection<Content: View>: View {
    private let eyebrow: SectionEyebrow
    @ViewBuilder private let content: () -> Content

    init(_ title: LocalizedStringKey, systemImage: String, tint: DomainTint = .accent,
         trailing: EyebrowTrailing = .none, @ViewBuilder content: @escaping () -> Content) {
        self.eyebrow = SectionEyebrow(title, systemImage: systemImage, tint: tint, trailing: trailing)
        self.content = content
    }

    /// A title that is data (a weekday, a category name), shown as written.
    init(verbatim title: String, systemImage: String, tint: DomainTint = .accent,
         trailing: EyebrowTrailing = .none, @ViewBuilder content: @escaping () -> Content) {
        self.eyebrow = SectionEyebrow(title: title, systemImage: systemImage, tint: tint, trailing: trailing)
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
            eyebrow
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Record dates

enum CoachRecordDate {
    /// The record-date treatment the Coach cards use: the record's real date, plus a Stale pill when the newest
    /// record is two or more days old.
    static func trailing(day: String?, now: Date = Date()) -> EyebrowTrailing {
        guard let day, let date = LocalCoachWindow.date(day) else { return .none }
        let age = LocalCoachWindow.calendar.dateComponents(
            [.day], from: date, to: LocalCoachWindow.calendar.startOfDay(for: now)).day ?? 0
        return .record(date: LocalCoachCardFormat.dayLabel(day, now: now), isStale: age >= 2)
    }
}

// MARK: Primary pill

/// The primary action: Today's Start pill (brand ink capsule, dark label) scaled up modestly for a page whose one
/// job is this action. The tap area reaches 44pt without growing the layout.
struct CoachPrimaryPillStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(StrandFont.subhead.weight(.semibold))
            .foregroundStyle(StrandPalette.appCanvas)
            .padding(.horizontal, NoopMetrics.space4)
            .padding(.vertical, 10)
            .background(StrandPalette.ink, in: Capsule(style: .continuous))
            .contentShape(Rectangle().inset(by: -4))
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.4)
    }
}

// MARK: Glance row

/// An icon circle, a title with an optional line under it, and a chevron: the shape of Today's "Today at a
/// glance" row. Flat, no surface; the caller wraps it in a `Button`.
struct CoachRow: View {
    let systemImage: String
    var tint: DomainTint = .accent
    let title: Text
    var subtitle: Text?
    var showsChevron = true

    var body: some View {
        HStack(spacing: NoopMetrics.space3) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint.accent)
                .frame(width: 30, height: 30)
                .background(Circle().fill(tint.accent.opacity(0.14)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                title.font(StrandFont.subhead.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
                if let subtitle {
                    subtitle.font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: NoopMetrics.space1)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: Fact strip

struct CoachFact {
    let label: LocalizedStringKey
    let value: String
    var unit: String?
}

/// Label-over-value columns with hairline dividers, the shape of `StatFooter(.prominent)` with the unit muted.
/// Equal columns on one baseline; steps down in size and then stacks as rows before anything truncates.
struct CoachFactStrip: View {
    let facts: [CoachFact]
    @ScaledMetric(relativeTo: .title3) private var valueSize: CGFloat = WidgetMetrics.statValueSize
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            stacked
        } else {
            ViewThatFits(in: .horizontal) {
                columns(size: valueSize)
                columns(size: valueSize * 0.85)
                columns(size: valueSize * 0.72)
                stacked
            }
        }
    }

    private func value(_ fact: CoachFact, size: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(fact.value)
                .font(StrandFont.number(size, weight: .semibold))
                .foregroundStyle(fact.value == WidgetMetrics.missingValue ? StrandPalette.textTertiary : StrandPalette.textPrimary)
            if let unit = fact.unit, fact.value != WidgetMetrics.missingValue {
                Text(unit).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .lineLimit(1)
    }

    private func columns(size: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(facts.enumerated()), id: \.offset) { index, fact in
                if index > 0 {
                    Rectangle().fill(StrandPalette.hairline).frame(width: 1, height: 36)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(fact.label).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary).lineLimit(1)
                    // One-line sizes report their full width, so ViewThatFits moves to the next size
                    // rather than truncating one column.
                    value(fact, size: size).fixedSize(horizontal: true, vertical: false)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, index == 0 ? 0 : NoopMetrics.space3)
                .padding(.trailing, index == facts.count - 1 ? 0 : NoopMetrics.space3)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                    Text(fact.label).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    Spacer(minLength: NoopMetrics.space2)
                    value(fact, size: valueSize)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

// MARK: Flat notice

/// A status line on the canvas (an error, a notice): a tinted symbol and secondary text, no box. The flat
/// replacement for `NoteCard` on Coach pages.
struct CoachNotice: View {
    enum Tone { case warning, info }

    let text: Text
    var tone: Tone = .warning

    private var symbol: String { tone == .warning ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath" }
    private var color: Color { tone == .warning ? StrandPalette.statusWarning : StrandPalette.textSecondary }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
            Image(systemName: symbol).font(StrandFont.caption).foregroundStyle(color)
                .accessibilityHidden(true)
            text.font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: Typing dots

/// Three quiet dots that rise and fall in turn while Coach is working; still under Reduce Motion.
struct CoachTypingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            dots(at: 0.5)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
                dots(at: context.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func dots(at time: Double) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                let phase = reduceMotion ? 0.5 : (sin((time * 2.6) - Double(index) * 0.9) + 1) / 2
                Circle().fill(StrandPalette.textTertiary)
                    .frame(width: 5, height: 5)
                    .opacity(0.35 + 0.65 * phase)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: Chip row

/// A single row of chips that scrolls sideways, bleeding to the screen edge so a chip that does not fit is
/// visibly cut off rather than hidden. The chips' tap areas reach the 44pt minimum: the scroll view is padded
/// taller than the chips and pulled back with the opposite negative padding, so the layout does not grow.
struct CoachChipRow<Content: View>: View {
    /// How far the row reaches past its container on each side (the page gutter).
    let bleed: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: NoopMetrics.space2) { content() }
                .padding(.horizontal, bleed)
                .padding(.vertical, 11)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .padding(.horizontal, -bleed)
        .padding(.vertical, -11)
    }
}

// MARK: Metric strip

/// The three records Coach reads, as Today's key metrics read: a domain symbol and label, the value bright with
/// its unit muted, a sparkline in the domain colour and the number of recorded days. Hairlines between columns;
/// stacked at accessibility sizes.
struct CoachMetricStrip: View {
    let metrics: [LocalCoachMetric]
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.whoop.rawValue
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title3) private var valueSize: CGFloat = 24

    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                ForEach(metrics) { column($0) }
            }
        } else {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                    if index > 0 {
                        Rectangle().fill(StrandPalette.hairline).frame(width: 1)
                            .accessibilityHidden(true)
                    }
                    column(metric)
                        .padding(.leading, index == 0 ? 0 : NoopMetrics.space3)
                        .padding(.trailing, index == metrics.count - 1 ? 0 : NoopMetrics.space3)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func column(_ metric: LocalCoachMetric) -> some View {
        let look = Self.look(for: metric)
        let shown = display(metric)
        let samples = metric.samples.filter(\.isFinite)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: look.symbol).font(StrandFont.caption).foregroundStyle(look.tint.accent)
                    .accessibilityHidden(true)
                Text(metric.title).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(shown.value).font(StrandFont.number(valueSize, weight: .semibold))
                    .foregroundStyle(shown.value == WidgetMetrics.missingValue ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                if let unit = shown.unit, shown.value != WidgetMetrics.missingValue {
                    Text(unit).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .lineLimit(1).minimumScaleFactor(0.7)
            if samples.count > 1 {
                Sparkline(values: samples, gradient: look.tint.chartGradient, lineWidth: 2, showsHover: false)
                    .frame(height: 24)
                    .accessibilityHidden(true)
            } else {
                Color.clear.frame(height: 24).accessibilityHidden(true)
            }
            if !samples.isEmpty {
                Text("\(samples.count) days").font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// The figure as the Coach cards show it: recovery whole, effort on the person's display scale, sleep as hours
    /// and minutes. A record that was not recorded reads "—", never zero.
    private func display(_ metric: LocalCoachMetric) -> (value: String, unit: String?) {
        guard metric.value != "Not recorded" else { return (WidgetMetrics.missingValue, nil) }
        let unit = metric.unit.isEmpty ? nil : metric.unit
        guard let stored = Double(metric.value) else { return (metric.value, unit) }
        switch metric.id {
        case "strain":
            return (UnitFormatter.effortDisplay(stored, scale: effortScale),
                    "of \(UnitFormatter.effortScaleMax(effortScale))")
        case "sleep":
            return (LocalCoachCardFormat.duration(minutes: stored * 60), nil)
        default:
            return (LocalCoachCardFormat.whole(stored), unit)
        }
    }

    private static func look(for metric: LocalCoachMetric) -> (symbol: String, tint: DomainTint) {
        switch metric.id {
        case "recovery": ("heart.fill", .recovery(score: Double(metric.value)))
        case "strain": ("flame.fill", .strain)
        case "sleep": ("moon.stars.fill", .sleep)
        case "hrv": ("waveform.path.ecg", .hrv)
        default: ("circle.fill", .accent)
        }
    }
}

// MARK: Medallion

/// A large symbol on a quiet tinted disc, the lead of an empty state.
struct CoachMedallion: View {
    let systemImage: String
    var tint: DomainTint = .accent

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 22, weight: .regular))
            .foregroundStyle(tint.accent)
            .frame(width: 52, height: 52)
            .background(Circle().fill(tint.accent.opacity(0.14)))
            .overlay(Circle().stroke(tint.accent.opacity(0.28), lineWidth: 1))
            .accessibilityHidden(true)
    }
}
#endif
