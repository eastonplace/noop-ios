import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

// MARK: - Coupled view (task #43), the optional classic coupled day read
//
// An optional, default-OFF day view that reads like the classic coupled home: one screen, three numbers,
// Recovery % / Day Strain on 0–21 / Sleep, for users who came across from another band and want the old
// glance back. NOOP's Today stays the default and is untouched.
//
// DISPLAY-ONLY, like the #268 Strain-scale toggle. This screen invents no score and stores nothing: it
// reads the SAME values Today already computes (recovery / Sleep composite / Strain strain / readiness) and
// re-presents them in the coupled layout. The only new mapping is the OPTIMAL strain band, a pure
// display-only read of today's recovery to a suggested strain range (never fed back into scoring).
//
// It renders in the LIQUID design language — the three scores are liquid vessels (recovery / strain on the
// 0–21 axis / sleep performance), the optimal-strain band is a liquid tube, the cards are the frosted liquid
// surface with UPPERCASE section overlines, and the day-of-sky backdrop carries behind — all routed through
// StrandPalette so the Classic / Titanium appearance toggle carries automatically. The word "WHOOP" appears
// in NO shipped UI string here (legal posture); the screen is called "Coupled view".
//
// Tap-throughs, matching the sibling screens' deep-link/back behaviour: the hero ring opens the Charge
// breakdown ("What shaped it", the same shared ChargeBreakdownSection content the Today ring opens, hosted
// here because TodayView's own sheet is view-private); the sleep row pushes the Sleep screen.

struct CoupledView: View {
    @EnvironmentObject var repo: Repository

    /// The Charge breakdown sheet, the hero ring's tap target. Its body builds LAZILY on presentation
    /// (the #819 pattern), reading drivers derived from the same displayed row the ring shows.
    @State private var showChargeBreakdown = false

    /// The day the coupled read describes, today's resolved row (the same `resolveToday` #304/#144 boundary
    /// Today anchors on), never a second store read.
    private var day: DailyMetric? { repo.today }

    /// Today's day key, tracking the resolved row when one exists (the Today idiom).
    private var todayKey: String { day?.day ?? Repository.logicalDayKey(Date()) }

    /// Recovery cold-start: nights banked so far while the HRV baseline still seeds, nil once recovery
    /// exists. The SAME pure helper Today's ring reads, so the two screens can't disagree.
    private var calibrationNights: Int? {
        RecoveryScorer.calibrationNights(nightlyHrv: repo.days.map(\.avgHrv),
                                         dayKeys: repo.days.map(\.day),
                                         hasRecovery: day?.recovery != nil)
    }

    /// The last strictly-prior scored recovery day, so a just-rolled-over morning carries yesterday's read
    /// rather than blanking, exactly the anchor Today uses for readiness (#543).
    private var carriedRecoveryDay: DailyMetric? {
        repo.days.last(where: { $0.recovery != nil && $0.day < todayKey })
    }

    /// The recovery value the ring shows: today's if scored, else the carried prior day's (never fabricated).
    private var recovery: Double? { day?.recovery ?? carriedRecoveryDay?.recovery }

    /// True when the hero is showing the CARRIED prior score rather than today's own, which drives the
    /// dimmed ring + the "Last night · <date>" stamp so an old number is never passed off as new (#543/#779).
    private var isCarryingRecovery: Bool { day?.recovery == nil && carriedRecoveryDay?.recovery != nil }

    /// Strain strain on NOOP's 0–100 axis for the day (stored row; no live recompute here, this is a
    /// glance screen, not the primary Today hero). nil when the day has no scored Strain.
    private var strain100: Double? {
        day.flatMap { repo.canonicalStrain(for: $0.day)?.storedValue }
    }

    /// Day strain mapped onto the 0–21 coupled axis through the single display-boundary converter.
    private var dayStrain21: Double? {
        strain100.map { StrainScale.displayValue(fromStored: $0) }
    }

    /// Sleep performance % for the day, the SAME single source of truth the Today Sleep score and the Sleep
    /// detail graph read: the imported figure when the export carried one, else the resolved Sleep composite.
    /// Never a local hours-vs-need approximation (keeps the coupled read in agreement with Today's Sleep).
    private var sleepPerformance: Double? {
        guard let d = day else { return nil }
        if let p = repo.importedSleep[d.day]?.performancePct { return p }
        return AnalyticsEngine.Rest.composite(daily: d)
    }

    /// On-device readiness, computed EXACTLY as Today does (ReadinessEngine.evaluate over the same rows,
    /// anchored on the last scored day ONLY when carrying), so the one-word pill matches the home screen's
    /// read. The carried anchor is gated on `isCarryingRecovery` (Today's `!todayScored` gate): on a normal
    /// scored day today's own key wins, so Coupled's pill can't diverge from Today's onto yesterday (#787).
    private var readinessLevel: ReadinessEngine.Level {
        let anchor = (isCarryingRecovery ? carriedRecoveryDay?.day : day?.day) ?? Repository.logicalDayKey(Date())
        return ReadinessEngine.evaluate(days: repo.days, today: anchor).level
    }

    var body: some View {
        // CoupledView is pushed from Today's card row. On iOS each tab supplies a NavigationStack, so the
        // sleep-row + breakdown pushes land in the ambient stack. On macOS this can render as a detail pane
        // with NO enclosing NavigationStack, so — exactly like MetricExplorerView / TrendsView (#753) —
        // wrap the scaffold in one here so the pushes get Back chrome instead of hanging. Same shared
        // scaffold renders on both.
        #if os(macOS)
        NavigationStack { scaffold }
        #else
        scaffold
        #endif
    }

    private var scaffold: some View {
        ScreenScaffold(title: "Day", subtitle: subtitleText,
                       // The day-of-sky liquid backdrop, matching Today / Health / Sleep / Trends: a fixed,
                       // full-bleed time-of-day sky behind the scroll content (does not scroll).
                       topBackground: nil) {
            ViewThatFits(in: .horizontal) {
                // Regular width (macOS / iPad): hero left, strain + sleep stacked right in a 2-column grid.
                HStack(alignment: .top, spacing: NoopMetrics.gap) {
                    heroCard
                        .frame(maxWidth: .infinity)
                    VStack(spacing: NoopMetrics.gap) {
                        strainCard
                        sleepCard
                    }
                    .frame(maxWidth: .infinity)
                }
                // Compact (iPhone): the three cards stack full-width.
                VStack(spacing: NoopMetrics.gap) {
                    heroCard
                    strainCard
                    sleepCard
                }
            }
            footerCaption
        }
        .sheet(isPresented: $showChargeBreakdown) { chargeBreakdownSheet }
    }

    // MARK: Header subtitle, "Today, d MMM"

    private var subtitleText: LocalizedStringKey {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("d MMM")
        return LocalizedStringKey("Today, \(f.string(from: Date()))")
    }

    // MARK: 1. HERO, the recovery vessel, coupled read (tap = the Charge breakdown)

