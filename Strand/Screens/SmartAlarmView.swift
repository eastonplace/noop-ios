import SwiftUI
import UserNotifications
import StrandDesign
import StrandAnalytics

/// Smart alarm (#207) — the iOS/macOS surface.
///
/// HONEST by design: a sideloaded, backgrounded app on iOS can't fire a dependable LOUD wake alarm
/// (that needs the critical-alert entitlement, which a non-App-Store build doesn't have), so this
/// platform deliberately does NOT offer a wake alarm. The dependable phone wake lives on Android,
/// which has the exact-alarm primitive. Here we offer the cross-platform WIND-DOWN nudge — a gentle
/// evening reminder — and we say plainly why there's no wake alarm, rather than promising one we
/// can't keep.
struct SmartAlarmView: View {
    // #766: this is now the ONE alarm surface. The strap's silent firmware wake-alarm used to live in a
    // separate card over in Automations, which let users conflate it with the wind-down reminder; it's
    // moved here so every wake/wind-down control sits together. Needs the model (to arm/disarm the strap
    // alarm over BLE) and the behavior store (the alarm's persisted on/time/weekdays).
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var behavior: BehaviorStore
    // T702: the promoted hero needs the canonical dynamic Sleep Need (repo) and enough Recovery
    // history to say honestly whether "In the green" can forecast tonight (intelligence).
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var intelligence: IntelligenceEngine

    @State private var windDownOn = WindDownNudge.isEnabled
    /// Earliest wake time the nudge is derived from (minutes since midnight). Seeded from the store.
    @State private var wakeMinutes = WindDownNudge.wakeMinutes

    // PR#554 (MumiZed) — per-day wake overrides. `perDayOn` reflects whether ANY override is set; the
    // `overrides` map mirrors the store so the pickers stay in sync. Additive: with none set, the nudge
    // behaves exactly as before (one wake time for every evening).
    @State private var perDayOn = WindDownNudge.hasPerDayOverrides
    @State private var overrides: [Int: Int] = WindDownNudge.perDayWakeOverrides
    /// Calendar weekday numbers laid out Monday-first (Mon…Sun → 2,3,4,5,6,7,1), matching AutomationsView.
    nonisolated private static let weekdayOrder = [2, 3, 4, 5, 6, 7, 1]

    // MARK: - T702: promoted SleepAlarmModuleCard hero
    //
    // The canonical dynamic Sleep Need, resolved once per appearance: repo.latestNoopSleepNeedV2 →
    // the Sleep page's own personal-mean fallback (byte-for-byte the same rule SleepView.sleepNeedMin
    // and CoupledView.sleepNeedMin already use) → the SleepNeedV2 default. WindDownNudge is pushed
    // the SAME resolved value (plan doc G6) so the wind-down nudge and the alarm's "be asleep by"
    // never plan off two different numbers.
    @State private var needMinutes: Double = SleepNeedV2.Config.production.defaultBaselineMinutes
    @State private var needIsStartingEstimate = true
    @State private var evidence: SmartAlarmEvidence?
    @State private var scheduleToolsExpanded = false
    @State private var backupStatus = String(localized: "Checking…")

