import SwiftUI
import StrandDesign
import StrandAnalytics

/// Saved schedules share one generation-safe runtime and one physical strap endpoint.
struct SmartAlarmView: View {
    @Environment(\.screenScaffoldPresentation) private var presentation
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var behavior: BehaviorStore
    @EnvironmentObject private var alarmRuntime: SmartAlarmRuntimeController
    @State private var editingAlarm: WakeAlarm?

    nonisolated private static let weekdayOrder = [2, 3, 4, 5, 6, 7, 1]

    var body: some View {
        Group {
            if presentation == .settingsDetail {
                NativeSettingsList {
                    Section("Wake alarms") { alarmRows; addButton }
                    Section("Delivery") { deliveryDetails; Button("Test alarm") { model.buzzStrapOnce() } }
                    Section { Text(Self.deliveryExplanation).font(.footnote).foregroundStyle(.secondary) }
                    Section { notificationsLink }
                }
                .navigationTitle("Alarms")
            } else {
                ScreenScaffold(title: "Alarms", subtitle: "Your wake schedule.") {
                    VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                        PaperCard {
                            VStack(alignment: .leading, spacing: 0) {
                                alarmRows
                                addButton.padding(.top, 12)
                            }
                        }
                        PaperCard {
                            VStack(alignment: .leading, spacing: 12) {
                                deliveryDetails
                                Button("Test alarm") { model.buzzStrapOnce() }
                            }
                        }
                        Text(Self.deliveryExplanation)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        notificationsLink
                    }
                }
                .toolbar(.hidden, for: .navigationBar)
            }
        }
        .sheet(item: $editingAlarm) { alarm in WakeAlarmEditor(alarm: alarm) }
        .task { alarmRuntime.refreshStatus() }
    }

    @ViewBuilder private var alarmRows: some View {
        if behavior.wakeAlarms.isEmpty {
            Text("No wake alarms").font(StrandFont.body).foregroundStyle(.secondary).padding(.vertical, 12)
        }
        ForEach(behavior.wakeAlarms) { alarm in
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(HStackLayout(spacing: 16))
            layout {
                Button { editingAlarm = alarm } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(SleepAlarmTime.clock(alarm.minutes))
                            .font(.system(.largeTitle, design: .default, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(alarm.enabled ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                        Text(Self.alarmWeekdaySummary(alarm.weekdays))
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                        if alarm.mode != .exactTime {
                            Text(alarm.mode == .sleepGoal ? "Sleep goal" : "In the green")
                                .font(StrandFont.caption).foregroundStyle(DomainTint.sleep.accent)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit alarm \(SleepAlarmTime.clock(alarm.minutes))")
                .accessibilityIdentifier("alarm.row.\(alarm.id.uuidString)")
                Toggle("Alarm \(SleepAlarmTime.clock(alarm.minutes))", isOn: Binding(
                    get: { behavior.wakeAlarms.first(where: { $0.id == alarm.id })?.enabled ?? false },
                    set: { behavior.setWakeAlarmEnabled(id: alarm.id, enabled: $0) }
                ))
                .labelsHidden()
                .accessibilityIdentifier("alarm.toggle.\(alarm.id.uuidString)")
            }
            .padding(.vertical, 14)
            if alarm.id != behavior.wakeAlarms.last?.id { Divider() }
        }
    }

    private var addButton: some View {
        Button {
            let minutes = ((behavior.wakeAlarms.last?.minutes ?? 410) + 10) % 1440
            editingAlarm = WakeAlarm(minutes: minutes)
        } label: { Label("Add alarm", systemImage: "plus.circle.fill") }
        .disabled(behavior.wakeAlarms.count >= WakeAlarmPlan.maximumAlarms)
        .accessibilityIdentifier("alarm.add")
        .accessibilityHint("Save up to five wake alarms")
    }

    private var deliveryDetails: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(alarmRuntime.deliveryStatus).font(StrandFont.subhead)
            Text("Phone backup: \(alarmRuntime.backupStatus)")
                .font(StrandFont.footnote).foregroundStyle(.secondary)
            if behavior.wakeAlarms.count >= WakeAlarmPlan.maximumAlarms {
                Text("Five alarms saved. Edit or delete an alarm to add another.")
                    .font(StrandFont.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var notificationsLink: some View {
        NavigationLink("Notifications") {
            NotificationSettingsView()
                .environment(\.screenScaffoldPresentation, .settingsDetail)
        }
    }

    private static let deliveryExplanation = String(localized: "The strap stores the next alarm only. To arm later strap alarms, Noop must run with the strap connected after each wake. Later alarms may not buzz while disconnected. Phone backup notifications are best effort and can be silenced by Focus or permissions. Keep a Clock alarm as your dependable backup.")

    nonisolated static func windDownTimeLabel(
        _ minutes: Int,
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        SleepAlarmTime.clock(minutes, locale: locale, calendar: calendar, timeZone: timeZone)
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
            guard days.count > 1 else { return days }
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

/// The draft stays local until Save. Closing the sheet leaves the saved schedule unchanged.
private struct WakeAlarmEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var behavior: BehaviorStore
    @EnvironmentObject private var intelligence: IntelligenceEngine
    @EnvironmentObject private var modeStore: SmartAlarmAdaptiveModeStore
    @State private var draft: WakeAlarm

    init(alarm: WakeAlarm) { _draft = State(initialValue: alarm) }

    private var isExisting: Bool { behavior.wakeAlarms.contains { $0.id == draft.id } }
    private var modes: [SleepAlarmWakeMode] {
        SleepAlarmEditorSupport.wakeModes(recoveryHistoryCount: intelligence.results.compactMap(\.recovery).count)
    }
    private var time: Binding<Date> {
        Binding(get: {
            Calendar.current.date(from: DateComponents(year: 2001, month: 1, day: 1,
                                                       hour: draft.minutes / 60, minute: draft.minutes % 60)) ?? Date()
        }, set: {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: $0)
            draft.minutes = (parts.hour ?? 7) * 60 + (parts.minute ?? 0)
        })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Wake time", selection: time, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel)
                        .accessibilityIdentifier("alarm.editor.time")
                    Toggle("Enabled", isOn: $draft.enabled)
                }
                Section("Repeat") {
                    ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { weekday in
                        Toggle(Calendar.current.weekdaySymbols[weekday - 1], isOn: Binding(
                            get: { SmartAlarmView.alarmWeekdayIsSelected(weekday, in: draft.weekdays) },
                            set: { _ in draft.weekdays = SmartAlarmView.alarmToggledWeekday(weekday, in: draft.weekdays) }
                        ))
                    }
                }
                Section {
                    Picker("Wake mode", selection: Binding(get: { draft.mode.rawValue }, set: {
                        if let mode = SmartAlarmEvaluator.Mode(rawValue: $0) { draft.mode = mode }
                    })) {
                        ForEach(modes) { mode in Text(mode.title).tag(mode.id).disabled(!mode.isAvailable) }
                    }
                    if let selected = modes.first(where: { $0.id == draft.mode.rawValue }) {
                        Text(selected.explanation).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if isExisting {
                    Section {
                        Button("Delete alarm", role: .destructive) {
                            behavior.deleteWakeAlarm(id: draft.id)
                            if !behavior.wakeAlarms.isEmpty { modeStore.mode = behavior.smartAlarmMode }
                            dismiss()
                        }
                        .accessibilityIdentifier("alarm.editor.delete")
                    }
                }
            }
            .navigationTitle(isExisting ? "Edit alarm" : "Add alarm")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("alarm.editor.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save alarm") {
                        if behavior.saveWakeAlarm(draft) {
                            if behavior.wakeAlarms.first?.id == draft.id { modeStore.mode = draft.mode }
                            dismiss()
                        }
                    }
                    .accessibilityIdentifier("alarm.editor.save")
                }
            }
        }
    }
}