    /// The recovery read as the signature liquid vessel (Today's HeroScoreCell idiom): a Charge-world
    /// vessel filled to the recovery fraction, with the recovery % counting up over it and the RECOVERY
    /// overline + readiness pill layered beneath. The whole hero is a button opening the Charge breakdown,
    /// mirroring Today's Charge-ring tap (A1). The vessel's own tap splashes (number is hit-transparent).
    private var heroCard: some View {
        Button {
            showChargeBreakdown = true
        } label: {
            card {
                VStack(spacing: 14) {
                    SectionHeader("Recovery", overline: "Coupled read")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ZStack {
                        PaperGauge(value: recovery.map { max(0, min(1, $0 / 100)) },
                                     tint: recovery.map { RecoveryBands.color(for: $0) }
                                         ?? StrandPalette.recoveryData,
                                     animated: recovery != nil)
                            // A carried (not-yet-rescored) morning reads dimmed, the Today #802 idiom.
                            .opacity(isCarryingRecovery ? 0.85 : 1)
                            .frame(width: 200, height: 200)
                            // The whole hero opens the Charge breakdown (the original tap contract), so the
                            // vessel doesn't intercept the tap with its own splash — the Button owns it.
                            .allowsHitTesting(false)
                        heroCentre
                            .allowsHitTesting(false)
                    }
                    .frame(width: 200, height: 200)
                    heroCaption
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(PaperPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(heroAccessibilityLabel)
        .accessibilityHint("See what shaped your Recovery")
    }

    /// The centre stack over the vessel: the recovery % counting up in white over the fluid, a RECOVERY
    /// overline in the SAMPLED recovery colour, and the one-word readiness pill (Push / Maintain / Sleep,
    /// #205 read).
    @ViewBuilder
    private var heroCentre: some View {
        let sampled = recovery.map { RecoveryBands.color(for: $0) } ?? StrandPalette.textTertiary
        VStack(spacing: 4) {
            if let r = recovery {
                CountUpText(value: r,
                            format: { "\(Int($0.rounded()))%" },
                            font: StrandFont.number(48),
                            color: .white)
                    .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            } else {
                Text("—")
                    .font(StrandFont.number(48))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
            }
            Text("RECOVERY")
                .font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .foregroundStyle(sampled)
            if let word = TodayView.readinessWord(readinessLevel) {
                readinessPill(word)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 24)
    }

    /// The honest state line under the ring: the "Last night · <date>" stamp when carrying a prior score
    /// (#543/#779, via the SAME pure caption Today uses), or the calibrating progress while the baseline
    /// seeds. Nothing when today's own score is showing.
    @ViewBuilder
    private var heroCaption: some View {
        if isCarryingRecovery, let prior = carriedRecoveryDay {
            Text(TodayView.carriedCaption(priorDayKey: prior.day, todayKey: todayKey))
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        } else if recovery == nil, let banked = calibrationNights {
            Text(ChargeBreakdownFormat.calibrationProgress(banked: banked, seed: Baselines.minNightsSeed))
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private var heroAccessibilityLabel: String {
        if let r = recovery { return String(localized: "Recovery \(Int(r.rounded())) percent") }
        if let banked = calibrationNights {
            return String(localized: "Recovery calibrating, \(banked) of \(Baselines.minNightsSeed) nights")
        }
        return String(localized: "Recovery, no data yet")
    }

    /// The one-word readiness pill (Push / Maintain / Sleep), tinted by the readiness level, matching the
    /// Today hero pill chrome. Reuses TodayView's word + level colour so the read stays consistent.
    private func readinessPill(_ word: String) -> some View {
        let tint = readinessTint(readinessLevel)
        return MicroBadge("\(word)", tint: tint)
            .accessibilityLabel("Readiness: \(word)")
    }

    /// The readiness level's tint, the SAME mapping TodayView.readinessColor uses.
    private func readinessTint(_ l: ReadinessEngine.Level) -> Color {
        switch l {
        case .primed:       return StrandPalette.accent
        case .balanced:     return StrandPalette.statusPositive
        case .strained:     return StrandPalette.statusWarning
        case .rundown:      return StrandPalette.metricRose
        case .insufficient: return StrandPalette.textTertiary
        }
    }

    // MARK: 2. STRAIN ROW, the effort vessel + coupled stat stack

    private var strainCard: some View {
        card {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader("Day Strain", overline: "Strain", trailing: strainBandWord)
                HStack(alignment: .center, spacing: 16) {
                    // Left: the liquid vessel filled to the 0–21 Day-Strain fraction (Strain world), with the
                    // strain value counting up over the fluid — the coupled read on the classic 0–21 axis.
                    ZStack {
                        PaperGauge(value: dayStrain21.map { max(0, min(1, $0 / 21)) },
                                     tint: StrandPalette.effortColor, animated: dayStrain21 != nil)
                            .frame(width: 148, height: 148)
                        Group {
                            if let s = dayStrain21 {
                                CountUpText(value: s,
                                            format: { String(format: "%.1f", $0) },
                                            font: StrandFont.number(34),
                                            color: .white)
                            } else {
                                Text("—").font(StrandFont.number(34)).foregroundStyle(.white)
                            }
                        }
                        .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
                        .lineLimit(1).minimumScaleFactor(0.5)
                        .allowsHitTesting(false)
                    }
                    .frame(width: 148, height: 148)

                    // Right: the coupled stat stack, OPTIMAL range (with a liquid tube band), calories, workouts.
                    VStack(alignment: .leading, spacing: 14) {
                        optimalStat
                        heroStat("Calories",
                                 caloriesText,
                                 tint: StrandPalette.metricAmber)
                        heroStat("Workouts",
                                 (day?.exerciseCount).map { "\($0)" } ?? "0",
                                 tint: StrandPalette.textPrimary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The band word (LIGHT / MODERATE / STRENUOUS / HIGH) the classic StrainGauge drew from the fill
    /// fraction, kept as the section-header trailing so the coupled read still names the effort band.
    private var strainBandWord: String? {
        guard let s = dayStrain21 else { return nil }
        return StrainScale.band(s).title
    }

    /// The OPTIMAL strain band stat, with a liquid tube visualising where the suggested band sits on the
    /// 0–21 axis (Charge world). A calibrating / unscored day shows a dash and an empty tube.
    private var optimalStat: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("OPTIMAL")
                .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textSecondary)
            Text(Self.optimalStrainRangeText(recovery: recovery))
                .font(StrandFont.number(20))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.6)
            PaperProgressBar(frac: optimalUpperFraction, tint: StrandPalette.recoveryData, height: 8, animated: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The optimal band's upper bound as a 0–1 fraction of the 0–21 axis, for the tube fill. 0 (empty) when
    /// recovery is unknown so the tube never fabricates a band.
    private var optimalUpperFraction: Double {
        guard let band = Self.optimalStrainRange(recovery: recovery) else { return 0 }
        return max(0, min(1, Double(band.upperBound) / 21))
    }

    /// Canonical compact value treatment shared with the Workouts hero stack.
    private func heroStat(_ title: String, _ value: String, tint: Color) -> some View {
        ValueToken(LocalizedStringKey(title), value: value, tint: tint)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Active calories for the day from the stored whole-day estimate. Never fabricated, a day with no
    /// estimate reads a dash.
    private var caloriesText: String {
        guard let k = day?.activeKcalEst else { return "—" }
        return "\(Int(k.rounded())) kcal"
    }

    // MARK: 3. SLEEP ROW, the sleep-performance ring + hours-vs-need read (tap = Sleep)

    private var sleepCard: some View {
        NavigationLink {
            SleepView()
        } label: {
            card {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader("Sleep performance", overline: "Last night", trailing: String(localized: "Sleep"))
                    HStack(alignment: .center, spacing: 16) {
                        // Left: the SLEEP PERFORMANCE % as the liquid vessel (Sleep world), with the score
                        // counting up over the fluid. Empty vessel when there's no scored performance.
                        ZStack {
                            PaperGauge(value: sleepPerformance.map { max(0, min(1, $0 / 100)) },
                                         tint: StrandPalette.restColor, animated: false)
                                .frame(width: 88, height: 88)
                            if let p = sleepPerformance {
                                CountUpText(value: p,
                                            format: { "\(Int($0.rounded()))" },
                                            font: StrandFont.number(24),
                                            color: .white)
                                    .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
                                    .allowsHitTesting(false)
                            }
                        }
                        .frame(width: 88, height: 88)

                        // Right: the slept-vs-needed two-line read + last night's bed–wake span footnote.
                        VStack(alignment: .leading, spacing: 4) {
                            if let asleep = day?.totalSleepMin, asleep > 0 {
                                Text("\(Self.hoursMinutes(asleep)) slept")
                                    .font(StrandFont.headline)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Text("\(Self.hoursMinutes(sleepNeedForDay)) needed")
                                    .font(StrandFont.subhead)
                                    .foregroundStyle(StrandPalette.textSecondary)
                            } else {
                                Text("No sleep tracked last night")
                                    .font(StrandFont.subhead)
                                    .foregroundStyle(StrandPalette.textSecondary)
                            }
                            if let span = bedWakeSpanText {
                                Text(span)
                                    .font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(PaperPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(sleepAccessibilityLabel)
        .accessibilityHint("Open Sleep")
    }

    private var sleepAccessibilityLabel: String {
        guard let p = sleepPerformance else { return String(localized: "Sleep performance not available") }
        if let asleep = day?.totalSleepMin, asleep > 0 {
            return String(localized: "Sleep performance \(Int(p.rounded())) percent. \(Self.hoursMinutes(asleep)) slept, \(Self.hoursMinutes(sleepNeedForDay)) needed")
        }
        return String(localized: "Sleep performance \(Int(p.rounded())) percent")
    }

    /// The night's need (minutes) for the slept-vs-needed read: the imported per-day figure when the
    /// export carried one, else the shared ≥ 7.5h personal-mean floor (matches SleepView.sleepNeedMin).
    private var sleepNeedForDay: Double {
        if let need = day.flatMap({ repo.importedSleep[$0.day]?.needMin }), need > 0 { return need }
        return sleepNeedMin
    }

    /// The personal sleep need (minutes): the recent-mean total sleep, never below a 7.5h floor. Byte-for-byte
    /// the same rule as SleepView.sleepNeedMin so the two screens agree.
    private var sleepNeedMin: Double {
        let banked = repo.days.compactMap { $0.totalSleepMin }.filter { $0 > 0 }
        let mean = banked.isEmpty ? nil : banked.reduce(0, +) / Double(banked.count)
        return Swift.max(450, mean ?? 450)   // 450 min = 7.5h
    }

    /// Last night's bed → wake span, e.g. "23:41 – 07:23", from the freshest banked sleep session, only
    /// when that session actually touches today's window (a days-old import is not "last night").
    private var bedWakeSpanText: String? {
        let dayStart = Calendar.current.startOfDay(for: Repository.logicalDay(Date()))
        let windowStart = Int(dayStart.timeIntervalSince1970)
        guard let s = repo.sleeps.filter({ $0.endTs > windowStart }).max(by: { $0.endTs < $1.endTs }) else {
            return nil
        }
        return "\(clockString(s.effectiveStartTs)) - \(clockString(s.endTs))"
    }

    // MARK: Footer

    // The brief quotes the footer with the brand word, but the hard legal / anonymity rule ("the word
    // never appears in a shipped UI string") wins over the illustrative copy: this keeps the exact intent
    // (a coupled read of NOOP's OWN scores, same data, different lens) without the branding word. The
    // matching Android caption is byte-identical.
    private var footerCaption: some View {
        Text("A classic one-glance read of NOOP's own scores. Same data, different lens.")
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
    }

    // MARK: Charge breakdown sheet (the hero tap target)
    //
    // The same "What shaped it" content the Today Charge ring opens: the shared ChargeBreakdownSection over
    // drivers DERIVED from the displayed row (never a second store scan), the honest calibrating countdown
    // while the baseline seeds, and the "How Recovery is calculated" method link. TodayView's own sheet is
    // view-private, so this hosts the SAME shared components with the same derivations, no engine work.

    /// The row the breakdown reads, mirroring the hero: today's own when scored, else the carried
    /// last-scored day, so the sheet always matches the ring above it.
    private var breakdownRow: DailyMetric? {
        if let t = day, t.recovery != nil { return t }
        return carriedRecoveryDay
    }

    /// The ordered Charge drivers for the displayed ring, the exact TodayView derivation (pure engine
    /// scoring against the folded personal baselines). Empty for a calibrating / cold-start night, which
    /// gates the sheet through to the countdown instead.
    private var chargeDrivers: [ChargeDriver] {
        guard let row = breakdownRow, let hrv = row.avgHrv, let rhr = row.restingHr else { return [] }
        let hrvBase = Baselines.foldHistory(repo.days.map(\.avgHrv), cfg: Baselines.hrvCfg)
        guard hrvBase.usable else { return [] }
        let rhrBase = Baselines.foldHistory(repo.days.map { $0.restingHr.map(Double.init) },
                                            cfg: Baselines.restingHRCfg)
        let respBase = Baselines.foldHistory(repo.days.map(\.respRateBpm), cfg: Baselines.respCfg)
        // Sleep-quality term = the same sleep performance the sleep row shows, ÷100 (AnalyticsEngine's form).
        let sleepPerf = sleepPerformance.map { $0 / 100.0 }
        return RecoveryScorer.chargeDrivers(
            hrv: hrv, rhr: Double(rhr), resp: row.respRateBpm,
            hrvBaseline: hrvBase,
            rhrBaseline: rhrBase.usable ? rhrBase : nil,
            respBaseline: respBase.usable ? respBase : nil,
            sleepPerf: sleepPerf, skinTempDev: row.skinTempDevC)
    }

    @ViewBuilder
    private var chargeBreakdownSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    let drivers = chargeDrivers
                    if drivers.isEmpty {
                        if let banked = calibrationNights {
                            calibrationCard(banked: banked)
                        } else {
                            NoopCard(padding: 18, tint: StrandPalette.recoveryData) {
                                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                                    Text("No Recovery breakdown yet")
                                        .font(StrandFont.headline)
                                        .foregroundStyle(StrandPalette.textPrimary)
                                    Text("Wear the strap overnight to score a night first.")
                                        .font(StrandFont.subhead)
                                        .foregroundStyle(StrandPalette.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    } else {
                        let hrvBase = Baselines.foldHistory(repo.days.map(\.avgHrv), cfg: Baselines.hrvCfg)
                        NoopCard(padding: 18, tint: StrandPalette.recoveryData) {
                            ChargeBreakdownSection(
                                drivers: drivers,
                                confidence: ScoreConfidence.charge(recovery: breakdownRow?.recovery,
                                                                   hrvBaseline: hrvBase),
                                skinTempRel: RecoveryScorer.skinTempRelative(deviationC: breakdownRow?.skinTempDevC))
                        }
                    }

                    // The general METHOD behind the score, clearly separated from today's values, exactly
                    // the link the Today breakdown carries. Pushes within this sheet's own NavigationStack.
                    NavigationLink {
                        ScoringGuideView(initialSection: .recovery, onClose: { showChargeBreakdown = false })
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "function")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(StrandPalette.recoveryData)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("How Recovery is calculated")
                                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                                Text("The method behind the score, not today's values.")
                                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 14).fill(StrandPalette.surfaceInset))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("How Recovery is calculated. The method behind the score.")
                }
                .padding(NoopMetrics.screenPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle("What shaped your Recovery")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showChargeBreakdown = false }
                        .foregroundStyle(StrandPalette.accent)
                }
                #else
                ToolbarItem {
                    Button("Done") { showChargeBreakdown = false }
                        .foregroundStyle(StrandPalette.accent)
                }
                #endif
            }
        }
    }

    /// The calibrating countdown card, the same pure `ChargeBreakdownFormat` copy the Today sheet shows,
    /// so the two breakdowns read identically while the baseline seeds.
    private func calibrationCard(banked: Int) -> some View {
        let remaining = max(1, Baselines.minNightsSeed - banked)
        let countdown = ChargeBreakdownFormat.calibrationCountdown(nightsRemaining: remaining)
        let unlock = ChargeBreakdownFormat.calibrationUnlockCopy(scoreName: String(localized: "Recovery"))
        let progress = ChargeBreakdownFormat.calibrationProgress(banked: banked, seed: Baselines.minNightsSeed)
        return NoopCard(padding: 14, tint: StrandPalette.recoveryData) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(StrandPalette.recoveryData)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(countdown)
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer(minLength: 0)
                        ScoreStatePill(
                            ChargeBreakdownFormat.tierState(.calibrating),
                            text: "\(ChargeBreakdownFormat.tierTag(.calibrating))"
                        )
                        .accessibilityLabel(ChargeBreakdownFormat.confidenceAccessibilityLabel(.calibrating))
                    }
                    Text(unlock)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(progress)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recovery baseline calibrating. \(countdown), \(unlock). \(progress).")
    }

    // MARK: Shared helpers

    /// The frosted liquid card surface, byte-for-byte the Paper Today.card style (rounded 22 + a
    /// resting hairline over surfaceRaised), so the coupled glance cards read identically to Today and the
    /// batch-1 liquid screens.
    private func card<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(StrandPalette.surfaceRaised)
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(StrandPalette.hairline, lineWidth: 1))
            )
    }

    private func clockString(_ ts: Int) -> String {
        Self.clockFmt.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    private static let clockFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()

    /// "6h 42m" from a minutes count, for the slept-vs-needed read. Mirror EXACTLY in Kotlin.
    static func hoursMinutes(_ minutes: Double) -> String {
        let total = Swift.max(0, Int(minutes.rounded()))
        return "\(total / 60)h \(total % 60)m"
    }

    // MARK: - OPTIMAL strain range (task #43), pure display-only recovery→strain mapping
    //
    // The classic coupled read suggests a Day-Strain target BAND from today's recovery: a green day earns a
    // higher optimal band, a red day a lower one. This is PRESENTATION ONLY, it is never fed back into any
    // score or engine; it just tells the user where a "matched" strain would sit on the 0–21 axis. The bands
    // are the APPROVED mapping and MUST stay byte-identical to the Android `optimalStrainRange`:
    //
    //   recovery ≥ 67 (green)       → 14–18 of 21
    //   34 ≤ recovery ≤ 66 (yellow) → 10–14
    //   recovery < 34 (red)         → 4–10
    //
    // nil recovery (calibrating / unscored day) → nil, the caller renders a dash, never a guessed band.

    /// The pure recovery→optimal-strain band. Returns nil when recovery is unknown. Bands per the doc above.
    static func optimalStrainRange(recovery: Double?) -> ClosedRange<Int>? {
        guard let r = recovery else { return nil }
        switch r {
        case 67...:   return 14...18
        case 34..<67: return 10...14
        default:      return 4...10
        }
    }

    /// The optimal band as display text ("14 to 18" / "—"). Byte-identical formatting to Android.
    static func optimalStrainRangeText(recovery: Double?) -> String {
        guard let band = optimalStrainRange(recovery: recovery) else { return "—" }
        return String(localized: "\(band.lowerBound) to \(band.upperBound)")
    }
}

// MARK: - Paper pillar details (S20/S21)

enum PaperPillarDetailKind: String, Identifiable {
    case charge, effort, rest, stress
    var id: String { rawValue }
}

/// Shared Paper detail skeleton for the two daytime pillars. It only aggregates already-resolved
/// daily/workout rows for display; scoring, storage, and workout routing remain unchanged.
struct PaperPillarDetailView: View {
    let kind: PaperPillarDetailKind
    let anchorDayKey: String

    @EnvironmentObject private var repo: Repository
    @StateObject private var profile = ProfileStore()
    @State private var workouts: [WorkoutRow] = []
    @State private var appleDays: [AppleDaily] = []
    @State private var computedZoneMinutes: [Double]?
    @State private var storedStress: [(day: String, value: Double)] = []
    @State private var daytimeStress: DaytimeStress.Result?
    @State private var latestSleepStart: Date?

    private var accent: Color {
        switch kind {
        case .charge: return latest.map { RecoveryBands.color(for: $0) } ?? StrandPalette.recoveryData
        case .effort: return StrandPalette.effortAccent
        case .rest: return StrandPalette.restAccent
        case .stress: return StrandPalette.stressAccent
        }
    }

    private var rows: [(day: String, value: Double)] {
        switch kind {
        case .charge:
            return repo.days.compactMap { day in day.recovery.map { (day.day, $0) } }
        case .effort:
            return repo.days.compactMap { day in
                guard let stored = repo.canonicalStrain(for: day.day)?.storedValue else { return nil }
                return (day.day, StrainScale.displayValue(fromStored: stored))
            }
        case .rest:
            return repo.days.compactMap { day in
                let value = repo.importedSleep[day.day]?.performancePct
                    ?? AnalyticsEngine.Rest.composite(daily: day)
                return value.map { (day.day, $0) }
            }
        case .stress:
            return stressModel?.fullTrend.map {
                (Self.dayFormatter.string(from: $0.date), $0.value)
            } ?? []
        }
    }

    private var calendar: Calendar { Calendar.current }
    private var anchorDate: Date {
        Self.dayFormatter.date(from: anchorDayKey) ?? calendar.startOfDay(for: Date())
    }
    private var metricDays: [CalendarMetricDay] {
        rows.compactMap { row in
            Self.dayFormatter.date(from: row.day).map { CalendarMetricDay(date: $0, value: row.value) }
        }
    }
    private var latest: Double? { TrendCalendar.value(on: anchorDate, in: metricDays, calendar: calendar) }
    private var yesterday: Double? {
        guard let date = calendar.date(byAdding: .day, value: -1, to: anchorDate) else { return nil }
        return TrendCalendar.value(on: date, in: metricDays, calendar: calendar)
    }
    private var sevenDayWindow: [CalendarMetricDay] {
        TrendCalendar.buildRollingWindow(observations: metricDays, through: anchorDate, count: 7,
                                         calendar: calendar)
    }
    private var baselineWindow: [CalendarMetricDay] {
        guard let dayBefore = calendar.date(byAdding: .day, value: -1, to: anchorDate) else { return [] }
        return TrendCalendar.buildRollingWindow(observations: metricDays, through: dayBefore, count: 28,
                                                calendar: calendar)
    }
    private var baseline: Double? { TrendCalendar.mean(of: baselineWindow) }
    private var sevenDayAverage: Double? { TrendCalendar.mean(of: sevenDayWindow) }
    private var latestDay: DailyMetric? { repo.days.last(where: { $0.day == anchorDayKey }) }
    private var stressModel: StressModel? { StressModel(days: repo.days, stored: storedStress) }

    var body: some View {
        NavigationStack {
            ScreenScaffold(
                title: LocalizedStringKey(detailTitle),
                subtitle: LocalizedStringKey(detailDateLabel),
                topBackground: nil,
                trailing: {
                    HStack(spacing: 14) {
                        Image(systemName: "square.and.arrow.up")
                        Image(systemName: "ellipsis")
                    }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(StrandPalette.textPrimary)
                }
            ) {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                    if kind == .charge {
                        recoveryLibraryOverview
                        chargeFactorsCard
                        recommendationCard
                    } else if kind == .effort {
                        strainLibraryOverview
                        effortContributorsCard
                        heartRateZonesCard
                    } else if kind == .rest {
                        heroCard
                        restStagesCard
                        restTimingCard
                        restInsightCard
                    } else {
                        heroCard
                        overTimeCard
                        stressBreakdownCard
                        stressRecommendationCard
                    }
                }
            }
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
        }
        .task(id: repo.refreshSeq) {
            async let workoutRows = repo.workoutRows()
            async let appleRows = repo.appleDailyRows()
            async let stressRows = repo.series(key: "stress", source: "my-whoop")
            async let sleepRows = repo.allSleepSessions(days: 14)
            workouts = await workoutRows
            appleDays = await appleRows
            storedStress = await stressRows
            let sleeps = await sleepRows
            latestSleepStart = sleeps.last.map {
                Date(timeIntervalSince1970: TimeInterval($0.effectiveStartTs))
            }
            await loadDaytimeStress()
            await loadComputedWorkoutZones()
        }
    }

    private var heroCard: some View {
        PaperCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 20) {
                    if let latest {
                        ScoreRing(value: latest, range: detailRange, accent: accent, size: 96,
                                  format: { kind == .stress || kind == .effort
                                      ? String(format: "%.1f", $0)
                                      : "\(Int($0.rounded()))"
                                  },
                                  centerCaption: nil)
                    } else {
                        ZStack {
                            Circle().stroke(StrandPalette.inset, lineWidth: 7)
                            Text("—").font(StrandFont.ringScoreLarge)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        .frame(width: 96, height: 96)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(heroTitle)
                            .font(StrandFont.cardTitle)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(heroCaption)
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                Divider().overlay(StrandPalette.hairline)
                heroStats
            }
        }
    }

    /// The library recovery composition backed only by the canonical daily rows.
    /// The existing factor/action sections remain below it so no unique production
    /// metric (especially respiratory rate) disappears during the visual adoption.
    private var recoveryLibraryOverview: some View {
        let history = TrendCalendar.buildRollingWindow(
            observations: metricDays, through: anchorDate, count: 14, calendar: calendar
        )
        let previous30 = baselineWindow.compactMap(\.value)
        let current = latest
        let percentile: Double = {
            guard let current, !previous30.isEmpty else { return 0 }
            return Double(previous30.filter { $0 < current }.count) / Double(previous30.count)
        }()
        return VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
            RecoveryArcCard(
                score: current,
                yesterday: yesterday,
                baseline: scoreText(baseline),
                yesterdayLabel: scoreText(yesterday),
                sevenDay: scoreText(sevenDayAverage)
            )
            if !previous30.isEmpty {
                RecoveryStandingRow(
                    percentile: percentile,
                    highDays: previous30.filter { $0 >= RecoveryScorer.bandYellowMax }.count,
                    mediumDays: previous30.filter {
                        $0 >= RecoveryScorer.bandRedMax && $0 < RecoveryScorer.bandYellowMax
                    }.count,
                    lowDays: previous30.filter { $0 < RecoveryScorer.bandRedMax }.count
                )
            }
            RecoveryDriverSplit(weights: [
                RecoveryDriverWeight(id: "hrv", label: "HRV", weight: RecoveryScorer.wHRV,
                                     color: StrandPalette.metricPurple),
                RecoveryDriverWeight(id: "rhr", label: "RHR", weight: RecoveryScorer.wRHR,
                                     color: StrandPalette.liveRed),
                RecoveryDriverWeight(id: "sleep", label: "Sleep", weight: RecoveryScorer.wSleep,
                                     color: StrandPalette.sleepAccent),
                RecoveryDriverWeight(id: "resp", label: "Resp", weight: RecoveryScorer.wResp,
                                     color: StrandPalette.accent),
                RecoveryDriverWeight(id: "temp", label: "Temp", weight: RecoveryScorer.wSkinTemp,
                                     color: StrandPalette.metricAmber),
            ])
            RecoveryHistoryStrip(days: history, anchorDate: anchorDate, calendar: calendar)
        }
    }

    /// Library strain gauge/history plus real workout rows. We intentionally omit
    /// the specimen's active/passive split and synthetic buildup curve because the
    /// repository does not store an authoritative passive-strain decomposition.
    private var strainLibraryOverview: some View {
        let displayed = latest ?? 0
        let targetInts = CoupledView.optimalStrainRange(recovery: latestDay?.recovery) ?? 0...21
        let target = Double(targetInts.lowerBound)...Double(targetInts.upperBound)
        let history = TrendCalendar.buildWeekWindow(
            observations: metricDays, containing: anchorDate, calendar: calendar
        )
        let scoredWorkouts = detailWorkouts.compactMap { workout -> (WorkoutRow, Double)? in
            guard let stored = StrainResolver.canonicalWorkout(workout)?.storedValue else { return nil }
            return (workout, StrainScale.displayValue(fromStored: stored))
        }
        return VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
            StrainGaugeCard(
                strain: displayed,
                target: target,
                sevenDayAverage: sevenDayAverage ?? displayed
            )
            StrainWeekStrip(days: history, target: target, anchorDate: anchorDate,
                            referenceDate: calendar.startOfDay(for: Date()), calendar: calendar)
            if !scoredWorkouts.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("ACTIVITIES").strandOverline()
                    ForEach(Array(scoredWorkouts.enumerated()), id: \.offset) { _, entry in
                        let workout = entry.0
                        let workoutStrain = entry.1
                        StrainActivityRow(
                            symbol: sportSymbol(workout.sport),
                            title: WorkoutSource.displaySport(workout.sport),
                            subtitle: durationText(workout.durationS ?? Double(workout.endTs - workout.startTs)),
                            context: workoutContext(workout),
                            strain: workoutStrain,
                            share: displayed > 0 ? min(max(workoutStrain / displayed, 0), 1) : 0
                        )
                    }
                }
            }
        }
    }

    private func workoutContext(_ workout: WorkoutRow) -> String {
        var parts: [String] = []
        if let average = workout.avgHr { parts.append("avg \(average) bpm") }
        if let peak = workout.maxHr { parts.append("max \(peak) bpm") }
        if let calories = workout.energyKcal, calories > 0 {
            parts.append("\(Int(calories.rounded())) cal")
        }
        return parts.isEmpty ? "Recorded workout" : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var heroStats: some View {
        if kind == .rest {
            StatTriplet([
                StatTripletItem("Duration", value: sleepDuration(latestDay?.totalSleepMin)),
                StatTripletItem("Efficiency", value: latestDay?.efficiency.map(percentText) ?? "—"),
                StatTripletItem("Resting HR", value: latestDay?.restingHr.map { "\($0) bpm" } ?? "—")
            ])
        } else {
            StatTriplet([
                StatTripletItem("Baseline", value: scoreText(baseline)),
                StatTripletItem("Yesterday", value: scoreText(yesterday)),
                StatTripletItem("7D Avg.", value: scoreText(sevenDayAverage))
            ])
        }
    }

    private var overTimeCard: some View {
        PaperCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(detailTitle.uppercased()) OVER TIME")
                    .font(StrandFont.sectionOverline)
                    .tracking(StrandFont.sectionOverlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                Chart {
                    ForEach(TrendCalendar.buildRollingWindow(
                        observations: metricDays, through: anchorDate, count: 14, calendar: calendar
                    )) { item in
                        if let value = item.value {
                            LineMark(x: .value("Day", item.date), y: .value("Score", value))
                                .foregroundStyle(kind == .charge ? StrandPalette.recoveryData : accent)
                                .lineStyle(StrokeStyle(lineWidth: NoopMetrics.chartLineWidth,
                                                       lineCap: .round, lineJoin: .round))
                            PointMark(x: .value("Day", item.date), y: .value("Score", value))
                                .foregroundStyle(kind == .charge
                                    ? RecoveryBands.color(for: value) : accent)
                                .symbolSize(12)
                        }
                    }
                    if let sevenDayAverage {
                        RuleMark(y: .value("7D Average", sevenDayAverage))
                            .foregroundStyle((kind == .charge ? StrandPalette.recoveryData : accent).opacity(0.55))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 4]))
                    }
                }
                .chartYScale(domain: detailRange)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) {
                        AxisGridLine().foregroundStyle(StrandPalette.hairline)
                        AxisValueLabel(format: .dateTime.weekday(.narrow).day())
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: detailAxisValues) {
                        AxisGridLine().foregroundStyle(StrandPalette.hairline)
                        AxisValueLabel().font(StrandFont.micro)
                    }
                }
                .frame(height: 150)
                HStack(spacing: 16) {
                    legendLine(dashed: false, label: detailTitle)
                    legendLine(dashed: true, label: "7D Avg.")
                }
            }
        }
    }

    private var chargeFactorsCard: some View {
        PaperCard {
            VStack(alignment: .leading, spacing: 0) {
                Text("KEY FACTORS")
                    .font(StrandFont.sectionOverline)
                    .tracking(StrandFont.sectionOverlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .padding(.bottom, 8)
                factorRow(icon: "waveform.path.ecg", name: "HRV",
                          value: latestDay?.avgHrv.map { "\(Int($0.rounded())) ms" } ?? "—",
                          status: hrvFactorBand)
                factorRow(icon: "heart", name: "RHR",
                          value: latestDay?.restingHr.map { "\($0) bpm" } ?? "—",
                          status: restingHRFactorBand)
                factorRow(icon: "moon", name: "Sleep",
                          value: latestDay.flatMap { AnalyticsEngine.Rest.composite(daily: $0) }
                            .map { "\(Int($0.rounded()))%" } ?? "—",
                          status: FactorBands.sleepPerformance(
                            percent: latestDay.flatMap { AnalyticsEngine.Rest.composite(daily: $0) }))
                factorRow(icon: "lungs", name: "Resp. Rate",
                          value: latestDay?.respRateBpm.map { String(format: "%.1f rpm", $0) } ?? "—",
                          status: respiratoryRateFactorBand)
                factorRow(icon: "thermometer.medium", name: "Skin Temp",
                          value: latestDay?.skinTempDevC.map { String(format: "%+.1f °C", $0) } ?? "—",
                          status: FactorBands.skinTemperature(
                            deviationC: latestDay?.skinTempDevC,
                            typicalBandC: RecoveryScorer.skinTempTypicalBandC),
                          divider: false)
            }
        }
    }

    private var recommendationCard: some View {
        NavigationLink {
            ScoringGuideView(initialSection: .recovery)
                #if os(iOS)
                .toolbar(.visible, for: .navigationBar)
                #endif
        } label: {
            PaperCard {
                HStack(spacing: 12) {
                    Image(systemName: "leaf.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(StrandPalette.recoveryData)
                        .frame(width: 38, height: 38)
                        .background(StrandPalette.recoveryData.opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text("RECOVERY RECOMMENDATION")
                            .font(StrandFont.sectionOverline)
                            .tracking(StrandFont.sectionOverlineTracking)
                        Text("Keep prioritizing recovery. Great sleep and low stress will build Recovery.")
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(StrandPalette.textPrimary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var effortContributorsCard: some View {
        let sessions = detailWorkouts
        let averageHR = sessions.compactMap(\.avgHr)
        let calories = sessions.compactMap(\.energyKcal).reduce(0, +)
        let maxHR = sessions.compactMap(\.maxHr).max()
        let duration = sessions.reduce(0.0) { $0 + ($1.durationS ?? Double($1.endTs - $1.startTs)) }
        let daily = detailAppleDay
        let resolvedAverageHR = averageHR.isEmpty ? daily?.avgHr : averageHR.reduce(0, +) / averageHR.count
        let resolvedCalories = calories > 0 ? calories : (daily?.activeKcal ?? latestDay?.activeKcalEst ?? 0)
        let resolvedMaxHR = maxHR ?? daily?.maxHr

        return PaperCard {
            VStack(alignment: .leading, spacing: 0) {
                Text("STRAIN CONTRIBUTORS")
                    .font(StrandFont.sectionOverline)
                    .tracking(StrandFont.sectionOverlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .padding(.bottom, 8)
                factorRow(icon: "heart", name: "Average HR",
                          value: resolvedAverageHR.map { "\($0) bpm" } ?? "—",
                          status: FactorBands.heartRate(
                            bpm: resolvedAverageHR.map(Double.init),
                            maxHR: profile.hrMax > 0 ? Double(profile.hrMax) : nil))
                factorRow(icon: "flame", name: "Calories",
                          value: resolvedCalories > 0 ? "\(Int(resolvedCalories.rounded())) kcal" : "—")
                factorRow(icon: "heart.circle.fill", name: "Max HR",
                          value: resolvedMaxHR.map { "\($0) bpm" } ?? "—",
                          status: FactorBands.heartRate(
                            bpm: resolvedMaxHR.map(Double.init),
                            maxHR: profile.hrMax > 0 ? Double(profile.hrMax) : nil))
                factorRow(icon: "clock.fill", name: "Duration",
                          value: duration > 0 ? durationText(duration) : "—",
                          divider: false)
            }
        }
    }

    private var heartRateZonesCard: some View {
        let zoneSet = profile.hrMax > 0
            ? HRZones.zones(maxHR: Double(profile.hrMax), source: "profile") : nil
        return PaperCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("HEART RATE ZONES")
                        .font(StrandFont.sectionOverline)
                        .tracking(StrandFont.sectionOverlineTracking)
                    Spacer()
                    NavigationLink("View Details") {
                        WorkoutsView()
                            #if os(iOS)
                            .toolbar(.visible, for: .navigationBar)
                            #endif
                    }
                        .font(StrandFont.caption.weight(.semibold))
                        .foregroundStyle(StrandPalette.link)
                }
                .foregroundStyle(StrandPalette.textSecondary)
                if let minutes = resolvedZoneMinutes, minutes.reduce(0, +) > 0 {
                    let total = minutes.reduce(0, +)
                    ZoneBars((1...5).map { zone in
                        let zoneMinutes = minutes[zone - 1]
                        return ZoneBarItem(zone: zone,
                                           fraction: zoneMinutes / total,
                                           duration: shortDuration(zoneMinutes),
                                           bpmRange: zoneSet?.bpmRangeLabel(forZone: zone))
                    })
                } else {
                    Text("Heart-rate zone time will appear after a workout records zone data.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    private var restStagesCard: some View {
        let legend: [(String, Color)] = [
            (String(localized: "Awake"), StrandPalette.sleepAwake),
            (String(localized: "REM"), StrandPalette.sleepREM),
            (String(localized: "Light"), StrandPalette.sleepLight),
            (String(localized: "Deep"), StrandPalette.sleepDeep)
        ]
        return PaperCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("SLEEP STAGES")
                    .font(StrandFont.sectionOverline)
                    .tracking(StrandFont.sectionOverlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                HStack(spacing: 12) {
                    ForEach(Array(legend.enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 5) {
                            Circle().fill(item.1).frame(width: 7, height: 7)
                            Text(item.0).font(StrandFont.micro)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                }
                if restIntervals.isEmpty {
                    Text("No sleep-stage timeline was recorded for this night.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 112, alignment: .center)
                } else {
                    Hypnogram(intervals: restIntervals, height: 128,
                              showsStageAxis: false, showsHover: true,
                              nightStart: latestSleepStart,
                              showsTimeAxis: latestSleepStart != nil,
                              smoothingSeconds: 300)
                }
            }
        }
    }

    private var restTimingCard: some View {
        let bed = timeInBedMinutes
        return PaperCard {
            StatTriplet([
                StatTripletItem("Time in bed", value: sleepDuration(bed)),
                StatTripletItem("Sleep efficiency", value: latestDay?.efficiency.map(percentText) ?? "—"),
                StatTripletItem("Latency", value: "—")
            ])
        }
    }

    private var restInsightCard: some View {
        PaperCard {
            HStack(spacing: 12) {
                Image(systemName: "moon.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(StrandPalette.restAccent)
                    .frame(width: 38, height: 38)
                    .background(StrandPalette.restTint, in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("SLEEP INSIGHT")
                        .font(StrandFont.sectionOverline)
                        .tracking(StrandFont.sectionOverlineTracking)
                    Text("Great sleep quality. Keep up your consistent bedtime routine.")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .foregroundStyle(StrandPalette.textPrimary)
            }
        }
    }

    private var stressBreakdownCard: some View {
        PaperCard {
            VStack(alignment: .leading, spacing: 0) {
                Text("STRESS BREAKDOWN")
                    .font(StrandFont.sectionOverline)
                    .tracking(StrandFont.sectionOverlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .padding(.bottom, 8)
                if let daytimeStress, !daytimeStress.scored.isEmpty {
                    ForEach(Array(stressBreakdown.enumerated()), id: \.offset) { index, item in
                        HStack(spacing: 10) {
                            Circle().fill(item.color).frame(width: 8, height: 8)
                            Text(item.label).font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Spacer()
                            Text("\(item.hours)h 00m")
                                .font(StrandFont.captionNumber)
                                .foregroundStyle(StrandPalette.textSecondary)
                            StatusBadge(LocalizedStringKey("\(item.percent)%"),
                                        style: .upToDate, tint: item.color)
                        }
                        .frame(minHeight: 40)
                        .overlay(alignment: .bottom) {
                            if index < stressBreakdown.count - 1 {
                                Rectangle().fill(StrandPalette.hairline).frame(height: 1)
                            }
                        }
                    }
                } else {
                    Text("A breakdown appears after enough daytime heart-rate data is recorded.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .padding(.vertical, 16)
                }
            }
        }
    }

    private var stressRecommendationCard: some View {
        PaperCard {
            HStack(spacing: 12) {
                Image(systemName: "leaf.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(StrandPalette.stressAccent)
                    .frame(width: 38, height: 38)
                    .background(StrandPalette.stressTint, in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("RESET RECOMMENDATION")
                        .font(StrandFont.sectionOverline)
                        .tracking(StrandFont.sectionOverlineTracking)
                    Text("You're handling stress well. A short walk can help you reset further.")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .foregroundStyle(StrandPalette.textPrimary)
            }
        }
    }

    private var restIntervals: [SleepInterval] {
        guard let day = latestDay else { return [] }
        let light = day.lightMin ?? 0
        let deep = day.deepMin ?? 0
        let rem = day.remMin ?? 0
        let awake = max(0, (timeInBedMinutes ?? 0) - (day.totalSleepMin ?? light + deep + rem))
        var cursor: TimeInterval = 0
        var result: [SleepInterval] = []
        func append(_ stage: SleepStage, minutes: Double) {
            guard minutes > 0 else { return }
            let end = cursor + minutes * 60
            result.append(SleepInterval(stage: stage, start: cursor, end: end))
            cursor = end
        }
        append(.light, minutes: light * 0.4)
        append(.deep, minutes: deep)
        append(.light, minutes: light * 0.3)
        append(.rem, minutes: rem)
        append(.light, minutes: light * 0.3)
        append(.awake, minutes: awake)
        return result
    }

    private var timeInBedMinutes: Double? {
        guard let asleep = latestDay?.totalSleepMin,
              let rawEfficiency = latestDay?.efficiency else { return latestDay?.totalSleepMin }
        let efficiency = rawEfficiency <= 1 ? rawEfficiency * 100 : rawEfficiency
        guard efficiency > 0 else { return asleep }
        return asleep / (efficiency / 100)
    }

    private struct StressBreakdownItem {
        let label: LocalizedStringKey
        let hours: Int
        let percent: Int
        let color: Color
    }

    private var stressBreakdown: [StressBreakdownItem] {
        let levels = daytimeStress?.scored.compactMap(\.level) ?? []
        let counts = [
            levels.filter { $0 < 0.75 }.count,
            levels.filter { $0 >= 0.75 && $0 < 1.5 }.count,
            levels.filter { $0 >= 1.5 && $0 < 2.25 }.count,
            levels.filter { $0 >= 2.25 }.count
        ]
        let total = max(1, counts.reduce(0, +))
        return [
            StressBreakdownItem(label: "Restful", hours: counts[0],
                                percent: Int((Double(counts[0]) / Double(total) * 100).rounded()),
                                color: StrandPalette.stressRestful),
            StressBreakdownItem(label: "Low", hours: counts[1],
                                percent: Int((Double(counts[1]) / Double(total) * 100).rounded()),
                                color: StrandPalette.stressLow),
            StressBreakdownItem(label: "Medium", hours: counts[2],
                                percent: Int((Double(counts[2]) / Double(total) * 100).rounded()),
                                color: StrandPalette.stressMedium),
            StressBreakdownItem(label: "High", hours: counts[3],
                                percent: Int((Double(counts[3]) / Double(total) * 100).rounded()),
                                color: StrandPalette.stressHigh)
        ]
    }

    private var detailWorkouts: [WorkoutRow] {
        let day = detailDayKey
        return workouts.filter {
            Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval($0.startTs))) == day
        }
    }

    private var detailDayKey: String {
        anchorDayKey
    }

    private var detailAppleDay: AppleDaily? {
        appleDays.last(where: { $0.day == detailDayKey })
    }

    private var resolvedZoneMinutes: [Double]? {
        if let imported = WorkoutZones.summary(from: detailWorkouts), imported.totalMinutes > 0 {
            return imported.minutes
        }
        return computedZoneMinutes
    }

    private func loadComputedWorkoutZones() async {
        let rows = detailWorkouts
        guard !rows.isEmpty else {
            computedZoneMinutes = nil
            return
        }
        var total = [Double](repeating: 0, count: 5)
        var found = false
        for row in rows where WorkoutZones.percents(row.zonesJSON) == nil {
            guard let minutes = await repo.workoutZoneMinutes(
                from: row.startTs,
                to: row.endTs,
                age: profile.age
            ), minutes.count == 5 else { continue }
            found = true
            for index in total.indices { total[index] += minutes[index] }
        }
        computedZoneMinutes = found ? total : nil
    }

    /// D16's personal 7-day baseline. The engine helper applies its real metric
    /// validity bounds and cold-start gate; excluding the displayed night prevents leakage.
    private func sevenDayDeviation(
        value: Double?,
        values: [Double?],
        cfg: MetricCfg
    ) -> Deviation? {
        guard let value else { return nil }
        let state = Baselines.rollingMeanSD(values, cfg: cfg, window: 7)
        guard state.usable else { return nil }
        return Baselines.deviation(value, state: state)
    }

    private var priorFactorDays: [DailyMetric] {
        Array(repo.days.dropLast().suffix(7))
    }

    private var hrvFactorBand: FactorBand? {
        let deviation = sevenDayDeviation(
            value: latestDay?.avgHrv,
            values: priorFactorDays.map(\.avgHrv),
            cfg: Baselines.hrvCfg)
        return FactorBands.hrv(deviationRatio: deviation?.ratio, zScore: deviation?.z)
    }

    private var restingHRFactorBand: FactorBand? {
        let deviation = sevenDayDeviation(
            value: latestDay?.restingHr.map(Double.init),
            values: priorFactorDays.map { $0.restingHr.map(Double.init) },
            cfg: Baselines.restingHRCfg)
        return FactorBands.restingHR(deviationRatio: deviation?.ratio, zScore: deviation?.z)
    }

    private var respiratoryRateFactorBand: FactorBand? {
        let deviation = sevenDayDeviation(
            value: latestDay?.respRateBpm,
            values: priorFactorDays.map(\.respRateBpm),
            cfg: Baselines.respCfg)
        return FactorBands.respiratoryRate(zScore: deviation?.z)
    }

    private func factorRow(icon: String, name: LocalizedStringKey, value: String,
                           status: FactorBand? = nil,
                           divider: Bool = true) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 24, height: 24)
                .background(StrandPalette.inset, in: Circle())
            Text(name).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
            Spacer(minLength: 8)
            Text(value).font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary)
            // D16: every word comes from FactorBands + the cited analytics source;
            // nil preserves the honest value-only fallback for metrics without a baseline.
            if let status {
                MicroBadge(LocalizedStringKey(status.localizationKey), tint: status.color)
            }
        }
        .frame(minHeight: 40)
        .overlay(alignment: .bottom) {
            if divider { Rectangle().fill(StrandPalette.hairline).frame(height: 1) }
        }
    }

    private func legendLine(dashed: Bool, label: String) -> some View {
        HStack(spacing: 6) {
            Capsule()
                .fill((kind == .charge ? StrandPalette.recoveryData : accent).opacity(dashed ? 0.55 : 1))
                .frame(width: 20, height: dashed ? 1 : 2)
            Text(label).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private var detailTitle: String {
        switch kind {
        case .charge: return String(localized: "Recovery")
        case .effort: return String(localized: "Strain")
        case .rest: return String(localized: "Sleep")
        case .stress: return String(localized: "Stress")
        }
    }

    private var detailRange: ClosedRange<Double> {
        switch kind {
        case .effort: return StrainScale.displayRange
        case .stress: return 0...3
        default: return 0...100
        }
    }

    private var detailAxisValues: [Double] {
        switch kind {
        case .effort: return [0, 7, 14, 21]
        case .stress: return [0, 1.5, 3]
        default: return [0, 50, 100]
        }
    }

    private var heroTitle: String {
        switch kind {
        case .charge:
            guard let latest else { return String(localized: "Calibrating") }
            return RecoveryBands.band(for: latest).rawValue.capitalized
        case .effort:
            guard let latest else { return String(localized: "Calibrating") }
            let band = StrainScale.band(latest).title
            return "\(band) \(String(localized: "Strain"))"
        case .rest: return String(localized: "Good Sleep")
        case .stress:
            switch stressModel?.band {
            case .high: return String(localized: "High Stress")
            case .medium: return String(localized: "Moderate Stress")
            default: return String(localized: "Low Stress")
            }
        }
    }

    private var heroCaption: LocalizedStringKey {
        switch kind {
        case .charge: return "Your body is still recovering."
        case .effort: return "You trained hard today. Productive, but don't overdo it."
        case .rest: return "You had a strong recovery."
        case .stress: return "You've been relaxed most of the day."
        }
    }

    private func scoreText(_ value: Double?) -> String {
        value.map { kind == .stress || kind == .effort ? String(format: "%.1f", $0) : "\(Int($0.rounded()))" } ?? "—"
    }

    private func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    private func durationText(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes) min"
    }

    private func shortDuration(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        return total >= 60 ? "\(total / 60)h\(total % 60)m" : "\(total)m"
    }

    private func sleepDuration(_ minutes: Double?) -> String {
        guard let minutes else { return "—" }
        let total = max(0, Int(minutes.rounded()))
        return total >= 60 ? "\(total / 60)h \(total % 60)m" : "\(total)m"
    }

    private func percentText(_ raw: Double) -> String {
        let percent = raw <= 1 ? raw * 100 : raw
        return "\(Int(percent.rounded()))%"
    }

    private func loadDaytimeStress() async {
        let calendar = Calendar.current
        let start = Int(calendar.startOfDay(for: Date()).timeIntervalSince1970)
        let end = Int(Date().timeIntervalSince1970)
        let hr = await repo.hrSamples(from: start, to: end, limit: 200_000)
        guard hr.count >= DaytimeStress.minHourHRSamples else {
            daytimeStress = .empty
            return
        }
        let rr = (try? await repo.storeHandle()?.rrIntervals(
            deviceId: repo.deviceId, from: start, to: end, limit: 200_000)) ?? []
        daytimeStress = DaytimeStress.analyze(
            hr: hr,
            rr: rr,
            tzOffsetSeconds: TimeZone.current.secondsFromGMT(for: Date())
        )
    }

    private var detailDateLabel: String {
        Self.headerDateFormatter.string(from: anchorDate)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let headerDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("EEE MMM d")
        return formatter
    }()
}

#if DEBUG
#Preview("Coupled view") {
    let repo = Repository(deviceId: "preview")
    repo.days = [
        DailyMetric(
            day: Repository.logicalDayKey(Date()),
            totalSleepMin: 402, efficiency: 92,
            deepMin: 84, remMin: 96, lightMin: 222, disturbances: 6,
            restingHr: 51, avgHrv: 68, recovery: 74, strain: 62,
            exerciseCount: 2,
            spo2Pct: 97, skinTempDevC: 0.1, respRateBpm: 14.4,
            steps: 8200, activeKcalEst: 640
        )
    ]
    repo.loaded = true
    return NavigationStack { CoupledView() }
        .environmentObject(repo)
        .frame(width: 900, height: 820)
        .preferredColorScheme(.dark)
}
#endif
