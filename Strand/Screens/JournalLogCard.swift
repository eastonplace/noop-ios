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

// MARK: - Journal

/// The Journal: one flat page that is the whole daily check-in. Mood, then the behaviours grouped the way a day goes,
/// each a one-tap Yes / No or a stepper that saves the moment it is touched, then a note, the last two weeks and the
/// shortcuts. There is no separate check-in screen or Save button to forget. It owns no persistence of its own: every
/// answer is written through Repository's journal API under the immutable catalog canonicals (the native
/// "noop-journal" source), so What Moves You and Heads-Up read exactly what was tapped. Typed or dictated notes keep
/// their explicit reviewed save in the composer sheet.
struct CoachingRootView: View {
    @EnvironmentObject private var repo: Repository
    @StateObject private var catalog = JournalCatalogStore()

    @State private var importedQuestions: [String] = []
    @State private var activeCanonicals: Set<String> = []
    /// 0 = today, 1 = yesterday: the evening check-in and the "I forgot last night" one.
    @State private var dayOffset = 0
    @State private var answers: [String: Bool] = [:]
    @State private var numeric: [String: Double] = [:]
    @State private var previousAnswers: [String: Bool] = [:]
    @State private var previousNumeric: [String: Double] = [:]
    @State private var mood: Int?
    @State private var loggedWindow: [Bool] = []
    @State private var recentEntries: [CoachingRecentEntry] = []
    @State private var stacks: [CoachingStack] = []
    @State private var loaded = false
    @State private var savedMessage: String?
    /// A typed/dictated note. It stays transient until its sheet's reviewed Save.
    @State private var composingEntry: JournalEntryPresentation?
    #if DEBUG && os(iOS)
    @State private var qaComposeOpened = false
    #endif

    /// The local day `daysBack` days before `now`, in the journal's own day-key form.
    nonisolated static func key(daysBack: Int, now: Date = Date(), calendar: Calendar = .current) -> String {
        Repository.localDayKey(calendar.date(byAdding: .day, value: -daysBack, to: now) ?? now, calendar: calendar)
    }

    private var dayKey: String { Self.key(daysBack: dayOffset) }

    private var items: [JournalCatalogItem] {
        let resolved = catalog.resolvedItems(imported: importedQuestions)
            .sorted { ($0.sortIndex, $0.display) < ($1.sortIndex, $1.display) }
        return activeCanonicals.isEmpty ? resolved : resolved.filter { activeCanonicals.contains($0.canonical) }
    }

    private func isAnswered(_ item: JournalCatalogItem) -> Bool {
        answers[item.canonical] != nil || numeric[item.canonical] != nil
    }

    private var answeredCount: Int { items.filter { isAnswered($0) }.count }

    private var groups: [CoachingCheckInGroup] {
        let present = Set(items.map(coachingPresentationGroup(for:)))
        return CoachingCheckInGroup.allCases.filter { present.contains($0) }
    }

    /// Yesterday answered something today has not yet: one tap copies just those gaps.
    private var canRepeatYesterday: Bool {
        dayOffset == 0 && items.contains { item in
            !isAnswered(item) && (previousAnswers[item.canonical] != nil || previousNumeric[item.canonical] != nil)
        }
    }

    private var loadKey: String { "\(repo.refreshSeq)|\(dayKey)" }

