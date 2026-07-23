import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// Shared presentation and binding seams for every in-app alarm editor. The stored
/// source of truth for enabled/time/weekdays remains `BehaviorStore`; adaptive mode and
/// transactional side effects are owned by the app-root alarm runtime.
@MainActor
enum SleepAlarmEditorSupport {
    struct SchedulePresentation {
        let nextDate: Date
        let continuousMinutes: Int
        let dayLabel: String
        let isUpcomingSleepPeriod: Bool
    }

    static func schedule(at now: Date, behavior: BehaviorStore, calendar: Calendar = .current) -> SchedulePresentation? {
        guard let next = SmartAlarmSchedule.nextDate(
            minutes: behavior.smartAlarmMinutes,
            weekdays: behavior.smartAlarmWeekdays,
            after: now,
            calendar: calendar
        ) else { return nil }
        let nowComponents = calendar.dateComponents([.hour, .minute], from: now)
        let nowMinuteOfDay = (nowComponents.hour ?? 0) * 60 + (nowComponents.minute ?? 0)
        // Keep elapsed time grounded in the scheduler's real Date. Civil days at DST can be 23 or 25
        // hours, so `dayOffset * 1_440 + clock time` is not a valid presentation timeline.
        let elapsedMinutes = max(0, Int((next.timeIntervalSince(now) / 60).rounded(.up)))
        let continuous = nowMinuteOfDay + elapsedMinutes
        let label: String
        if calendar.isDateInToday(next) {
            label = String(localized: "Today")
        } else if calendar.isDateInTomorrow(next) {
            label = String(localized: "Tomorrow")
        } else {
            label = next.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        }
        return SchedulePresentation(
            nextDate: next,
            continuousMinutes: continuous,
            dayLabel: label,
            isUpcomingSleepPeriod: next.timeIntervalSince(now) <= 24 * 60 * 60
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

    static func wakeBinding(_ behavior: BehaviorStore, now: Date) -> Binding<Int> {
        Binding(
            get: {
                schedule(at: now, behavior: behavior)?.continuousMinutes
                    ?? behavior.smartAlarmMinutes
            },
            set: { proposedMinutes in
                guard let presentation = schedule(at: now, behavior: behavior) else { return }
                let delta = proposedMinutes - presentation.continuousMinutes
                guard let proposedDate = Calendar.current.date(
                    byAdding: .minute,
                    value: delta,
                    to: presentation.nextDate
                ), Calendar.current.isDate(proposedDate, inSameDayAs: presentation.nextDate)
                else { return }
                let components = Calendar.current.dateComponents([.hour, .minute], from: proposedDate)
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
        let nowMinutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        let plan = displayedPlan
        let selected = wakeModes.first { $0.id == alarmMode.mode.rawValue }
        let windowMinutes = selected?.windowMinutes ?? 0
        let schedule = SleepAlarmEditorSupport.schedule(at: date, behavior: behavior)
        let wake = schedule?.continuousMinutes ?? SleepAlarmTime.nextOccurrence(
            now: nowMinutes, timeOfDay: behavior.smartAlarmMinutes)
        let asleepBy = SleepAlarmTime.asleepByMinutes(
            wakeMinutes: wake,
            windowMinutes: windowMinutes,
            needMinutes: plan.minutes
        )

        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            SleepAlarmModuleCard(
                armed: $behavior.smartAlarmEnabled,
                modes: wakeModes,
                selectedModeId: SleepAlarmEditorSupport.modeBinding(alarmMode),
                wakeMinutes: SleepAlarmEditorSupport.wakeBinding(behavior, now: date),
                nowMinutes: nowMinutes,
                needMinutes: plan.minutes,
                wakeDayLabel: schedule?.dayLabel ?? String(localized: "No enabled day"),
                deliveryStatus: alarmRuntime.deliveryStatus,
                showsBedtimePlan: schedule?.isUpcomingSleepPeriod == true
            )

            if plan.isStartingEstimate {
                Text("Starting estimate — NOOP hasn't computed your personal Sleep Need yet.")
                    .font(StrandFont.micro)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .padding(.horizontal, 4)
            }

            if behavior.smartAlarmEnabled, schedule?.isUpcomingSleepPeriod == true {
                SleepPlanTimeline(
                    now: nowMinutes,
                    asleepBy: asleepBy,
                    windowStart: wake - windowMinutes,
                    alarm: wake
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
