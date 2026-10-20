import SwiftUI
import UserNotifications
import StrandAnalytics
import StrandDesign

/// All phone reminder choices live here; wrist behavior and firmware alarm remain linked editors.
struct NotificationSettingsView: View {
    @ObservedObject private var preferences = NotificationPreferences.shared
    @ObservedObject private var coordinator = NotificationCoordinator.shared
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var repo: Repository
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var authorization: UNAuthorizationStatus = .notDetermined
    @State private var permissionError: String?
    @State private var previewEssentials = false
    private let weekdays = [2, 3, 4, 5, 6, 7, 1]

    var body: some View {
        NativeSettingsList {
            Section {
                LabeledContent("Notification permission", value: permissionLabel)
                if authorization == .notDetermined {
                    Button("Enable notifications") { Task { await requestPermission() } }
                }
                #if os(iOS)
                Button("Open system notification settings") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                }
                #endif
                if let permissionError { Text(permissionError).foregroundStyle(.secondary) }
                if let status = coordinator.setupStatus { Text(status).foregroundStyle(.secondary) }
            } header: { Text("Delivery status") } footer: {
                Text("Your choices are saved even when system permission is off. Focus and system settings can delay delivery. New notifications are quiet by default.")
            }
            Section {
                Button("Preview Essentials") { previewEssentials = true }
            } footer: {
                Text("Save morning and workout summary choices. Phone summaries wait for current-data and sleep verification. Workout results are available with In app. Your chosen reminders and device alerts keep their existing settings.")
            }
            Section {
                modePicker("Morning summary", group: .morningSummary)
                Toggle("Wind-down reminder", isOn: $preferences.windDownEnabled)
                if preferences.windDownEnabled {
                    DatePicker("Default wake time", selection: time($preferences.windDownWakeMinutes), displayedComponents: .hourAndMinute)
                    Stepper("Wind-down lead: \(preferences.windDownLeadMinutes) min", value: $preferences.windDownLeadMinutes, in: 0...120, step: 5)
                    NavigationLink("Wake time by weekday") { windDownDays }
                    Text("One reminder each evening, calculated from the next wake time, current Sleep Need and your chosen lead.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                NavigationLink("Wake alarm") { SmartAlarmView().environment(\.screenScaffoldPresentation, .settingsDetail) }
            } header: { Text("Sleep") } footer: {
                Text("Your morning summary choice is saved. Delivery waits for current-data and sleep verification. Wind-down reminders use generic copy and your chosen schedule.")
            }
            Section {
                modePicker("Scheduled workout", group: .workoutPlan, allowsInApp: false)
                if preferences.mode(for: .workoutPlan) == .notify {
                    Stepper("Remind me \(preferences.workoutReminderLeadMinutes) min before", value: $preferences.workoutReminderLeadMinutes, in: 0...120, step: 5)
                    Text("One reminder per workout with a saved date and time. Reminders are prepared seven days ahead and refreshed when Noop opens. Edit a workout's schedule in Lift.").font(.footnote).foregroundStyle(.secondary)
                }
                modePicker("Workout summary", group: .workoutSummary)
                modePicker("Daily strain target", group: .strainTarget)
            } header: { Text("Training") } footer: {
                Text("Summary and strain target choices are saved. Phone summaries wait for sleep verification; strain target alerts also wait for current-data verification. Choose In app for completed-workout results. A scheduled reminder opens your plan and never starts a workout.")
            }
            Section {
                modePicker("Journal check-in", group: .journalCheckIn, allowsInApp: false)
                DatePicker("Check-in time", selection: time($preferences.journalMinutes), displayedComponents: .hourAndMinute)
                NavigationLink("Check-in days") { journalDays }
                Text(preferences.journalWeekdays.isEmpty ? "Choose at least one day to schedule a reminder." : "Up to \(preferences.journalWeekdays.count) reminders each week. Completed entries are skipped when Noop checks your schedule.")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: { Text("Habits") } footer: {
                Text("Check-ins are prepared seven days ahead and refreshed when Noop opens. Hiding Journal does not cancel a chosen check-in. Breathe and Hydrate have no automatic schedule here.")
            }
            Section {
                Toggle("Low and full battery alerts", isOn: $preferences.batteryAlerts)
                Toggle("Predictive battery reminders", isOn: $preferences.batteryPredictiveAlerts)
            } header: { Text("Device") } footer: {
                Text("Existing battery choices are preserved. Related low-battery and runtime warnings share one charging episode. A charge warning can be delayed once by 15 minutes while it remains current.")
            }
            Section {
                modePicker("Weekly review", group: .weeklyReview, allowsInApp: false)
                Picker("Review day", selection: $preferences.weeklyReviewWeekday) {
                    ForEach(weekdays, id: \.self) { Text(weekdayName($0)).tag($0) }
                }
                DatePicker("Review time", selection: time($preferences.weeklyReviewMinutes), displayedComponents: .hourAndMinute)
            } header: { Text("Reviews") } footer: {
                Text("At most one reminder each week. Weekly and wind-down reminders repeat without opening Noop. Review details require a complete period with enough valid data.")
            }
            Section {
                Toggle("Health-pattern alerts", isOn: $preferences.illnessWatch)
                    .onChange(of: preferences.illnessWatch) { _, _ in model.reevaluateIllness() }
            } header: { Text("Recovery") } footer: {
                Text("Your existing choice is preserved. Health-pattern phone alerts wait for current-data and sleep verification. Patterns are informational, not diagnoses.")
            }
            Section {
                Toggle("Proactive notifications", isOn: $preferences.proactiveEnabled)
                Toggle("Preview new advice without sending", isOn: $preferences.dryRunEnabled)
                Toggle("Quiet hours for proactive advice", isOn: $preferences.quietHoursEnabled)
                if preferences.quietHoursEnabled {
                    DatePicker("Quiet hours start", selection: time($preferences.quietStartMinutes), displayedComponents: .hourAndMinute)
                    DatePicker("Quiet hours end", selection: time($preferences.quietEndMinutes), displayedComponents: .hourAndMinute)
                }
                Toggle("Show health details in previews", isOn: $preferences.showHealthDetails)
            } header: { Text("Timing & privacy") } footer: {
                Text("Proactive advice is limited to 2 notices per day, 10 per rolling week and 3 hours between notices. Turn it off to pause advice while keeping chosen reminders and wake alarms. Preview mode records new advice locally without sending it. Private previews are the default; sensitive journal details are never included. iOS preview settings still apply.")
            }
            Section {
                NavigationLink("Wrist alerts & actions") { AutomationsView().environment(\.screenScaffoldPresentation, .settingsDetail) }
            } footer: {
                Text("Manage inactivity reminders, stress check-ins, coaching and physical strap actions.")
            }
        }
        .confirmationDialog("Choose Essentials?", isPresented: $previewEssentials, titleVisibility: .visible) {
            Button("Use Essentials") {
                preferences.setMode(.notify, for: .morningSummary)
                preferences.setMode(.notify, for: .workoutSummary)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Save Notify for morning and completed-workout summaries. Phone delivery waits for current-data and sleep verification. When available, summaries share a limit of 2 proactive notices per day, 10 per rolling week, with 3 hours between them. You can choose In app for workout results now. No timed reminders are added.")
        }
        .navigationTitle("Notifications")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            await refreshPermission()
            let plan = await repo.canonicalSleepNeedPlan(onOrBefore: Repository.localDayKey(Date()))
            WindDownNudge.updateCanonicalNeedMinutes(plan.minutes)
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await refreshPermission() } } }
    }

