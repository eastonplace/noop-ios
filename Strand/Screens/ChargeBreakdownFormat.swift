import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Charge breakdown presentation (pure, testable)
//
// LANE 2 (iOS UI) presentation helpers for the "What shaped it" Charge breakdown, the score-
// confidence tier presentation, the calibrating countdown copy and the relative skin-temp label. Every
// helper here is PURE (no SwiftUI state, no I/O) so the chip formatter and countdown copy are
// unit-tested directly; the views below consume them. They are presentation only: nothing here
// recomputes a score, a confidence or a driver delta - those arrive from the engine
// (`ChargeDriver`, `ScoreConfidence`, `SkinTempRelative`) and are surfaced verbatim.
//
// No fabricated numbers, no em-dashes. Design-system tokens only (StrandPalette / StrandFont /
// NoopMetrics); the +N/-N chip uses the recovery ramp endpoints (green peak / red depleted) so a
// supporting term reads green and a limiting term reads red, matching the Charge colour world.

enum ChargeBreakdownFormat {

    // MARK: - Signed point-delta chip (A1)

    /// The chip label for a term's signed point contribution, e.g. +6 pts / -3 pts / 0 pts.
    /// Always carries an explicit sign for a non-zero delta so a positive term reads "+N" not "N".
    /// Pure + unit-tested (`ChargeBreakdownFormatTests`).
    static func chipLabel(deltaPoints: Int) -> String {
        // Whole-phrase variants per sign/count so translators never see a stitched unit fragment.
        if deltaPoints > 0 {
            return deltaPoints == 1 ? String(localized: "+\(deltaPoints) pt")
                                    : String(localized: "+\(deltaPoints) pts")
        }
        if deltaPoints < 0 {   // the minus sign rides the value
            return deltaPoints == -1 ? String(localized: "\(deltaPoints) pt")
                                     : String(localized: "\(deltaPoints) pts")
        }
        return String(localized: "0 pts")
    }

    /// The chip colour for a signed delta, sampled from the RECOVERY RAMP endpoints so the Charge
    /// colour world stays consistent: a term that supported recovery (positive) reads the ramp's
    /// green peak, one that limited it (negative) reads the red depleted end, and a neutral term
    /// reads tertiary text so it doesn't shout. Pure.
    static func chipColor(deltaPoints: Int) -> Color {
        if deltaPoints > 0 { return StrandPalette.recoveryColor(100) }   // green peak end of the ramp
        if deltaPoints < 0 { return StrandPalette.recoveryColor(0) }     // red depleted end of the ramp
        return StrandPalette.textTertiary
    }

    /// VoiceOver phrasing of one driver row: label, signed points, value vs baseline, verdict.
    /// Built from the engine row verbatim (no recompute). Pure.
    static func driverAccessibilityLabel(_ d: ChargeDriver) -> String {
        // Whole-phrase variants (direction x count, and with/without baseline) so translators see
        // complete sentences, never stitched direction/plural fragments.
        let pts: String
        if d.deltaPoints == 0 {
            pts = String(localized: "no change")
        } else {
            let n = abs(d.deltaPoints)
            switch (d.deltaPoints > 0, n == 1) {
            case (true, true):   pts = String(localized: "up 1 point")
            case (true, false):  pts = String(localized: "up \(n) points")
            case (false, true):  pts = String(localized: "down 1 point")
            case (false, false): pts = String(localized: "down \(n) points")
            }
        }
        // The engine's label + verdict are catalog KEYS (see ChargeDrivers.swift). Interpolating them
        // raw into a String(localized:) template would leave them English in a localized build (the
        // template is the lookup key, its substitutions are not re-localized), so look each up first
        // and interpolate the already-localized text. valueText/baselineText are numeric read-outs.
        let label = String(localized: String.LocalizationValue(d.label))
        let verdict = String(localized: String.LocalizationValue(d.verdict))
        if d.baselineText.isEmpty {
            return String(localized: "\(label): \(pts). \(d.valueText). \(verdict).")
        }
        return String(localized: "\(label): \(pts). \(d.valueText), \(d.baselineText). \(verdict).")
    }

    // MARK: - Score-confidence tier chip (A3)

    /// The short tier TAG surfaced on a score tile / breakdown header. Pure presentation of the
    /// EXISTING `ScoreConfidence` (never recomputed): calibrating -> CALIBRATING, building -> EST.,
    /// solid -> REL. (reliable). Unit-tested.
    static func tierTag(_ confidence: ScoreConfidence) -> String {
        switch confidence {
        case .calibrating: return String(localized: "CALIBRATING")
        case .building:    return String(localized: "EST.")
        case .solid:       return String(localized: "REL.")
        }
    }

    /// The `ScoreState` pill style that carries the tier chip, mapping the existing confidence onto
    /// the design system's score-lifecycle hues (slate / blue / green). Pure.
    static func tierState(_ confidence: ScoreConfidence) -> ScoreState {
        switch confidence {
        case .calibrating: return .calibrating
        case .building:    return .building
        case .solid:       return .solid
        }
    }

