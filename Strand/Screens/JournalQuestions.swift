import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Coaching catalog helpers

/// Shared by the one-page Journal (`CoachingRootView`, `JournalQuickLogSection`) and the Coach sheet.
enum CoachingCheckInGroup: String, CaseIterable, Identifiable {
    case sleep = "Sleep setup"
    case fuel = "Fuel"
    case training = "Training & activity"
    case recovery = "Recovery & stress"
    case supplements = "Supplements & medication"

    var id: String { rawValue }
    /// The group's name as the Journal's lists show it, looked up in the string table.
    var title: LocalizedStringKey { LocalizedStringKey(rawValue) }
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

// MARK: - Editing rules

/// What the question page changes, kept out of the views so each edit is one catalog call a test can drive.
/// The stored key (`canonical`) is never touched, so history, logged and imported, stays under the question.
@MainActor
enum JournalQuestionEditing {
    enum Answer: CaseIterable, Hashable {
        case yesNo, number

        var title: String {
            switch self {
            case .yesNo: return String(localized: "Yes / No")
            case .number: return String(localized: "Number")
            }
        }
    }

    static func answer(of item: JournalCatalogItem) -> Answer { item.kind.isNumeric ? .number : .yesNo }

    /// Yes / No is `.bool`. Number starts without a unit, and a question that already counts keeps the unit it has.
    static func setAnswer(_ answer: Answer, for canonical: String, in catalog: JournalCatalogStore) {
        switch answer {
        case .yesNo:
            catalog.setKind(canonical, to: .bool)
        case .number:
            guard catalog.item(for: canonical)?.kind.isNumeric != true else { return }
            catalog.setKind(canonical, to: .numeric(unitLabel: nil))
        }
    }

    /// The one on/off state: the Journal asks a question that is neither hidden nor switched off. A question with no
    /// membership row yet is asked, as the Journal does.
    static func isShown(_ item: JournalCatalogItem, membership: CoachingBehaviorMembership?) -> Bool {
        !item.hidden && (membership?.isActive ?? true)
    }

    /// Turning a question on also brings back one that an earlier hide had put away. Turning it off only switches it
    /// off, so a custom question is never lost by a toggle.
    static func setShown(_ shown: Bool, canonical: String, membership: CoachingBehaviorMembership,
                         in catalog: JournalCatalogStore) -> CoachingBehaviorMembership {
        if shown { catalog.restore(canonical) }
        return CoachingBehaviorMembership(setId: membership.setId, canonicalQuestion: membership.canonicalQuestion,
                                          coachingGroup: membership.coachingGroup, sortIndex: membership.sortIndex,
                                          isActive: shown, isQuickAdd: membership.isQuickAdd)
    }

    /// Only a custom question can be deleted; a built-in one is switched off instead.
    static func delete(_ canonical: String, from catalog: JournalCatalogStore) -> Bool {
        guard catalog.isCustom(canonical) else { return false }
        catalog.remove(canonical)
        return true
    }

    /// A stable accessibility identifier suffix for a question, e.g. "did-you-drink-any-alcohol".
    static func slug(_ canonical: String) -> String {
        let words = JournalCatalogStore.norm(canonical)
            .map { $0.isLetter || $0.isNumber ? String($0) : " " }.joined()
            .split(separator: " ")
        return words.joined(separator: "-")
    }
}

// MARK: - Edit questions

/// Everything about the questions the Journal asks, in one place: which are on, and (one tap in) each one's name,
/// group, answer type and whether it can be deleted. Listed in the same groups, in the same order, as the Journal.
struct CoachingBehaviorSettingsView: View {
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @StateObject private var catalog = JournalCatalogStore()
    @State private var importedQuestions: [String] = []
    @State private var activeSet: CoachingBehaviorSet?
    @State private var memberships: [CoachingBehaviorMembership] = []
    @State private var showAdd = false
    @State private var openedQuestion: String?
    /// The question just added, opened on its own page once the Add sheet has gone.
    @State private var addedQuestion: String?

