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
            summarySection
            healthSection
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("todayDashboard.settings")
        .accessibilityValue(selectionAccessibilityValue)
        .navigationTitle("Today Dashboard")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton().accessibilityIdentifier("todayDashboard.edit") }
        #endif
        .onAppear(perform: normalizeHealthSelection)
    }

    private var summarySection: some View {
        Section {
            ForEach(summaryRows) { metric in
                summaryToggle(metric)
            }
            .onMove(perform: moveSummary)
        } header: {
            Text("Summary metrics")
        } footer: {
            Text("Choose at least one score for the summary row. Use Edit to change the order.")
        }
    }

    private var healthSection: some View {
        Section {
            ForEach(healthRows) { card in
                healthToggle(card)
            }
            .onMove(perform: moveHealth)
        } header: {
            Text("Health Monitor")
        } footer: {
            Text("Choose one to nine metrics. Use Edit to change the order. Missing readings show a dash. All metrics remain available from Today.")
        }
    }

    private func summaryToggle(_ metric: TodaySummaryMetric) -> some View {
        let enabled: Bool = summarySelection.contains(metric)
        let disabled: Bool = enabled && summarySelection.count == 1
        return Toggle(metric.title, isOn: summaryBinding(metric))
            .disabled(disabled)
            .accessibilityIdentifier("today.summary.\(metric.id)")
    }

    private func healthToggle(_ card: DashboardCard) -> some View {
        let enabled: Bool = healthSelection.contains(card)
        let disabled: Bool = (enabled && healthSelection.count == 1)
            || (!enabled && healthSelection.count == DashboardCardPrefs.maximumCount)
        return Toggle(card.title, isOn: healthBinding(card))
            .disabled(disabled)
            .accessibilityIdentifier("today.health.\(card.id)")
    }

    private func summaryBinding(_ metric: TodaySummaryMetric) -> Binding<Bool> {
        Binding<Bool>(
            get: { summarySelection.contains(metric) },
            set: { setSummary(metric, enabled: $0) }
        )
    }

    private func healthBinding(_ card: DashboardCard) -> Binding<Bool> {
        Binding<Bool>(
            get: { healthSelection.contains(card) },
            set: { setHealth(card, enabled: $0) }
        )
    }

    private var selectionAccessibilityValue: String {
        let summaryIDs: String = summarySelection.map(\.rawValue).joined(separator: ",")
        let healthIDs: String = healthSelection.map(\.rawValue).joined(separator: ",")
        return "summary:" + summaryIDs + ";health:" + healthIDs
    }

    private func normalizeHealthSelection() {
        // Preserve the same one-time migration even when Settings is opened before Today.
        if !healthNormalized {
            healthRaw = DashboardCardPrefs.encode(
                DashboardCardPrefs.migratedSelection(healthRaw, hydrationEnabled: hydrationEnabled))
            healthNormalized = true
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