    /// The small confidence-dot colour, reusing the same lifecycle hue as the tier pill so the dot
    /// and the tag never disagree. Pure.
    static func confidenceDotColor(_ confidence: ScoreConfidence) -> Color {
        tierState(confidence).color
    }

    /// VoiceOver phrasing retained when the old hand-rolled confidence chip is rendered by the
    /// canonical `ScoreStatePill`.
    static func confidenceAccessibilityLabel(_ confidence: ScoreConfidence) -> String {
        switch confidence {
        case .calibrating: return String(localized: "Confidence: calibrating")
        case .building:    return String(localized: "Confidence: estimate")
        case .solid:       return String(localized: "Confidence: reliable")
        }
    }

    // MARK: - Calibrating countdown copy (A4)

    /// The hero countdown line shown in place of an empty/zero Charge while the baseline is still
    /// building, e.g. "2 nights to go". `nightsRemaining` is the EXISTING calibrating value (seed
    /// gate minus banked, clamped >= 1 by the caller); the singular/plural reads honestly. Pure +
    /// unit-tested.
    static func calibrationCountdown(nightsRemaining: Int) -> String {
        // Whole-phrase variants per count so translators never see a stitched plural fragment.
        let n = max(0, nightsRemaining)
        return n == 1 ? String(localized: "1 night to go") : String(localized: "\(n) nights to go")
    }

    /// The supporting line under the countdown, naming the score whose baseline is unlocking. Pure.
    /// `scoreName` is the user-facing score word (e.g. "Recovery"); kept a parameter so the same copy
    /// serves any baseline-building score honestly without hard-coding one.
    static func calibrationUnlockCopy(scoreName: String) -> String {
        String(localized: "more overnight wear to unlock your \(scoreName) baseline")
    }

    /// "Calibrating, 1 of 4 nights" progress label for the countdown card header. `banked` is the
    /// nights gathered so far, `seed` the gate (`Baselines.minNightsSeed`). Pure + unit-tested.
    static func calibrationProgress(banked: Int, seed: Int) -> String {
        String(localized: "Calibrating, \(max(0, banked)) of \(seed) nights")
    }

    // MARK: - Relative skin-temp label (A5)

    /// The relative skin-temp read-out, e.g. "+0.3 C vs your normal" / "-0.4 C vs your normal".
    /// Built from the engine's signed deviation; one decimal, explicit sign, never a fake absolute.
    /// Pure + unit-tested.
    static func skinTempDeviationLabel(_ rel: SkinTempRelative) -> String {
        let sign = rel.deviationC >= 0 ? "+" : ""
        return String(localized: "\(sign)\(String(format: "%.1f", rel.deviationC)) C vs your normal")
    }

    /// The plain-English tier word for the relative skin-temp marker. Pure.
    static func skinTempTierWord(_ tier: SkinTempRelative.Tier) -> String {
        switch tier {
        case .cooler:  return String(localized: "Cooler than your baseline")
        case .typical: return String(localized: "Typical for you")
        case .warmer:  return String(localized: "Warmer than your baseline")
        }
    }
}

// MARK: - A1: "What shaped it" Charge breakdown

/// The "What shaped it" breakdown rendered under the Charge ring: a header carrying the confidence
/// tier chip, then one row per engine-supplied `ChargeDriver` (biggest mover first), and the A5
/// relative skin-temp marker at the foot when present. Every value is surfaced verbatim from the
/// engine; nothing here recomputes a score, a delta or a tier. The caller GATES on a non-empty driver
/// list, so this view assumes at least one row (a calibrating night shows the countdown instead).
struct ChargeBreakdownSection: View {
    let drivers: [ChargeDriver]
    let confidence: ScoreConfidence
    var skinTempRel: SkinTempRelative? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
            Divider().overlay(StrandPalette.hairline)
            HStack(alignment: .firstTextBaseline) {
                Text("What shaped it").strandOverline()
                Spacer()
                ScoreStatePill(
                    ChargeBreakdownFormat.tierState(confidence),
                    text: "\(ChargeBreakdownFormat.tierTag(confidence))"
                )
                .accessibilityLabel(ChargeBreakdownFormat.confidenceAccessibilityLabel(confidence))
            }
            VStack(spacing: NoopMetrics.rowSpacing) {
                let maxMag = drivers.map { abs($0.deltaPoints) }.max() ?? 1
                ForEach(Array(drivers.enumerated()), id: \.offset) { _, driver in
                    ChargeDriverRow(driver: driver, maxMagnitude: maxMag)
                }
            }
            // A5 , the night's relative skin-temp marker, tagged REL., shown as a deviation from the
            // personal normal rather than a fake clinical absolute. Only when the night carries one.
            if let rel = skinTempRel {
                SkinTempDeviationRow(rel: rel)
                    .padding(.top, NoopMetrics.space1)
            }
            // Plan doc G4 (spec 012 T702): the approved Sleep-in-Charge note, shown only when a real
            // "Sleep quality" driver row is present above (never claim the integration when the term
            // didn't actually feed the score). Not flag-gated — it states an integration fact true
            // under both legacy and V2 authority, not a V2 methodology claim.
            if drivers.contains(where: { $0.label == "Sleep quality" }) {
                Text("Last night's Sleep Performance contributes to Charge alongside HRV, resting heart rate, respiration, and skin-temperature deviation. The exact Sleep Performance shown on the Sleep screen is the value used here.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, NoopMetrics.space1)
            }
        }
    }
}

