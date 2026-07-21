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
    let onChanged: () -> Void              // parent re-runs load() after a write

    init(importedQuestions: [String], answers: [String: Bool],
         numericAnswers: [String: Double] = [:], dayOffset: Binding<Int>,
         onChanged: @escaping () -> Void) {
        self.importedQuestions = importedQuestions
        self.answers = answers
        self.numericAnswers = numericAnswers
        self._dayOffset = dayOffset
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
    /// Kit 44 adapters. Both are loaded from production persistence; no fixture
    /// answers or synthetic streak days enter the component layer.
    @State private var selectedMood: Int?
    @State private var loggedWindow: [Bool] = []

    private var dayKey: String {
        Repository.localDayKey(
            Calendar.current.date(byAdding: .day, value: -dayOffset, to: Date()) ?? Date())
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
            PaperCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text(editing
                         ? "Rename, regroup, or remove an item to tidy your list. Renaming keeps the original question behind the scenes, so a WHOOP import still lines up. Custom items are deleted; built-in ones are hidden and can be restored below."
                         : dayOffset == -1
                         ? "Logging ahead for tomorrow: today's activities inform tomorrow's recovery, just as yesterday's are reflected in today's. Tomorrow's answers line up with tomorrow's morning."
                         : "Answers are about the night and day leading into this morning, the same attribution a WHOOP export uses, so logged and imported days line up.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(JournalGroup.displayOrder, id: \.self) { group in
                        groupBlock(group)
                    }

                    if !editing {
                        Divider().overlay(StrandPalette.hairline).padding(.leading, 54)
                        JournalMoodRow(mood: moodBinding)
                        if !loggedWindow.isEmpty {
                            JournalStreakStrip(logged: loggedWindow)
                        }
                    }

                    Divider().overlay(StrandPalette.hairline)
                    addRow
                }
            }
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
            HStack {
                Button("Cancel") { renaming = nil }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Save") {
                    catalog.rename(item.canonical, to: renameDraft)
                    renaming = nil
                }
                .buttonStyle(.borderedProminent)
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
                .buttonStyle(.bordered)
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
        pillButton(label, selected: dayOffset == offset) {
            dayOffset = offset
            onChanged()   // reload the selected day's answers
        }
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
                .foregroundStyle(selected ? StrandPalette.surfaceBase : StrandPalette.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(selected ? StrandPalette.textPrimary : StrandPalette.surfaceInset,
                            in: Capsule())
                .overlay(Capsule().stroke(selected ? StrandPalette.textPrimary : StrandPalette.hairline,
                                          lineWidth: 1))
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

// MARK: - Coaching

/// The journal's primary product surface. It deliberately owns no persistence of its own: every
/// occurrence is read from and written through Repository's existing journal API, preserving the
/// canonical question keys consumed by What Moves You.
struct CoachingRootView: View {
    @EnvironmentObject private var repo: Repository
    @StateObject private var catalog = JournalCatalogStore()

    @State private var importedQuestions: [String] = []
    @State private var todayAnswers: [String: Bool] = [:]
    @State private var todayNumeric: [String: Double] = [:]
    @State private var recentEntries: [CoachingRecentEntry] = []
    @State private var coachingMemberships: [CoachingBehaviorMembership] = []
    @State private var stacks: [CoachingStack] = []
    @State private var loaded = false
    @State private var savedMessage: String?

    private var todayKey: String { Repository.localDayKey(Date()) }
    private var activeItems: [JournalCatalogItem] {
        catalog.resolvedItems(imported: importedQuestions)
            .sorted { ($0.sortIndex, $0.display) < ($1.sortIndex, $1.display) }
    }
    private var loggedCount: Int {
        activeItems.filter { todayAnswers[$0.canonical] != nil || todayNumeric[$0.canonical] != nil }.count
    }
    private var quickItems: [JournalCatalogItem] {
        let quick = coachingMemberships.filter { $0.isActive && $0.isQuickAdd }.map(\.canonicalQuestion)
        let keys = quick.isEmpty ? Array(activeItems.prefix(6).map(\.canonical)) : quick
        let byKey = Dictionary(uniqueKeysWithValues: activeItems.map { ($0.canonical, $0) })
        return keys.compactMap { byKey[$0] }
    }

    var body: some View {
        NavigationStack {
            ScreenScaffold(title: "Coaching", subtitle: "Small check-ins, useful patterns") {
                if loaded {
                    VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                        checkInCard
                        shortcutsCard
                        quickAddSection
                        recentSection
                        NoteCard("Entries stay on this device and feed the same What Moves You analysis as the classic journal.",
                                 style: .privacy)
                    }
                } else {
                    ComingSoon(what: "Loading today’s check-in…", symbol: "checkmark.circle")
                }
            }
            .task(id: repo.refreshSeq) { await load() }
        }
        .tint(StrandPalette.journalAccent)
    }

    private var checkInCard: some View {
        PaperCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                HStack(spacing: NoopMetrics.space4) {
                    let progress = activeItems.isEmpty ? 0 : Double(loggedCount) / Double(activeItems.count)
                    CoachingProgressRing(value: progress,
                                         label: "\(Int((progress * 100).rounded()))%")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Today’s check-in")
                            .font(StrandFont.title2)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("\(loggedCount) of \(activeItems.count) logged")
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textSecondary)
                        if let savedMessage {
                            Label(savedMessage, systemImage: "checkmark.circle.fill")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                }

                NavigationLink {
                    CoachingCheckInView { Task { await load() } }
                } label: {
                    Label("Continue check-in", systemImage: "arrow.right")
                        .font(StrandFont.headline.weight(.semibold))
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: NoopMetrics.controlHeight)
                        .background(StrandPalette.journalAccent,
                                    in: RoundedRectangle(cornerRadius: NoopButtonMetrics.cornerRadius,
                                                         style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the existing journal check-in")
            }
        }
    }

    private var shortcutsCard: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Shortcuts")
            PaperCard {
                VStack(spacing: 0) {
                    coachingActionRow(title: "Repeat yesterday", subtitle: "Copy yesterday’s logged behaviors",
                                      icon: "arrow.counterclockwise", dot: StrandPalette.journalAccent) {
                        Task { await repeatYesterday() }
                    }
                    Divider().overlay(StrandPalette.hairline)
                    if let stack = stacks.first {
                        NavigationLink { CoachingStackDetailView(stack: stack) { Task { await load() } } } label: {
                            HStack(spacing: 12) {
                                Circle().fill(stack.isActive ? StrandPalette.journalAccent : StrandPalette.textTertiary)
                                    .frame(width: 8, height: 8)
                                Image(systemName: "square.stack.3d.up")
                                    .foregroundStyle(StrandPalette.textPrimary).frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Stacks").font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                                    Text(stack.name).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                                }
                                Spacer()
                                StatusBadge(stack.isActive ? "Active" : "Paused", style: stack.isActive ? .success : .queued)
                                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                            .frame(minHeight: NoopMetrics.rowHeight)
                        }
                        .buttonStyle(.plain)
                    } else {
                        SettingsRow(icon: "square.stack.3d.up", title: "Stacks", subtitle: "No stacks configured") {
                            StatusBadge("Not configured", style: .notConnected)
                        }
                    }
                    Divider().overlay(StrandPalette.hairline)
                    NavigationLink { CoachingBehaviorSettingsView() } label: {
                        SettingsRow(icon: "slider.horizontal.3", title: "Edit behaviors",
                                    subtitle: "Names, groups and logging type")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var quickAddSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            HStack {
                SectionHeader("Quick Add")
                Spacer()
                NavigationLink { CoachingQuickAddView() } label: {
                    Text("More").font(StrandFont.caption.weight(.semibold))
                        .foregroundStyle(StrandPalette.journalAccent)
                }
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: NoopMetrics.space3) {
                ForEach(quickItems) { item in
                    Button { Task { await quickLog(item) } } label: {
                        HStack(spacing: 8) {
                            Image(systemName: todayAnswers[item.canonical] == true ? "checkmark.circle.fill" : "plus.circle")
                                .foregroundStyle(StrandPalette.journalAccent)
                            Text(coachingShortDisplayName(for: item))
                                .font(StrandFont.caption.weight(.medium))
                                .foregroundStyle(StrandPalette.textPrimary)
                                .lineLimit(2)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .background(StrandPalette.journalAccent.opacity(0.10),
                                    in: RoundedRectangle(cornerRadius: NoopMetrics.radius2, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: NoopMetrics.radius2, style: .continuous)
                            .strokeBorder(StrandPalette.journalAccent.opacity(0.22), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Recent Entries")
            PaperCard {
                if recentEntries.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Image(systemName: "square.and.pencil")
                            .foregroundStyle(StrandPalette.journalAccent)
                        Text("Nothing logged yet").font(StrandFont.body.weight(.semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("Your latest check-ins will appear here.").font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(recentEntries.prefix(5).enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { Divider().overlay(StrandPalette.hairline) }
                            HStack(spacing: 12) {
                                Circle().fill(StrandPalette.journalAccent.opacity(0.16)).frame(width: 34, height: 34)
                                    .overlay(Image(systemName: entry.numeric == nil ? "checkmark" : "number")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(StrandPalette.journalAccent))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.display).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                                        .lineLimit(1)
                                    Text(entry.day).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                                }
                                Spacer()
                                if let numeric = entry.numeric {
                                    TinyMetricBadge(CoachingRecentEntry.format(numeric), tint: StrandPalette.journalAccent)
                                } else {
                                    Text(entry.answeredYes ? "Yes" : "No")
                                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                                }
                            }
                            .frame(minHeight: NoopMetrics.rowHeight)
                        }
                    }
                }
            }
        }
    }

    private func coachingActionRow(title: LocalizedStringKey, subtitle: LocalizedStringKey,
                                   icon: String, dot: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Circle().fill(dot).frame(width: 8, height: 8)
                Image(systemName: icon).foregroundStyle(StrandPalette.textPrimary).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                    Text(subtitle).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .frame(minHeight: NoopMetrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @MainActor private func load() async {
        let imported = await repo.importedJournalEntries()
        let all = await repo.journalEntries()
        let answers = await repo.nativeJournalAnswers(day: todayKey)
        let numeric = await repo.nativeJournalNumeric(day: todayKey)
        importedQuestions = Array(Set(imported.map(\.question))).sorted()
        let resolved = catalog.resolvedItems(imported: importedQuestions)
        if let store = await repo.storeHandle() {
            let defaults = resolved.enumerated().map { index, item in
                CoachingBehaviorMembership(setId: "daily-fundamentals", canonicalQuestion: item.canonical,
                                           coachingGroup: coachingPresentationGroup(for: item).rawValue,
                                           sortIndex: index, isActive: true, isQuickAdd: index < 6)
            }
            if let set = try? await store.ensureDefaultCoachingSet(name: "Daily fundamentals", memberships: defaults) {
                coachingMemberships = (try? await store.coachingMemberships(setId: set.id)) ?? []
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
            stacks = (try? await store.coachingStacks()) ?? []
        }
        todayAnswers = answers
        todayNumeric = numeric
        recentEntries = all.reversed().prefix(12).map {
            CoachingRecentEntry(day: $0.day,
                                display: catalog.displayName(for: $0.question),
                                answeredYes: $0.answeredYes,
                                numeric: $0.numericValue)
        }
        loaded = true
    }

    @MainActor private func quickLog(_ item: JournalCatalogItem) async {
        await repo.saveJournalAnswer(day: todayKey, question: item.canonical, answeredYes: true)
        savedMessage = "Saved locally"
        await load()
    }

    @MainActor private func repeatYesterday() async {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        let key = Repository.localDayKey(yesterday)
        let answers = await repo.nativeJournalAnswers(day: key)
        let numeric = await repo.nativeJournalNumeric(day: key)
        for (question, answer) in answers {
            if let value = numeric[question] {
                await repo.saveJournalNumeric(day: todayKey, question: question, value: value)
            } else {
                await repo.saveJournalAnswer(day: todayKey, question: question, answeredYes: answer)
            }
        }
        savedMessage = answers.isEmpty ? "Nothing logged yesterday" : "Yesterday repeated"
        await load()
    }
}

private struct CoachingProgressRing: View {
    let value: Double
    let label: String
    var body: some View {
        ZStack {
            Circle().stroke(StrandPalette.journalAccent.opacity(0.14), lineWidth: 7)
            Circle().trim(from: 0, to: min(max(value, 0), 1))
                .stroke(StrandPalette.journalAccent,
                        style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(label).font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
        }
        .frame(width: 76, height: 76)
        .accessibilityLabel("\(Int(value * 100)) percent complete")
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

private enum CoachingCheckInControl {
    case toggle
    case quantity(step: Double, unit: String)
}

/// Full daily check-in. Grouping and control choice are presentation only; immutable catalog
/// canonicals remain the keys for every Repository write.
struct CoachingCheckInView: View {
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @StateObject private var catalog = JournalCatalogStore()

    private let onSaved: () -> Void
    @State private var importedQuestions: [String] = []
    @State private var answers: [String: Bool] = [:]
    @State private var quantities: [String: Double] = [:]
    @State private var collapsed: Set<CoachingCheckInGroup> = []
    @State private var loaded = false
    @State private var saving = false
    @State private var activeCanonicals: Set<String> = []

    init(onSaved: @escaping () -> Void = {}) { self.onSaved = onSaved }

    private var todayKey: String { Repository.localDayKey(Date()) }
    private var items: [JournalCatalogItem] {
        let resolved = catalog.resolvedItems(imported: importedQuestions)
            .sorted { ($0.sortIndex, $0.display) < ($1.sortIndex, $1.display) }
        return activeCanonicals.isEmpty ? resolved : resolved.filter { activeCanonicals.contains($0.canonical) }
    }
    private var answeredCount: Int {
        items.filter { answers[$0.canonical] != nil || quantities[$0.canonical] != nil }.count
    }
    private var progress: Double { items.isEmpty ? 0 : Double(answeredCount) / Double(items.count) }

    var body: some View {
        ScreenScaffold(title: "Evening Check-In", subtitle: "Saved locally", backAction: { dismiss() }) {
            if loaded {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                    progressHeader
                    ForEach(CoachingCheckInGroup.allCases) { group in
                        groupCard(group)
                    }
                    classicLink
                    actions
                }
            } else {
                ComingSoon(what: "Loading your behaviors…", symbol: "checkmark.circle")
            }
        }
        .task { await load() }
        .tint(StrandPalette.journalAccent)
        .navigationBarBackButtonHidden(true)
    }

    private var progressHeader: some View {
        PaperCard {
            HStack(spacing: NoopMetrics.space4) {
                CoachingProgressRing(value: progress, label: "\(Int((progress * 100).rounded()))%")
                VStack(alignment: .leading, spacing: 5) {
                    Text("How did today go?").font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                    Text("\(answeredCount) of \(items.count) behaviors answered")
                        .font(StrandFont.body).foregroundStyle(StrandPalette.textSecondary)
                    Label("Nothing leaves this device", systemImage: "lock.fill")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }

    private func groupItems(_ group: CoachingCheckInGroup) -> [JournalCatalogItem] {
        items.filter { coachingGroup(for: $0) == group }
    }

    @ViewBuilder private func groupCard(_ group: CoachingCheckInGroup) -> some View {
        let rows = groupItems(group)
        if !rows.isEmpty {
            PaperCard {
                VStack(spacing: 0) {
                    Button {
                        if collapsed.contains(group) { collapsed.remove(group) } else { collapsed.insert(group) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: group.icon).foregroundStyle(StrandPalette.journalAccent).frame(width: 24)
                            Text(group.rawValue).font(StrandFont.cardTitle).foregroundStyle(StrandPalette.textPrimary)
                            Spacer()
                            Text("\(rows.count)").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                            Image(systemName: collapsed.contains(group) ? "chevron.right" : "chevron.down")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        .frame(minHeight: NoopMetrics.rowHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if !collapsed.contains(group) {
                        ForEach(rows) { item in
                            Divider().overlay(StrandPalette.hairline)
                            checkInRow(item)
                        }
                    }
                }
            }
        }
    }

    private func checkInRow(_ item: JournalCatalogItem) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.display).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(controlCaption(item)).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer(minLength: 8)
            switch control(for: item) {
            case .toggle:
                Toggle("", isOn: answerBinding(item.canonical))
                    .labelsHidden()
                    .tint(StrandPalette.journalAccent)
            case let .quantity(step, unit):
                quantityControl(item, step: step, unit: unit)
            }
        }
        .frame(minHeight: NoopMetrics.rowHeight)
    }

    private func quantityControl(_ item: JournalCatalogItem, step: Double, unit: String) -> some View {
        HStack(spacing: 6) {
            Button { adjust(item.canonical, by: -step) } label: {
                Image(systemName: "minus").frame(width: 30, height: 30)
                    .background(StrandPalette.inset, in: Circle())
            }
            .buttonStyle(.plain)
            VStack(spacing: 0) {
                Text(CoachingRecentEntry.format(quantities[item.canonical] ?? 0))
                    .font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary)
                Text(unit).font(StrandFont.micro).foregroundStyle(StrandPalette.textSecondary)
            }
            .frame(minWidth: 46)
            Button { adjust(item.canonical, by: step) } label: {
                Image(systemName: "plus").frame(width: 30, height: 30)
                    .background(StrandPalette.journalAccent.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(StrandPalette.textPrimary)
    }

    private var classicLink: some View {
        NavigationLink { InsightsView(focusedJournal: true) } label: {
            PaperCard {
                SettingsRow(icon: "list.bullet.rectangle", title: "Open classic journal",
                            subtitle: "Use Yes / No chips or edit custom questions")
            }
        }
        .buttonStyle(.plain)
    }

    private var actions: some View {
        HStack(spacing: NoopMetrics.space3) {
            Button("Cancel") { dismiss() }
                .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
            Button {
                Task { await save() }
            } label: {
                Label(saving ? "Saving…" : "Save check-in", systemImage: "checkmark")
            }
            .buttonStyle(CoachingAccentButtonStyle())
            .disabled(saving)
        }
    }

    private func answerBinding(_ canonical: String) -> Binding<Bool> {
        Binding(get: { answers[canonical] ?? false }, set: { answers[canonical] = $0 })
    }

    private func adjust(_ canonical: String, by step: Double) {
        let next = max(0, (quantities[canonical] ?? 0) + step)
        quantities[canonical] = next
        answers[canonical] = next > 0
    }

    private func coachingGroup(for item: JournalCatalogItem) -> CoachingCheckInGroup {
        coachingPresentationGroup(for: item)
    }

    private func control(for item: JournalCatalogItem) -> CoachingCheckInControl {
        if item.kind.isNumeric { return .quantity(step: 1, unit: item.kind.unitLabel ?? "units") }
        let q = JournalCatalogStore.norm(item.canonical)
        if q.contains("alcohol") { return .quantity(step: 1, unit: "servings") }
        if q.contains("caffeine") { return .quantity(step: 1, unit: "servings") }
        if q.contains("magnesium") { return .quantity(step: 1, unit: "dose") }
        if q.contains("sauna") { return .quantity(step: 10, unit: "min") }
        return .toggle
    }

    private func controlCaption(_ item: JournalCatalogItem) -> String {
        switch control(for: item) {
        case .toggle: return String(localized: "Tap if this happened")
        case let .quantity(_, unit): return String(localized: "Log \(unit)")
        }
    }

    @MainActor private func load() async {
        let imported = await repo.importedJournalEntries()
        importedQuestions = Array(Set(imported.map(\.question))).sorted()
        let resolved = catalog.resolvedItems(imported: importedQuestions)
        if let store = await repo.storeHandle() {
            let defaults = resolved.enumerated().map { index, item in
                CoachingBehaviorMembership(setId: "daily-fundamentals", canonicalQuestion: item.canonical,
                                           coachingGroup: coachingPresentationGroup(for: item).rawValue,
                                           sortIndex: index, isActive: true, isQuickAdd: index < 6)
            }
            if let set = try? await store.ensureDefaultCoachingSet(name: "Daily fundamentals", memberships: defaults) {
                let membership = (try? await store.coachingMemberships(setId: set.id)) ?? []
                activeCanonicals = Set(membership.filter(\.isActive).map(\.canonicalQuestion))
            }
        }
        answers = await repo.nativeJournalAnswers(day: todayKey)
        quantities = await repo.nativeJournalNumeric(day: todayKey)
        loaded = true
    }

    @MainActor private func save() async {
        saving = true
        for item in items where answers[item.canonical] != nil || quantities[item.canonical] != nil {
            if let value = quantities[item.canonical], value > 0 {
                await repo.saveJournalNumeric(day: todayKey, question: item.canonical, value: value)
            } else {
                await repo.saveJournalAnswer(day: todayKey, question: item.canonical,
                                             answeredYes: answers[item.canonical] ?? false)
            }
        }
        saving = false
        onSaved()
        dismiss()
    }
}

private struct CoachingAccentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(StrandFont.headline.weight(.semibold))
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity)
            .frame(height: NoopMetrics.controlHeight)
            .background(StrandPalette.journalAccent,
                        in: RoundedRectangle(cornerRadius: NoopButtonMetrics.cornerRadius,
                                             style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.4)
    }
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
        ScreenScaffold(title: "Behavior Settings", subtitle: "Your check-in set", backAction: { dismiss() }) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                activeSetCard
                addButton
                SectionHeader("Behaviors", overline: "Drag to reorder")
                PaperCard {
                    VStack(spacing: 0) {
                        ForEach(Array(memberships.enumerated()), id: \.element.id) { index, membership in
                            if index > 0 { Divider().overlay(StrandPalette.hairline) }
                            behaviorRow(membership, index: index)
                        }
                    }
                }
                NoteCard("Active controls whether an item appears in Check-In. Quick Add controls the Coaching shortcut grid. Neither setting changes journal history or What Moves You keys.",
                         style: .info)
            }
        }
        .task { await load() }
        .sheet(isPresented: $showAdd) { CoachingAddBehaviorSheet(catalog: catalog) { Task { await load() } } }
        .tint(StrandPalette.journalAccent)
        .navigationBarBackButtonHidden(true)
    }

    private var activeSetCard: some View {
        PaperCard {
            HStack(spacing: 12) {
                Circle().fill(StrandPalette.journalAccent.opacity(0.14)).frame(width: 44, height: 44)
                    .overlay(Image(systemName: "checklist").foregroundStyle(StrandPalette.journalAccent))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Active behavior set").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    Text(activeSet?.name ?? "Daily fundamentals")
                        .font(StrandFont.cardTitle).foregroundStyle(StrandPalette.textPrimary)
                }
                Spacer()
                Menu("Change Set") {
                    Button(activeSet?.name ?? "Daily fundamentals") {}
                }
                .font(StrandFont.caption.weight(.semibold))
                .foregroundStyle(StrandPalette.journalAccent)
            }
        }
    }

    private var addButton: some View {
        Button { showAdd = true } label: {
            Label("Add custom behavior", systemImage: "plus")
                .font(StrandFont.body.weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .frame(height: NoopMetrics.controlHeight)
                .background(StrandPalette.journalAccent.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: NoopMetrics.radius3, style: .continuous))
        }
        .buttonStyle(.plain)
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
                .buttonStyle(CoachingAccentButtonStyle())
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
                    .font(StrandFont.caption.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
                    .frame(maxWidth: .infinity).frame(height: 36)
                    .background(StrandPalette.journalAccent.opacity(logged ? 0.18 : 0.10), in: Capsule())
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