    /// Every question, switched off or hidden ones included, in the Journal's own order.
    private var items: [JournalCatalogItem] {
        catalog.resolvedItems(imported: importedQuestions, includeHidden: true)
    }

    private func membership(for item: JournalCatalogItem) -> CoachingBehaviorMembership? {
        let key = JournalCatalogStore.norm(item.canonical)
        return memberships.first { JournalCatalogStore.norm($0.canonicalQuestion) == key }
    }

    private struct GroupedQuestions: Identifiable {
        let group: CoachingCheckInGroup
        let items: [JournalCatalogItem]
        var id: String { group.rawValue }
    }

    private var groupedItems: [GroupedQuestions] {
        let all = items
        return CoachingCheckInGroup.allCases.compactMap { group in
            let inGroup = all.filter { coachingPresentationGroup(for: $0) == group }
                .sorted { ($0.sortIndex, $0.display) < ($1.sortIndex, $1.display) }
            return inGroup.isEmpty ? nil : GroupedQuestions(group: group, items: inGroup)
        }
    }

    var body: some View {
        ScreenScaffold(title: "Edit questions", subtitle: "What the Journal asks", backAction: { dismiss() }) {
            VStack(alignment: .leading, spacing: 0) {
                FlatSection("Your questions", systemImage: "checklist", tint: .journal,
                            trailing: .text(activeSet?.name ?? String(localized: "Daily fundamentals"))) {
                    VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                        Text("Turn a question off to stop being asked. Tap one to rename it, move it or change its answer.")
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
                    }
                }
                ForEach(groupedItems) { entry in
                    FlatSectionSeparator()
                    FlatSection(entry.group.title, systemImage: entry.group.icon, tint: .journal, contentSpacing: 2) {
                        VStack(spacing: 0) {
                            ForEach(Array(entry.items.enumerated()), id: \.element.canonical) { index, item in
                                if index > 0 { FlatRowSeparator() }
                                questionRow(item)
                            }
                        }
                    }
                }
                FlatSectionSeparator()
                NavigationLink { InsightsView() } label: {
                    JournalLinkRow(title: "More Insights",
                                   subtitle: "Mind check-ins, the caffeine log and what your journal moves",
                                   icon: "chart.xyaxis.line")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("journal.moreInsights")
            }
            .padding(.top, NoopMetrics.space2)
        }
        .task { await load() }
        .sheet(isPresented: $showAdd, onDismiss: openAddedQuestion) {
            CoachingAddBehaviorSheet(catalog: catalog) { canonical in addedQuestion = canonical }
        }
        .navigationDestination(item: $openedQuestion) { canonical in
            JournalQuestionPage(catalog: catalog, canonical: canonical, importedQuestions: importedQuestions,
                                isShown: shownBinding(canonical: canonical)) {
                Task { await load() }
            }
        }
        .tint(StrandPalette.journalAccent)
        .navigationBarBackButtonHidden(true)
    }

