import SwiftUI
import StrandDesign
import WhoopStore

/// Native journal logging, yes/no chips and numeric fields for the merged behaviour catalog plus a
/// custom-question field, hosted at the top of Insights. Answers write under
/// `Repository.journalDeviceId` ("noop-journal"), NEVER the imported source, so a CSV re-import can't
/// clobber them and clearing is safe (imported rows are never touched). Tri-state: tapping the selected
/// chip again clears the answer. Day attribution follows the importer's wake-day convention, answers
/// describe the night and day leading into the selected morning, so logged days line up with imported
/// history.
///
/// v2 (#322): items sit under collapsible groups (Nutrition / Supplements / …); an item can be a
/// numeric value (with a unit) instead of a toggle; and custom items can be renamed / regrouped /
/// converted / reordered in edit mode. The stored KEY (`canonical`) never changes on a rename, so all
/// history, logged and imported, stays joined under the original question.
struct JournalLogCard: View {
    @EnvironmentObject var repo: Repository
    /// The journal catalog is single-user state owned here (UserDefaults-backed), so hosting the card
    /// needs no app-level injection.
    @StateObject private var catalog = JournalCatalogStore()

    /// Distinct imported question strings (from InsightsView's load), adopted into the catalog so
    /// logged answers and imported history group under the same behaviour.
    let importedQuestions: [String]
    /// question → answeredYes for the selected day, native rows only (drives the chip state).
    let answers: [String: Bool]
    /// question → numeric value for the selected day, native rows only (drives the numeric fields).
    let numericAnswers: [String: Double]
    @Binding var dayOffset: Int            // -1 = tomorrow, 0 = today, 1 = yesterday
    /// Notification-hosted entries retain the civil record key across midnight and timezone changes.
    @Binding private var selectedDayKey: String?
    /// `.full` is the Insights card with its own header, day pills and notes. `.embedded` is for a host
    /// that already owns the day (one picker) and its own heading: only the note row and the questions remain.
    enum Chrome { case full, embedded }
    let chrome: Chrome
    let onChanged: () -> Void              // parent re-runs load() after a write

    init(importedQuestions: [String], answers: [String: Bool],
         numericAnswers: [String: Double] = [:], dayOffset: Binding<Int>,
         selectedDayKey: Binding<String?> = .constant(nil), chrome: Chrome = .full,
         onChanged: @escaping () -> Void) {
        self.chrome = chrome
        self.importedQuestions = importedQuestions
        self.answers = answers
        self.numericAnswers = numericAnswers
        self._dayOffset = dayOffset
        self._selectedDayKey = selectedDayKey
        self.onChanged = onChanged
    }

    @State private var customDraft = ""
    @State private var customIsNumeric = false
    @State private var customGroup: JournalGroup = .other
    /// Edit mode: swaps the answer controls for rename/group/convert/remove and reveals hidden items.
    @State private var editing = false
    /// Collapsed groups (persisted per group).
    @AppStorage("journal.collapsedGroups") private var collapsedGroupsRaw = ""
    /// The item being renamed (drives the rename sheet).
    @State private var renaming: JournalCatalogItem?
    @State private var renameDraft = ""
    /// The edit-mode item awaiting the shared consequence-first hold gate.
    @State private var removing: JournalCatalogItem?
    /// Typed/dictated entries remain transient until their sheet's explicit reviewed save.
    @State private var composingEntry: JournalEntryPresentation?
    /// Kit 44 adapters. Both are loaded from production persistence; no fixture
    /// answers or synthetic streak days enter the component layer.
    @State private var selectedMood: Int?
    @State private var loggedWindow: [Bool] = []

    nonisolated static func entryDayKey(selectedDayKey: String?, dayOffset: Int, now: Date = Date(), calendar: Calendar = .current) -> String {
        if let selectedDayKey { return selectedDayKey }
        let date = calendar.date(byAdding: .day, value: -dayOffset, to: now) ?? now
        return Repository.localDayKey(date, calendar: calendar)
    }

    private var dayKey: String {
        Self.entryDayKey(selectedDayKey: selectedDayKey, dayOffset: dayOffset)
    }

