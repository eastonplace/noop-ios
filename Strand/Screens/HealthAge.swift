import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Health Monitor: Fitness Age and Vitality
//
// Two weekly, on-device reads, each a flat section: an eyebrow, a hero value and what to know about it. Neither is a
// biological or medical age; the copy says so (docs/FITNESS_AGE.md is the contract for Fitness Age).

// MARK: - Fitness Age

/// The "Fitness Age" section: a weekly, on-device fitness comparison (NOT a biological age) computed by
/// IntelligenceEngine from the Nes/HUNT model and read back from the "fitness_age" metricSeries under the strap source.
/// Depends only on `repo` (the weekly value + the recent dailies that drive the readiness checklist) and `profile`
/// (age/sex/waist), so the ~1 Hz live HR stream never re-renders it.
///
/// Two states, both honest about coverage:
///   • a value exists → the Fitness Age as a hero, a younger/older-than-your-age sentence and the ± band, tappable
///     through to the detail, with an "ⓘ How accurate is this?" affordance that reveals the readiness checklist.
///   • no value yet → the checklist directly, with required-missing inputs offering Settings.
///
/// The checklist groups inputs by ROLE exactly as the engine reports them: "Drives your Fitness Age"
/// (age/sex/resting-HR/activity) vs "Unlocks your VO₂max" (height+weight/waist) — never implying the body
/// measurements sharpen the age (the body term cancels in the model).
struct FitnessAgeSection: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore

    /// Latest weekly Fitness Age (years) read from the "fitness_age" metricSeries, nil until loaded/computed.
    @State private var fitnessAge: Double?
    /// Latest estimated VO₂max (ml/kg/min) from "vo2max_est" — only present once a waist is set.
    @State private var vo2max: Double?
    @State private var loaded = false

    /// Reveal the readiness checklist (the "ⓘ How accurate is this?" disclosure under a shown value).
    @State private var showReadiness = false

    /// The drill-down this section can present, as an item-driven sheet (two stacked `.sheet` modifiers race on macOS).
    /// `.settings`: Settings (the profile card) so a required-missing input can be filled in place.
    private enum FitnessSheet: String, Identifiable {
        case settings
        var id: String { rawValue }
    }
    @State private var fitnessSheet: FitnessSheet?

    /// The coverage counts the engine's verdict is built from: the last 7 computed/imported days give the resting-HR and
    /// activity counts, the profile gives the rest.
    private var coverage: (rhrDays: Int, activityDays: Int) {
        let last7 = repo.days.suffix(7)
        return (last7.compactMap { $0.restingHr }.count,
                last7.filter { repo.canonicalStrain(for: $0.day) != nil }.count)
    }

    private func readiness(_ coverage: (rhrDays: Int, activityDays: Int)) -> FitnessAgeReadiness {
        FitnessAgeEngine.assessReadiness(
            hasAge: profile.age > 0,
            hasSex: !profile.sex.isEmpty,
            rhrDays: coverage.rhrDays,
            activityDays: coverage.activityDays,
            hasHeightWeight: profile.heightCm > 0 && profile.weightKg > 0,
            hasWaist: profile.waistCm > 0)
    }

    var body: some View {
        content
            .sheet(item: $fitnessSheet) { which in
                NavigationStack {
                    switch which {
                    case .settings:
                        // TODO(lane-merge): openSettings(.personalProfile)
                        SettingsView()
                    }
                }
                // Health is a pushed screen: its sheet must not hand Settings the drill-in role, or the pages Settings
                // pushes would leave the native look they have in the Settings tab.
                .settingsSheetScreenScaffoldEnvironment()
                #if os(macOS)
                .frame(width: 900, height: 820)
                #endif
            }
            .task(id: repo.refreshSeq) { await load() }
    }

    @ViewBuilder private var content: some View {
        let coverage = self.coverage
        if let age = fitnessAge {
            VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
                // Tap the hero to open the Fitness Age detail.
                NavigationLink { FitnessAgeDetailView() } label: { hero(age: age) }
                    .buttonStyle(FlatRowPressStyle())
                disclosure
                if showReadiness {
                    FitnessAgeReadinessList(readiness: readiness(coverage), rhrDays: coverage.rhrDays,
                                            activityDays: coverage.activityDays, lead: nil,
                                            onFix: { fitnessSheet = .settings })
                        .transition(.opacity)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
                SectionEyebrow("Fitness Age", systemImage: "figure.run", tint: HealthTint.fitnessAge)
                if loaded {
                    // No value yet: lead with the checklist so the user sees exactly what's still needed.
                    let verdict = readiness(coverage)
                    FitnessAgeReadinessList(
                        readiness: verdict, rhrDays: coverage.rhrDays, activityDays: coverage.activityDays,
                        lead: verdict.canCompute
                            ? "A few more days and we can show your Fitness Age."
                            : "A few more days of wear, plus the basics below, and we can show your Fitness Age.",
                        onFix: { fitnessSheet = .settings })
                } else {
                    // Brief read of the weekly value; an honest placeholder rather than an empty gap.
                    HealthEmptyNote(symbol: "figure.run", text: "Reading your Fitness Age…")
                }
            }
        }
    }

    /// The shown-value hero: the Fitness Age as a number, the younger/older-than-your-age sentence, the optional VO₂max
    /// and the ± band caption.
    private func hero(age: Double) -> some View {
        let shown = FitnessAgeCopy.shownAge(age)
        let calendarAge = FitnessAgeCopy.calendarAge(profile)
        let delta = FitnessAgeCopy.delta(fitnessAge: age, calendarAge: calendarAge)
        let line = FitnessAgeCopy.deltaLine(delta)
        return VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
            SectionEyebrow(
                "Fitness Age", systemImage: "figure.run", tint: HealthTint.fitnessAge,
                trailing: .text(String(localized: "vs age \(FitnessAgeCopy.shownCalendarAge(calendarAge))")),
                showsChevron: true)
            HeroValue(value: "\(shown)", unit: String(localized: "yrs"))
            Text(verbatim: line)
                .font(StrandFont.subhead)
                .foregroundStyle(FitnessAgeCopy.deltaColor(delta))
                .fixedSize(horizontal: false, vertical: true)
            if let vo2 = vo2max {
                MetricValueRow(systemImage: "lungs.fill", label: String(localized: "VO₂max"),
                               value: DrillInFormat.number(vo2), unit: String(localized: "ml/kg/min"),
                               tint: HealthTint.fitnessAge)
            }
            Text(verbatim: FitnessAgeCopy.bandCaption)
                .font(StrandFont.micro)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Fitness Age \(shown), \(line). Tap for details.")
    }

    /// The honest disclosure: what we have / what we still need, grouped by what it unlocks.
    private var disclosure: some View {
        Button {
            withAnimation(StrandMotion.interactive) { showReadiness.toggle() }
        } label: {
            HStack(spacing: NoopMetrics.space2) {
                Image(systemName: "info.circle")
                    .font(StrandFont.caption)
                    .foregroundStyle(HealthTint.fitnessAge.accent)
                    .accessibilityHidden(true)
                Text("How accurate is this?")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: NoopMetrics.space2)
                Image(systemName: showReadiness ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(FlatRowPressStyle())
        // Whole-string key per variant (never a stitched Hide/Show fragment).
        .accessibilityLabel(showReadiness
            ? "How accurate is this? Hide the data behind your Fitness Age"
            : "How accurate is this? Show the data behind your Fitness Age")
    }

    /// Load the latest weekly Fitness Age (+ optional VO₂max) from the strap's metricSeries. Uses the same
    /// `exploreSeries(key:source:)` path every other metric on this screen reads, with source "my-whoop" (the Repository
    /// merges the computed "-noop" rows under any real import). Takes the freshest point — the weekly value is keyed to
    /// the week's Saturday and refines through the week.
    private func load() async {
        let loadSeq = repo.refreshSeq
        async let vo2Load = repo.exploreSeries(key: "vo2max_est", source: "my-whoop")
        let faPts = await repo.exploreSeries(key: "fitness_age", source: "my-whoop")
        guard !Task.isCancelled, loadSeq == repo.refreshSeq else { return }
        fitnessAge = faPts.last?.value
        loaded = true

        let nextVO2 = await vo2Load.last?.value
        guard !Task.isCancelled, loadSeq == repo.refreshSeq else { return }
        vo2max = nextVO2
    }
}

// MARK: - Vitality / Body Age

/// The "Vitality" section: a weekly wellness score (0–100) + a Body Age in years, computed by IntelligenceEngine from the
/// published mortality-hazard model and read back from the metricSeries. A wellness trend from your habits — NOT a
/// clinical biological age. Recomputes the live best/worst factor the same way the engine does, for the plain-English
/// "why".
struct VitalitySection: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore
    @State private var vitality: Double?
    @State private var bodyAge: Double?
    @State private var loaded = false

    private var contributions: [VitalityEngine.Contribution] {
        let last7 = repo.days.suffix(7)
        let nights = last7.compactMap { $0.totalSleepMin }.map { Double($0) / 60.0 }.filter { $0 > 0 }
        let hrvs = last7.compactMap { $0.avgHrv }
        let rhrs = last7.compactMap { $0.restingHr }.map(Double.init)
        let steps = last7.compactMap { $0.steps }.map(Double.init)
        func mean(_ a: [Double]) -> Double? { a.isEmpty ? nil : a.reduce(0, +) / Double(a.count) }
        // Aggregate EXACTLY as the stored headline does (IntelligenceEngine), so this "what's driving it" breakdown
        // reconciles with the Vitality / Body Age number it explains rather than being recomputed on different
        // statistics: resting HR + HRV are MEDIANED (robust to one outlier night), sleep + steps are MEANED. Using the
        // mean for all four let a single bad RHR/HRV reading drift the breakdown out of step with the median-based
        // headline (code review).
        return VitalityEngine.contributions(.init(
            chronoAge: Double(profile.age),
            restingHR: rhrs.isEmpty ? nil : IntelligenceEngine.medianOf(rhrs),
            sleepHours: mean(nights),
            sleepConsistency: VitalityEngine.sleepConsistency(nightlyHours: nights),
            rmssd: hrvs.isEmpty ? nil : IntelligenceEngine.medianOf(hrvs),
            rmssdNorm: VitalityEngine.rmssdNorm(forAge: Double(profile.age)),
            steps: mean(steps)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
            SectionEyebrow("Vitality", systemImage: "sparkles", tint: HealthTint.vitality,
                           trailing: .text(String(localized: "Weekly")))
            if let v = vitality, let ba = bodyAge {
                hero(vitality: v, bodyAge: ba)
            } else if loaded {
                HealthEmptyNote(symbol: "sparkles", text: "A few more days and we can show your Vitality.")
            } else {
                HealthEmptyNote(symbol: "sparkles", text: "Reading your Vitality…")
            }
        }
        .task(id: repo.refreshSeq) { await load() }
    }

    private func hero(vitality v: Double, bodyAge ba: Double) -> some View {
        let delta = Double(profile.age) - ba
        let younger = delta >= 0
        let yrs = Int(abs(delta).rounded())
        let sorted = contributions.sorted { $0.lnHazard < $1.lnHazard }
        let best = sorted.first
        let worst = sorted.last
        return VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
            HeroValue(value: "\(Int(v.rounded()))", unit: "/ 100")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Vitality \(Int(v.rounded())) out of 100")
            FactStrip(facts: [
                .init("Body Age", value: "\(Int(ba.rounded())) \(String(localized: "yrs"))"),
                .init("vs your age", value: bodyAgeDeltaLine(yrs: yrs, younger: younger)),
            ])
            if let best, best.lnHazard < 0 {
                factorLine(symbol: "arrow.up.right.circle.fill", color: StrandPalette.statusPositive,
                           text: String(localized: "Helping most: \(Self.factorLabel(best))"))
            }
            if let worst, worst.lnHazard > 0 {
                factorLine(symbol: "arrow.down.right.circle.fill", color: StrandPalette.statusWarning,
                           text: String(localized: "Holding you back: \(Self.factorLabel(worst))"))
            }
            Text("A wellness estimate from your habits, not a clinical biological age.")
                .font(StrandFont.micro)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func factorLine(symbol: String, color: Color, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
            Image(systemName: symbol)
                .font(StrandFont.caption)
                .foregroundStyle(color)
                .frame(width: WidgetMetrics.metricIconWidth)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// The engine's factor names are English; the screen says them in the person's language, keyed by the factor.
    static func factorLabel(_ contribution: VitalityEngine.Contribution) -> String {
        switch contribution.key {
        case "rhr": String(localized: "Resting heart rate")
        case "vo2max": String(localized: "Cardio fitness")
        case "sleep": String(localized: "Sleep duration")
        case "consistency": String(localized: "Sleep regularity")
        case "hrv": String(localized: "Heart-rate variability")
        case "steps": String(localized: "Daily steps")
        default: contribution.label
        }
    }

    /// The Body Age delta as whole-phrase variants per count and direction, so translators see complete phrases (never a
    /// stitched plural or direction fragment).
    private func bodyAgeDeltaLine(yrs: Int, younger: Bool) -> String {
        if yrs == 0 { return String(localized: "about your age") }
        switch (younger, yrs == 1) {
        case (true, true): return String(localized: "1 yr younger")
        case (true, false): return String(localized: "\(yrs) yrs younger")
        case (false, true): return String(localized: "1 yr older")
        case (false, false): return String(localized: "\(yrs) yrs older")
        }
    }

    private func load() async {
        let loadSeq = repo.refreshSeq
        async let vitalityLoad = repo.exploreSeries(key: "vitality", source: "my-whoop")
        async let bodyAgeLoad = repo.exploreSeries(key: "body_age", source: "my-whoop")
        let nextVitality = await vitalityLoad.last?.value
        let nextBodyAge = await bodyAgeLoad.last?.value
        guard !Task.isCancelled, loadSeq == repo.refreshSeq else { return }
        vitality = nextVitality
        bodyAge = nextBodyAge
        loaded = true
    }
}
