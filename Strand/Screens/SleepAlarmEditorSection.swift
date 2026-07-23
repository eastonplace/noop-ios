import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// Shared presentation and binding seams for every in-app alarm editor. The stored
/// source of truth for enabled/time/weekdays remains `BehaviorStore`; adaptive mode and
/// transactional side effects are owned by the app-root alarm runtime.
@MainActor
enum SleepAlarmEditorSupport {
    struct SchedulePresentation: Equatable, Sendable {
        /// The scheduler's authoritative civil-time endpoint. Display and day identity must always derive
        /// from this Date rather than by wrapping an elapsed-duration axis at 1,440 minutes.
        let endpoint: Date
        /// A display/timeline coordinate whose modulo-1,440 clock is the endpoint's real calendar clock.
        /// Its distance from `nowAxisMinutes` is derived from `endpoint.timeIntervalSince(now)`, so the
        /// relative countdown remains correct on 23-hour and 25-hour civil days.
        let wakeAxisMinutes: Int
        let nowAxisMinutes: Int
        let remainingSeconds: TimeInterval
        let dayLabel: String
        let isUpcomingSleepPeriod: Bool

        var remainingMinutes: Int {
            max(0, Int((remainingSeconds / 60).rounded(.up)))
        }

        func date(forAxisMinute axisMinute: Int) -> Date {
            endpoint.addingTimeInterval(TimeInterval(axisMinute - wakeAxisMinutes) * 60)
        }

        func clockLabel(
            for axisMinute: Int,
            locale: Locale = .autoupdatingCurrent,
            calendar inputCalendar: Calendar = .autoupdatingCurrent
        ) -> String {
            let calendar = inputCalendar
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return formatter.string(from: date(forAxisMinute: axisMinute))
                .replacingOccurrences(of: "\u{202F}", with: " ")
        }

        func wakeClock(
            locale: Locale = .autoupdatingCurrent,
            calendar: Calendar = .autoupdatingCurrent
        ) -> String {
            clockLabel(for: wakeAxisMinutes, locale: locale, calendar: calendar)
        }

        func voiceOverWakeTimeValue(
            locale: Locale = .autoupdatingCurrent,
            calendar: Calendar = .autoupdatingCurrent
        ) -> String {
            String(localized: "Wake time \(wakeClock(locale: locale, calendar: calendar)), \(dayLabel)")
        }
    }

    static func schedule(
        at now: Date,
        behavior: BehaviorStore,
        calendar: Calendar = .current
    ) -> SchedulePresentation? {
        schedule(
            at: now,
            minutes: behavior.smartAlarmMinutes,
            weekdays: behavior.smartAlarmWeekdays,
            calendar: calendar
        )
    }