    private var windDownDays: some View {
        List {
            ForEach(weekdays, id: \.self) { day in
                Section(weekdayName(day)) {
                    Toggle("Use a different wake time", isOn: Binding(get: { preferences.windDownPerDayWakeMinutes[day] != nil }, set: { on in
                        var map = preferences.windDownPerDayWakeMinutes
                        map[day] = on ? preferences.windDownWakeMinutes : nil
                        preferences.windDownPerDayWakeMinutes = map
                    }))
                    if preferences.windDownPerDayWakeMinutes[day] != nil {
                        DatePicker("Wake time", selection: time(Binding(get: { preferences.windDownPerDayWakeMinutes[day] ?? preferences.windDownWakeMinutes }, set: { value in
                            var map = preferences.windDownPerDayWakeMinutes; map[day] = value; preferences.windDownPerDayWakeMinutes = map
                        })), displayedComponents: .hourAndMinute)
                    }
                }
            }
        }.navigationTitle("Wake time by weekday")
    }
    private var journalDays: some View {
        List {
            ForEach(weekdays, id: \.self) { day in
                Toggle(weekdayName(day), isOn: Binding(get: { preferences.journalWeekdays.contains(day) }, set: { on in
                    var days = preferences.journalWeekdays
                    if on { days.insert(day) } else { days.remove(day) }
                    preferences.journalWeekdays = days
                }))
            }
        }.navigationTitle("Check-in days")
    }
    private func modePicker(_ title: LocalizedStringKey, group: NotificationGroup, allowsInApp: Bool = true) -> some View {
        Picker(title, selection: Binding(get: { preferences.mode(for: group) }, set: { preferences.setMode($0, for: group) })) {
            Text("Off").tag(NotificationDeliveryMode.off)
            if allowsInApp { Text("In app").tag(NotificationDeliveryMode.inApp) }
            Text("Notify").tag(NotificationDeliveryMode.notify)
        }
    }
    private func weekdayName(_ day: Int) -> String { Calendar.current.weekdaySymbols[day - 1] }
    private func time(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(get: { Calendar.current.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60, second: 0, of: Date()) ?? Date() }, set: {
            let value = Calendar.current.dateComponents([.hour, .minute], from: $0)
            minutes.wrappedValue = (value.hour ?? 0) * 60 + (value.minute ?? 0)
        })
    }
    private var permissionLabel: String {
        switch authorization {
        case .authorized: return String(localized: "Allowed")
        case .provisional: return String(localized: "Quiet delivery")
        case .ephemeral: return String(localized: "Temporary permission")
        case .denied: return String(localized: "Off in system settings")
        case .notDetermined: return String(localized: "Not requested")
        @unknown default: return String(localized: "Unavailable")
        }
    }
    private func refreshPermission() async { authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }
    private func requestPermission() async {
        do { _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
        catch { permissionError = String(localized: "Permission could not be requested. Open system notification settings to try again.") }
        await refreshPermission()
        NotificationCenter.default.post(name: .notificationPreferencesDidChange, object: preferences)
    }
}
