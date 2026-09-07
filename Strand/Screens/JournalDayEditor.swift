import SwiftUI
import StrandDesign
import WhoopStore

/// Edits belong to the selected morning. Loading, typing and saving never consult a moving "today" key.
struct JournalDayEditor: View {
    let date: Date
    @ObservedObject var catalog: JournalCatalogStore
    var includeInactive = false
    let onSaved: () -> Void
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @State private var draft: JournalDraft
    @State private var originalRows: [JournalEntry] = []
    @State private var items: [JournalCatalogItem] = []
    @State private var collapsed: Set<JournalGroup> = []
    @State private var search: String
    @State private var onlyUnanswered = false
    @State private var invalidKeys: Set<String> = []
    @State private var numericText: [String: String] = [:]
    @State private var originalNumericKeys: Set<String> = []
    @State private var loaded = false
    @State private var saving = false
    @State private var failure: String?
    @State private var notice: String?
    @State private var discard = false
    @State private var copying = false

    init(date: Date = .now, catalog: JournalCatalogStore, includeInactive: Bool = false,
         initialSearch: String = "", onSaved: @escaping () -> Void = {}) {
        self.date = date
        self.catalog = catalog
        self.includeInactive = includeInactive
        self.onSaved = onSaved
        _draft = State(initialValue: JournalDraft(day: JournalExperiencePolicy.dayKey(date), answers: [:]))
        _search = State(initialValue: initialSearch)
    }
    private var dirty: Bool { !draft.changedKeys.isEmpty || !invalidKeys.isEmpty }
    private var completed: Int { items.filter { draft.answers[$0.canonical] != nil }.count }
    private var visible: [JournalCatalogItem] {
        items.filter { item in
            (!onlyUnanswered || draft.answers[item.canonical] == nil || draft.baseline[item.canonical] == nil || invalidKeys.contains(item.canonical)) &&
            (search.isEmpty || item.display.localizedCaseInsensitiveContains(search) || item.canonical.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        ExperienceScroll {
            if loaded {
                header
                TextField("Find a question", text: $search)
                    .font(StrandFont.body).padding(14)
                    .background(StrandPalette.card, in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityLabel("Find a journal question")
                Toggle("Only unanswered", isOn: $onlyUnanswered)
                    .font(StrandFont.body).tint(StrandPalette.journalAccent)
                if let notice {
                    ExperienceMessage(title: "Draft updated", message: notice, symbol: "doc.on.doc")
                }
                if visible.isEmpty {
                    ExperienceMessage(title: items.isEmpty ? "No questions selected" : "No questions in this view",
                                      message: items.isEmpty ? "Select questions in Journal settings." : "Change the search or turn off the unanswered filter.",
                                      symbol: "checklist")
                }
                ForEach(JournalGroup.displayOrder, id: \.self) { group in groupCard(group) }
                Text("An unanswered question stays unanswered. Save when you are ready.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            } else if failure == nil {
                ProgressView("Loading questions…").frame(maxWidth: .infinity).padding(32)
            }
            if let failure {
                ExperienceMessage(title: loaded ? "Check-in has not saved" : "Check-in could not load",
                                  message: failure, symbol: "exclamationmark.triangle", tint: StrandPalette.statusWarning)
                if !loaded { NoopButton("Retry", kind: .secondary, fullWidth: true) { Task { await load() } } }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { saveBar }
        .navigationTitle(date.formatted(.dateTime.month(.abbreviated).day()))
        .navigationBarBackButtonHidden(true)
        .noopFocusedTask()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { requestClose() }.disabled(saving)
            }
            ToolbarItem(placement: .confirmationAction) {
                Menu {
                    Button("Fill from previous day", systemImage: "doc.on.doc") { Task { await copyPreviousDay() } }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("Check-in options")
                .disabled(!loaded || saving || copying)
            }
        }
        .interactiveDismissDisabled(dirty || saving)
        .confirmationDialog("Discard unsaved changes?", isPresented: $discard, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        } message: { Text("Your previously saved answers will stay unchanged.") }
        .task { if !loaded { await load() } }
    }

    private var header: some View {
        PaperCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 16) {
                    ExperienceProgress(completed: completed, total: items.count)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Morning check-in").font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                        Text(date.formatted(date: .complete, time: .omitted))
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                Text("Describe the day and night before this morning.")
                    .font(StrandFont.body).foregroundStyle(StrandPalette.textSecondary)
                Label(dirty ? "Unsaved changes" : "Saved answers loaded", systemImage: dirty ? "pencil.circle" : "checkmark.circle")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.journalAccent)
            }
        }
    }

    @ViewBuilder private func groupCard(_ group: JournalGroup) -> some View {
        let rows = visible.filter { $0.group == group }
        if !rows.isEmpty {
            PaperCard {
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        if collapsed.contains(group) { collapsed.remove(group) } else { collapsed.insert(group) }
                    } label: {
                        HStack(spacing: 10) {
                            Text(group.title).font(StrandFont.cardTitle)
                            Spacer(minLength: 4)
                            Text("\(rows.filter { draft.answers[$0.canonical] != nil }.count)/\(rows.count)")
                                .font(StrandFont.caption).monospacedDigit().foregroundStyle(StrandPalette.textSecondary)
                            Image(systemName: collapsed.contains(group) ? "chevron.down" : "chevron.up")
                        }
                        .foregroundStyle(StrandPalette.textPrimary).frame(minHeight: 48).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(group.title), \(collapsed.contains(group) ? "collapsed" : "expanded")")
                    if !collapsed.contains(group) {
                        ForEach(rows) { item in
                            Divider().overlay(StrandPalette.hairline)
                            answerRow(item).padding(.vertical, 16).id(item.canonical)
                        }
                    }
                }
            }
        }
    }

    private func answerRow(_ item: JournalCatalogItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.display).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if item.kind.isNumeric || originalNumericKeys.contains(item.canonical) {
                JournalQuantityInput(title: item.display, unit: item.kind.unitLabel ?? "",
                                     answer: binding(item.canonical),
                                     text: Binding(get: { numericText[item.canonical, default: ""] },
                                                   set: { numericText[item.canonical] = $0 })) { invalid in
                    if invalid { invalidKeys.insert(item.canonical) } else { invalidKeys.remove(item.canonical) }
                }
            } else {
                HStack(spacing: 10) {
                    answerButton("Yes", value: true, question: item.canonical)
                    answerButton("No", value: false, question: item.canonical)
                    if draft.answers[item.canonical] != nil {
                        Button { draft.set(nil, for: item.canonical) } label: {
                            Image(systemName: "xmark.circle").frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain).foregroundStyle(StrandPalette.textSecondary)
                        .accessibilityLabel("Clear answer for \(item.display)")
                    }
                }
                Text(draft.answers[item.canonical] == nil ? "Not answered" : "Answer selected")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .disabled(saving)
        .accessibilityElement(children: .contain)
    }
    private func answerButton(_ title: String, value: Bool, question: String) -> some View {
        let selected = draft.answers[question] == .boolean(value)
        return Button { draft.set(.boolean(value), for: question) } label: {
            HStack(spacing: 6) {
                if selected { Image(systemName: "checkmark") }
                Text(LocalizedStringKey(title)).font(StrandFont.body.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(selected ? StrandPalette.onInk : StrandPalette.textPrimary)
            .background(selected ? StrandPalette.accent : StrandPalette.inset, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(question)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func binding(_ key: String) -> Binding<JournalAnswer?> {
        Binding(get: { draft.answers[key] }, set: { draft.set($0, for: key) })
    }
    private var saveBar: some View {
        VStack(spacing: 8) {
            if failure != nil, loaded {
                Text("Save failed. Your edits remain on screen.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.statusWarning)
            }
            if !invalidKeys.isEmpty {
                Text("Correct \(invalidKeys.count) numeric field(s) before saving.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.statusWarning)
            }
            NoopButton(saving ? "Saving check-in…" : "Save check-in", systemImage: saving ? "hourglass" : "checkmark",
                       kind: .primary, fullWidth: true) { Task { await save() } }
                .disabled(!loaded || saving || copying || !invalidKeys.isEmpty || draft.changedKeys.isEmpty)
        }
        .padding(16).background(StrandPalette.appCanvas)
        .overlay(alignment: .top) { Rectangle().fill(StrandPalette.hairline).frame(height: 1) }
    }
    private func requestClose() { if dirty { discard = true } else { dismiss() } }

    @MainActor private func load() async {
        failure = nil
        do {
            let config = try await JournalExperienceStore.configuration(repo: repo, catalog: catalog)
            let rows = try await JournalExperienceStore.read(repo: repo, from: draft.day, to: draft.day)
            try Task.checkCancellation()
            items = includeInactive ? config.items.filter { !$0.hidden } : config.activeItems
            originalRows = rows
            originalNumericKeys = Set(rows.filter { $0.numericValue != nil }.map(\.question))
            numericText = Dictionary(rows.compactMap { row in
                row.numericValue.map { (row.question, JournalNumberInput.format($0)) }
            }, uniquingKeysWith: { _, last in last })
            draft = JournalDraft(day: draft.day, answers: JournalExperienceStore.answers(rows))
            loaded = true
        } catch is CancellationError { return }
        catch { failure = error.localizedDescription }
    }
    @MainActor private func copyPreviousDay() async {
        guard loaded, !saving, !copying else { return }
        copying = true
        defer { copying = false }
        do {
            let previous = JournalExperiencePolicy.dayKey(JournalExperiencePolicy.day(offset: 1, from: date))
            let rows = try await JournalExperienceStore.read(repo: repo, from: previous, to: previous)
            let existing = Set(draft.answers.keys)
            let count = draft.copyMissing(from: JournalExperienceStore.answers(rows), activeKeys: Set(items.map(\.canonical)).subtracting(invalidKeys))
            for (key, value) in draft.answers where !existing.contains(key) {
                if case .number(let number) = value { numericText[key] = JournalNumberInput.format(number) }
            }
            notice = "\(count) unanswered questions filled. Existing answers stayed unchanged. Review, then save."
        } catch { failure = error.localizedDescription }
    }
    @MainActor private func save() async {
        guard loaded, !saving, invalidKeys.isEmpty else { return }
        saving = true
        failure = nil
        do {
            let saved = try await JournalExperienceStore.save(repo: repo, draft: draft, baseline: originalRows)
            originalRows = saved
            draft.acceptSavedAnswers(JournalExperienceStore.answers(saved))
            saving = false
            onSaved()
            dismiss()
        } catch {
            saving = false
            failure = error.localizedDescription
        }
    }
}

private struct JournalQuantityInput: View {
    let title: String
    let unit: String
    @Binding var answer: JournalAnswer?
    @Binding var text: String
    let onInvalid: (Bool) -> Void
    private var invalid: Bool { JournalNumberInput.parse(text) == .invalid }
    @FocusState private var focused: Bool
    private var number: Double? { if case .number(let value) = answer { value } else { nil } }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                TextField("Not answered", text: $text)
                    .font(StrandFont.bodyNumber).monospacedDigit().focused($focused)
                    .padding(12).frame(minHeight: 44)
                    .background(StrandPalette.inset, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("\(title), \(unit)")
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                if !unit.isEmpty { Text(unit).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary) }
                Button { text = ""; answer = nil; focused = false } label: {
                    Image(systemName: "xmark.circle").frame(width: 44, height: 44)
                }.buttonStyle(.plain).accessibilityLabel("Clear \(title)")
            }
            if focused {
                Button("Done entering value") { focused = false }
                    .font(StrandFont.caption).frame(minHeight: 44).buttonStyle(.plain)
            }
            if invalid {
                Text("Enter a nonnegative number using your region’s decimal separator.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.statusWarning)
            } else if case .boolean(let yes) = answer {
                Text(yes ? "Saved as Yes. Enter a number to change it." : "Saved as No. Enter a number to change it.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            } else if number == 0 {
                Text("Zero is a recorded value.").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .onChange(of: number) { _, value in
            if !focused, !invalid { text = value.map { JournalNumberInput.format($0) } ?? "" }
        }
        .onChange(of: text) { _, value in
            switch JournalNumberInput.parse(value) {
            case .empty: answer = nil
            case .value(let number): answer = .number(number)
            case .invalid: break
            }
            onInvalid(invalid)
        }
    }
}
