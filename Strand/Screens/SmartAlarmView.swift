import SwiftUI
import StrandDesign
import StrandAnalytics

/// Alarm controls: a strap-firmware endpoint plus best-effort adaptive evaluation and phone backup.
/// The UI owns no BLE/notification side effects; every editor writes shared state and the app-root
/// `SmartAlarmRuntimeController` reconciles one generation-safe configuration.
struct SmartAlarmView: View {
    @Environment(\.screenScaffoldPresentation) private var presentation
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var behavior: BehaviorStore
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var intelligence: IntelligenceEngine
    @EnvironmentObject private var alarmMode: SmartAlarmAdaptiveModeStore
    @EnvironmentObject private var alarmRuntime: SmartAlarmRuntimeController

    /// Calendar weekday numbers laid out Monday-first (Mon…Sun → 2,3,4,5,6,7,1), matching AutomationsView.
    nonisolated private static let weekdayOrder = [2, 3, 4, 5, 6, 7, 1]

    // MARK: - Promoted SleepAlarmModuleCard hero

    @State private var needMinutes: Double = SleepNeedV2.Config.production.defaultBaselineMinutes
    @State private var needIsStartingEstimate = true
    @State private var scheduleToolsExpanded = false

    var body: some View {
        Group {
            if presentation == .settingsDetail {
                nativeSettingsBody
            } else {
                ScreenScaffold(title: "Alarms",
                               subtitle: "Wake alarm controls.") {
                    VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                        alarmHeroSection
                        scheduleAndStrapTools
                        notificationsLink
                        honestyCard
                    }
                }
                .toolbar(.hidden, for: .navigationBar)
            }
        }
        .task(id: repo.refreshSeq) {
            await resolveCanonicalNeed()
            alarmRuntime.refreshStatus()
        }

    }

    private var nativeSettingsBody: some View {
        NativeSettingsList {
            Section {
                Toggle("Strap alarm", isOn: $behavior.smartAlarmEnabled)
                Picker("Wake mode", selection: SleepAlarmEditorSupport.modeBinding(alarmMode)) {
                    ForEach(wakeModes) { mode in
                        Text(mode.title).tag(mode.id).disabled(!mode.isAvailable)
                    }
                }
                DatePicker("Wake time", selection: alarmTimeBinding, displayedComponents: .hourAndMinute)
                LabeledContent("Backup notification", value: alarmRuntime.backupStatus)
                Button("Test Strap Alarm") { model.buzzStrapOnce() }
            } header: {
                Text("Wake alarm")
            } footer: {
                Text("The primary alarm is a silent strap vibration. Keep a Clock alarm as a dependable backup because notification delivery can be limited by Focus or permissions.")
            }

            Section {
                ForEach(Self.weekdayOrder, id: \.self) { weekday in
                    Toggle(
                        Self.weekdayName(weekday),
                        isOn: Binding(
                            get: { Self.alarmWeekdayIsSelected(weekday, in: behavior.smartAlarmWeekdays) },
                            set: { _ in
                                behavior.smartAlarmWeekdays = Self.alarmToggledWeekday(
                                    weekday,
                                    in: behavior.smartAlarmWeekdays
                                )
                            }
                        )
                    )
                }
            } header: {
                Text("Alarm days")
            } footer: {
                Text(Self.alarmWeekdaySummary(behavior.smartAlarmWeekdays))
            }

            Section {
                notificationsLink
            } footer: {
                Text("Wind-down and other reminders are managed in Notifications.")
            }

            if let evidence = alarmRuntime.evidence {
                Section("Last evaluation") {
                    LabeledContent("Decision", value: Self.decisionWord(evidence.decision))
                    Text(evidence.reason)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Sleep & alarm")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var notificationsLink: some View {
        NavigationLink("Notifications") {
            NotificationSettingsView()
                .environment(\.screenScaffoldPresentation, .settingsDetail)
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
        PaperCard {
            VStack(alignment: .leading, spacing: 16) {
                Toggle("Wake alarm", isOn: $behavior.smartAlarmEnabled)
                    .font(StrandFont.headline)
                ViewThatFits(in: .horizontal) {
                    DatePicker("Wake time", selection: alarmTimeBinding, displayedComponents: .hourAndMinute)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Wake time")
                        DatePicker("Wake time", selection: alarmTimeBinding, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .accessibilityLabel("Wake time")
                    }
                }
                .font(StrandFont.subhead)
                Divider()
                Picker("Wake mode", selection: SleepAlarmEditorSupport.modeBinding(alarmMode)) {
                    ForEach(wakeModes) { mode in
                        Text(mode.title).tag(mode.id).disabled(!mode.isAvailable)
                    }
                }
                .font(StrandFont.subhead)
                if let mode = wakeModes.first(where: { $0.id == alarmMode.mode.rawValue }) {
                    Text(mode.explanation)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                Text(alarmRuntime.deliveryStatus)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
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

    private static func weekdayName(_ dow: Int) -> String {
        let names = [String(localized: "Sunday"), String(localized: "Monday"), String(localized: "Tuesday"),
                     String(localized: "Wednesday"), String(localized: "Thursday"), String(localized: "Friday"),
                     String(localized: "Saturday")]
        return (1...7).contains(dow) ? names[dow - 1] : String(localized: "Day \(dow)")
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
