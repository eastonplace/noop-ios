import SwiftUI
import StrandDesign
import WhoopStore

/// Compatibility entry points keep existing routes and callers on the refreshed journal flow.
struct CoachingRootView: View {
    var body: some View { JournalExperienceView() }
}

struct CoachingCheckInView: View {
    @StateObject private var catalog = JournalCatalogStore()
    @State private var date = Date()
    var onSaved: () -> Void = {}
    var body: some View { JournalDayEditor(date: date, catalog: catalog, onSaved: onSaved) }
}

struct CoachingBehaviorSettingsView: View {
    @StateObject private var catalog = JournalCatalogStore()
    var body: some View { JournalBehaviorEditor(catalog: catalog) }
}

struct CoachingQuickAddView: View {
    @StateObject private var catalog = JournalCatalogStore()
    @State private var date = Date()
    var body: some View { JournalDayEditor(date: date, catalog: catalog) }
}

/// The inline Insights card opens the same safe editor. Its parent still owns the selected day and reload.
struct JournalLogCard: View {
    let importedQuestions: [String]
    let answers: [String: Bool]
    var numericAnswers: [String: Double] = [:]
    @Binding var dayOffset: Int
    let onChanged: () -> Void
    @StateObject private var catalog = JournalCatalogStore()
    @State private var target: EditTarget?
    @State private var settings = false
    private struct EditTarget: Identifiable { let id = UUID(); let date: Date }
    private var date: Date { JournalExperiencePolicy.day(offset: dayOffset) }
    private var items: [JournalCatalogItem] { catalog.resolvedItems(imported: importedQuestions) }
    private var count: Int { items.filter { answers[$0.canonical] != nil || numericAnswers[$0.canonical] != nil }.count }

    var body: some View {
        let morningLabel = "Morning of \(date.formatted(date: .abbreviated, time: .omitted))"
        return PaperCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 16) {
                    ExperienceProgress(completed: count, total: items.count)
                    ExperienceSectionHeading(title: "Journal", detail: morningLabel)
                }
                Picker("Morning", selection: $dayOffset) {
                    Text("Yesterday").tag(1)
                    Text("Today").tag(0)
                    Text("Tomorrow").tag(-1)
                }.pickerStyle(.segmented)
                Text("Describe the day and night before this morning.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                NoopButton("Edit check-in", systemImage: "square.and.pencil", kind: .primary, fullWidth: true) {
                    target = EditTarget(date: date)
                }
                JournalMoodCheckIn(date: date)
                Button("Manage journal questions") { settings = true }
                    .font(StrandFont.caption).frame(minHeight: 44)
            }
        }
        .onChange(of: dayOffset) { _, _ in onChanged() }
        .sheet(item: $target) { selected in
            NavigationStack {
                JournalDayEditor(date: selected.date, catalog: catalog, includeInactive: true, onSaved: onChanged)
            }.noopFocusedTask()
        }
        .sheet(isPresented: $settings) {
            NavigationStack {
                JournalBehaviorEditor(catalog: catalog, onSaved: onChanged)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { settings = false } } }
            }.noopFocusedTask()
        }
    }
}

/// A routine uses the same native journal transaction, including its provenance record.
struct CoachingStackDetailView: View {
    let stack: CoachingStack
    var onChanged: () -> Void = {}
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @StateObject private var catalog = JournalCatalogStore()
    @State private var items: [CoachingStackItem] = []
    @State private var selected: Set<String> = []
    @State private var notes = ""
    @State private var active = true
    @State private var loaded = false
    @State private var saving = false
    @State private var didSave = false
    @State private var failure: String?
    @State private var confirming = false
    @State private var discard = false
    @State private var edited = false
    @State private var day = JournalExperiencePolicy.dayKey(Date())
    @State private var submissionID = UUID().uuidString
    @State private var loggedAt = Int(Date().timeIntervalSince1970)
    @State private var lastUse: CoachingStackUse?

