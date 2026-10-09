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
        return .record(date: LocalCoachCardFormat.dayLabel(date, now: now), isStale: age >= 2)
    }
}

// MARK: Primary pill

/// The primary action: Today's Start pill (brand ink capsule, dark label) scaled up modestly for a page whose one
/// job is this action. The tap area reaches 44pt without growing the layout. Disabled it is the standard quiet
/// look (the chip wash behind a tertiary label), never a dimmed accent, so it cannot be mistaken for a rendering fault.
struct CoachPrimaryPillStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(StrandFont.subhead.weight(.semibold))
            .foregroundStyle(isEnabled ? StrandPalette.appCanvas : StrandPalette.textTertiary)
            .padding(.horizontal, NoopMetrics.space4)
            .padding(.vertical, 10)
            .background(isEnabled ? StrandPalette.ink : StrandPalette.chipFill, in: Capsule(style: .continuous))
            .contentShape(Rectangle().inset(by: -4))
            .opacity(isEnabled && configuration.isPressed ? 0.78 : 1)
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
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

// MARK: Fact strip

struct CoachFact {
    let label: LocalizedStringKey
    let value: String
    var unit: LocalizedStringKey?
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
/// replacement for `NoteCard` on Coach pages. A failure passes `details`: the system's own wording, kept out of
/// the sentence and one tap away under "Details".
struct CoachNotice: View {
    enum Tone { case warning, info }

    let text: Text
    var tone: Tone = .warning
    var details: String?

    private var symbol: String { tone == .warning ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath" }
    private var color: Color { tone == .warning ? StrandPalette.statusWarning : StrandPalette.textSecondary }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
            Image(systemName: symbol).font(StrandFont.caption).foregroundStyle(color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                text.font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                if let details { CoachNoticeDetails(text: details).id(details) }
            }
            // Always its full height: when the page is short (large text, Details open) the conversation above gives
            // way, never the sentence.
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // With Details the sentence and the button stay two elements, so the button can be reached.
        .accessibilityElement(children: details == nil ? .combine : .contain)
    }
}

extension CoachNotice {
    /// A failure message as the person should meet it: a plain sentence, the system's wording under Details.
    init(error raw: String) {
        let copy = CoachErrorCopy(raw)
        self.init(text: Text(LocalizedStringKey(copy.message)), tone: .warning, details: copy.details)
    }
}

/// "Details" and a chevron; opened, the system's text. Long text scrolls inside a bounded height instead of
/// pushing the page's composer off the screen.
private struct CoachNoticeDetails: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .footnote) private var maxTextHeight: CGFloat = 132
    @State private var isExpanded = Self.startsOpen
    @State private var textHeight: CGFloat = 0

    /// A capture can start the disclosure open: `--noop-coach-details-open`. DEBUG only.
    private static var startsOpen: Bool {
        #if DEBUG
        CommandLine.arguments.contains("--noop-coach-details-open")
        #else
        false
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text("Details")
                    Image(systemName: "chevron.down").font(StrandFont.micro.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0)).accessibilityHidden(true)
                }
                .font(StrandFont.footnote.weight(.semibold))
                .foregroundStyle(StrandPalette.textSecondary)
                .chipHitTarget()
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))
            .accessibilityIdentifier("coach.errorDetails")
            if isExpanded {
                ScrollView {
                    Text(verbatim: text)
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: CoachDetailsHeightKey.self, value: proxy.size.height)
                        })
                }
                .onPreferenceChange(CoachDetailsHeightKey.self) { textHeight = $0 }
                .frame(height: min(textHeight, maxTextHeight))
            }
        }
    }
}

private struct CoachDetailsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// How a failure reads on screen: one plain sentence the person can act on, with the system's own wording kept
/// under Details. The engine's messages are either curated sentences (shown as written) or a
/// `LocalCoachErrorPrefix` phrase followed by the system's text, which is never the headline.
struct CoachErrorCopy: Equatable {
    /// An English catalog key, shown through `LocalizedStringKey`.
    let message: String
    /// The original text, when `message` replaced it.
    let details: String?

