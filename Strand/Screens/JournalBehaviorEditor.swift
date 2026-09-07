import SwiftUI
import StrandDesign
import WhoopStore

struct JournalBehaviorEditor: View {
    @ObservedObject var catalog: JournalCatalogStore
    var onSaved: () -> Void = {}
    @EnvironmentObject private var repo: Repository
    @State private var config: JournalExperienceConfiguration?
    @State private var search = ""
    @State private var saving = false
    @State private var failure: String?
    @State private var newItem = false
    @State private var editing: JournalCatalogItem?
    @State private var removing: JournalCatalogItem?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ExperienceScroll {
            ExperienceSectionHeading(title: "Your journal questions", detail: config?.setName ?? "Daily fundamentals")
            TextField("Search questions", text: $search).font(StrandFont.body).padding(14)
                .background(StrandPalette.card, in: RoundedRectangle(cornerRadius: 14))
            NoopButton("Add a question", systemImage: "plus", kind: .primary, fullWidth: true) { newItem = true }
            Text("Active questions appear in check-ins. Quick entries appear on the journal home screen.")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            if let config {
                ForEach(config.memberships) { membership in
                    if let item = config.items.first(where: { $0.canonical == membership.canonicalQuestion }),
                       search.isEmpty || item.display.localizedCaseInsensitiveContains(search) {
                        itemCard(item, membership: membership)
                    }
                }
            } else if failure == nil {
                ProgressView("Loading questions…").frame(maxWidth: .infinity).padding(20)
            }
            if let failure {
                ExperienceMessage(title: "Change could not be verified", message: failure,
                                  symbol: "exclamationmark.triangle", tint: StrandPalette.statusWarning)
                NoopButton("Reload saved settings", kind: .secondary, fullWidth: true) { Task { await load() } }
            }
        }
        .navigationTitle("Journal settings")
        .noopFocusedTask()
        .task { await load() }
        .sheet(isPresented: $newItem) {
            JournalQuestionEditor(catalog: catalog, item: nil) { Task { await load(); onSaved() } }
        }
        .sheet(item: $editing) { item in
            JournalQuestionEditor(catalog: catalog, item: item) { Task { await load(); onSaved() } }
        }
        .confirmationDialog("Remove this question from your journal?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            if let removing {
                Button(removing.custom ? "Delete custom question" : "Hide question", role: .destructive) {
                    catalog.remove(removing.canonical)
                    self.removing = nil
                    Task { await load(); onSaved() }
                }
            }
            Button("Keep question", role: .cancel) { removing = nil }
        } message: { Text("Saved journal history stays unchanged. Hidden built-in questions can be restored here.") }
    }

    private func itemCard(_ item: JournalCatalogItem, membership: CoachingBehaviorMembership) -> some View {
        PaperCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.display).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(item.group.title) · \(item.kind.isNumeric ? "Number" : "Yes / No")")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    }
                    Spacer(minLength: 0)
                    Menu {
                        Button("Edit question") { editing = item }
                        Button("Move up") { move(membership, delta: -1) }
                            .disabled(config?.memberships.first?.id == membership.id)
                        Button("Move down") { move(membership, delta: 1) }
                            .disabled(config?.memberships.last?.id == membership.id)
                        if item.hidden {
                            Button("Restore question") { catalog.restore(item.canonical); Task { await load(); onSaved() } }
                        } else {
                            Button(item.custom ? "Delete question" : "Hide question", role: .destructive) { removing = item }
                        }
                    } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                    .accessibilityLabel("Options for \(item.display)")
                }
                if item.hidden {
                    Text("Hidden · Restore from the options menu").font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                } else {
                    Toggle("Active", isOn: binding(membership, quick: false)).tint(StrandPalette.journalAccent)
                        .accessibilityLabel("Active, \(item.display)")
                    Toggle("Quick entry", isOn: binding(membership, quick: true)).tint(StrandPalette.journalAccent)
                        .accessibilityLabel("Quick entry, \(item.display)")
                }
            }
            .disabled(saving)
        }
    }
    private func binding(_ row: CoachingBehaviorMembership, quick: Bool) -> Binding<Bool> {
        Binding(get: { quick ? row.isQuickAdd : row.isActive }, set: { value in
            guard let config else { return }
            let rows = config.memberships.map { current in
                current.id == row.id ? CoachingBehaviorMembership(
                    setId: current.setId, canonicalQuestion: current.canonicalQuestion,
                    coachingGroup: current.coachingGroup, sortIndex: current.sortIndex,
                    isActive: quick ? current.isActive : value,
                    isQuickAdd: quick ? value : current.isQuickAdd) : current
            }
            persist(rows)
        })
    }
    private func move(_ row: CoachingBehaviorMembership, delta: Int) {
        guard var rows = config?.memberships, let index = rows.firstIndex(where: { $0.id == row.id }),
              rows.indices.contains(index + delta) else { return }
        rows.swapAt(index, index + delta)
        persist(rows.enumerated().map { offset, current in
            .init(setId: current.setId, canonicalQuestion: current.canonicalQuestion,
                  coachingGroup: current.coachingGroup, sortIndex: offset,
                  isActive: current.isActive, isQuickAdd: current.isQuickAdd)
        })
    }
    private func persist(_ rows: [CoachingBehaviorMembership]) {
        guard !saving else { return }
        saving = true
        failure = nil
        Task { @MainActor in
            defer { saving = false }
            do {
                guard let store = await repo.storeHandle(), let setId = rows.first?.setId else {
                    throw JournalExperienceStore.Failure.unavailable
                }
                try await store.upsertCoachingMemberships(rows)
                let saved = try await store.coachingMemberships(setId: setId)
                let expected = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
                let actual = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
                guard expected.allSatisfy({ actual[$0.key] == $0.value }) else { throw NativeJournalEditError.verificationFailed }
                await load()
                onSaved()
            } catch { failure = error.localizedDescription }
        }
    }
    @MainActor private func load() async {
        failure = nil
        do { config = try await JournalExperienceStore.configuration(repo: repo, catalog: catalog) }
        catch is CancellationError { return }
        catch { failure = error.localizedDescription }
    }
}