    var body: some View {
        // #766: retitled to "Alarms" because it now holds BOTH the strap's silent wake-alarm and the
        // evening wind-down reminder, so naming it "Wind-Down" undersold it. One surface, clearly labelled.
        ScreenScaffold(title: "Alarms",
                       subtitle: "Wake and wind-down controls.") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                alarmHeroSection
                scheduleAndStrapTools
                windDownCard
                honestyCard
            }
        }
        .task {
            await resolveCanonicalNeed()
            SmartAlarmEvidenceStore.refreshCorrelation()
            evidence = SmartAlarmEvidenceStore.latest
        }
        .task(id: behavior.smartAlarmEnabled) { await refreshBackupStatus() }
        .task(id: scheduleToolsExpanded) {
            if scheduleToolsExpanded { await refreshBackupStatus() }
        }
        // Stored edits are reconciled once by the app-root SmartAlarmCommandReconciler.
        // Keeping side effects out of each editor prevents duplicate BLE commands when
        // Sleep and Alarms remain mounted at the same time.
    }

    // MARK: - T702 hero: real clock, real modes, real canonical need

    private var recoveryHistoryCount: Int {
        intelligence.results.compactMap(\.recovery).count
    }

    private var wakeModes: [SleepAlarmWakeMode] {
        SleepAlarmEditorSupport.wakeModes(recoveryHistoryCount: recoveryHistoryCount)
    }

    private var smartAlarmModeBinding: Binding<String> {
        Binding(
            get: { behavior.smartAlarmMode.rawValue },
            set: { raw in
                guard let mode = SmartAlarmEvaluator.Mode(rawValue: raw) else { return }
                behavior.smartAlarmMode = mode
            }
        )
    }

    /// Bridges the real time-of-day store (`behavior.smartAlarmMinutes`, 0..<1440) onto the module's
    /// continuous wake axis for a given "now" — resolves to later today or tomorrow, whichever is the
    /// actual next occurrence, and writes any nudge straight back to the same store the DatePicker
    /// below edits (one binding, two controls).
    private func wakeContinuousBinding(now: Date) -> Binding<Int> {
        Binding(
            get: {
                SleepAlarmEditorSupport.schedule(at: now, behavior: behavior)?.continuousMinutes
                    ?? behavior.smartAlarmMinutes
            },
            set: { newContinuous in
                behavior.smartAlarmMinutes = ((newContinuous % 1_440) + 1_440) % 1_440
            }
        )
    }

    /// Resolve tonight's canonical dynamic Sleep Need, three tiers, honest about which one landed:
    /// 1) the real V2 point at/before today (`repo.latestNoopSleepNeedV2`);
    /// 2) else the Sleep page's own personal-mean fallback — byte-for-byte `SleepView.sleepNeedMin`
    ///    (CoupledView.sleepNeedMin already mirrors the same rule, so all three screens agree);
    /// 3) else the SleepNeedV2 default (480 min), labelled a starting estimate, never silently.
    /// Pushes the resolved value into `WindDownNudge` (plan doc G6) so wind-down times off the same
    /// number the alarm module's "be asleep by" does.
    private func resolveCanonicalNeed() async {
        let today = Repository.localDayKey(Date())
        let plan = await repo.canonicalSleepNeedPlan(onOrBefore: today)
        needMinutes = plan.minutes
        needIsStartingEstimate = plan.isStartingEstimate
        WindDownNudge.updateCanonicalNeedMinutes(needMinutes)
    }

    /// The hero: the promoted module (real clock via `TimelineView`, real modes, real need) plus the
    /// quiet last-evaluation evidence row and tonight's real plan timeline. A 60 s tick is plenty for
    /// a "be asleep by" countdown; the module itself still recomputes instantly on every user edit.
    private var alarmHeroSection: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let comps = Calendar.current.dateComponents([.hour, .minute], from: context.date)
            let nowMinutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
            let modes = wakeModes
            let selected = modes.first { $0.id == behavior.smartAlarmMode.rawValue }
            let windowMinutes = selected?.windowMinutes ?? 0
            let schedule = SleepAlarmEditorSupport.schedule(at: context.date, behavior: behavior)
            let wake = schedule?.continuousMinutes ?? SleepAlarmTime.nextOccurrence(
                now: nowMinutes, timeOfDay: behavior.smartAlarmMinutes)
            let windowStart = wake - windowMinutes
            let asleepBy = SleepAlarmTime.asleepByMinutes(wakeMinutes: wake, windowMinutes: windowMinutes,
                                                           needMinutes: needMinutes)

            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                SleepAlarmModuleCard(
                    armed: $behavior.smartAlarmEnabled,
                    modes: modes,
                    selectedModeId: smartAlarmModeBinding,
                    wakeMinutes: wakeContinuousBinding(now: context.date),
                    nowMinutes: nowMinutes,
                    needMinutes: needMinutes,
                    wakeDayLabel: schedule?.dayLabel ?? String(localized: "No enabled day"),
                    deliveryStatus: SleepAlarmEditorSupport.deliveryStatus(model: model, behavior: behavior),
                    showsBedtimePlan: schedule?.isUpcomingSleepPeriod == true
                )
                if needIsStartingEstimate {
                    Text("Starting estimate — NOOP hasn't computed your personal Sleep Need yet.")
                        .font(StrandFont.micro)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .padding(.horizontal, 4)
                }
                if let evidence {
                    evaluationEvidenceRow(evidence)
                }
                if behavior.smartAlarmEnabled, schedule?.isUpcomingSleepPeriod == true {
                    SleepPlanTimeline(now: nowMinutes, asleepBy: asleepBy, windowStart: windowStart, alarm: wake)
                }
            }
        }
    }

    /// Quiet "last evaluation" evidence row (T702): decision, reason, and the correlated strap
    /// armed/fired times when the strap has confirmed them. Read-only, no controls — a diagnostic
    /// trace of the SAME hardened evaluator/actuation path in `AppModel`, never re-derived here.
    private func evaluationEvidenceRow(_ e: SmartAlarmEvidence) -> some View {
        PaperCard(padding: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Last evaluation".uppercased())
                        .font(StrandFont.overline)
                        .tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer(minLength: 8)
                    Text(e.evaluatedAt, format: .relative(presentation: .named))
                        .font(StrandFont.micro)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Text("\(Self.decisionWord(e.decision)) · \(e.reason)")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textPrimary)
                if let armed = e.strapReportedArmedAt {
                    Text("Strap confirmed armed at \(armed.formatted(date: .omitted, time: .shortened))")
                        .font(StrandFont.micro)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                if let fired = e.observedStrapWakeAt {
                    Text("Strap fired at \(fired.formatted(date: .omitted, time: .shortened))")
                        .font(StrandFont.micro)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    private static func decisionWord(_ d: SmartAlarmEvaluator.Decision) -> String {
        switch d {
        case .wait:        return String(localized: "Waiting")
        case .wakeNow:      return String(localized: "Woke early")
        case .endpoint:     return String(localized: "Endpoint reached")
        case .unavailable:  return String(localized: "Unavailable")
        }
    }

    /// Kit 47 is the only primary alarm editor. The former production screen repeated enable/time
    /// controls in two more legacy cards underneath it, which made the adoption visually false and
    /// created competing bindings for the same store. The tools that are not part of the promoted
    /// module remain reachable here: the exact time picker, weekday schedule, test buzz, and backup
    /// status. Collapsing them keeps the accepted lab module intact above the fold without dropping a
    /// production capability.
    private var scheduleAndStrapTools: some View {
        PaperCard(padding: 14) {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(StrandMotion.interactive) {
                        scheduleToolsExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(StrandPalette.sleepAccent)
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(StrandPalette.surfaceInset)
                            )
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Schedule & strap tools")
                                .font(StrandFont.caption.weight(.semibold))
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text("Exact-time picker, weekdays, test buzz, and backup status")
                                .font(StrandFont.micro)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .rotationEffect(.degrees(scheduleToolsExpanded ? 180 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Schedule and strap tools")
                .accessibilityValue(scheduleToolsExpanded ? "Expanded" : "Collapsed")

                if scheduleToolsExpanded {
                    Divider().overlay(StrandPalette.hairline)
                        .padding(.vertical, 12)

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Exact wake time")
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Spacer(minLength: 12)
                            DatePicker("", selection: alarmTimeBinding, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                                .datePickerStyle(.compact)
                                .accessibilityLabel("Exact wake time")
                        }

                        Divider().overlay(StrandPalette.hairline)
                        alarmWeekdayPicker
                        Divider().overlay(StrandPalette.hairline)

                        SettingsRow(icon: "iphone", title: "Backup notification",
                                    subtitle: "Phone fallback when the strap alarm is armed",
                                    showsChevron: false) {
                            Text(backupStatus)
                        }

                        NoteCard("Alarms use your strap's vibration. Keep it charged and within range.",
                                 style: .warning)
                        PrimaryButton("Test alarm") { model.buzzStrapOnce() }
                    }
                }
            }
        }
    }

    @MainActor
    private func refreshBackupStatus() async {
        guard behavior.smartAlarmEnabled else {
            backupStatus = String(localized: "Off")
            return
        }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            backupStatus = String(localized: "Unavailable · permission denied")
            return
        }
        let pending = await center.pendingNotificationRequests()
        let scheduled = pending.contains { $0.identifier.hasPrefix("smart-alarm-wake-backup") }
        backupStatus = scheduled ? String(localized: "Scheduled") : String(localized: "Not scheduled")
    }

    // The up-front, honest note about the difference between the strap's silent buzz (above) and a loud
    // phone wake. The strap alarm is real, but it's a gentle wrist buzz, not a sound, so we say plainly
    // to keep a backup, and that the louder smart wake lives on Android.
    private var honestyCard: some View {
        StrandCard(padding: 20) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "bell.slash")
                    .foregroundStyle(StrandPalette.statusWarning)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("The strap alarm is a silent buzz, not a sound")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("The wake alarm can buzz your wrist from the strap's firmware after the strap confirms it is armed. A phone backup notification is best-effort: Focus, silent mode, or denied notification permission can prevent it from alerting you. Keep your phone's built-in Clock alarm as your dependable backup.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var windDownCard: some View {
        // Sleep-tinted when armed so the active state reads in the sleep world; neutral when off.
        StrandCard(padding: 20, tint: windDownOn ? StrandPalette.restColor : nil) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Evening").strandOverline()
                    HStack(spacing: 10) {
                        Image(systemName: "moon.zzz.fill")
                            .foregroundStyle(StrandPalette.restColor)
                            .accessibilityHidden(true)
                        Text("Wind-down nudge")
                            .font(StrandFont.title2)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                }

                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Remind me to wind down")
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("A calm evening reminder, timed from your wake time and usual sleep need. It's a suggestion, not an alarm.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: $windDownOn)
                        .labelsHidden().toggleStyle(.switch).tint(StrandPalette.ink)
                        .accessibilityLabel("Remind me to wind down")
                        .onChangeCompat(of: windDownOn) { on in WindDownNudge.setEnabled(on) }
                }
                .frame(minHeight: 42)

                if windDownOn {
                    Divider().overlay(StrandPalette.hairline)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Wake time")
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text("The nudge fires \(WindDownNudge.sleepNeedMinutes / 60)h \(WindDownNudge.leadMinutes)m before this.")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        Spacer()
                        DatePicker("", selection: wakeBinding, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .accessibilityLabel("Wake time")
                    }
                    Text("You'll be reminded around \(timeLabel(WindDownNudge.nudgeMinuteOfDay())).")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)

                    Divider().overlay(StrandPalette.hairline)
                    perDaySection
                }
            }
        }
    }

    // PR#554 — per-day wake overrides. A toggle reveals a per-weekday wake-time editor; with it off (or no
    // override set) every evening uses the single wake time above. Each weekday row shows the effective wake
    // (override or the default) and lets the user set or clear that day's time.
    @ViewBuilder private var perDaySection: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Different wake time per day")
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("Set a wake time for specific days (a lie-in at the weekend, say). Days you leave alone use the time above.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: $perDayOn)
                .labelsHidden().toggleStyle(.switch).tint(StrandPalette.ink)
                .accessibilityLabel("Different wake time per day")
                .onChangeCompat(of: perDayOn) { on in
                    // Turning the section OFF clears every override (so the nudge reverts to the single time);
                    // turning it ON just reveals the editor — no override is created until the user sets one.
                    if !on {
                        for weekday in 1...7 { WindDownNudge.setWakeOverride(weekday: weekday, minutes: nil) }
                        overrides = [:]
                    }
                }
        }
        .frame(minHeight: 42)

        if perDayOn {
            VStack(spacing: 8) {
                ForEach(Self.weekdayOrder, id: \.self) { weekday in
                    weekdayOverrideRow(weekday)
                }
            }
            .padding(.top, 4)
        }
    }

    /// One weekday's override row: the day name, the effective wake time (override or default), a picker to
    /// set it, and a clear control shown only when an override exists for that day.
    private func weekdayOverrideRow(_ weekday: Int) -> some View {
        let effective = overrides[weekday] ?? wakeMinutes
        let hasOverride = overrides[weekday] != nil
        return HStack(spacing: 12) {
            Text(Self.weekdayName(weekday))
                .font(StrandFont.subhead)
                .foregroundStyle(hasOverride ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                .frame(width: 96, alignment: .leading)
            Spacer(minLength: 0)
            if hasOverride {
                Button {
                    WindDownNudge.setWakeOverride(weekday: weekday, minutes: nil)
                    overrides[weekday] = nil
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear \(Self.weekdayName(weekday)) override, use the default wake time")
            }
            DatePicker("", selection: overrideBinding(weekday, effective: effective),
                       displayedComponents: .hourAndMinute)
                .labelsHidden()
                .accessibilityLabel("\(Self.weekdayName(weekday)) wake time")
        }
    }

    /// A binding for one weekday's wake override — reads the effective minute, writes a NEW override (a pick
    /// always sets that day's override) into both the store and the local mirror, rescheduling via the store.
    private func overrideBinding(_ weekday: Int, effective: Int) -> Binding<Date> {
        Binding(
            get: {
                var c = DateComponents()
                c.hour = effective / 60
                c.minute = effective % 60
                return Calendar.current.date(from: c) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                let m = (c.hour ?? 7) * 60 + (c.minute ?? 0)
                WindDownNudge.setWakeOverride(weekday: weekday, minutes: m)
                overrides[weekday] = m
            }
        )
    }

    /// Full weekday name for a Calendar weekday number (1=Sun…7=Sat).
    private static func weekdayName(_ dow: Int) -> String {
        let names = [String(localized: "Sunday"), String(localized: "Monday"), String(localized: "Tuesday"),
                     String(localized: "Wednesday"), String(localized: "Thursday"), String(localized: "Friday"),
                     String(localized: "Saturday")]
        return (1...7).contains(dow) ? names[dow - 1] : String(localized: "Day \(dow)")
    }

    // Bridges the minutes-since-midnight store to a DatePicker's Date, persisting + rescheduling.
    private var wakeBinding: Binding<Date> {
        Binding(
            get: {
                var c = DateComponents()
                c.hour = wakeMinutes / 60
                c.minute = wakeMinutes % 60
                return Calendar.current.date(from: c) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                let m = (c.hour ?? 7) * 60 + (c.minute ?? 0)
                wakeMinutes = m
                WindDownNudge.setWakeMinutes(m)
            }
        )
    }

    private func timeLabel(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    // MARK: - Strap alarm weekday picker (#766, moved here from Automations, behaviour intact)

    private var alarmWeekdayPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(Self.weekdayOrder, id: \.self) { dow in
                    let selected = Self.alarmWeekdayIsSelected(dow, in: behavior.smartAlarmWeekdays)
                    Text(Self.alarmWeekdayInitial(dow))
                        .font(StrandFont.caption)
                        .foregroundStyle(selected ? StrandPalette.surfaceBase : StrandPalette.textSecondary)
                        .frame(width: 30, height: 30)
                        .background(selected ? StrandPalette.accent : StrandPalette.surfaceInset, in: Circle())
                        .contentShape(Circle())
                        .onTapGesture { behavior.smartAlarmWeekdays = Self.alarmToggledWeekday(dow, in: behavior.smartAlarmWeekdays) }
                        .accessibilityLabel(Self.weekdayName(dow))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            Text(Self.alarmWeekdaySummary(behavior.smartAlarmWeekdays))
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Bridges the strap alarm's minutes-since-midnight store to a DatePicker's Date.
    private var alarmTimeBinding: Binding<Date> {
        Binding(
            get: {
                var c = DateComponents()
                c.hour = behavior.smartAlarmMinutes / 60
                c.minute = behavior.smartAlarmMinutes % 60
                return Calendar.current.date(from: c) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                behavior.smartAlarmMinutes = (c.hour ?? 7) * 60 + (c.minute ?? 0)
            }
        )
    }

    // The strap-alarm weekday rules: pure + nonisolated so they stay unit-testable. Kept byte-identical
    // to the originals in AutomationsView (only renamed with an `alarm` prefix to avoid colliding with
    // this view's full-name `weekdayName`).

    /// A day reads as "on" when the set is empty (= every day) or explicitly contains it.
    nonisolated static func alarmWeekdayIsSelected(_ dow: Int, in days: Set<Int>) -> Bool {
        days.isEmpty || days.contains(dow)
    }

    /// Toggle one weekday, normalising "every day" at both ends so the empty set always means every day.
    nonisolated static func alarmToggledWeekday(_ dow: Int, in days: Set<Int>) -> Set<Int> {
        var next: Set<Int>
        if days.isEmpty {
            next = Set(1...7)
            next.remove(dow)
        } else if days.contains(dow) {
            next = days
            next.remove(dow)
        } else {
            next = days
            next.insert(dow)
        }
        return next.count == 7 ? [] : next
    }

    /// Human-readable summary of the selection.
    nonisolated static func alarmWeekdaySummary(_ days: Set<Int>) -> String {
        if days.isEmpty || days.count == 7 { return String(localized: "Every day") }
        if days == Set(2...6) { return String(localized: "Weekdays") }
        if days == Set([1, 7]) { return String(localized: "Weekends") }
        return weekdayOrder.filter { days.contains($0) }.map { alarmWeekdayShort($0) }.joined(separator: ", ")
    }

    /// One-letter day chip. Derived from the localized short name so the initials follow the
    /// language (and Tue/Thu or Sat/Sun never share a single collision-prone key). English output
    /// is byte-identical to the old hardcoded initials.
    private static func alarmWeekdayInitial(_ dow: Int) -> String {
        let short = alarmWeekdayShort(dow)
        return short == "?" ? "?" : String(short.prefix(1))
    }

    nonisolated private static func alarmWeekdayShort(_ dow: Int) -> String {
        switch dow {
        case 1: return String(localized: "Sun")
        case 2: return String(localized: "Mon")
        case 3: return String(localized: "Tue")
        case 4: return String(localized: "Wed")
        case 5: return String(localized: "Thu")
        case 6: return String(localized: "Fri")
        case 7: return String(localized: "Sat")
        default: return "?"
        }
    }
}