    init(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // One of Coach's own sentences, bare or inside the system's text (a tool that failed with it): lead with it.
        if let curated = LocalCoachFailure.allCases.compactMap(\.errorDescription).first(where: { text.contains($0) }) {
            message = curated
            details = text == curated ? nil : text
        } else if let known = Self.plain.first(where: { text.hasPrefix($0.prefix) }) {
            message = known.message
            details = text
        } else {
            message = text
            details = nil
        }
    }

    /// The plain sentence for each phrase the engine puts before a system error's own wording.
    static let plain: [(prefix: String, message: String)] = [
        (LocalCoachErrorPrefix.responseStopped,
         "Coach could not finish that reply. Try again, or ask it a different way."),
        (LocalCoachErrorPrefix.recordsUnreadable,
         "Coach could not read your records just now. Try again in a moment."),
        (LocalCoachErrorPrefix.settingsUnreadable,
         "Coach could not read its saved settings, so it is off for now. Restart NOOP to try again."),
        (LocalCoachErrorPrefix.settingsNotSaved,
         "Your latest Coach settings were not saved. Try changing them again."),
        (LocalCoachErrorPrefix.historyUnreadable,
         "Coach could not load your saved conversations. Restart NOOP to try again."),
        (LocalCoachErrorPrefix.changesNotSaved,
         "Your latest Coach changes were not saved. Try again."),
        (LocalCoachErrorPrefix.storageUnavailable,
         "Coach could not open its storage, so nothing will be saved. Restart NOOP to try again.")
    ]
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
/// stacked at accessibility sizes and wherever a column would truncate.
struct CoachMetricStrip: View {
    let metrics: [LocalCoachMetric]
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.whoop.rawValue
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title3) private var valueSize: CGFloat = 24

    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    /// Columns keep a line's room for the sparkline so their values align, unless no column has one to draw.
    private var reservesChart: Bool { metrics.contains { $0.samples.filter(\.isFinite).count > 1 } }

    var body: some View {
        if typeSize.isAccessibilitySize {
            stacked
        } else {
            // Three columns while every label and value fits whole; stacked when a size would truncate one.
            ViewThatFits(in: .horizontal) {
                columns(size: valueSize)
                columns(size: valueSize * 0.85)
                stacked
            }
        }
    }

