import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// Shared presentation and binding seams for every in-app alarm editor. The stored
/// source of truth remains `BehaviorStore`; this type owns no parallel alarm state.
@MainActor
enum SleepAlarmEditorSupport {
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

    static func modeBinding(_ behavior: BehaviorStore) -> Binding<String> {
        Binding(
            get: { behavior.smartAlarmMode.rawValue },
            set: { raw in
                guard let mode = SmartAlarmEvaluator.Mode(rawValue: raw) else { return }
                behavior.smartAlarmMode = mode
            }
        )
    }

    static func wakeBinding(_ behavior: BehaviorStore, nowMinutes: Int) -> Binding<Int> {
        Binding(
            get: {
                SleepAlarmTime.nextOccurrence(
                    now: nowMinutes,
                    timeOfDay: behavior.smartAlarmMinutes
                )
            },
            set: { continuousMinutes in
                behavior.smartAlarmMinutes = ((continuousMinutes % 1_440) + 1_440) % 1_440
            }
        )
    }
}

/// The fully editable alarm module embedded on Sleep. It uses the exact same
/// `BehaviorStore` fields as Alarms and delegates actuation to the single app-root
/// reconciler, so mounting both tabs cannot double-arm the strap.
struct SleepAlarmEditorSection: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var behavior: BehaviorStore
    @EnvironmentObject private var intelligence: IntelligenceEngine

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
        }
    }

    @ViewBuilder
    private func alarmModule(at date: Date) -> some View {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        let nowMinutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        let plan = displayedPlan
        let selected = wakeModes.first { $0.id == behavior.smartAlarmMode.rawValue }
        let windowMinutes = selected?.windowMinutes ?? 0
        let wake = SleepAlarmTime.nextOccurrence(
            now: nowMinutes,
            timeOfDay: behavior.smartAlarmMinutes
        )
        let asleepBy = SleepAlarmTime.asleepByMinutes(
            wakeMinutes: wake,
            windowMinutes: windowMinutes,
            needMinutes: plan.minutes
        )

        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            SleepAlarmModuleCard(
                armed: $behavior.smartAlarmEnabled,
                modes: wakeModes,
                selectedModeId: SleepAlarmEditorSupport.modeBinding(behavior),
                wakeMinutes: SleepAlarmEditorSupport.wakeBinding(behavior, nowMinutes: nowMinutes),
                nowMinutes: nowMinutes,
                needMinutes: plan.minutes
            )

            if plan.isStartingEstimate {
                Text("Starting estimate — NOOP hasn't computed your personal Sleep Need yet.")
                    .font(StrandFont.micro)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .padding(.horizontal, 4)
            }

            if behavior.smartAlarmEnabled {
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