    var body: some View {
        NavigationStack {
            ScreenScaffold(title: "Journal", subtitle: "Tap once. It saves itself.") {
                if loaded {
                    VStack(alignment: .leading, spacing: 0) {
                        dayHeader
                        FlatSectionSeparator()
                        JournalMoodRow(mood: moodBinding)
                        ForEach(groups) { group in
                            FlatSectionSeparator()
                            groupSection(group)
                        }
                        FlatSectionSeparator()
                        noteSection
                        Group {
                            FlatSectionSeparator()
                            historySection
                            FlatSectionSeparator()
                            shortcutsSection
                            privacyLine
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("journal.home")
                } else {
                    ComingSoon(what: "Loading today’s check-in…", symbol: "checkmark.circle")
                }
            }
            .task(id: loadKey) { await load() }
            #if os(iOS)
            // The scaffold header is this screen's only chrome; the stack's own bar would stack a second
            // one above it.
            .toolbar(.hidden, for: .navigationBar)
            #endif
        }
        .tint(StrandPalette.journalAccent)
        .sheet(item: $composingEntry) { entry in
            JournalEntryComposer(catalog: catalog, presentation: entry,
                                 importedQuestions: importedQuestions, currentDay: entry.day,
                                 onSaved: { Task { await load() } })
                .environmentObject(repo)
        }
        #if DEBUG && os(iOS)
        // `--noop-qa-route journal-compose`: open the composer over this screen once it has loaded.
        .onChange(of: loaded) { _, isLoaded in
            guard isLoaded, QARoute.requested == .journalCompose, !qaComposeOpened else { return }
            qaComposeOpened = true
            composingEntry = JournalEntryPresentation(day: dayKey, sourceIdentity: repo.journalEntrySourceIdentity)
        }
        #endif
    }

    // MARK: Day and progress

    private var dayLabel: String {
        let date = Calendar.current.date(byAdding: .day, value: -dayOffset, to: Date()) ?? Date()
        return date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }

    private var dayHeader: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space4) {
            HStack(spacing: NoopMetrics.space2) {
                ChoiceChipButton(title: "Yesterday", isSelected: dayOffset == 1) { select(daysBack: 1) }
                ChoiceChipButton(title: "Today", isSelected: dayOffset == 0) { select(daysBack: 0) }
                Spacer(minLength: NoopMetrics.space2)
                Text(verbatim: dayLabel)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            JournalProgressHeader(
                answered: answeredCount, total: items.count,
                caption: dayOffset == 0
                    ? String(localized: "Saves as you tap. Answers describe the day and night leading into tomorrow.")
                    : String(localized: "Filling in yesterday. Saves as you tap."))
            if canRepeatYesterday || savedMessage != nil {
                HStack(spacing: NoopMetrics.space3) {
                    if canRepeatYesterday {
                        Button { Task { await repeatYesterday() } } label: {
                            Label("Same as yesterday", systemImage: "arrow.counterclockwise")
                        }
                        .buttonStyle(SecondaryPillButtonStyle())
                        .accessibilityHint("Copies yesterday’s answers into the questions you have not answered today")
                        .accessibilityIdentifier("journal.repeatYesterday")
                    }
                    if let savedMessage {
                        Label(savedMessage, systemImage: "checkmark.circle.fill")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
            }
        }
        .padding(.top, NoopMetrics.space2)
    }

    private func select(daysBack: Int) {
        guard dayOffset != daysBack else { return }
        savedMessage = nil
        dayOffset = daysBack
    }

    // MARK: Questions

    private func groupItems(_ group: CoachingCheckInGroup) -> [JournalCatalogItem] {
        items.filter { coachingPresentationGroup(for: $0) == group }
    }

    private func groupSection(_ group: CoachingCheckInGroup) -> some View {
        let rows = groupItems(group)
        let done = rows.filter { isAnswered($0) }.count
        return FlatSection(verbatim: group.rawValue, systemImage: group.icon, tint: .journal,
                           trailing: .text("\(done)/\(rows.count)"), contentSpacing: 2) {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { FlatRowSeparator(leadingInset: 42) }
                    row(item)
                }
            }
        }
    }

    @ViewBuilder private func row(_ item: JournalCatalogItem) -> some View {
        if item.kind.isNumeric {
            JournalQuantityRow(icon: coachingIcon(for: item), tint: coachingTint(for: item),
                               title: coachingShortDisplayName(for: item), unit: item.kind.unitLabel ?? "",
                               value: numericBinding(item))
        } else {
            JournalHabitToggle(icon: coachingIcon(for: item), tint: coachingTint(for: item),
                               question: coachingShortDisplayName(for: item), answer: answerBinding(item))
        }
    }

    /// Every tap writes at once for the day it was made on, then the page updates in place.
    private func answerBinding(_ item: JournalCatalogItem) -> Binding<Bool?> {
        Binding(
            get: { answers[item.canonical] },
            set: { next in
                let day = dayKey
                answers[item.canonical] = next
                savedMessage = nil
                markLogged()
                Task {
                    if let next {
                        await repo.saveJournalAnswer(day: day, question: item.canonical, answeredYes: next)
                    } else {
                        await repo.clearJournalAnswer(day: day, question: item.canonical)
                    }
                }
            }
        )
    }

    private func numericBinding(_ item: JournalCatalogItem) -> Binding<Double?> {
        Binding(
            get: { numeric[item.canonical] },
            set: { next in
                let day = dayKey
                numeric[item.canonical] = next
                answers[item.canonical] = next.map { _ in true }
                savedMessage = nil
                markLogged()
                Task {
                    if let next {
                        await repo.saveJournalNumeric(day: day, question: item.canonical, value: next)
                    } else {
                        await repo.clearJournalAnswer(day: day, question: item.canonical)
                    }
                }
            }
        )
    }

    private var moodBinding: Binding<Int?> {
        Binding(
            get: { mood },
            set: { next in
                let day = dayKey
                mood = next
                guard let next else { return }
                Task { await repo.saveMood(day: day, value: next) }
            }
        )
    }

    /// The two-week strip ends today, so a tap on today or yesterday lights its dot without a reload.
    private func markLogged() {
        let index = loggedWindow.count - 1 - dayOffset
        guard loggedWindow.indices.contains(index) else { return }
        loggedWindow[index] = !answers.isEmpty || !numeric.isEmpty
    }

    @MainActor private func repeatYesterday() async {
        let day = dayKey
        var copied = 0
        for item in items where !isAnswered(item) {
            if let value = previousNumeric[item.canonical] {
                numeric[item.canonical] = value
                answers[item.canonical] = true
                await repo.saveJournalNumeric(day: day, question: item.canonical, value: value)
                copied += 1
            } else if let answer = previousAnswers[item.canonical] {
                answers[item.canonical] = answer
                await repo.saveJournalAnswer(day: day, question: item.canonical, answeredYes: answer)
                copied += 1
            }
        }
        markLogged()
        savedMessage = copied == 0 ? String(localized: "Nothing new to copy")
                                   : String(localized: "Copied \(copied) from yesterday")
    }

    // MARK: Note, history, shortcuts

    private var noteSection: some View {
        FlatSection("Notes", systemImage: "square.and.pencil", tint: .journal, contentSpacing: 2) {
            JournalComposeRow {
                composingEntry = JournalEntryPresentation(day: dayKey, sourceIdentity: repo.journalEntrySourceIdentity)
            }
        }
    }

    private var historySection: some View {
        FlatSection("Your logging", systemImage: "calendar", tint: .journal) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                if !loggedWindow.isEmpty {
                    JournalStreakStrip(logged: loggedWindow)
                }
                if recentEntries.isEmpty {
                    Text("Your latest answers will appear here.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(recentEntries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { FlatRowSeparator() }
                            recentRow(entry)
                        }
                    }
                }
            }
        }
    }

    private func recentRow(_ entry: CoachingRecentEntry) -> some View {
        HStack(spacing: NoopMetrics.space3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.display)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                Text(verbatim: entry.day)
                    .font(StrandFont.caption)
                    .monospacedDigit()
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: NoopMetrics.space2)
            Text(verbatim: entry.numeric.map(CoachingRecentEntry.format)
                 ?? (entry.answeredYes ? String(localized: "Yes") : String(localized: "No")))
                .font(StrandFont.captionNumber)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .frame(minHeight: 48)
        .accessibilityElement(children: .combine)
    }

    private var shortcutsSection: some View {
        FlatSection("Shortcuts", systemImage: "square.grid.2x2", tint: .journal, contentSpacing: 0) {
            VStack(spacing: 0) {
                NavigationLink { CoachingBehaviorSettingsView() } label: {
                    linkRow(title: "Choose questions", subtitle: "What the check-in asks, and in what order",
                            icon: "slider.horizontal.3")
                }
                .buttonStyle(.plain)
                FlatRowSeparator(leadingInset: 36)
                NavigationLink { CoachingQuickAddView() } label: {
                    linkRow(title: "Quick Add", subtitle: "Log one thing without the full list", icon: "plus.circle")
                }
                .buttonStyle(.plain)
                if let stack = stacks.first {
                    FlatRowSeparator(leadingInset: 36)
                    NavigationLink { CoachingStackDetailView(stack: stack) { Task { await load() } } } label: {
                        linkRow(title: "Stacks", verbatimSubtitle: stack.name, icon: "square.stack.3d.up")
                    }
                    .buttonStyle(.plain)
                }
                FlatRowSeparator(leadingInset: 36)
                NavigationLink { InsightsView(focusedJournal: true) } label: {
                    linkRow(title: "Rename or add questions", subtitle: "Custom questions, groups and numbers",
                            icon: "list.bullet.rectangle")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func linkRow(title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil,
                         verbatimSubtitle: String? = nil, icon: String) -> some View {
        HStack(spacing: NoopMetrics.space3) {
            Image(systemName: icon)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.journalAccent)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                if let subtitle {
                    Text(subtitle).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                } else if let verbatimSubtitle {
                    Text(verbatim: verbatimSubtitle).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            Spacer(minLength: NoopMetrics.space2)
            Image(systemName: "chevron.right")
                .font(StrandFont.caption.weight(.semibold))
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }

    private var privacyLine: some View {
        Label {
            Text("Entries stay on this device and feed What Moves You and Heads-Up.")
        } icon: {
            Image(systemName: "lock.fill")
        }
        .font(StrandFont.caption)
        .foregroundStyle(StrandPalette.textTertiary)
        .padding(.top, NoopMetrics.space4)
        .padding(.bottom, NoopMetrics.space6)
    }

    // MARK: Load

    @MainActor private func load() async {
        let day = dayKey
        let previousDay = Self.key(daysBack: dayOffset + 1)
        let imported = await repo.importedJournalEntries()
        let all = await repo.journalEntries()
        let questions = Array(Set(imported.map(\.question))).sorted()
        let resolved = catalog.resolvedItems(imported: questions)
        var active: Set<String> = []
        var loadedStacks: [CoachingStack] = []
        if let store = await repo.storeHandle() {
            let defaults = resolved.enumerated().map { index, item in
                CoachingBehaviorMembership(setId: "daily-fundamentals", canonicalQuestion: item.canonical,
                                           coachingGroup: coachingPresentationGroup(for: item).rawValue,
                                           sortIndex: index, isActive: true, isQuickAdd: index < 6)
            }
            if let set = try? await store.ensureDefaultCoachingSet(name: "Daily fundamentals", memberships: defaults) {
                let memberships = (try? await store.coachingMemberships(setId: set.id)) ?? []
                active = Set(memberships.filter(\.isActive).map(\.canonicalQuestion))
            }
            let magnesium = resolved.first { JournalCatalogStore.norm($0.canonical).contains("magnesium") }
            let sauna = resolved.first { JournalCatalogStore.norm($0.canonical).contains("sauna") }
            let preset = CoachingStack(id: "evening-recovery", name: "Evening recovery",
                                       description: "A simple wind-down routine for the behaviors you already track.",
                                       scheduleLabel: "Daily", isActive: true, notes: nil, sortIndex: 0)
            let presetItems = [
                magnesium.map { CoachingStackItem(stackId: preset.id, canonicalQuestion: $0.canonical,
                                                  dose: 1, unit: "dose", sortIndex: 0) },
                sauna.map { CoachingStackItem(stackId: preset.id, canonicalQuestion: $0.canonical,
                                              dose: 10, unit: "min", sortIndex: 1) },
            ].compactMap { $0 }
            if !presetItems.isEmpty {
                _ = try? await store.ensureDefaultCoachingStack(preset, items: presetItems)
            }
            loadedStacks = (try? await store.coachingStacks()) ?? []
        }
        let dayAnswers = await repo.nativeJournalAnswers(day: day)
        let dayNumeric = await repo.nativeJournalNumeric(day: day)
        let earlierAnswers = await repo.nativeJournalAnswers(day: previousDay)
        let earlierNumeric = await repo.nativeJournalNumeric(day: previousDay)
        let dayMood = await repo.mood(day: day)
        // The person may have switched day while this was reading; the newer load owns the page.
        guard day == dayKey else { return }
        importedQuestions = questions
        activeCanonicals = active
        stacks = loadedStacks
        answers = dayAnswers
        numeric = dayNumeric
        previousAnswers = earlierAnswers
        previousNumeric = earlierNumeric
        mood = dayMood
        loggedWindow = JournalStreakSummary.window(loggedDays: Set(all.map(\.day)),
                                                   endingOn: Self.key(daysBack: 0), days: 14)
        recentEntries = all.reversed().prefix(5).map {
            CoachingRecentEntry(day: $0.day,
                                display: catalog.displayName(for: $0.question),
                                answeredYes: $0.answeredYes,
                                numeric: $0.numericValue)
        }
        loaded = true
    }
}

private struct CoachingRecentEntry: Identifiable {
    let id = UUID()
    let day: String
    let display: String
    let answeredYes: Bool
    let numeric: Double?

    static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

private enum CoachingCheckInGroup: String, CaseIterable, Identifiable {
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

private func coachingPresentationGroup(for item: JournalCatalogItem) -> CoachingCheckInGroup {
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
private func coachingIcon(for item: JournalCatalogItem) -> String {
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
private func coachingTint(for item: JournalCatalogItem) -> Color {
    switch coachingPresentationGroup(for: item) {
    case .sleep: return StrandPalette.sleepAccent
    case .fuel: return StrandPalette.metricAmber
    case .training: return StrandPalette.strainAccent
    case .recovery: return StrandPalette.metricRose
    case .supplements: return StrandPalette.metricCyan
    }
}

/// Coaching shortcuts use compact catalog labels while every persistence/analytics call continues
/// to receive `item.canonical`. User-authored display renames still win verbatim.
private func coachingShortDisplayName(for item: JournalCatalogItem) -> String {
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
        ScreenScaffold(title: "Choose questions", subtitle: "What the check-in asks", backAction: { dismiss() }) {
            VStack(alignment: .leading, spacing: 0) {
                FlatSection("Your check-in", systemImage: "checklist", tint: .journal,
                            trailing: .text(activeSet?.name ?? String(localized: "Daily fundamentals"))) {
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        Text("Active questions appear in the Journal. Quick Add questions get one-tap shortcuts. Neither changes your history or What Moves You.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button { showAdd = true } label: { Label("Add a question", systemImage: "plus") }
                            .buttonStyle(SecondaryPillButtonStyle())
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
                Text("ACTIVE").font(StrandFont.micro).foregroundStyle(StrandPalette.textSecondary)
                Toggle("", isOn: membershipBinding(membership, keyPath: \.isActive)).labelsHidden().noopToggle()
            }
            VStack(spacing: 2) {
                Text("QUICK ADD").font(StrandFont.micro).foregroundStyle(StrandPalette.textSecondary)
                Toggle("", isOn: membershipBinding(membership, keyPath: \.isQuickAdd)).labelsHidden().noopToggle()
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

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                CompactFormField("Behavior name", text: $name)
                NoopDropdown("Group", options: JournalGroup.displayOrder, selection: $group) { $0.title }
                Spacer()
                Button("Add behavior") {
                    catalog.addCustom(name, group: group)
                    onAdded()
                    dismiss()
                }
                .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(NoopMetrics.screenPadding)
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle("Add Behavior")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Quick Add

struct CoachingQuickAddView: View {
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @StateObject private var catalog = JournalCatalogStore()
    @State private var importedQuestions: [String] = []
    @State private var memberships: [CoachingBehaviorMembership] = []
    @State private var answers: [String: Bool] = [:]
    @State private var search = ""
    @State private var showAll = false

    private var todayKey: String { Repository.localDayKey(Date()) }
    private var resolved: [String: JournalCatalogItem] {
        Dictionary(uniqueKeysWithValues: catalog.resolvedItems(imported: importedQuestions).map { ($0.canonical, $0) })
    }
    private var visible: [CoachingBehaviorMembership] {
        memberships.filter { membership in
            membership.isActive && (showAll || membership.isQuickAdd) &&
            (search.isEmpty || {
                let item = resolved[membership.canonicalQuestion]
                let short = item.map(coachingShortDisplayName(for:)) ?? membership.canonicalQuestion
                return short.localizedCaseInsensitiveContains(search) ||
                    membership.canonicalQuestion.localizedCaseInsensitiveContains(search)
            }())
        }
    }

    var body: some View {
        ScreenScaffold(title: "Quick Add", subtitle: "Log without the full check-in", backAction: { dismiss() }) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                PaperSearchField(
                    "Search behaviors",
                    text: $search,
                    height: NoopMetrics.controlHeight,
                    cornerRadius: NoopMetrics.radius3
                )

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: NoopMetrics.space3) {
                    ForEach(visible) { membership in quickTile(membership) }
                }

                Button(showAll ? "Show Quick Add only" : "View all behaviors") { showAll.toggle() }
                    .font(StrandFont.body.weight(.semibold))
                    .foregroundStyle(StrandPalette.journalAccent)
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .background(StrandPalette.journalAccent.opacity(0.10), in: RoundedRectangle(cornerRadius: NoopMetrics.radius3))
                    .buttonStyle(.plain)
            }
        }
        .task { await load() }
        .tint(StrandPalette.journalAccent)
        .navigationBarBackButtonHidden(true)
    }

    private func quickTile(_ membership: CoachingBehaviorMembership) -> some View {
        let item = resolved[membership.canonicalQuestion]
        let logged = answers[membership.canonicalQuestion] == true
        return PaperCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: logged ? "checkmark.circle.fill" : "plus.circle.fill")
                    .font(StrandFont.title2).foregroundStyle(StrandPalette.journalAccent)
                Text(item.map(coachingShortDisplayName(for:)) ?? membership.canonicalQuestion)
                    .font(StrandFont.body.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(2).frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
                Text(membership.coachingGroup).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                Button(logged ? "Added" : "Add") { Task { await add(membership) } }
                    .font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(logged ? StrandPalette.onLightFill : StrandPalette.textPrimary)
                    .frame(maxWidth: .infinity).frame(height: 36)
                    .background(logged ? StrandPalette.solidFill : Color.clear, in: Capsule())
                    .overlay(Capsule().stroke(logged ? Color.clear : StrandPalette.hairlineStrong, lineWidth: 1))
                    .buttonStyle(.plain)
            }
        }
    }

    @MainActor private func load() async {
        let imported = await repo.importedJournalEntries()
        importedQuestions = Array(Set(imported.map(\.question))).sorted()
        let items = catalog.resolvedItems(imported: importedQuestions)
        answers = await repo.nativeJournalAnswers(day: todayKey)
        guard let store = await repo.storeHandle() else { return }
        let defaults = items.enumerated().map { index, item in
            CoachingBehaviorMembership(setId: "daily-fundamentals", canonicalQuestion: item.canonical,
                                       coachingGroup: coachingPresentationGroup(for: item).rawValue,
                                       sortIndex: index, isActive: true, isQuickAdd: index < 6)
        }
        if let set = try? await store.ensureDefaultCoachingSet(name: "Daily fundamentals", memberships: defaults) {
            memberships = (try? await store.coachingMemberships(setId: set.id)) ?? []
        }
    }

    @MainActor private func add(_ membership: CoachingBehaviorMembership) async {
        await repo.saveJournalAnswer(day: todayKey, question: membership.canonicalQuestion, answeredYes: true)
        answers = await repo.nativeJournalAnswers(day: todayKey)
    }
}

/// Detail for a configured routine. Stack use is provenance only: checked items always write real
/// journal occurrences through Repository so What Moves You sees the same canonical inputs as manual logs.
struct CoachingStackDetailView: View {
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @StateObject private var catalog = JournalCatalogStore()

    let stack: CoachingStack
    let onChanged: () -> Void
    @State private var items: [CoachingStackItem] = []
    @State private var selected: Set<String> = []
    @State private var notes = ""
    @State private var isActive = true
    @State private var lastUse: CoachingStackUse?
    @State private var saving = false
    @State private var didSave = false

    init(stack: CoachingStack, onChanged: @escaping () -> Void = {}) {
        self.stack = stack
        self.onChanged = onChanged
    }

    private var todayKey: String { Repository.localDayKey(Date()) }

    var body: some View {
        ScreenScaffold(title: LocalizedStringKey(stack.name), subtitle: "Stack detail", backAction: { dismiss() }) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                hero
                itemChecklist
                historyCard
                notesCard
                actions
            }
        }
        .task { await load() }
        .tint(StrandPalette.journalAccent)
        .navigationBarBackButtonHidden(true)
    }

    private var hero: some View {
        PaperCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    StatusBadge(isActive ? "Active" : "Paused", style: isActive ? .success : .queued)
                    Spacer()
                    Toggle("", isOn: Binding(get: { isActive }, set: { value in
                        isActive = value
                        Task { await persistSettings() }
                    }))
                    .labelsHidden()
                }
                Text("Preset · \(stack.scheduleLabel ?? "Any time")")
                    .font(StrandFont.overline).foregroundStyle(StrandPalette.textSecondary)
                Text(stack.description ?? "Log the checked items together without changing their journal identity.")
                    .font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var itemChecklist: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Items", overline: "This use")
            PaperCard {
                if items.isEmpty {
                    Text("No items in this stack yet.").font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Divider().overlay(StrandPalette.hairline) }
                            Button { toggle(item) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: selected.contains(item.canonicalQuestion)
                                          ? "checkmark.circle.fill" : "circle")
                                        .font(StrandFont.title2).foregroundStyle(StrandPalette.journalAccent)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(shortName(item.canonicalQuestion)).font(StrandFont.body)
                                            .foregroundStyle(StrandPalette.textPrimary)
                                        Text(doseLabel(item)).font(StrandFont.caption)
                                            .foregroundStyle(StrandPalette.textSecondary)
                                    }
                                    Spacer()
                                }
                                .frame(minHeight: NoopMetrics.rowHeight).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var historyCard: some View {
        PaperCard {
            SettingsRow(icon: "clock", title: "Last used",
                        subtitle: lastUse.map { $0.skipped ? "Skipped \($0.day)" : "Logged \($0.day)" }
                            ?? "Not used yet")
        }
    }

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Notes")
            TextField("Optional note for this routine", text: $notes, axis: .vertical)
                .font(StrandFont.body).lineLimit(3...6).padding(16)
                .background(StrandPalette.card, in: RoundedRectangle(cornerRadius: NoopMetrics.radius3))
                .overlay(RoundedRectangle(cornerRadius: NoopMetrics.radius3)
                    .strokeBorder(StrandPalette.cardBorder, lineWidth: 1))
        }
    }

    private var actions: some View {
        VStack(spacing: NoopMetrics.space3) {
            Button { Task { await logStack() } } label: {
                Label(didSave ? "Stack logged" : saving ? "Logging…" : "Log Stack",
                      systemImage: didSave ? "checkmark" : "square.stack.3d.up.fill")
            }
            .buttonStyle(NoopButtonStyle(.primary, fullWidth: true)).disabled(saving || selected.isEmpty)
            Button("Skip for now") { Task { await skip() } }
                .font(StrandFont.body.weight(.semibold)).foregroundStyle(StrandPalette.textSecondary)
                .frame(maxWidth: .infinity).frame(height: 48).buttonStyle(.plain)
        }
    }

    private func shortName(_ canonical: String) -> String {
        let item = catalog.resolvedItems(imported: []).first { $0.canonical == canonical }
        return item.map(coachingShortDisplayName(for:)) ?? canonical
    }

    private func doseLabel(_ item: CoachingStackItem) -> String {
        guard let dose = item.dose else { return "Journal occurrence" }
        return "\(CoachingRecentEntry.format(dose)) \(item.unit ?? "units")"
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
        if await repo.logCoachingStack(stackId: stack.id, day: todayKey, items: checked,
                                       notes: notes.nilIfEmpty) != nil,
           let store = await repo.storeHandle() {
            lastUse = try? await store.coachingStackUses(stackId: stack.id).first
        }
        saving = false
        didSave = true
        onChanged()
    }

    @MainActor private func skip() async {
        _ = await repo.logCoachingStack(stackId: stack.id, day: todayKey, items: [],
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