    private func columns(size: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                if index > 0 {
                    Rectangle().fill(StrandPalette.hairline).frame(width: 1)
                        .accessibilityHidden(true)
                }
                column(metric, size: size, fitsWhole: true)
                    .padding(.leading, index == 0 ? 0 : NoopMetrics.space3)
                    .padding(.trailing, index == metrics.count - 1 ? 0 : NoopMetrics.space3)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space4) {
            ForEach(metrics) { column($0, size: valueSize, fitsWhole: false) }
        }
    }

    /// `fitsWhole` makes the column report the full width of its label and value, so `ViewThatFits` moves on to
    /// the next layout instead of truncating one of them.
    private func column(_ metric: LocalCoachMetric, size: CGFloat, fitsWhole: Bool) -> some View {
        let look = Self.look(for: metric)
        let shown = CoachMetricFigure(metric, effortScale: effortScale)
        let samples = metric.samples.filter(\.isFinite)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: look.symbol).font(StrandFont.caption).foregroundStyle(look.tint.accent)
                    .accessibilityHidden(true)
                Self.label(for: metric).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
            }
            .fixedSize(horizontal: fitsWhole, vertical: false)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(shown.value).font(StrandFont.number(size, weight: .semibold))
                    .foregroundStyle(shown.value == WidgetMetrics.missingValue ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                if let unit = shown.unitText, shown.value != WidgetMetrics.missingValue {
                    unit.font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .lineLimit(1)
            .fixedSize(horizontal: fitsWhole, vertical: false)
            if samples.count > 1 {
                Sparkline(values: samples, gradient: look.tint.chartGradient, lineWidth: 2, showsHover: false)
                    .frame(height: 24)
                    .accessibilityHidden(true)
            } else if reservesChart {
                Color.clear.frame(height: 24).accessibilityHidden(true)
            }
            if !samples.isEmpty {
                Text(daysTitle(samples.count))
                    .font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func daysTitle(_ count: Int) -> LocalizedStringKey {
        count == 1 ? "1 day" : "\(count) days"
    }

    /// The label for each record, worded as Today words it (Strain, not Effort) and read through the catalog. The
    /// record's own title stays what the model is told; it is only the fallback for a record this strip does not know.
    private static func label(for metric: LocalCoachMetric) -> Text {
        switch metric.id {
        case "recovery": Text("Recovery")
        case "strain": Text("Strain")
        case "sleep": Text("Sleep")
        case "hrv": Text("HRV")
        default: Text(verbatim: metric.title)
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

/// What one record in the metric strip shows: the figure as the Coach cards show it (recovery whole, strain on the
/// person's display scale, sleep as hours and minutes) and its unit. A record that is not a number, because the day
/// was not recorded, reads "—", never zero. Pure, so it can be tested.
struct CoachMetricFigure: Equatable {
    enum Unit: Equatable {
        /// "of 21": the top of the strain scale.
        case ofScale(String)
        /// The record's own unit, shown as it is ("ms", "/100").
        case plain(String)
    }

    let value: String
    let unit: Unit?

    init(_ metric: LocalCoachMetric, effortScale: EffortScale) {
        guard let stored = Double(metric.value) else {
            value = WidgetMetrics.missingValue
            unit = nil
            return
        }
        switch metric.id {
        case "strain":
            value = UnitFormatter.effortDisplay(stored, scale: effortScale)
            unit = .ofScale(UnitFormatter.effortScaleMax(effortScale))
        case "sleep":
            value = LocalCoachCardFormat.duration(minutes: stored * 60)
            unit = nil
        default:
            value = LocalCoachCardFormat.whole(stored)
            unit = metric.unit.isEmpty ? nil : .plain(metric.unit)
        }
    }

    var unitText: Text? {
        switch unit {
        case .ofScale(let top)?: return Text("of \(top)")
        case .plain(let text)?: return Text(verbatim: text)
        case nil: return nil
        }
    }
}

// MARK: Plan wording

/// The plan's few pure sentences and figures, kept out of the views so they can be tested.
enum CoachPlanText {
    /// The Overview's plan entry line. The count is a plural in every language; with no plan it is the invitation.
    static func entrySubtitle(sessions: Int?, saved: Bool) -> LocalizedStringResource {
        guard let sessions else { return "Build, review and save your next workout." }
        return saved ? "\(sessions) sessions · Saved to your workouts" : "\(sessions) sessions · Ready for your review"
    }

    /// Whole minutes per session, averaged over the plan's days; nil when there are none.
    static func minutesPerSession(_ minutes: [Int]) -> Int? {
        minutes.isEmpty ? nil : Int((Double(minutes.reduce(0, +)) / Double(minutes.count)).rounded())
    }
}

// MARK: Icon chip tap target

private struct CoachGrownRect: Shape {
    let dx: CGFloat
    let dy: CGFloat
    func path(in rect: CGRect) -> Path { Path(rect.insetBy(dx: -dx, dy: -dy)) }
}

extension View {
    /// Grows an icon-only chip's tap area to 44pt without moving anything: it reaches 9pt past the chip's sides and
    /// 12.5pt past its top and bottom. Two such chips 18pt apart get a full target each and neither overlaps the
    /// other (`chipHitTarget()` reaches 13pt on every side, for a chip with room around it).
    func iconChipHitTarget() -> some View {
        contentShape(CoachGrownRect(dx: 9, dy: 12.5))
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