/// One driver row: a signed point-delta chip (+N green / -N red), the value vs baseline, a thin
/// progress bar proportional to the term's magnitude, and the plain-English verdict line. The bar is
/// a presentation cue for "how big a mover" this term was, scaled within the day's own drivers.
struct ChargeDriverRow: View {
    let driver: ChargeDriver
    /// The largest |deltaPoints| in the same breakdown, so each bar reads as a share of the day's
    /// biggest mover. Defaults to this row's own magnitude (full bar) when not supplied.
    var maxMagnitude: Int? = nil

    private var chipText: String { ChargeBreakdownFormat.chipLabel(deltaPoints: driver.deltaPoints) }
    private var chipHue: Color { ChargeBreakdownFormat.chipColor(deltaPoints: driver.deltaPoints) }
    private var magnitude: Double { Double(abs(driver.deltaPoints)) }
    private var barMax: Double { Double(max(1, maxMagnitude ?? abs(driver.deltaPoints))) }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(LocalizedStringKey(driver.label))
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer(minLength: 8)
                // The signed point-delta chip , green for a supporting term, red for a limiting one.
                MicroBadge("\(chipText)", tint: chipHue)
            }
            // value vs baseline , the baseline line is omitted for terms with no learned baseline.
            HStack(spacing: 6) {
                Text(driver.valueText)
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(StrandPalette.textSecondary)
                if !driver.baselineText.isEmpty {
                    Text("·").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    Text(driver.baselineText)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer(minLength: 0)
            }
            // A thin magnitude bar tinted to the chip hue, reading the term's share of the biggest mover.
            PipBar(value: magnitude, range: 0...barMax, segments: 16, tint: chipHue, height: 6)
                .accessibilityHidden(true)
            Text(LocalizedStringKey(driver.verdict))
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ChargeBreakdownFormat.driverAccessibilityLabel(driver))
    }
}

/// A5 , the relative skin-temp deviation row: "Skin temperature · +0.3 C vs your normal" with a REL.
/// tag pill (the relative tier is reliable presentation, never a clinical absolute). Tinted amber to
/// match the skin-temp accent used in the Charge model explainer.
struct SkinTempDeviationRow: View {
    let rel: SkinTempRelative

    private var deviationText: String { ChargeBreakdownFormat.skinTempDeviationLabel(rel) }
    private var tierWord: String { ChargeBreakdownFormat.skinTempTierWord(rel.tier) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "thermometer.medium")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(StrandPalette.metricAmber)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("Skin temperature")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(deviationText)
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                Text(tierWord)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: 0)
            // The relative tier is a reliable read of a measured deviation, so it carries the REL. tag.
            ScoreStatePill(
                ChargeBreakdownFormat.tierState(.solid),
                text: "\(ChargeBreakdownFormat.tierTag(.solid))"
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Skin temperature \(deviationText). \(tierWord). Reliable.")
    }
}

#if DEBUG
#Preview("Recovery breakdown") {
    ScrollView {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
            HStack(spacing: 10) {
                ScoreStatePill(.calibrating, text: "\(ChargeBreakdownFormat.tierTag(.calibrating))")
                ScoreStatePill(.building, text: "\(ChargeBreakdownFormat.tierTag(.building))")
                ScoreStatePill(.solid, text: "\(ChargeBreakdownFormat.tierTag(.solid))")
            }
            NoopCard(padding: 18, tint: StrandPalette.recoveryData) {
                ChargeBreakdownSection(
                    drivers: [
                        ChargeDriver(label: "Heart rate variability", deltaPoints: 7,
                                     valueText: "72 ms", baselineText: "64 ms baseline",
                                     verdict: "above baseline, supporting recovery"),
                        ChargeDriver(label: "Resting heart rate", deltaPoints: -4,
                                     valueText: "60 bpm", baselineText: "56 bpm baseline",
                                     verdict: "above baseline, limiting recovery"),
                        ChargeDriver(label: "Sleep quality", deltaPoints: 2,
                                     valueText: "88%", baselineText: "",
                                     verdict: "a strong night, supporting recovery"),
                    ],
                    confidence: .building,
                    skinTempRel: SkinTempRelative(deviationC: 0.3, tier: .warmer))
            }
        }
        .padding(NoopMetrics.screenPadding)
    }
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}

#endif