    private func questionRow(_ item: JournalCatalogItem) -> some View {
        let slug = JournalQuestionEditing.slug(item.canonical)
        let name = coachingShortDisplayName(for: item)
        return HStack(spacing: NoopMetrics.space3) {
            Button { openedQuestion = item.canonical } label: {
                HStack(spacing: NoopMetrics.space3) {
                    Image(systemName: coachingIcon(for: item))
                        .font(StrandFont.body)
                        .foregroundStyle(coachingTint(for: item))
                        .frame(width: 24)
                        .accessibilityHidden(true)
                    Text(verbatim: name)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(FlatRowPressStyle())
            .accessibilityLabel(Text(verbatim: name))
            .accessibilityHint(Text("Opens this question"))
            .accessibilityIdentifier("journal.question.\(slug)")
            Toggle(isOn: shownBinding(canonical: item.canonical)) { Text(verbatim: name) }
                .labelsHidden()
                .noopToggle()
                .accessibilityIdentifier("journal.question.\(slug).toggle")
        }
    }

    private func openAddedQuestion() {
        guard let canonical = addedQuestion else { return }
        addedQuestion = nil
        Task {
            await load()
            openedQuestion = canonical
        }
    }

    private func shownBinding(canonical: String) -> Binding<Bool> {
        let key = JournalCatalogStore.norm(canonical)
        return Binding(
            get: {
                guard let item = items.first(where: { JournalCatalogStore.norm($0.canonical) == key }) else { return false }
                return JournalQuestionEditing.isShown(item, membership: membership(for: item))
            },
            set: { shown in setShown(shown, canonical: canonical) })
    }

    private func setShown(_ shown: Bool, canonical: String) {
        let key = JournalCatalogStore.norm(canonical)
        guard let index = memberships.firstIndex(where: { JournalCatalogStore.norm($0.canonicalQuestion) == key }) else { return }
        memberships[index] = JournalQuestionEditing.setShown(shown, canonical: canonical,
                                                             membership: memberships[index], in: catalog)
        persist()
    }

    private func persist() {
        let rows = memberships
        Task { if let store = await repo.storeHandle() { try? await store.upsertCoachingMemberships(rows) } }
    }

    @MainActor private func load() async {
        let imported = await repo.importedJournalEntries()
        importedQuestions = Array(Set(imported.map(\.question))).sorted()
        let all = catalog.resolvedItems(imported: importedQuestions, includeHidden: true)
        guard let store = await repo.storeHandle() else { return }
        let defaults = all.enumerated().map { index, item in
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

// MARK: - One question

/// One question's page: its name, group, answer and whether the Journal asks it. A custom question can also be
/// deleted here. The name saves as you type; the stored key never changes, so history stays joined.
struct JournalQuestionPage: View {
    @ObservedObject var catalog: JournalCatalogStore
    let canonical: String
    let importedQuestions: [String]
    @Binding var isShown: Bool
    let onChanged: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var loadedName = false
    @State private var confirmingDelete = false

    init(catalog: JournalCatalogStore, canonical: String, importedQuestions: [String],
         isShown: Binding<Bool>, onChanged: @escaping () -> Void) {
        self.catalog = catalog
        self.canonical = canonical
        self.importedQuestions = importedQuestions
        self._isShown = isShown
        self.onChanged = onChanged
    }

    private var item: JournalCatalogItem? {
        let key = JournalCatalogStore.norm(canonical)
        return catalog.resolvedItems(imported: importedQuestions, includeHidden: true)
            .first { JournalCatalogStore.norm($0.canonical) == key }
    }

    private var currentName: String { item.map(coachingShortDisplayName(for:)) ?? canonical }
    private var slug: String { JournalQuestionEditing.slug(canonical) }

    var body: some View {
        ScreenScaffold(title: LocalizedStringKey(currentName), backAction: { leave() }) {
            VStack(alignment: .leading, spacing: 0) {
                FlatSection("Question", systemImage: "checklist", tint: .journal, contentSpacing: 2) {
                    VStack(spacing: 0) {
                        nameRow
                        FlatRowSeparator()
                        groupRow
                        FlatRowSeparator()
                        answerRow
                        FlatRowSeparator()
                        showRow
                    }
                }
                if item?.custom == true {
                    FlatSectionSeparator()
                    deleteButton
                }
            }
            .padding(.top, NoopMetrics.space2)
        }
        .onAppear {
            guard !loadedName else { return }
            loadedName = true
            draft = currentName
        }
        .onDisappear { commitName() }
        .tint(StrandPalette.journalAccent)
        .navigationBarBackButtonHidden(true)
    }

    private var nameRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: NoopMetrics.space3) {
                Text("Name").font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                TextField("Question name", text: $draft)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .multilineTextAlignment(.trailing)
                    .submitLabel(.done)
                    .onSubmit { commitName() }
                    .onChange(of: draft) { _, _ in saveWhileTyping() }
                    .accessibilityIdentifier("journal.question.\(slug).name")
            }
            .frame(minHeight: 56)
            Text("History stays under the original question so WHOOP imports still line up.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, NoopMetrics.space2)
        }
    }

    private var groupRow: some View {
        let current = item?.group ?? .other
        return menuRow("Group", value: current.title, identifier: "journal.question.\(slug).group") {
            ForEach(JournalGroup.displayOrder, id: \.self) { group in
                Button {
                    catalog.setGroup(canonical, to: group)
                    onChanged()
                } label: {
                    if group == current { Label(group.title, systemImage: "checkmark") } else { Text(group.title) }
                }
            }
        }
    }

    private var answerRow: some View {
        let current = item.map(JournalQuestionEditing.answer(of:)) ?? .yesNo
        return menuRow("Answer", value: current.title, identifier: "journal.question.\(slug).answer") {
            ForEach(JournalQuestionEditing.Answer.allCases, id: \.self) { answer in
                Button {
                    JournalQuestionEditing.setAnswer(answer, for: canonical, in: catalog)
                    onChanged()
                } label: {
                    if answer == current { Label(answer.title, systemImage: "checkmark") } else { Text(answer.title) }
                }
            }
        }
    }

    private func menuRow<Options: View>(_ title: LocalizedStringKey, value: String, identifier: String,
                                        @ViewBuilder options: () -> Options) -> some View {
        Menu {
            options()
        } label: {
            HStack(spacing: NoopMetrics.space3) {
                Text(title).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                Spacer(minLength: 8)
                Text(verbatim: value).font(StrandFont.body).foregroundStyle(StrandPalette.textSecondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(FlatRowPressStyle())
        .accessibilityIdentifier(identifier)
    }

    private var showRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: NoopMetrics.space3) {
                Text("Show in Journal").font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                Spacer(minLength: 8)
                Toggle("Show in Journal", isOn: $isShown)
                    .labelsHidden()
                    .noopToggle()
                    .accessibilityIdentifier("journal.question.\(slug).show")
            }
            .frame(minHeight: 56)
            Text("Turn it off to stop being asked. Your history stays.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, NoopMetrics.space2)
        }
    }

    private var deleteButton: some View {
        Button { confirmingDelete = true } label: {
            Text("Delete question")
                .font(StrandFont.subhead.weight(.semibold))
                .foregroundStyle(StrandPalette.statusCritical)
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(FlatRowPressStyle())
        .accessibilityIdentifier("journal.question.\(slug).delete")
        .confirmationDialog("Delete this question?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete question", role: .destructive) {
                if JournalQuestionEditing.delete(canonical, from: catalog) {
                    onChanged()
                    dismiss()
                }
            }
            Button("Keep question", role: .cancel) {}
        } message: {
            Text("Your past answers are kept, but the Journal stops asking it.")
        }
    }

    /// A non-blank name saves as it is typed. A blank one waits for the field to be left, so clearing the box to
    /// retype does not snap back to the original wording mid-edit.
    private func saveWhileTyping() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard loadedName, item != nil, !trimmed.isEmpty, trimmed != currentName else { return }
        catalog.rename(canonical, to: trimmed)
    }

    private func commitName() {
        guard loadedName, item != nil else { return }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != currentName else { return }
        catalog.rename(canonical, to: trimmed)
        draft = currentName
        onChanged()
    }

    private func leave() {
        commitName()
        dismiss()
    }
}

private struct CoachingAddBehaviorSheet: View {
    @ObservedObject var catalog: JournalCatalogStore
    /// Called with the new question's key once it is added, so the list can open its page.
    let onAdded: (String) -> Void
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
                        let canonical = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        catalog.addCustom(canonical, group: group)
                        onAdded(canonical)
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
