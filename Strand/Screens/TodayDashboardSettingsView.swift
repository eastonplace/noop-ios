import SwiftUI

/// Native Settings owns both display-only Today selections. No health data is changed here.
struct TodayDashboardSettingsView: View {
    @AppStorage(TodaySummaryPreferences.selectionKey) private var summaryRaw = ""
    @AppStorage(DashboardCardPrefs.selectionKey) private var healthRaw = ""
    @AppStorage(DashboardCardPrefs.normalizedV2Key) private var healthNormalized = false
    @AppStorage(HydrationStore.enabledKey) private var hydrationEnabled = false

    private var summarySelection: [TodaySummaryMetric] { TodaySummaryPreferences.decodeEnabled(summaryRaw) }
    private var healthSelection: [DashboardCard] {
        DashboardCardPrefs.decodeEnabled(healthRaw, hydrationEnabled: hydrationEnabled)
    }
    private var summaryRows: [TodaySummaryMetric] {
        summarySelection + TodaySummaryMetric.allCases.filter { !summarySelection.contains($0) }
    }
    private var healthRows: [DashboardCard] {
        healthSelection + DashboardCardPrefs.eligibleCards(hydrationEnabled: hydrationEnabled)
            .filter { !healthSelection.contains($0) }
    }

    var body: some View {
        NativeSettingsList {
            Section {
                ForEach(summaryRows) { metric in
                    let enabled = summarySelection.contains(metric)
                    Toggle(metric.title, isOn: Binding(
                        get: { summarySelection.contains(metric) },
                        set: { setSummary(metric, enabled: $0) }
                    ))
                    .disabled(enabled && summarySelection.count == 1)
                    .accessibilityIdentifier("today.summary.\(metric.id)")
                }
                .onMove(perform: moveSummary)
            } header: {
                Text("Summary metrics")
            } footer: {
                Text("Choose at least one score for the summary row. Use Edit to change the order.")
            }

            Section {
                ForEach(healthRows) { card in
                    let enabled = healthSelection.contains(card)
                    Toggle(card.title, isOn: Binding(
                        get: { healthSelection.contains(card) },
                        set: { setHealth(card, enabled: $0) }
                    ))
                    .disabled((enabled && healthSelection.count == 1)
                              || (!enabled && healthSelection.count == DashboardCardPrefs.maximumCount))
                    .accessibilityIdentifier("today.health.\(card.id)")
                }
                .onMove(perform: moveHealth)
            } header: {
                Text("Health Monitor")
            } footer: {
                Text("Choose one to nine metrics. Use Edit to change the order. Missing readings show a dash. All metrics remain available from Today.")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("todayDashboard.settings")
        .accessibilityValue("summary:" + summarySelection.map(\.rawValue).joined(separator: ",")
                            + ";health:" + healthSelection.map(\.rawValue).joined(separator: ","))
        .navigationTitle("Today Dashboard")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton().accessibilityIdentifier("todayDashboard.edit") }
        #endif
        .onAppear {
            // Preserve the same one-time migration even when Settings is opened before Today.
            if !healthNormalized {
                healthRaw = DashboardCardPrefs.encode(
                    DashboardCardPrefs.migratedSelection(healthRaw, hydrationEnabled: hydrationEnabled))
                healthNormalized = true
            }
        }
    }

    private func setSummary(_ metric: TodaySummaryMetric, enabled: Bool) {
        var selection = summarySelection
        if enabled {
            if !selection.contains(metric) { selection.append(metric) }
        } else if selection.count > 1 {
            selection.removeAll { $0 == metric }
        }
        summaryRaw = TodaySummaryPreferences.encode(selection)
    }

    private func moveSummary(from offsets: IndexSet, to destination: Int) {
        var rows = summaryRows
        rows.move(fromOffsets: offsets, toOffset: destination)
        summaryRaw = TodaySummaryPreferences.encode(rows.filter { summarySelection.contains($0) })
    }

    private func setHealth(_ card: DashboardCard, enabled: Bool) {
        var selection = healthSelection
        if enabled {
            if !selection.contains(card), selection.count < DashboardCardPrefs.maximumCount { selection.append(card) }
        } else if selection.count > 1 {
            selection.removeAll { $0 == card }
        }
        healthRaw = DashboardCardPrefs.encode(selection)
    }

    private func moveHealth(from offsets: IndexSet, to destination: Int) {
        var rows = healthRows
        rows.move(fromOffsets: offsets, toOffset: destination)
        healthRaw = DashboardCardPrefs.encode(rows.filter { healthSelection.contains($0) })
    }
}
