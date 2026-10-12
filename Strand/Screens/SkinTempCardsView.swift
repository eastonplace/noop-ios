import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Skin-temperature suite blocks (v5 pillar)
//
// Three self-contained, reusable blocks built on the underused nightly skin-temperature signal, each driven entirely
// by a pure StrandAnalytics engine RESULT passed in via init (the analytics pass runs the engines and the Health
// Monitor mounts these under its Skin temperature section):
//
//   • CycleAwarenessCard   — CyclePhaseEngine.Result. OPT-IN (period/cycle tracking is the
//                            most sensitive health category). Awareness only — NOT
//                            contraception, NOT a fertility/ovulation predictor, NOT a
//                            diagnosis. Phase + cycle-day RANGE + probabilistic next-period
//                            WINDOW (never a hard date).
//   • BodyClockCard        — CircadianEngine.PhaseEstimate (+ optional JetLagPlan). Estimated
//                            body-clock phase + a jet-lag / shift plan that is LIGHT + SLEEP
//                            TIMING only (never a supplement/drug).
//   • HeadsUpCard          — IllnessSignalEngine.Result. The confounder-suppressed illness
//                            "heads-up". On-device estimate — not a diagnosis.
//
// They are flat blocks in the widget language: a headline row with the confidence on the shared state pill, free text
// on the canvas, the pill buttons for actions, and no card around any of it. Privacy-forward copy: this data is
// physically incapable of leaving the device, and every sensitive surface says so.
//
// The blocks take VALUES, not stores — so a slip here stays local and can't take Health down, and the engines stay
// testable + I/O-free upstream.

// MARK: - Shared chrome

/// The standing privacy promise repeated on every sensitive skin-temp surface (the single
/// biggest competitive wedge vs cloud cycle trackers, and the ethical stance).
private let skinTempPrivacyLine =
    String(localized: "This stays on your device. It is never uploaded, never synced, never shared.")

/// A small, footnote-styled privacy row with a lock glyph — dropped at the foot of each
/// sensitive block so the promise is impossible to miss without shouting.
private struct PrivacyNote: View {
    var text: String = skinTempPrivacyLine
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "lock.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
            Text(text)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The headline row of a block: its title and a quiet line under it on the leading side, the confidence pill on the
/// trailing side. At an accessibility size the pill drops under the title instead of squeezing it.
private struct SkinTempBlockHeader: View {
    let title: String
    let subtitle: String?
    let pillTitle: LocalizedStringKey?
    let pillTone: StrandTone

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                heading
                pill
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                heading
                Spacer(minLength: NoopMetrics.space2)
                pill
            }
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title)
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(verbatim: subtitle)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var pill: some View {
        if let pillTitle { StatePill(pillTitle, tone: pillTone, showsDot: false) }
    }
}

/// A quiet text action under a block: the secondary ink, a 44pt tap area, never a bordered control.
private struct SkinTempQuietButton: View {
    let title: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(FlatRowPressStyle())
    }
}

// MARK: - 1. Cycle awareness (OPT-IN)

/// Cycle phase awareness from the nightly skin-temperature shift, corroborated by the luteal
/// RHR rise + HRV drop. OPT-IN by design — the host shows this only after the user enables
/// cycle awareness (default OFF). Awareness only; never contraception/fertility/diagnosis.
struct CycleAwarenessCard: View {
    /// The classified result from `CyclePhaseEngine.classify(...)`, computed in the analytics pass.
    let result: CyclePhaseEngine.Result
    /// The nightly fused-index (or temp-deviation) series, oldest→newest, for the sparkline.
    /// Optional — the block is honest with or without a curve.
    var curve: [Double] = []
    /// Called when the user taps "Log period start" (opt-in logged-period mode). nil hides it.
    var onLogPeriod: (() -> Void)? = nil
    /// Called when the user opens the cycle detail screen. nil makes the block non-navigating.
    var onOpenDetail: (() -> Void)? = nil
    /// Called when the user turns cycle awareness OFF from here (#801). nil hides the off control.
    /// Provided so the feature can be turned off in-place exactly where it was turned on (the opt-in
    /// block's "Turn on" lives in the same Health spot), rather than only from Automations.
    var onTurnOff: (() -> Void)? = nil

    // Cycle awareness reads in the calm, NON-VALENCED Sleep indigo world (mirroring Mind): a
    // phase is just information, never framed good/bad. No red, ever.
    private var hue: Color { StrandPalette.restColor }

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
            SkinTempBlockHeader(
                title: String(localized: "Cycle awareness"),
                subtitle: String(localized: "From your nightly temperature"),
                pillTitle: confidenceLabel, pillTone: confidenceTone)