private struct JournalQuestionEditor: View {
    @ObservedObject var catalog: JournalCatalogStore
    let item: JournalCatalogItem?
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var numeric = false
    @State private var unit = ""
    @State private var group: JournalGroup = .other
    @State private var discard = false
    private var dirty: Bool {
        name != (item?.display ?? "") || numeric != (item?.kind.isNumeric ?? false) ||
        unit != (item?.kind.unitLabel ?? "") || group != (item?.group ?? .other)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Question") { TextField("Question or habit name", text: $name) }
                Section("Answer") {
                    Toggle("Record a number", isOn: $numeric)
                    if numeric { TextField("Unit, such as minutes", text: $unit) }
                }
                Section("Group") {
                    Picker("Group", selection: $group) {
                        ForEach(JournalGroup.displayOrder, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                Section {
                    Text("Renaming keeps the original history key. Changing the answer type affects future edits.")
                        .font(StrandFont.footnote)
                }
            }
            .scrollContentBackground(.hidden)
            .background(StrandPalette.appCanvas)
            .navigationTitle(item == nil ? "Add question" : "Edit question")
            .noopFocusedTask()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { if dirty { discard = true } else { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let kind: JournalKind = numeric ? .numeric(unitLabel: unit.isEmpty ? nil : unit) : .bool
                        if let item {
                            catalog.rename(item.canonical, to: name)
                            catalog.setKind(item.canonical, to: kind)
                            catalog.setGroup(item.canonical, to: group)
                        } else { catalog.addCustom(name, kind: kind, group: group) }
                        onSaved()
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .confirmationDialog("Discard question changes?", isPresented: $discard, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
        }
        .interactiveDismissDisabled(dirty)
        .onAppear {
            name = item?.display ?? ""
            numeric = item?.kind.isNumeric ?? false
            unit = item?.kind.unitLabel ?? ""
            group = item?.group ?? .other
        }
    }
}