    nonisolated static func schedule(
        at now: Date,
        minutes: Int,
        weekdays: Set<Int>,
        calendar inputCalendar: Calendar,
        locale: Locale = .autoupdatingCurrent
    ) -> SchedulePresentation? {
        let calendar = inputCalendar
        guard let endpoint = SmartAlarmSchedule.nextDate(
            minutes: minutes,
            weekdays: weekdays,
            after: now,
            calendar: calendar
        ) else { return nil }

        let endpointComponents = calendar.dateComponents([.hour, .minute], from: endpoint)
        let endpointMinuteOfDay = (endpointComponents.hour ?? 0) * 60 + (endpointComponents.minute ?? 0)
        let civilDayOffset = max(0, calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: endpoint)
        ).day ?? 0)
        let wakeAxisMinutes = civilDayOffset * 1_440 + endpointMinuteOfDay
        let remainingSeconds = max(0, endpoint.timeIntervalSince(now))
        let remainingMinutes = max(0, Int((remainingSeconds / 60).rounded(.up)))

        let label: String
        if civilDayOffset == 0 {
            label = String(localized: "Today")
        } else if civilDayOffset == 1 {
            label = String(localized: "Tomorrow")
        } else {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate("EEEE MMM d")
            label = formatter.string(from: endpoint)
        }
        return SchedulePresentation(
            endpoint: endpoint,
            wakeAxisMinutes: wakeAxisMinutes,
            nowAxisMinutes: wakeAxisMinutes - remainingMinutes,
            remainingSeconds: remainingSeconds,
            dayLabel: label,
            isUpcomingSleepPeriod: remainingSeconds <= 24 * 60 * 60
        )
    }

    static func wakeModes(recoveryHistoryCount: Int) -> [SleepAlarmWakeMode] {
        let greenAvailability: SleepAlarmWakeMode.Availability =
            recoveryHistoryCount >= RecoveryForecaster.minBaselineNights
                ? .available
                : .unavailable(
                    reason: String(
                        localized: "Needs a few more scored nights of Recovery to forecast tonight (\(recoveryHistoryCount) of \(RecoveryForecaster.minBaselineNights) so far)."
                    )
                )

        return [
            SleepAlarmWakeMode(
                id: SmartAlarmEvaluator.Mode.exactTime.rawValue,
                title: String(localized: "Exact time"),
                explanation: String(
                    localized: "Wakes you with the strap's firmware alarm at exactly the time you set — no window."
                ),
                windowMinutes: 0
            ),
            SleepAlarmWakeMode(
                id: SmartAlarmEvaluator.Mode.sleepGoal.rawValue,
                title: String(localized: "Sleep goal"),
                explanation: String(
                    localized: "Best-effort early wake once tonight's Sleep Need is banked, inside a \(SmartAlarmEvaluator.adaptiveWindowMinutes)-minute window. The strap's exact-time alarm stays armed as the fail-safe; early wake is best-effort on iOS, never guaranteed."
                ),
                windowMinutes: SmartAlarmEvaluator.adaptiveWindowMinutes
            ),
            SleepAlarmWakeMode(
                id: SmartAlarmEvaluator.Mode.inTheGreen.rawValue,
                title: String(localized: "In the green"),
                explanation: String(
                    localized: "Best-effort early wake once tomorrow's Recovery is projected to land in the green, inside a \(SmartAlarmEvaluator.adaptiveWindowMinutes)-minute window. Same fail-safe endpoint and same iOS best-effort caveat as Sleep goal."
                ),
                windowMinutes: SmartAlarmEvaluator.adaptiveWindowMinutes,
                availability: greenAvailability
            ),
        ]
    }

    static func modeBinding(_ modeStore: SmartAlarmAdaptiveModeStore) -> Binding<String> {
        Binding(
            get: { modeStore.mode.rawValue },
            set: { raw in
                guard let mode = SmartAlarmEvaluator.Mode(rawValue: raw) else { return }
                modeStore.mode = mode
            }
        )
    }

    /// The compact +/- editor is a clock-time editor for one recurring weekday occurrence, not a date
    /// editor. Reject a nudge that crosses that occurrence's midnight; otherwise modulo persistence would
    /// turn Monday 00:02 minus five minutes into Monday 23:57 (almost a day later).
    nonisolated static func sameOccurrenceMinute(current: Int, proposed: Int) -> Int? {
        guard current >= 0 else { return nil }
        let dayStart = (current / 1_440) * 1_440
        guard proposed >= dayStart, proposed < dayStart + 1_440 else { return nil }
        return proposed
    }

    /// Recurring schedules persist only wall-clock components. Crossing a timezone-offset transition
    /// would discard which repeated-hour occurrence the user was editing, so the compact nudge rejects it.
    nonisolated static func preservesTimeZoneOccurrence(
        endpoint: Date,
        proposed: Date,
        calendar: Calendar
    ) -> Bool {
        calendar.isDate(proposed, inSameDayAs: endpoint)
            && calendar.timeZone.secondsFromGMT(for: proposed)
                == calendar.timeZone.secondsFromGMT(for: endpoint)
    }

    static func wakeBinding(_ behavior: BehaviorStore, now: Date) -> Binding<Int> {
        Binding(
            get: {
                schedule(at: now, behavior: behavior)?.wakeAxisMinutes
                    ?? behavior.smartAlarmMinutes
            },
            set: { proposedMinutes in
                guard let presentation = schedule(at: now, behavior: behavior) else { return }
                let delta = proposedMinutes - presentation.wakeAxisMinutes
                let calendar = Calendar.current
                guard let proposedDate = calendar.date(
                    byAdding: .minute,
                    value: delta,
                    to: presentation.endpoint
                ), preservesTimeZoneOccurrence(
                    endpoint: presentation.endpoint,
                    proposed: proposedDate,
                    calendar: calendar
                )
                else { return }
                let components = calendar.dateComponents([.hour, .minute], from: proposedDate)
                behavior.smartAlarmMinutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
            }
        )
    }
}