            // The headline phase line + cycle-day range.
            phaseHeadline

            if curve.count > 1 {
                Sparkline(values: curve,
                          gradient: Gradient(colors: [hue.opacity(0.4), StrandPalette.restBright]),
                          showsHover: false)
                    .frame(height: 30)
                    .accessibilityHidden(true)
            }

            // Honest one-line status / next-period window.
            Text(verbatim: statusLine)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let window = result.nextPeriodWindow {
                nextPeriodRow(window)
            }

            actions

            // The standing awareness-only legal line (verbatim from the engine) + privacy promise.
            Text(verbatim: CyclePhaseEngine.awarenessLine)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            PrivacyNote()

            // In-place off control (#801): the toggle is symmetric, it can be turned off right where it was turned
            // on, not only from Automations. A quiet text action so it sits below the awareness/privacy lines
            // without competing with the primary ones.
            if let onTurnOff {
                SkinTempQuietButton(title: "Turn off cycle awareness", action: onTurnOff)
                    .accessibilityHint("Stops reading a cycle phase from your nightly temperature. You can turn it back on here any time.")
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: pieces

    private var phaseHeadline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: phaseTitle)
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let dayText = cycleDayText {
                Text(verbatim: dayText)
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: accessibilityHeadline))
    }

    private func nextPeriodRow(_ window: CyclePhaseEngine.NextPeriodWindow) -> some View {
        // A probabilistic WINDOW, never a single confident date — the copy reflects that.
        HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
            HealthGlyph(systemImage: "calendar", color: hue)
            Text("A period is likely between \(prettyDay(window.earliestDay)) and \(prettyDay(window.latestDay)) (a window, not a fixed date).")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var actions: some View {
        if onLogPeriod != nil || onOpenDetail != nil {
            ChipRow {
                if let onLogPeriod {
                    Button("Log period start", action: onLogPeriod)
                        .buttonStyle(SecondaryPillButtonStyle())
                        .accessibilityHint("Optional. Stored only on this device.")
                }
                if let onOpenDetail {
                    Button("View detail", action: onOpenDetail)
                        .buttonStyle(SecondaryPillButtonStyle())
                }
            }
        }
    }

    // MARK: derived copy

    private var phaseTitle: String {
        switch result.phase {
        case .follicular:   return String(localized: "Follicular")
        case .periOvulatory: return String(localized: "Mid-cycle shift")
        case .luteal:       return String(localized: "Luteal")
        case .unknown:      return String(localized: "No clear pattern")
        case .learning:     return String(localized: "Learning your pattern")
        }
    }

    /// "~day 18–22" — always a RANGE, never a single point.
    private var cycleDayText: String? {
        guard let lo = result.cycleDayLow, let hi = result.cycleDayHigh else { return nil }
        return lo == hi ? String(localized: "· ~day \(lo)") : String(localized: "· ~day \(lo)-\(hi)")
    }

    private var statusLine: String { result.note }

    private var confidenceLabel: LocalizedStringKey {
        switch result.confidence {
        case .learning: return "Learning"
        case .building: return "Building"
        case .solid:    return "Solid"
        }
    }

    private var confidenceTone: StrandTone {
        switch result.confidence {
        case .learning: return .neutral
        case .building: return .accent
        case .solid:    return .positive
        }
    }

    private var accessibilityHeadline: String {
        if let lo = result.cycleDayLow, let hi = result.cycleDayHigh {
            return lo == hi
                ? String(localized: "Cycle phase: \(phaseTitle). About day \(lo).")
                : String(localized: "Cycle phase: \(phaseTitle). About day \(lo) to \(hi).")
        }
        return String(localized: "Cycle phase: \(phaseTitle).")
    }
}

// MARK: - Cycle awareness opt-in (empty / disabled states)