    var body: some View {
        let saveTitle: LocalizedStringKey = didSave ? "Routine saved" : saving ? "Saving…" : "Log selected items"
        return ExperienceScroll {
            ExperienceSectionHeading(title: stack.name, detail: "Morning of \(day)")
            if let description = stack.description {
                Text(description).font(StrandFont.body).foregroundStyle(StrandPalette.textSecondary)
            }
            if loaded {
                Toggle("Routine active", isOn: Binding(get: { active }, set: updateActive))
                    .tint(StrandPalette.journalAccent).disabled(saving)
                PaperCard {
                    VStack(alignment: .leading, spacing: 12) {
                        ExperienceSectionHeading(title: "This entry", detail: "Choose the items you completed")
                        ForEach(items) { item in
                            Button {
                                if selected.contains(item.canonicalQuestion) { selected.remove(item.canonicalQuestion) }
                                else { selected.insert(item.canonicalQuestion) }
                                edited = true
                            } label: {
                                HStack(alignment: .center, spacing: 12) {
                                    Image(systemName: selected.contains(item.canonicalQuestion) ? "checkmark.circle.fill" : "circle")
                                        .font(StrandFont.title2).foregroundStyle(StrandPalette.journalAccent)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(catalog.displayName(for: item.canonicalQuestion)).font(StrandFont.body)
                                        if let dose = item.dose, dose.isFinite {
                                            Text("\(JournalNumberInput.format(dose)) \(item.unit ?? "")")
                                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .foregroundStyle(StrandPalette.textPrimary).frame(minHeight: 56).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selected.contains(item.canonicalQuestion) ? .isSelected : [])
                            .disabled(saving || didSave)
                        }
                    }
                }
                TextField("Note for this entry", text: $notes, axis: .vertical)
                    .font(StrandFont.body).lineLimit(3...6).padding(16)
                    .background(StrandPalette.card, in: RoundedRectangle(cornerRadius: 16))
                    .disabled(saving || didSave)
                    .onChange(of: notes) { _, _ in if loaded { edited = true } }
                if let lastUse {
                    Label("\(lastUse.skipped ? "Skipped" : "Logged") \(lastUse.day)", systemImage: "clock")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                if didSave {
                    ExperienceMessage(title: "Routine saved", message: "The selected answers and routine record were saved together.",
                                      symbol: "checkmark.circle.fill", tint: StrandPalette.journalAccent)
                }
            } else if failure == nil { ProgressView("Loading routine…").padding(20) }
            if let failure {
                ExperienceMessage(title: "Routine has not saved", message: failure,
                                  symbol: "exclamationmark.triangle", tint: StrandPalette.statusWarning)
            }
        }
        .navigationTitle("Routine")
        .navigationBarBackButtonHidden(true)
        .noopFocusedTask()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { if edited && !didSave { discard = true } else { dismiss() } }.disabled(saving)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                NoopButton(saveTitle, systemImage: "checkmark",
                           kind: .primary, fullWidth: true) { confirming = true }
                    .disabled(!loaded || saving || didSave || selected.isEmpty)
                Button("Skip this routine") { Task { await save(skipped: true) } }
                    .font(StrandFont.caption).frame(minHeight: 44).disabled(!loaded || saving || didSave)
            }.padding(16).background(StrandPalette.appCanvas)
        }
        .confirmationDialog("Log the selected routine items?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Log selected items") { Task { await save(skipped: false) } }
            Button("Keep reviewing", role: .cancel) {}
        } message: { Text("These values will replace existing answers for the selected items on \(day). Other answers stay unchanged.") }
        .confirmationDialog("Discard this routine draft?", isPresented: $discard, titleVisibility: .visible) {
            Button("Discard draft", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        }
        .interactiveDismissDisabled(saving || (edited && !didSave))
        .task { await load() }
    }
    @MainActor private func load() async {
        do {
            guard let store = await repo.storeHandle() else { throw JournalExperienceStore.Failure.unavailable }
            let rows = try await store.coachingStackItems(stackId: stack.id)
            let uses = try await store.coachingStackUses(stackId: stack.id)
            try Task.checkCancellation()
            items = rows
            selected = Set(rows.map(\.canonicalQuestion))
            active = stack.isActive
            lastUse = uses.first
            loaded = true
        } catch is CancellationError { return }
        catch { failure = error.localizedDescription }
    }
    private func updateActive(_ value: Bool) {
        guard !saving else { return }
        saving = true
        Task { @MainActor in
            defer { saving = false }
            do {
                guard let store = await repo.storeHandle() else { throw JournalExperienceStore.Failure.unavailable }
                try await store.updateCoachingStack(id: stack.id, isActive: value, notes: stack.notes)
                let saved = try await store.coachingStacks()
                guard saved.first(where: { $0.id == stack.id })?.isActive == value else { throw NativeJournalEditError.verificationFailed }
                active = value
                onChanged()
            } catch { failure = error.localizedDescription }
        }
    }
    @MainActor private func save(skipped: Bool) async {
        guard !saving, !didSave else { return }
        saving = true
        failure = nil
        defer { saving = false }
        do {
            guard let store = await repo.storeHandle() else { throw JournalExperienceStore.Failure.unavailable }
            let rows = try await JournalExperienceStore.read(repo: repo, from: day, to: day)
            let baseline = Dictionary(rows.map { ($0.question, $0) }, uniquingKeysWith: { _, last in last })
            let checked = skipped ? [] : items.filter { selected.contains($0.canonicalQuestion) }
            let edits = checked.map { item in
                NativeJournalEdit(question: item.canonicalQuestion, expected: baseline[item.canonicalQuestion],
                                  replacement: JournalEntry(day: day, question: item.canonicalQuestion,
                                                            answeredYes: true, notes: notes.isEmpty ? nil : notes,
                                                            numericValue: item.dose))
            }
            let use = CoachingStackUse(id: submissionID, stackId: stack.id, day: day, loggedAt: loggedAt,
                                       notes: notes.isEmpty ? nil : notes, skipped: skipped)
            _ = try await store.applyNativeJournalEdits(day: day, edits: edits, stackUse: use)
            didSave = true
            edited = false
            lastUse = use
            onChanged()
            if skipped { dismiss() }
        } catch { failure = error.localizedDescription }
    }
}

struct CoachingStackDemoRoute: View {
    @EnvironmentObject private var repo: Repository
    @State private var stack: CoachingStack?
    @State private var loaded = false
    var body: some View {
        Group {
            if let stack { CoachingStackDetailView(stack: stack) }
            else if loaded { ExperienceMessage(title: "No routine configured", message: "Your saved routines will appear here.", symbol: "square.stack.3d.up") }
            else { ProgressView("Loading routine…") }
        }
        .task {
            guard let store = await repo.storeHandle() else { loaded = true; return }
            stack = try? await store.coachingStacks().first
            loaded = true
        }
    }
}
