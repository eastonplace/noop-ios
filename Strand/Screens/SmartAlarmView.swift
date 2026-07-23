import SwiftUI
import StrandDesign
import StrandAnalytics

/// Alarm controls: a strap-firmware endpoint plus best-effort adaptive evaluation and phone backup.
/// The UI owns no BLE/notification side effects; every editor writes shared state and the app-root
/// `SmartAlarmRuntimeController` reconciles one generation-safe configuration.
struct SmartAlarmView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var behavior: BehaviorStore
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var intelligence: IntelligenceEngine
    @EnvironmentObject private var alarmMode: SmartAlarmAdaptiveModeStore
    @EnvironmentObject private var alarmRuntime: SmartAlarmRuntimeController

    @State private var windDownOn = WindDownNudge.isEnabled
    @State private var windDownPermissionDenied = false
    /// Earliest wake time the nudge is derived from (minutes since midnight). Seeded from the store.
    @State private var wakeMinutes = WindDownNudge.wakeMinutes

    // PR#554 (MumiZed) — per-day wake overrides. `perDayOn` reflects whether ANY override is set; the
    // `overrides` map mirrors the store so the pickers stay in sync. Additive: with none set, the nudge
    // behaves exactly as before (one wake time for every evening).
    @State private var perDayOn = WindDownNudge.hasPerDayOverrides
    @State private var overrides: [Int: Int] = WindDownNudge.perDayWakeOverrides
    /// Calendar weekday numbers laid out Monday-first (Mon…Sun → 2,3,4,5,6,7,1), matching AutomationsView.
    nonisolated private static let weekdayOrder = [2, 3, 4, 5, 6, 7, 1]

    // MARK: - Promoted SleepAlarmModuleCard hero

    @State private var needMinutes: Double = SleepNeedV2.Config.production.defaultBaselineMinutes
    @State private var needIsStartingEstimate = true
    @State private var scheduleToolsExpanded = false

    var body: some View {
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
            alarmRuntime.refreshStatus()
        }
        .alert("Notifications are off", isPresented: $windDownPermissionDenied) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Allow notifications in Settings before enabling the wind-down nudge.")
        }
    }

    private var recoveryHistoryCount: Int {
        intelligence.results.compactMap(\.recovery).count
    }

    private var wakeModes: [SleepAlarmWakeMode] {
        SleepAlarmEditorSupport.wakeModes(recoveryHistoryCount: recoveryHistoryCount)
    }

    /// Resolve tonight's canonical dynamic Sleep Need, three tiers, honest about which one landed.
    private func resolveCanonicalNeed() async {
        let today = Repository.localDayKey(Date())
        let plan = await repo.canonicalSleepNeedPlan(onOrBefore: today)
        needMinutes = plan.minutes
        needIsStartingEstimate = plan.isStartingEstimate
        WindDownNudge.updateCanonicalNeedMinutes(needMinutes)
    }

    /// The promoted module plus last-evaluation evidence and tonight's real plan timeline.
    private var alarmHeroSection: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let comps = Calendar.current.dateComponents([.hour, .minute], from: context.date)
            let nowMinutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
            let modes = wakeModes
            let selected = modes.first { $0.id == alarmMode.mode.rawValue }
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
                    selectedModeId: SleepAlarmEditorSupport.modeBinding(alarmMode),
                    wakeMinutes: SleepAlarmEditorSupport.wakeBinding(behavior, now: context.date),
                    nowMinutes: nowMinutes,
                    needMinutes: needMinutes,
                    wakeDayLabel: schedule?.dayLabel ?? String(localized: "No enabled day"),
                    deliveryStatus: alarmRuntime.deliveryStatus,
                    showsBedtimePlan: schedule?.isUpcomingSleepPeriod == true
                )
                if needIsStartingEstimate {
                    Text("Starting estimate — NOOP hasn't computed your personal Sleep Need yet.")
                        .font(StrandFont.micro)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .padding(.horizontal, 4)
                }
                if let evidence = alarmRuntime.evidence {
                    evaluationEvidenceRow(evidence)
                }
                if behavior.smartAlarmEnabled, schedule?.isUpcomingSleepPeriod == true {
                    SleepPlanTimeline(now: nowMinutes, asleepBy: asleepBy, windowStart: windowStart, alarm: wake)
                }
            }
        }
    }

    /// Read-only diagnostic trace of the exact runtime generation that produced the current endpoint.
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
        case .wakeNow:     return String(localized: "Woke early")
        case .endpoint:    return String(localized: "Endpoint reached")
        case .unavailable: return String(localized: "Unavailable")
        }
    }

    /// The exact time picker, weekday schedule, test buzz, and actual backup-notification status.
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
                            Text(alarmRuntime.backupStatus)
                        }

                        NoteCard("Alarms use your strap's vibration. Keep it charged and within range.",
                                 style: .warning)
                        PrimaryButton("Test alarm") { model.buzzStrapOnce() }
                    }
                }
            }
        }
    }

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
                        .onChangeCompat(of: windDownOn) { on in
                            WindDownNudge.setEnabled(on) { outcome in
                                switch outcome {
                                case .scheduled, .off:
                                    windDownOn = WindDownNudge.isEnabled
                                case .denied:
                                    windDownOn = false
                                    windDownPermissionDenied = true
                                }
                            }
                        }
                }
                .frame(minHeight: 42)

                if windDownOn {
                    Divider().overlay(StrandPalette.hairline)
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            windDownWakeTimeCopy
                            Spacer(minLength: 12)
                            DatePicker("Wake time", selection: wakeBinding, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                                .accessibilityLabel("Wake time")
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            windDownWakeTimeCopy
                            DatePicker("Wake time", selection: wakeBinding, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                                .accessibilityLabel("Wake time")
                        }
                    }
                    Text("You'll be reminded around \(Self.windDownTimeLabel(WindDownNudge.nudgeMinuteOfDay())).")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)

                    Divider().overlay(StrandPalette.hairline)
                    perDaySection
                }
            }
        }
    }

    private var windDownWakeTimeCopy: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Wake time")
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("The nudge fires \(WindDownNudge.sleepNeedMinutes / 60)h \(WindDownNudge.leadMinutes)m before this.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var perDaySection: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                perDayCopy
                Spacer(minLength: 12)
                perDayToggle
            }
            VStack(alignment: .leading, spacing: 10) {
                perDayCopy
                perDayToggle
            }
        }
        .frame(minHeight: 44)

        if perDayOn {
            VStack(spacing: 8) {
                ForEach(Self.weekdayOrder, id: \.self) { weekday in
                    weekdayOverrideRow(weekday)
                }
            }
            .padding(.top, 4)
        }
    }

    private var perDayCopy: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Different wake time per day")
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("Set a wake time for specific days (a lie-in at the weekend, say). Days you leave alone use the time above.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var perDayToggle: some View {
        Toggle("Different wake time per day", isOn: $perDayOn)
            .labelsHidden().toggleStyle(.switch).tint(StrandPalette.ink)
            .accessibilityLabel("Different wake time per day")
            .onChangeCompat(of: perDayOn) { on in
                if !on {
                    WindDownNudge.setWakeOverrides([:])
                    overrides = [:]
                }
            }
    }

    private func weekdayOverrideRow(_ weekday: Int) -> some View {
        let effective = overrides[weekday] ?? wakeMinutes
        let hasOverride = overrides[weekday] != nil
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                weekdayOverrideLabel(weekday, hasOverride: hasOverride)
                Spacer(minLength: 0)
                weekdayOverrideControls(weekday, effective: effective, hasOverride: hasOverride)
            }
            VStack(alignment: .leading, spacing: 8) {
                weekdayOverrideLabel(weekday, hasOverride: hasOverride)
                weekdayOverrideControls(weekday, effective: effective, hasOverride: hasOverride)
            }
        }
    }

    private func weekdayOverrideLabel(_ weekday: Int, hasOverride: Bool) -> some View {
        Text(Self.weekdayName(weekday))
            .font(StrandFont.subhead)
            .foregroundStyle(hasOverride ? StrandPalette.textPrimary : StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func weekdayOverrideControls(_ weekday: Int, effective: Int, hasOverride: Bool) -> some View {
        HStack(spacing: 8) {
            if hasOverride {
                Button {
                    WindDownNudge.setWakeOverride(weekday: weekday, minutes: nil)
                    overrides[weekday] = nil
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear \(Self.weekdayName(weekday)) override")
                .accessibilityHint("Uses the default wake time")
            }
            DatePicker("\(Self.weekdayName(weekday)) wake time",
                       selection: overrideBinding(weekday, effective: effective),
                       displayedComponents: .hourAndMinute)
                .labelsHidden()
                .accessibilityLabel("\(Self.weekdayName(weekday)) wake time")
        }
    }

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

    private static func weekdayName(_ dow: Int) -> String {
        let names = [String(localized: "Sunday"), String(localized: "Monday"), String(localized: "Tuesday"),
                     String(localized: "Wednesday"), String(localized: "Thursday"), String(localized: "Friday"),
                     String(localized: "Saturday")]
        return (1...7).contains(dow) ? names[dow - 1] : String(localized: "Day \(dow)")
    }

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

    nonisolated static func windDownTimeLabel(
        _ minutes: Int,
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        SleepAlarmTime.clock(minutes, locale: locale, calendar: calendar, timeZone: timeZone)
    }

    private var alarmWeekdayPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: alarmWeekdayColumns, spacing: 6) {
                ForEach(Self.weekdayOrder, id: \.self) { dow in
                    let selected = Self.alarmWeekdayIsSelected(dow, in: behavior.smartAlarmWeekdays)
                    Button {
                            behavior.smartAlarmWeekdays = Self.alarmToggledWeekday(
                                dow, in: behavior.smartAlarmWeekdays
                            )
                    } label: {
                        Text(Self.alarmWeekdayInitial(dow))
                            .font(StrandFont.caption)
                            .foregroundStyle(selected ? StrandPalette.surfaceBase : StrandPalette.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(selected ? StrandPalette.accent : StrandPalette.surfaceInset,
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Self.weekdayName(dow))
                        .accessibilityValue(selected ? "Selected" : "Not selected")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityHint("Double-tap to \(selected ? "exclude" : "include") this day")
                }
            }
            Text(Self.alarmWeekdaySummary(behavior.smartAlarmWeekdays))
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var alarmWeekdayColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 44), spacing: 6),
            count: dynamicTypeSize.isAccessibilitySize ? 4 : 7
        )
    }

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

    nonisolated static func alarmWeekdayIsSelected(_ dow: Int, in days: Set<Int>) -> Bool {
        days.isEmpty || days.contains(dow)
    }

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

    nonisolated static func alarmWeekdaySummary(_ days: Set<Int>) -> String {
        if days.isEmpty || days.count == 7 { return String(localized: "Every day") }
        if days == Set(2...6) { return String(localized: "Weekdays") }
        if days == Set([1, 7]) { return String(localized: "Weekends") }
        return weekdayOrder.filter { days.contains($0) }.map { alarmWeekdayShort($0) }.joined(separator: ", ")
    }

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