    private var selectedDate: Date? {
        guard let selectedDayKey else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: selectedDayKey), formatter.string(from: date) == selectedDayKey else { return nil }
        return date
    }

    /// The resolved, grouped catalog for the current imported set. Hidden items included only while
    /// editing (so they can be restored in place).
    private var resolved: [JournalCatalogItem] {
        catalog.resolvedItems(imported: importedQuestions, includeHidden: editing)
    }

    /// Items grouped by their group, each group ordered by sortIndex then display.
    private func items(in group: JournalGroup) -> [JournalCatalogItem] {
        resolved.filter { $0.group == group }
            .sorted { ($0.sortIndex, $0.display) < ($1.sortIndex, $1.display) }
    }

    private var collapsedGroups: Set<String> {
        Set(collapsedGroupsRaw.split(separator: ",").map(String.init))
    }

    private func toggleCollapsed(_ group: JournalGroup) {
        var set = collapsedGroups
        if set.contains(group.rawValue) { set.remove(group.rawValue) } else { set.insert(group.rawValue) }
        collapsedGroupsRaw = set.sorted().joined(separator: ",")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            if chrome == .full {
                HStack(alignment: .center) {
                    SectionHeader("Journal", overline: "Log")
                    Spacer()
                    if editing {
                        pillButton("Done", selected: true) { editing = false }
                    } else {
                        pillButton("Edit", selected: false) { editing = true }
                        dayPill("Tomorrow", offset: -1)
                        dayPill("Today", offset: 0)
                        dayPill("Yesterday", offset: 1)
                    }
                }
                if let selectedDate {
                    Text(selectedDate.formatted(date: .complete, time: .omitted))
                        .font(.headline)
                        .accessibilityLabel("Journal date: \(selectedDate.formatted(date: .complete, time: .omitted))")
                }
            }
            PaperCard {
                VStack(alignment: .leading, spacing: 10) {
                    if chrome == .embedded && editing {
                        plainTextButton("Done") { editing = false }
                    }
                    if chrome == .full || editing {
                        Text(editing
                             ? "Rename, regroup, or remove an item to tidy your list. Renaming keeps the original question behind the scenes, so a WHOOP import still lines up. Custom items are deleted; built-in ones are hidden and can be restored below."
                             : dayOffset == -1
                             ? "Logging ahead for tomorrow: today's activities inform tomorrow's recovery, just as yesterday's are reflected in today's. Tomorrow's answers line up with tomorrow's morning."
                             : "Answers are about the night and day leading into this morning, the same attribution a WHOOP export uses, so logged and imported days line up.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !editing {
                        JournalComposeRow {
                            composingEntry = JournalEntryPresentation(day: dayKey, sourceIdentity: repo.journalEntrySourceIdentity)
                        }
                    }

                    ForEach(JournalGroup.displayOrder, id: \.self) { group in
                        groupBlock(group)
                    }

                    if chrome == .full {
                        if !editing {
                            Divider().overlay(StrandPalette.hairline).padding(.leading, 54)
                            JournalMoodRow(mood: moodBinding)
                            if !loggedWindow.isEmpty {
                                JournalStreakStrip(logged: loggedWindow)
                            }
                        }

                        Divider().overlay(StrandPalette.hairline)
                        addRow
                    } else if editing {
                        Divider().overlay(StrandPalette.hairline)
                        addRow
                    } else {
                        plainTextButton("Edit questions") { editing = true }
                    }
                }
            }
        }
        .sheet(item: $composingEntry) { entry in
            JournalEntryComposer(catalog: catalog, presentation: entry,
                                 importedQuestions: importedQuestions, currentDay: dayKey,
                                 onSaved: onChanged)
                .environmentObject(repo)
        }
        .sheet(item: $renaming) { item in renameSheet(item) }
        .sheet(item: $removing) { item in
            ZStack {
                StrandPalette.canvas.ignoresSafeArea()
                DestructiveGateCard(
                    title: item.custom
                        ? String(localized: "Delete this journal item?")
                        : String(localized: "Hide this journal item?"),
                    message: item.custom
                        ? String(localized: "Delete \(item.display)? Its existing logged history is kept under the original question, but the custom item will be removed from your journal.")
                        : String(localized: "Hide \(item.display)? Its history is kept, and you can restore the item from journal edit mode."),
                    confirmTitle: item.custom
                        ? String(localized: "Hold to delete")
                        : String(localized: "Hold to hide"),
                    completedTitle: item.custom
                        ? String(localized: "Deleted")
                        : String(localized: "Hidden"),
                    cancelTitle: String(localized: "Keep item"),
                    cancel: { removing = nil },
                    confirm: {
                        // Preserve the catalog's exact existing custom-delete / built-in-hide behavior.
                        catalog.remove(item.canonical)
                        removing = nil
                    }
                )
                .padding(20)
            }
            .presentationDetents([.height(350)])
            .presentationDragIndicator(.hidden)
        }
        .task(id: dayKey) { await loadJournalKitState() }
    }

    // MARK: - Group block

    @ViewBuilder private func groupBlock(_ group: JournalGroup) -> some View {
        let groupItems = items(in: group)
        // Empty groups hidden outside edit mode; in edit mode all six show so items can be moved in.
        if !groupItems.isEmpty || editing {
            let collapsed = collapsedGroups.contains(group.rawValue)
            VStack(alignment: .leading, spacing: 8) {
                Button { toggleCollapsed(group) } label: {
                    HStack(spacing: 6) {
                        Text(group.title.uppercased())
                            .font(StrandFont.overline)
                            .tracking(StrandFont.overlineTracking)
                            .foregroundStyle(StrandPalette.textTertiary)
                        Text("\(groupItems.count)")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                        Spacer()
                        Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(group.title), \(groupItems.count) items, \(collapsed ? "collapsed" : "expanded")")

                if !collapsed {
                    ForEach(groupItems) { item in itemRow(item) }
                }
            }
        }
    }

    // MARK: - Item row

    @ViewBuilder private func itemRow(_ item: JournalCatalogItem) -> some View {
        if editing {
            HStack {
                Text(verbatim: item.display)
                    .font(StrandFont.body)
                    .foregroundStyle(item.hidden ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                Spacer()
                editControls(item)
            }
        } else if item.kind.isNumeric {
            VStack(alignment: .trailing, spacing: 4) {
                JournalQuantityRow(
                    icon: journalIcon(for: item),
                    tint: journalTint(for: item),
                    title: item.display,
                    unit: item.kind.unitLabel ?? "",
                    value: numericBinding(for: item)
                )
                // Preserve #322's exact decimal-entry and clear tools. The kit's
                // stepper is primary; this compact editor keeps arbitrary doses reachable.
                numericField(item)
            }
        } else {
            JournalHabitToggle(
                icon: journalIcon(for: item),
                tint: journalTint(for: item),
                question: item.display,
                answer: answerBinding(for: item)
            )
        }
    }

    private func answerBinding(for item: JournalCatalogItem) -> Binding<Bool?> {
        Binding(
            get: { answers[item.canonical] },
            set: { next in
                Task {
                    if let next {
                        await repo.saveJournalAnswer(day: dayKey, question: item.canonical, answeredYes: next)
                    } else {
                        await repo.clearJournalAnswer(day: dayKey, question: item.canonical)
                    }
                    onChanged()
                    await loadJournalKitState()
                }
            }
        )
    }

    private func numericBinding(for item: JournalCatalogItem) -> Binding<Double?> {
        Binding(
            get: { numericAnswers[item.canonical] },
            set: { next in
                Task {
                    if let next {
                        await repo.saveJournalNumeric(day: dayKey, question: item.canonical, value: next)
                    } else {
                        await repo.clearJournalAnswer(day: dayKey, question: item.canonical)
                    }
                    onChanged()
                    await loadJournalKitState()
                }
            }
        )
    }

    private var moodBinding: Binding<Int?> {
        Binding(
            get: { selectedMood },
            set: { next in
                selectedMood = next
                guard let next else { return }
                Task { await repo.saveMood(day: dayKey, value: next) }
            }
        )
    }

    private func journalIcon(for item: JournalCatalogItem) -> String {
        switch item.group {
        case .nutrition: return item.kind.isNumeric ? "wineglass" : "fork.knife"
        case .supplements: return "pills.fill"
        case .health: return "heart.text.square.fill"
        case .behaviour: return "checkmark.circle.fill"
        case .lifestyle: return "moon.stars.fill"
        case .other: return "square.and.pencil"
        }
    }

    private func journalTint(for item: JournalCatalogItem) -> Color {
        switch item.group {
        case .nutrition: return StrandPalette.metricAmber
        case .supplements: return StrandPalette.metricCyan
        case .health: return StrandPalette.metricRose
        case .behaviour: return StrandPalette.journalAccent
        case .lifestyle: return StrandPalette.sleepAccent
        case .other: return StrandPalette.metricPurple
        }
    }

    @MainActor private func loadJournalKitState() async {
        selectedMood = await repo.mood(day: dayKey)
        let entries = await repo.journalEntries()
        let loggedDays = Set(entries.map(\.day))
        loggedWindow = JournalStreakSummary.window(loggedDays: loggedDays, endingOn: dayKey, days: 14)
    }

    // MARK: - Numeric field

    private func numericField(_ item: JournalCatalogItem) -> some View {
        let current = numericAnswers[item.canonical]
        return HStack(spacing: 6) {
            Spacer(minLength: 54)
            NumericLogField(
                value: current,
                placeholder: "—",
                onCommit: { v in commitNumeric(item.canonical, value: v) })
            .frame(width: 64)
            if let unit = item.kind.unitLabel, !unit.isEmpty {
                Text(verbatim: unit)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            if current != nil {
                Button {
                    Task { await repo.clearJournalAnswer(day: dayKey, question: item.canonical); onChanged() }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear \(item.display)")
            }
        }
    }

    private func commitNumeric(_ q: String, value: Double) {
        Task {
            await repo.saveJournalNumeric(day: dayKey, question: q, value: value)
            onChanged()
        }
    }

    // MARK: - Edit-mode controls

    private func editControls(_ item: JournalCatalogItem) -> some View {
        HStack(spacing: 10) {
            if item.hidden {
                pillButton("Restore", selected: false) { catalog.restore(item.canonical) }
            } else {
                Menu {
                    Button("Rename…") { startRename(item) }
                    Menu("Group") {
                        ForEach(JournalGroup.displayOrder, id: \.self) { g in
                            Button(g.title) { catalog.setGroup(item.canonical, to: g) }
                        }
                    }
                    if item.kind.isNumeric {
                        Button("Change to Yes/No") { catalog.setKind(item.canonical, to: .bool) }
                    } else {
                        Button("Change to Number") { catalog.setKind(item.canonical, to: .numeric(unitLabel: nil)) }
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Edit \(item.display)")

                removeButton(item)
            }
        }
    }

    /// Edit-mode control: delete a custom question / hide a built-in one. Tinted red to read as removal.
    private func removeButton(_ item: JournalCatalogItem) -> some View {
        Button { removing = item } label: {
            Image(systemName: "minus.circle.fill")
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.statusCritical)
        }
        .buttonStyle(.plain)
        .help(item.custom ? "Delete this custom item" : "Hide this item")
        .accessibilityLabel(item.custom ? "Delete \(item.display)" : "Hide \(item.display)")
    }

    // MARK: - Rename sheet

    private func startRename(_ item: JournalCatalogItem) {
        renameDraft = item.displayName ?? item.canonical
        renaming = item
    }

    private func renameSheet(_ item: JournalCatalogItem) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            Text("Rename item").font(StrandFont.headline)
            TextField("Display name", text: $renameDraft)
                .textFieldStyle(.roundedBorder)
            Text("History stays under the original question so WHOOP imports still line up.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: NoopMetrics.space3) {
                Button("Cancel") { renaming = nil }
                    .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
                Button("Save") {
                    catalog.rename(item.canonical, to: renameDraft)
                    renaming = nil
                }
                .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
            }
        }
        .padding(NoopMetrics.space4)
        .frame(minWidth: 320)
    }

    // MARK: - Add row

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Add a custom item…", text: $customDraft)
                    .textFieldStyle(.roundedBorder)
                pillButton(customIsNumeric ? "Number" : "Yes/No", selected: customIsNumeric) {
                    customIsNumeric.toggle()
                }
                Button("Add") {
                    let t = customDraft.trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty else { return }
                    catalog.addCustom(t,
                                      kind: customIsNumeric ? .numeric(unitLabel: nil) : .bool,
                                      group: customGroup)
                    customDraft = ""
                }
                .buttonStyle(ChipButtonStyle())
                .disabled(customDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Picker("Group", selection: $customGroup) {
                ForEach(JournalGroup.displayOrder, id: \.self) { g in
                    Text(g.title).tag(g)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityLabel("New item group")
        }
    }

    // MARK: - Controls

    private func dayPill(_ label: LocalizedStringKey, offset: Int) -> some View {
        let target = Self.entryDayKey(selectedDayKey: nil, dayOffset: offset)
        let isSelected = selectedDayKey.map { $0 == target } ?? (dayOffset == offset)
        return pillButton(label, selected: isSelected) {
            if selectedDayKey != nil { selectedDayKey = target }
            dayOffset = offset
            onChanged()   // reload the selected day's answers
        }
    }

    /// A plain accent-text action: no capsule, border or glass, with a 44pt tap area.
    private func plainTextButton(_ label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(StrandFont.subhead.weight(.semibold))
                .foregroundStyle(StrandPalette.accent)
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func answerPill(_ label: LocalizedStringKey, q: String, value: Bool) -> some View {
        let selected = answers[q] == value
        return pillButton(label, selected: selected) {
            Task {
                // Tri-state: re-tapping the filled chip clears the answer (natural-key delete,
                // scoped to "noop-journal", imported rows can never be removed this way).
                if selected {
                    await repo.clearJournalAnswer(day: dayKey, question: q)
                } else {
                    await repo.saveJournalAnswer(day: dayKey, question: q, answeredYes: value)
                }
                onChanged()
            }
        }
    }

    private func pillButton(_ label: LocalizedStringKey, selected: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(StrandFont.footnote)
                .foregroundStyle(selected ? StrandPalette.onLightFill : StrandPalette.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(selected ? StrandPalette.solidFill : Color.clear, in: Capsule())
                .overlay(Capsule().stroke(selected ? StrandPalette.solidFill : StrandPalette.hairlineStrong, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// A compact numeric log field: shows the current value or a ghost placeholder, commits a Double on
/// return / focus-out. Kept small so the numeric row reads like the yes/no pills.
private struct NumericLogField: View {
    let value: Double?
    let placeholder: String
    let onCommit: (Double) -> Void

    @State private var text = ""

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.center)
            .font(StrandFont.number(15))
            .onAppear { text = value.map(Self.format) ?? "" }
            .onChangeCompat(of: value) { v in text = v.map(Self.format) ?? "" }
            .onSubmit { commit() }
        #if os(iOS)
            .keyboardType(.decimalPad)
        #endif
    }

    private func commit() {
        let cleaned = text.replacingOccurrences(of: ",", with: ".")
        if let v = Double(cleaned) { onCommit(v) }
    }

    private static func format(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}

// MARK: - Coaching catalog helpers

/// Shared by the one-page Journal (`CoachingRootView`, `JournalQuickLogSection`) and the Coach sheet.
enum CoachingCheckInGroup: String, CaseIterable, Identifiable {
    case sleep = "Sleep setup"
    case fuel = "Fuel"
    case training = "Training & activity"
    case recovery = "Recovery & stress"
    case supplements = "Supplements & medication"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .sleep: return "moon"
        case .fuel: return "fork.knife"
        case .training: return "figure.run"
        case .recovery: return "heart.text.square"
        case .supplements: return "pills"
        }
    }
}

func coachingPresentationGroup(for item: JournalCatalogItem) -> CoachingCheckInGroup {
    switch item.group {
    case .nutrition: return .fuel
    case .supplements: return .supplements
    case .health, .behaviour: return .recovery
    case .other: return .training
    case .lifestyle:
        let q = JournalCatalogStore.norm(item.canonical)
        return (q.contains("bed") || q.contains("read")) ? .sleep : .recovery
    }
}

/// A behaviour's own symbol where the question says what it is, else its group's.
func coachingIcon(for item: JournalCatalogItem) -> String {
    let q = JournalCatalogStore.norm(item.canonical)
    if q.contains("alcohol") { return "wineglass" }
    if q.contains("caffeine") || q.contains("coffee") { return "cup.and.saucer.fill" }
    if q.contains("screen") { return "iphone" }
    if q.contains("eat") || q.contains("meal") { return "fork.knife" }
    if q.contains("stress") { return "bolt.heart" }
    if q.contains("sauna") { return "thermometer.sun" }
    if q.contains("share") && q.contains("bed") { return "person.2.fill" }
    if q.contains("sick") { return "bed.double.fill" }
    if q.contains("magnesium") || q.contains("supplement") { return "pills.fill" }
    if q.contains("read") { return "book.fill" }
    return coachingPresentationGroup(for: item).icon
}

/// The colour of a behaviour's group, matching the rest of the app's domains.
func coachingTint(for item: JournalCatalogItem) -> Color {
    switch coachingPresentationGroup(for: item) {
    case .sleep: return StrandPalette.sleepAccent
    case .fuel: return StrandPalette.metricAmber
    case .training: return StrandPalette.strainAccent
    case .recovery: return StrandPalette.metricRose
    case .supplements: return StrandPalette.metricCyan
    }
}

/// An amount to count instead of Yes / No: numeric questions, and the behaviours where how much matters.
/// A zero saves as an explicit No, so the with/without split still sees it.
func coachingQuantity(for item: JournalCatalogItem) -> JournalQuickLog.Amount? {
    typealias Unit = JournalQuickLog.Unit
    if item.kind.isNumeric {
        return .init(step: 1, unit: JournalQuickLog.catalogUnit(item.kind.unitLabel ?? String(localized: "units")))
    }
    let q = JournalCatalogStore.norm(item.canonical)
    if q.contains("alcohol") {
        return .init(step: 1, unit: Unit(singular: String(localized: "drink"), plural: String(localized: "drinks")))
    }
    if q.contains("caffeine") {
        return .init(step: 1, unit: Unit(singular: String(localized: "serving"), plural: String(localized: "servings")))
    }
    if q.contains("magnesium") {
        return .init(step: 1, unit: Unit(singular: String(localized: "dose"), plural: String(localized: "doses")))
    }
    if q.contains("sauna") { return .init(step: 10, unit: JournalQuickLog.fixedUnit(String(localized: "min"))) }
    return nil
}

/// Coaching shortcuts use compact catalog labels while every persistence/analytics call continues
/// to receive `item.canonical`. User-authored display renames still win verbatim.
func coachingShortDisplayName(for item: JournalCatalogItem) -> String {
    if let renamed = item.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !renamed.isEmpty {
        return renamed
    }
    let q = JournalCatalogStore.norm(item.canonical)
    if q.contains("alcohol") { return "Alcohol" }
    if q.contains("caffeine") { return "Late caffeine" }
    if q.contains("screen") && q.contains("bed") { return "Screen in bed" }
    if q.contains("eat close") || q.contains("bedtime") { return "Late meal" }
    if q.contains("stressed") { return "Stress" }
    if q.contains("sauna") { return "Sauna" }
    if q.contains("share") && q.contains("bed") { return "Shared bed" }
    if q.contains("sick") || q.contains("ill") { return "Sick / illness" }
    if q.contains("magnesium") { return "Magnesium" }
    if q.contains("read") && q.contains("bed") { return "Read before bed" }
    var label = item.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
    if label.lowercased().hasPrefix("did you ") { label.removeFirst(8) }
    if label.hasSuffix("?") { label.removeLast() }
    return label.prefix(1).uppercased() + label.dropFirst()
}

// MARK: - Behavior settings

struct CoachingBehaviorSettingsView: View {
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @StateObject private var catalog = JournalCatalogStore()
    @State private var importedQuestions: [String] = []
    @State private var activeSet: CoachingBehaviorSet?
    @State private var memberships: [CoachingBehaviorMembership] = []
    @State private var showAdd = false

    private var resolved: [String: JournalCatalogItem] {
        Dictionary(uniqueKeysWithValues: catalog.resolvedItems(imported: importedQuestions,
                                                               includeHidden: true).map { ($0.canonical, $0) })
    }

    var body: some View {
        ScreenScaffold(title: "Edit questions", subtitle: "What the Journal asks", backAction: { dismiss() }) {
            VStack(alignment: .leading, spacing: 0) {
                FlatSection("Your questions", systemImage: "checklist", tint: .journal,
                            trailing: .text(activeSet?.name ?? String(localized: "Daily fundamentals"))) {
                    VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                        Text("Questions that are on appear in the Journal. Turning one off changes nothing about your history or What Moves You.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button { showAdd = true } label: {
                            Label("Add a question", systemImage: "plus")
                                .font(StrandFont.subhead.weight(.semibold))
                                .foregroundStyle(StrandPalette.journalAccent)
                                .frame(minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(FlatRowPressStyle())
                        .accessibilityIdentifier("journal.addQuestion")
                        NavigationLink { InsightsView(focusedJournal: true) } label: {
                            JournalLinkRow(title: "Rename or add questions",
                                           subtitle: "Custom questions, groups and numbers",
                                           icon: "list.bullet.rectangle")
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("journal.renameQuestions")
                    }
                }
                FlatSectionSeparator()
                FlatSection("Questions", systemImage: "line.3.horizontal", tint: .journal, contentSpacing: 2) {
                    VStack(spacing: 0) {
                        ForEach(Array(memberships.enumerated()), id: \.element.id) { index, membership in
                            if index > 0 { FlatRowSeparator() }
                            behaviorRow(membership, index: index)
                        }
                    }
                }
            }
            .padding(.top, NoopMetrics.space2)
        }
        .task { await load() }
        .sheet(isPresented: $showAdd) { CoachingAddBehaviorSheet(catalog: catalog) { Task { await load() } } }
        .tint(StrandPalette.journalAccent)
        .navigationBarBackButtonHidden(true)
    }

    private func behaviorRow(_ membership: CoachingBehaviorMembership, index: Int) -> some View {
        let item = resolved[membership.canonicalQuestion]
        return HStack(spacing: 10) {
            Menu {
                Button("Move up") { move(index, by: -1) }.disabled(index == 0)
                Button("Move down") { move(index, by: 1) }.disabled(index == memberships.count - 1)
            } label: {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(StrandPalette.textTertiary).frame(width: 24, height: 40)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item?.display ?? membership.canonicalQuestion)
                    .font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary).lineLimit(2)
                Text(membership.coachingGroup)
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer(minLength: 6)
            VStack(spacing: 2) {
                Text("ON").font(StrandFont.micro).foregroundStyle(StrandPalette.textSecondary)
                Toggle("", isOn: membershipBinding(membership, keyPath: \.isActive)).labelsHidden().noopToggle()
            }
        }
        .frame(minHeight: 68)
    }

    private func membershipBinding(_ membership: CoachingBehaviorMembership,
                                   keyPath: KeyPath<CoachingBehaviorMembership, Bool>) -> Binding<Bool> {
        Binding(get: { memberships.first(where: { $0.id == membership.id })?[keyPath: keyPath] ?? false },
                set: { value in update(membership, keyPath: keyPath, value: value) })
    }

    private func update(_ membership: CoachingBehaviorMembership,
                        keyPath: KeyPath<CoachingBehaviorMembership, Bool>, value: Bool) {
        guard let index = memberships.firstIndex(where: { $0.id == membership.id }) else { return }
        let current = memberships[index]
        memberships[index] = CoachingBehaviorMembership(
            setId: current.setId, canonicalQuestion: current.canonicalQuestion,
            coachingGroup: current.coachingGroup, sortIndex: current.sortIndex,
            isActive: keyPath == \.isActive ? value : current.isActive,
            isQuickAdd: keyPath == \.isQuickAdd ? value : current.isQuickAdd)
        persist()
    }

    private func move(_ index: Int, by delta: Int) {
        let destination = index + delta
        guard memberships.indices.contains(destination) else { return }
        memberships.swapAt(index, destination)
        memberships = memberships.enumerated().map { offset, current in
            CoachingBehaviorMembership(setId: current.setId, canonicalQuestion: current.canonicalQuestion,
                                       coachingGroup: current.coachingGroup, sortIndex: offset,
                                       isActive: current.isActive, isQuickAdd: current.isQuickAdd)
        }
        persist()
    }

    private func persist() {
        let rows = memberships
        Task { if let store = await repo.storeHandle() { try? await store.upsertCoachingMemberships(rows) } }
    }

    @MainActor private func load() async {
        let imported = await repo.importedJournalEntries()
        importedQuestions = Array(Set(imported.map(\.question))).sorted()
        let items = catalog.resolvedItems(imported: importedQuestions)
        guard let store = await repo.storeHandle() else { return }
        let defaults = items.enumerated().map { index, item in
            CoachingBehaviorMembership(setId: "daily-fundamentals", canonicalQuestion: item.canonical,
                                       coachingGroup: coachingPresentationGroup(for: item).rawValue,
                                       sortIndex: index, isActive: true, isQuickAdd: index < 6)
        }
        if let set = try? await store.ensureDefaultCoachingSet(name: "Daily fundamentals", memberships: defaults) {
            activeSet = set
            memberships = (try? await store.coachingMemberships(setId: set.id)) ?? []
        }
    }
}

private struct CoachingAddBehaviorSheet: View {
    @ObservedObject var catalog: JournalCatalogStore
    let onAdded: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var group: JournalGroup = .other

    private var canAdd: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            ScreenScaffold(title: "Add a question") {
                VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                    CompactFormField("Question name", text: $name)
                    NoopDropdown("Group", options: JournalGroup.displayOrder, selection: $group) { $0.title }
                    Button {
                        catalog.addCustom(name, group: group)
                        onAdded()
                        dismiss()
                    } label: {
                        Text("Add question")
                            .font(StrandFont.subhead.weight(.semibold))
                            .foregroundStyle(canAdd ? StrandPalette.journalAccent : StrandPalette.textTertiary)
                            .frame(minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(FlatRowPressStyle())
                    .disabled(!canAdd)
                    .accessibilityIdentifier("journal.addQuestion.confirm")
                }
            }
            .background(StrandPalette.appCanvas.ignoresSafeArea())
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
            .sheetScreenScaffoldEnvironment(onClose: { dismiss() })
        }
        .tint(StrandPalette.journalAccent)
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Stack detail

/// Detail for a configured routine. Stack use is provenance only: checked items always write real
/// journal occurrences through Repository so What Moves You sees the same canonical inputs as manual logs.
/// It logs to the day the Journal has open, so "Yesterday" on the page is "Yesterday" here.
struct CoachingStackDetailView: View {
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @StateObject private var catalog = JournalCatalogStore()

    let stack: CoachingStack
    let day: String
    let onChanged: () -> Void
    @State private var items: [CoachingStackItem] = []
    @State private var selected: Set<String> = []
    @State private var notes = ""
    @State private var isActive = true
    @State private var lastUse: CoachingStackUse?
    @State private var saving = false
    @State private var didSave = false

    init(stack: CoachingStack, day: String = JournalBehaviorDay.yesterdayStorageKey(),
         onChanged: @escaping () -> Void = {}) {
        self.stack = stack
        self.day = day
        self.onChanged = onChanged
    }

    var body: some View {
        ScreenScaffold(title: LocalizedStringKey(stack.name), backAction: { dismiss() }) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                intro
                itemChecklist
                activeRow
                notesField
                actions
            }
        }
        .task { await load() }
        .tint(StrandPalette.journalAccent)
        .navigationBarBackButtonHidden(true)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            Text(verbatim: stack.description ?? String(localized: "Log these together. Each one is saved as its own Journal answer."))
                .font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: lastUsedText)
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
        }
    }

    private var itemChecklist: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionEyebrow("Saves to \(JournalBehaviorDay.label(forStorageKey: day))", tint: .journal)
            if items.isEmpty {
                Text("Nothing in here yet.").font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .padding(.vertical, NoopMetrics.space3)
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { FlatRowSeparator() }
                    itemRow(item)
                }
            }
        }
    }

    private func itemRow(_ item: CoachingStackItem) -> some View {
        let isOn = selected.contains(item.canonicalQuestion)
        return Button { toggle(item) } label: {
            HStack(spacing: NoopMetrics.space3) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: shortName(item.canonicalQuestion))
                        .font(isOn ? StrandFont.body.weight(.semibold) : StrandFont.body)
                        .foregroundStyle(isOn ? StrandPalette.journalAccent : StrandPalette.textSecondary)
                    if let dose = doseLabel(item) {
                        Text(verbatim: dose).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            .monospacedDigit()
                    }
                }
                Spacer(minLength: 0)
                if isOn {
                    Image(systemName: "checkmark").font(StrandFont.subhead.weight(.semibold))
                        .foregroundStyle(StrandPalette.journalAccent).accessibilityHidden(true)
                }
            }
            .frame(minHeight: 52).contentShape(Rectangle())
        }
        .buttonStyle(FlatRowPressStyle())
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var activeRow: some View {
        Toggle(isOn: Binding(get: { isActive }, set: { value in
            isActive = value
            Task { await persistSettings() }
        })) {
            Text("Active").font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
        }
        .frame(minHeight: 44)
    }

    private var notesField: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionEyebrow("Note", tint: .journal)
            TextField("Optional note for this routine", text: $notes, axis: .vertical)
                .font(StrandFont.body).lineLimit(1...5).padding(.vertical, NoopMetrics.space3)
            Rectangle().fill(StrandPalette.hairlineStrong).frame(height: 1)
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { Task { await logStack() } } label: {
                HStack(spacing: NoopMetrics.space1) {
                    if didSave { Image(systemName: "checkmark").accessibilityHidden(true) }
                    Text(didSave ? "Logged" : saving ? "Logging…" : "Log these together")
                }
                .font(StrandFont.subhead.weight(.semibold))
                .foregroundStyle(selected.isEmpty ? StrandPalette.textTertiary : StrandPalette.journalAccent)
                .frame(minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(FlatRowPressStyle()).disabled(saving || selected.isEmpty)
            Button { Task { await skip() } } label: {
                Text("Skip for now").font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .frame(minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(FlatRowPressStyle())
        }
    }

    /// "Logged Yesterday", "Skipped Oct 21" or "Not used yet": the day written the way the Journal writes it.
    private var lastUsedText: String {
        guard let lastUse else { return String(localized: "Not used yet") }
        let label = JournalBehaviorDay.label(forStorageKey: lastUse.day)
        return lastUse.skipped ? String(localized: "Skipped \(label)") : String(localized: "Logged \(label)")
    }

    private func shortName(_ canonical: String) -> String {
        let item = catalog.resolvedItems(imported: []).first { $0.canonical == canonical }
        return item.map(coachingShortDisplayName(for:)) ?? canonical
    }

    private func doseLabel(_ item: CoachingStackItem) -> String? {
        guard let dose = item.dose else { return nil }
        return JournalQuickLog.amountText(dose, unit: JournalQuickLog.catalogUnit(item.unit ?? String(localized: "units")))
    }

    private func toggle(_ item: CoachingStackItem) {
        if selected.contains(item.canonicalQuestion) { selected.remove(item.canonicalQuestion) }
        else { selected.insert(item.canonicalQuestion) }
    }

    @MainActor private func load() async {
        guard let store = await repo.storeHandle() else { return }
        items = (try? await store.coachingStackItems(stackId: stack.id)) ?? []
        selected = Set(items.map(\.canonicalQuestion))
        lastUse = try? await store.coachingStackUses(stackId: stack.id).first
        notes = stack.notes ?? ""
        isActive = stack.isActive
    }

    @MainActor private func persistSettings() async {
        guard let store = await repo.storeHandle() else { return }
        try? await store.updateCoachingStack(id: stack.id, isActive: isActive,
                                             notes: notes.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
        onChanged()
    }

    @MainActor private func logStack() async {
        saving = true
        let checked = items.filter { selected.contains($0.canonicalQuestion) }
        if await repo.logCoachingStack(stackId: stack.id, day: day, items: checked,
                                       notes: notes.nilIfEmpty) != nil,
           let store = await repo.storeHandle() {
            lastUse = try? await store.coachingStackUses(stackId: stack.id).first
        }
        saving = false
        didSave = true
        onChanged()
    }

    @MainActor private func skip() async {
        _ = await repo.logCoachingStack(stackId: stack.id, day: day, items: [],
                                        notes: notes.nilIfEmpty, skipped: true)
        onChanged()
        dismiss()
    }
}

/// Stable simulator entry for the T137/T139 full-page proof. It resolves the same persisted preset
/// used by Coaching Root rather than constructing a view-only fake stack.
struct CoachingStackDemoRoute: View {
    @EnvironmentObject private var repo: Repository
    @State private var stack: CoachingStack?

    var body: some View {
        Group {
            if let stack {
                CoachingStackDetailView(stack: stack)
            } else {
                ComingSoon(what: "Loading your stack…", symbol: "square.stack.3d.up")
                    .task { await load() }
            }
        }
    }

    @MainActor private func load() async {
        guard let store = await repo.storeHandle() else { return }
        if let existing = try? await store.coachingStacks().first {
            stack = existing
            return
        }
        let preset = CoachingStack(id: "evening-recovery", name: "Evening recovery",
                                   description: "A simple wind-down routine for the behaviors you already track.",
                                   scheduleLabel: "Daily", isActive: true, notes: nil, sortIndex: 0)
        let items = [
            CoachingStackItem(stackId: preset.id, canonicalQuestion: "Did you take magnesium?",
                              dose: 1, unit: "dose", sortIndex: 0),
            CoachingStackItem(stackId: preset.id, canonicalQuestion: "Did you use a sauna?",
                              dose: 10, unit: "min", sortIndex: 1),
        ]
        stack = try? await store.ensureDefaultCoachingStack(preset, items: items)
    }
}

private extension String {
    var nilIfEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