/// Shown in place of `CycleAwarenessCard` when the user has NOT opted in. A single calm
/// opt-in block restating the privacy promise at the point of consent (manual-first; default OFF).
struct CycleAwarenessOptInCard: View {
    /// Toggles cycle awareness ON (the host persists the preference, default OFF).
    var onEnable: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
            SkinTempBlockHeader(title: String(localized: "Cycle awareness"), subtitle: nil, pillTitle: nil, pillTone: .neutral)
            Text("NOOP can read a coarse menstrual-cycle phase from your nightly skin temperature, entirely on your device. It is awareness only: not contraception, not a fertility predictor, not a medical service.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            PrivacyNote()
            ChipRow {
                Button("Turn on cycle awareness", action: onEnable)
                    .buttonStyle(SecondaryPillButtonStyle())
            }
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - 2. Body Clock

/// Estimated body-clock phase + an optional jet-lag / shift plan. The plan is LIGHT + SLEEP
/// TIMING only — never a supplement. Behavioural awareness, approximate.
struct BodyClockCard: View {
    /// The phase estimate from `CircadianEngine.estimatePhase(...)`, computed in the analytics pass.
    let estimate: CircadianEngine.PhaseEstimate
    /// Optional active re-entrainment plan (jet-lag / shift). nil = no plan running.
    var plan: CircadianEngine.JetLagPlan? = nil
    /// Opens the body-clock detail / jet-lag planner. nil makes the block non-navigating.
    var onOpenPlanner: (() -> Void)? = nil

    // The body clock reads in the cool Sleep world — calm, sleep-adjacent, non-valenced.
    private var hue: Color { StrandPalette.restColor }

    var body: some View {
        // Its own section: the body clock is read from light and sleep timing, not from skin temperature, so it does
        // not sit under the "Skin temperature · From your nightly sensor" eyebrow.
        VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
            SectionEyebrow("Body clock", systemImage: "moon.stars", tint: .custom(hue),
                           trailing: .pill(confidenceLabel, tone: confidenceTone))
            VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
                Text("Light + sleep timing only")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(verbatim: offsetTitle)
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(verbatim: estimate.note)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                // The estimated temperature-minimum clock time — the canonical phase marker.
                HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                    HealthGlyph(systemImage: "moon.stars", color: hue)
                    Text("Estimated body-clock low around \(clockString(estimate.tempMinHour))")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)

                if let plan, plan.direction != .none, let firstDay = plan.days.first {
                    planSummary(plan, firstDay: firstDay)
                }

                if let onOpenPlanner {
                    SkinTempQuietButton(title: plan == nil ? "Plan a trip or shift" : "View the full plan", action: onOpenPlanner)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: pieces

    private func planSummary(_ plan: CircadianEngine.JetLagPlan, firstDay: CircadianEngine.DayPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Plan · \(plan.estimatedDays)-day shift")
                .foregroundStyle(StrandPalette.textTertiary)
                .microLabelFit(lines: 2, weight: .semibold)
            // Day 1's concrete light + lights-out cue — light + sleep timing only.
            Text("Day 1: bright light \(clockString(firstDay.brightLightStartHour))-\(clockString(firstDay.brightLightEndHour)), lights-out around \(clockString(firstDay.targetSleepHour)).")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: plan.note)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: derived copy

    /// "About 25 min later than your schedule" — a plain, skimmable headline. An hour or more reads in hours
    /// ("About 3 h 14 min earlier than your schedule").
    private var offsetTitle: String {
        Self.offsetTitle(offsetMinutes: estimate.offsetVsScheduleMinutes, unreadable: estimate.confidence == .unreadable)
    }

    static func offsetTitle(offsetMinutes: Double, unreadable: Bool) -> String {
        let mins = Int(abs(offsetMinutes).rounded())
        if unreadable { return String(localized: "Hard to read right now") }
        if mins <= 20 { return String(localized: "About in sync with your schedule") }
        let later = offsetMinutes > 0
        if mins < 60 {
            return later
                ? String(localized: "About \(mins) min later than your schedule")
                : String(localized: "About \(mins) min earlier than your schedule")
        }
        let span = durationText(minutes: mins)
        return later
            ? String(localized: "About \(span) later than your schedule")
            : String(localized: "About \(span) earlier than your schedule")
    }

    /// "3 h 14 min", or "3 h" on the hour.
    static func durationText(minutes: Int) -> String {
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? String(localized: "\(hours) h") : String(localized: "\(hours) h \(rest) min")
    }

    private var confidenceLabel: LocalizedStringKey {
        switch estimate.confidence {
        case .unreadable: return "Calibrating"
        case .wide:       return "Building"
        case .solid:      return "Solid"
        }
    }

    private var confidenceTone: StrandTone {
        switch estimate.confidence {
        case .unreadable: return .neutral
        case .wide:       return .accent
        case .solid:      return .positive
        }
    }

    /// Render a fractional clock hour as "HH:MM" (locale-free, matching the engine's own helper).
    private func clockString(_ hour: Double) -> String {
        var h = hour.truncatingRemainder(dividingBy: 24)
        if h < 0 { h += 24 }
        var hh = Int(h)
        var mm = Int(((h - Double(hh)) * 60).rounded())
        if mm == 60 { mm = 0; hh = (hh + 1) % 24 }
        return String(format: "%02d:%02d", hh, mm)
    }
}

// MARK: - 3. Heads-Up (illness early-warning, confounder-suppressed)

/// The confounder-suppressed illness "heads-up". Renders the engine's already-decided level +
/// copy; the host only mounts it when the engine returns a non-quiet level. On-device estimate
/// — not a diagnosis. The level sets the tint: amber when raised, the calm rest colour otherwise.
struct HeadsUpCard: View {
    /// The decision from `IllnessSignalEngine.evaluate(...)`, computed in the analytics pass.
    let result: IllnessSignalEngine.Result
    /// Optional parallel Mahalanobis distance (IllnessDistance), computed on the SAME z-vector. It does
    /// NOT gate this block (the engine's level already did); when the level is raised and a distance is
    /// present we append a subtle "Confidence" line so the user can gauge how strong the signal is.
    var distance: IllnessDistance.Result? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
            HStack(alignment: .top, spacing: NoopMetrics.space3) {
                GlyphDisc(glyph, tint: .custom(hue))
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: title)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: result.copy)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            // The visible "why": which signals fired. Explainability is what earns trust.
            if !result.firedSignals.isEmpty {
                whyRow(label: "Signals up", values: result.firedSignals, tint: hue)
            }
            // ...and what was ruled out (the differentiating part vs a black-box warning).
            if !result.suppressedBy.isEmpty {
                whyRow(label: "Explained by", values: result.suppressedBy, tint: StrandPalette.textTertiary)
            }
            // Optional confidence read from the parallel Mahalanobis distance, only when the level is
            // raised. Subtle by design: it augments, never gates (the engine already decided to raise).
            if let confidence = confidenceLine {
                Text(verbatim: confidence)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(title). \(result.copy)"))
    }

    private func whyRow(label: LocalizedStringKey, values: [String], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .foregroundStyle(StrandPalette.textTertiary)
                .microLabelFit(lines: 2, weight: .semibold)
            // Each fired signal / confounder as a quiet chip.
            FlowChips(values: values, tint: tint)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: derived presentation

    /// The hue follows the level: raised/already-unwell = amber warning (matches the shipped banner);
    /// suppressed/mild = a calmer neutral so it never scares.
    private var hue: Color {
        switch result.level {
        case .raised, .alreadyUnwell: return StrandPalette.statusWarning
        case .suppressed, .mild:      return StrandPalette.restColor
        case .quiet:                  return StrandPalette.restColor
        }
    }

    private var glyph: String {
        switch result.level {
        case .raised:        return "exclamationmark.triangle.fill"
        case .alreadyUnwell: return "bed.double.fill"
        case .suppressed:    return "info.circle.fill"
        case .mild:          return "waveform.path"
        case .quiet:         return "checkmark.circle.fill"
        }
    }

    private var title: String {
        switch result.level {
        case .raised:        return String(localized: "Heads-up")
        case .alreadyUnwell: return String(localized: "Sleep up")
        case .suppressed:    return String(localized: "Probably not illness")
        case .mild:          return String(localized: "A few signals are up")
        case .quiet:         return String(localized: "Nothing notable")
        }
    }

    /// A subtle confidence read from the parallel Mahalanobis distance, surfaced ONLY on the RAISED state
    /// (and when a distance is present). nil otherwise. The already-unwell state is driven purely by the
    /// user's own log and can have a near-zero distance (0-1 present features), giving a misleading
    /// "Confidence: slight (distance 0.0)", so it's excluded. The raised path always has >= 2 present
    /// features, so its distance is meaningful. The band mirrors Android exactly. (Augment-only, never gates.)
    private var confidenceLine: String? {
        guard result.level == .raised,
              let d = distance else { return nil }
        return String(localized: "Confidence: \(IllnessConfidence.band(d.distance)) (distance \(IllnessConfidence.formatted(d.distance)))")
    }
}

// MARK: - Illness confidence band (shared wording, mirrored byte-for-byte on Android)

/// Maps the parallel Mahalanobis distance to a plain confidence word + a one-decimal display value.
/// This is presentation-only: it NEVER decides whether the Heads-Up block shows (the engine's level
/// already did). Bands: >= 3.5 strong, >= 2.5 moderate, else slight. Identical to the Kotlin twin.
enum IllnessConfidence {
    static func band(_ distance: Double) -> String {
        if distance >= 3.5 { return String(localized: "strong") }
        if distance >= 2.5 { return String(localized: "moderate") }
        return String(localized: "slight")
    }
    static func formatted(_ distance: Double) -> String {
        String(format: "%.1f", distance)
    }
}

// MARK: - Small chip flow (shared by Heads-Up)

/// A wrapping row of small tinted chips. Used for fired signals / confounders so a long list
/// never clips. Decorative wrapping; the parent combines it into one VoiceOver stop.
private struct FlowChips: View {
    let values: [String]
    var tint: Color = StrandPalette.textTertiary
    var body: some View {
        // A simple wrapping HStack via a flexible layout; for the small counts here a plain
        // HStack with wrapping fallback is enough and avoids a custom Layout dependency.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { chips }
            VStack(alignment: .leading, spacing: 6) { chips }
        }
    }
    @ViewBuilder private var chips: some View {
        ForEach(values, id: \.self) { v in
            Text(verbatim: v)
                .font(StrandFont.captionNumber)
                .foregroundStyle(StrandPalette.textPrimary)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(tint.opacity(0.14), in: Capsule(style: .continuous))
        }
    }
}

// MARK: - Day formatting

/// "12 Jun" from a "yyyy-MM-dd" key (locale-aware for display only; the engine math stays UTC).
private func prettyDay(_ key: String) -> String {
    let parts = key.split(separator: "-")
    guard parts.count == 3, let m = Int(parts[1]), let d = Int(parts[2]), (1...12).contains(m) else { return key }
    let months = [String(localized: "Jan"), String(localized: "Feb"), String(localized: "Mar"),
                  String(localized: "Apr"), String(localized: "May"), String(localized: "Jun"),
                  String(localized: "Jul"), String(localized: "Aug"), String(localized: "Sep"),
                  String(localized: "Oct"), String(localized: "Nov"), String(localized: "Dec")]
    return "\(d) \(months[m - 1])"
}

#if DEBUG
#Preview("Skin-temp blocks") {
    ScrollView {
        VStack(alignment: .leading, spacing: 0) {
            CycleAwarenessCard(
                result: CyclePhaseEngine.Result(
                    phase: .luteal, confidence: .solid,
                    cycleDayLow: 20, cycleDayHigh: 24, cycleLengthDays: 28,
                    nextPeriodWindow: .init(earliestDay: "2026-06-24", latestDay: "2026-06-28"),
                    shiftMarkers: [], note: "Luteal range — temperature is running above your baseline."),
                curve: (0..<60).map { 0.1 * sin(Double($0) / 9) + 0.05 },
                onLogPeriod: {}, onOpenDetail: {})
            FlatSectionSeparator()
            CycleAwarenessOptInCard(onEnable: {})
            FlatSectionSeparator()
            BodyClockCard(
                estimate: CircadianEngine.PhaseEstimate(
                    tempMinHour: 5.2, acrophaseHours: 16.0, offsetVsScheduleMinutes: 38,
                    confidence: .solid, note: "Your body clock looks later (a night-owl lean)."),
                plan: CircadianEngine.JetLagPlan(
                    direction: .advance, totalShiftHours: 3, estimatedDays: 3,
                    days: [.init(dayIndex: 1, brightLightStartHour: 7, brightLightEndHour: 9,
                                 dimFromHour: 21, targetSleepHour: 22.75, targetWakeHour: 6.5,
                                 guidance: "")],
                    note: "Shifting your clock 3.0 h earlier, about an hour a day. Light and sleep timing only."),
                onOpenPlanner: {})
            FlatSectionSeparator()
            HeadsUpCard(result: IllnessSignalEngine.Result(
                score: 64, level: .raised,
                firedSignals: ["RHR +6", "HRV −22%", "skin temp +0.7 °C"],
                suppressedBy: [], signalCount: 3,
                copy: "Heads-up — your body looks strained. RHR +6, HRV −22%, skin temp +0.7 °C. With no alcohol or travel logged, consider taking it easy. On-device estimate — not a diagnosis."))
            FlatSectionSeparator()
            HeadsUpCard(result: IllnessSignalEngine.Result(
                score: 28, level: .suppressed,
                firedSignals: ["RHR +5", "skin temp +0.6 °C"],
                suppressedBy: ["alcohol"], signalCount: 2,
                copy: "Some signals are up (RHR +5, skin temp +0.6 °C), but you logged alcohol — likely that, not illness. On-device estimate — not a diagnosis."))
        }
        .padding(.horizontal, 16)
    }
    .background(StrandPalette.appCanvas)
    .preferredColorScheme(.dark)
}
#endif
