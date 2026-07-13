import SwiftUI
import StrandDesign

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

                    Divider().overlay(StrandPalette.hairline)
                    addRow
                }
            }
        }
        .sheet(item: $renaming) { item in renameSheet(item) }
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
        HStack {
            Text(verbatim: item.display)   // display = rename ?? canonical; data, not a UI literal
                .font(StrandFont.body)
                .foregroundStyle(item.hidden ? StrandPalette.textTertiary : StrandPalette.textPrimary)
            Spacer()
            if editing {
                editControls(item)
            } else if item.kind.isNumeric {
                numericField(item)
            } else {
                answerPill("Yes", q: item.canonical, value: true)
                answerPill("No", q: item.canonical, value: false)
            }
        }
    }

    // MARK: - Numeric field

    private func numericField(_ item: JournalCatalogItem) -> some View {
        let current = numericAnswers[item.canonical]
        return HStack(spacing: 6) {
            stepperButton("minus", q: item.canonical, current: current)
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
            stepperButton("plus", q: item.canonical, current: current)
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

    private func stepperButton(_ symbol: String, q: String, current: Double?) -> some View {
        Button {
            let base = current ?? 0
            let next = max(0, symbol == "plus" ? base + 1 : base - 1)
            commitNumeric(q, value: next)
        } label: {
            Image(systemName: "\(symbol).circle")
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(symbol == "plus" ? "Increase" : "Decrease")
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
        Button { catalog.remove(item.canonical) } label: {
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
    private var quickItems: [JournalCatalogItem] { Array(activeItems.prefix(6)) }

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
                    CoachingProgressRing(value: activeItems.isEmpty ? 0 : Double(loggedCount) / Double(activeItems.count),
                                         label: "\(loggedCount)")
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
                    InsightsView(focusedJournal: true)
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
                    HStack(spacing: 12) {
                        Circle().fill(StrandPalette.textTertiary).frame(width: 8, height: 8)
                        Image(systemName: "square.stack.3d.up")
                            .foregroundStyle(StrandPalette.textPrimary).frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Stacks").font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                            Text("No stacks configured").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        }
                        Spacer()
                        StatusBadge("Not configured", style: .notConnected)
                    }
                    .frame(minHeight: NoopMetrics.rowHeight)
                    Divider().overlay(StrandPalette.hairline)
                    NavigationLink { InsightsView(focusedJournal: true) } label: {
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
                NavigationLink { InsightsView(focusedJournal: true) } label: {
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
                            Text(item.display)
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