/// The fully editable alarm module embedded on Sleep. It uses the exact same
/// `BehaviorStore` fields as Alarms and delegates actuation to the single app-root
/// runtime, so mounting both tabs cannot double-arm the strap.
struct SleepAlarmEditorSection: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var behavior: BehaviorStore
    @EnvironmentObject private var intelligence: IntelligenceEngine
    @EnvironmentObject private var alarmMode: SmartAlarmAdaptiveModeStore
    @EnvironmentObject private var alarmRuntime: SmartAlarmRuntimeController

    @State private var needPlan: CanonicalSleepNeedPlan?

    private var displayedPlan: CanonicalSleepNeedPlan {
        needPlan ?? CanonicalSleepNeedPlan(
            minutes: Double(WindDownNudge.sleepNeedMinutes),
            isStartingEstimate: !WindDownNudge.hasCachedCanonicalNeed
        )
    }

    private var recoveryHistoryCount: Int {
        intelligence.results.compactMap(\.recovery).count
    }

    private var wakeModes: [SleepAlarmWakeMode] {
        SleepAlarmEditorSupport.wakeModes(recoveryHistoryCount: recoveryHistoryCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                alarmModule(at: context.date)
            }

            NavigationLink {
                SmartAlarmView()
                    .environment(\.screenScaffoldNavigationRole, .detail)
            } label: {
                SettingsRow(
                    icon: "slider.horizontal.3",
                    title: "Schedule, wind-down & strap tools",
                    subtitle: "Weekdays, test buzz, backup status, and reminder settings",
                    showsChevron: true
                )
                .padding(.horizontal, 13)
                .padding(.vertical, 2)
                .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(StrandPalette.hairline, lineWidth: 1)
                }
            }
            .buttonStyle(PaperPressStyle())
        }
        .task(id: repo.refreshSeq) {
            await reloadCanonicalNeed()
            alarmRuntime.refreshStatus()
        }
    }

    @ViewBuilder
    private func alarmModule(at date: Date) -> some View {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        let currentMinuteOfDay = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        let plan = displayedPlan
        let selected = wakeModes.first { $0.id == alarmMode.mode.rawValue }
        let windowMinutes = selected?.windowMinutes ?? 0
        let schedule = SleepAlarmEditorSupport.schedule(at: date, behavior: behavior)
        let wake = schedule?.wakeAxisMinutes ?? SleepAlarmTime.nextOccurrence(
            now: currentMinuteOfDay, timeOfDay: behavior.smartAlarmMinutes)
        let now = schedule?.nowAxisMinutes ?? currentMinuteOfDay
        let asleepBy = SleepAlarmTime.asleepByMinutes(
            wakeMinutes: wake,
            windowMinutes: windowMinutes,
            needMinutes: plan.minutes
        )
        let clockLabel: (Int) -> String = { minute in
            schedule?.clockLabel(for: minute) ?? SleepAlarmTime.clock(minute)
        }

        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            SleepAlarmModuleCard(
                armed: $behavior.smartAlarmEnabled,
                modes: wakeModes,
                selectedModeId: SleepAlarmEditorSupport.modeBinding(alarmMode),
                wakeMinutes: SleepAlarmEditorSupport.wakeBinding(behavior, now: date),
                nowMinutes: now,
                needMinutes: plan.minutes,
                wakeDayLabel: schedule?.dayLabel ?? String(localized: "No enabled day"),
                deliveryStatus: alarmRuntime.deliveryStatus,
                showsBedtimePlan: schedule?.isUpcomingSleepPeriod == true,
                clockLabel: clockLabel
            )

            if plan.isStartingEstimate {
                Text("Starting estimate — NOOP hasn't computed your personal Sleep Need yet.")
                    .font(StrandFont.micro)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .padding(.horizontal, 4)
            }

            if behavior.smartAlarmEnabled, schedule?.isUpcomingSleepPeriod == true {
                SleepPlanTimeline(
                    now: now,
                    asleepBy: asleepBy,
                    windowStart: wake - windowMinutes,
                    alarm: wake,
                    clockLabel: clockLabel
                )
            }
        }
    }

    @MainActor
    private func reloadCanonicalNeed() async {
        let plan = await repo.canonicalSleepNeedPlan(
            onOrBefore: Repository.localDayKey(Date())
        )
        guard !Task.isCancelled else { return }
        needPlan = plan
        WindDownNudge.updateCanonicalNeedMinutes(plan.minutes)
    }
}
