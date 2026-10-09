#if os(iOS)
import SwiftUI
import StrandDesign

struct LocalCoachLibraryView: View {
    @EnvironmentObject private var coach: LocalCoachEngine
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var renaming: LocalCoachConversation?
    @State private var newTitle = ""
    let onSelect: () -> Void

    private var filtered: [LocalCoachConversation] {
        coach.conversations.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.messages.contains { $0.text.localizedCaseInsensitiveContains(search) } }
    }

    var body: some View {
        NavigationStack {
            NativeSettingsList {
                Section {
                    Button {
                        coach.newConversation()
                        onSelect()
                        dismiss()
                    } label: { Label("Start a conversation", systemImage: "square.and.pencil") }
                }
                Section("On this iPhone") {
                    ForEach(filtered) { conversation in
                        Button {
                            coach.selectConversation(conversation.id)
                            onSelect()
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(conversation.title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary).lineLimit(2)
                                Text(conversation.messages.last?.text ?? "No messages yet")
                                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary).lineLimit(2)
                                Text(conversation.updatedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            }.padding(.vertical, 5)
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) { coach.deleteConversation(conversation.id) }
                            Button("Rename") { newTitle = conversation.title; renaming = conversation }.tint(StrandPalette.accentMuted)
                        }
                    }
                }
                if !coach.messages.isEmpty {
                    Section {
                        ShareLink(item: coach.exportConversation()) {
                            Label("Export current conversation", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
            .overlay {
                if filtered.isEmpty && !search.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            .searchable(text: $search, prompt: "Find a conversation")
            .navigationTitle("Conversations")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("Rename conversation", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Title", text: $newTitle)
                Button("Save") { if let item = renaming { coach.renameConversation(item.id, title: newTitle) }; renaming = nil }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
        }
        .coachSettingsSheetEnvironment()
    }
}

struct LocalCoachMemoryView: View {
    @EnvironmentObject private var coach: LocalCoachEngine
    @State private var editing: LocalCoachMemory?
    @State private var adding = false

    private var canAdd: Bool { coach.preferences.usePersonalData && coach.preferences.memoryEnabled }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if coach.isPreview { LocalCoachFixtureLabel().padding(.bottom, NoopMetrics.space3) }
                header
                if coach.memories.isEmpty {
                    CoachSectionSeparator()
                    emptyMemory
                }
                ForEach(LocalCoachMemory.Category.allCases) { category in
                    let entries = coach.memories.filter { $0.category == category }
                    if !entries.isEmpty {
                        CoachSectionSeparator()
                        categorySection(category, entries)
                    }
                }
                Label("Saved locally. Never added automatically.", systemImage: "lock")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .padding(.top, NoopMetrics.space4)
            }
            .padding(.horizontal, NoopMetrics.space4)
            .padding(.top, CoachRhythm.pageTop)
            .padding(.bottom, CoachRhythm.pageBottom)
        }
        .sheet(isPresented: $adding) { LocalCoachMemoryEditor(memory: nil).noopSheetPresentation(largeFirst: true) }
        .sheet(item: $editing) { LocalCoachMemoryEditor(memory: $0).noopSheetPresentation(largeFirst: true) }
        .accessibilityIdentifier("coach.memory")
    }

    // MARK: Header

    /// What the page is for, the master switch, and (once something is remembered) the Add chip.
    private var header: some View {
        CoachSection("What Coach remembers", systemImage: "person.crop.circle.badge.checkmark", tint: .accent,
                     trailing: coach.memories.isEmpty ? .none : .custom(AnyView(addChip))) {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text("A coach that\nknows your context.").font(StrandFont.title1)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("Your goals, routines and preferences. You decide what is remembered, and you can edit or remove it at any time.")
                    .font(StrandFont.subhead).lineSpacing(3).foregroundStyle(StrandPalette.textSecondary)
            }
            Toggle("Use my memory", isOn: $coach.preferences.memoryEnabled)
                .font(StrandFont.subhead).noopToggle()
                .frame(minHeight: 44)
                // The row is 44pt tall for the touch target; take the spare air back where the section ends.
                .padding(.bottom, coach.preferences.usePersonalData ? -8 : 0)
            if !coach.preferences.usePersonalData {
                CoachNotice(text: Text("Allow local records in Coach settings to add and use personal memory."),
                            tone: .warning)
            }
        }
    }

    private var addChip: some View {
        Button { adding = true } label: {
            WidgetChip(appTitle: "Add", systemImage: "plus", showsChevron: false, overhangs: false)
                .chipHitTarget()
        }
        .buttonStyle(.plain)
        .disabled(!canAdd)
        .opacity(canAdd ? 1 : 0.45)
        .accessibilityLabel("Add something about you")
        .accessibilityIdentifier("coach.addMemory")
    }

    // MARK: Entries

    private func categorySection(_ category: LocalCoachMemory.Category, _ entries: [LocalCoachMemory]) -> some View {
        // Every category wears the Coach accent, like the other Coach eyebrows; only the symbol tells them apart.
        CoachSection(LocalizedStringKey(category.title), systemImage: Self.symbol(for: category), tint: .accent,
                     trailing: .text("\(entries.count)")) {
            VStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, memory in
                    if index > 0 {
                        Rectangle().fill(StrandPalette.hairline).frame(height: 1).accessibilityHidden(true)
                    }
                    memoryRow(memory)
                }
            }
            // The rows carry their own air; pull them in so the gaps under the eyebrow and above the next
            // section's hairline match the rest of the page.
            .padding(.top, -6)
            .padding(.bottom, -14)
        }
    }

    /// One fact, in the person's own words. A fact switched off stays listed, quiet, with an Off pill. The
    /// pencil chip says the row edits; the whole row is the button.
    private func memoryRow(_ memory: LocalCoachMemory) -> some View {
        Button { editing = memory } label: {
            HStack(alignment: .top, spacing: NoopMetrics.space3) {
                Text(memory.text).font(StrandFont.subhead).lineSpacing(3)
                    .foregroundStyle(memory.enabled ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: NoopMetrics.space1)
                if !memory.enabled { StatePill("Off", tone: .neutral, showsDot: false) }
                WidgetChip(systemImage: "pencil", showsChevron: false, overhangs: false)
            }
            .padding(.vertical, NoopMetrics.space3)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Edit")
    }

    private static func symbol(for category: LocalCoachMemory.Category) -> String {
        switch category {
        case .goals: "scope"
        case .identity: "person.crop.circle"
        case .lifestyle: "leaf"
        case .preferences: "slider.horizontal.3"
        case .events: "calendar"
        case .healthHistory: "cross.case"
        case .mood: "face.smiling"
        }
    }

    /// Nothing remembered yet: what goes here and the one action.
    private var emptyMemory: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            Text("Nothing saved yet").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
            Text("Add a goal, routine or preference and Coach will use it in your conversations.")
                .font(StrandFont.subhead).lineSpacing(3).foregroundStyle(StrandPalette.textSecondary)
            Button { adding = true } label: { Text("Add something about you") }
                .buttonStyle(CoachPrimaryPillStyle())
                .disabled(!canAdd)
                .accessibilityIdentifier("coach.addMemory")
        }
    }
}

private struct LocalCoachMemoryEditor: View {
    @EnvironmentObject private var coach: LocalCoachEngine
    @Environment(\.dismiss) private var dismiss
    let memory: LocalCoachMemory?
    @State private var text: String
    @State private var category: LocalCoachMemory.Category
    @State private var enabled: Bool
    @State private var confirmDelete = false

    init(memory: LocalCoachMemory?) {
        self.memory = memory
        _text = State(initialValue: memory?.text ?? "")
        _category = State(initialValue: memory?.category ?? .goals)
        _enabled = State(initialValue: memory?.enabled ?? true)
    }

    var body: some View {
        NavigationStack {
            NativeSettingsList {
                Section("What should Coach know?") {
                    TextField("A goal, routine or preference", text: $text, axis: .vertical).lineLimit(4...10)
                    Picker("Category", selection: $category) {
                        ForEach(LocalCoachMemory.Category.allCases) { Text(LocalizedStringKey($0.title)).tag($0) }
                    }
                    Toggle("Use in conversations", isOn: $enabled)
                }
                if memory != nil {
                    Section { Button("Delete memory", role: .destructive) { confirmDelete = true } }
                }
                if let error = coach.errorText { CoachNotice(error: error) }
            }
            .navigationTitle(memory == nil ? "Add memory" : "Edit memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if var value = memory {
                            value.text = text; value.category = category; value.enabled = enabled
                            coach.updateMemory(value)
                            if coach.memories.first(where: { $0.id == value.id })?.text == text.trimmingCharacters(in: .whitespacesAndNewlines) { dismiss() }
                        } else {
                            let count = coach.memories.count
                            coach.addMemory(text: text, category: category)
                            if coach.memories.count > count { dismiss() }
                        }
                    }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.utf8.count > 2_000)
                }
            }
            .confirmationDialog("Delete this memory?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete memory", role: .destructive) {
                    if let memory { coach.deleteMemory(memory.id) }
                    dismiss()
                }
            }
        }
        .coachSettingsSheetEnvironment()
    }
}

struct LocalCoachSettingsView: View {
    @EnvironmentObject private var coach: LocalCoachEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            NativeSettingsList {
                Section {
                    Label(coach.availability.title, systemImage: "apple.intelligence")
                    Toggle("Enable on-device Coach", isOn: $coach.preferences.enabled)
                    Toggle("Use my local records", isOn: $coach.preferences.usePersonalData)
                } header: { Text("Private intelligence") } footer: {
                    Text("Local Coach uses Apple’s on-device model. No API key is needed. It never falls back to a cloud model. Apple Intelligence must be enabled and its model downloaded on a supported device.")
                }
                Section("Make it yours") {
                    Picker("Coaching style", selection: $coach.preferences.style) {
                        Text("Direct and supportive").tag("Direct and supportive")
                        Text("Detailed and analytical").tag("Detailed and analytical")
                        Text("Calm and encouraging").tag("Calm and encouraging")
                    }
                    TextField("Anything else Coach should consider?", text: $coach.preferences.customInstructions, axis: .vertical)
                        .lineLimit(3...6)
                    Toggle("Use saved memory", isOn: $coach.preferences.memoryEnabled)
                    Toggle("Morning brief when I open Coach", isOn: $coach.preferences.autoBrief)
                    Toggle("Read replies aloud", isOn: $coach.preferences.speakReplies)
                }
                Section {
                    NavigationLink { SiriShortcutsSettingsView() } label: { Label("Siri & Shortcuts", systemImage: "waveform") }
                } header: { Text("Beyond the keyboard") } footer: {
                    Text("Siri can open Coach for your question, daily brief or workout plan. Personal records require your local-data permission.")
                }
                Section {
                    NavigationLink { CoachView() } label: { Label("Cloud coach", systemImage: "cloud") }
                } header: { Text("Separate advanced option") } footer: {
                    Text("The existing cloud coach has its own provider, API key and data-sharing consent. Local Coach does not use those settings.")
                }
                Section {
                    NavigationLink { LocalCoachDiagnosticsView() } label: {
                        Label("Testing & bug reports", systemImage: "ladybug")
                    }
                }
                Section("Model status") {
                    if let capacity = coach.contextCapacity { LabeledContent("Context capacity", value: "\(capacity.formatted()) tokens") }
                    if let seconds = coach.responseSeconds, !coach.isPreview {
                        LabeledContent("Last response", value: seconds.formatted(.number.precision(.fractionLength(1))) + " seconds")
                    }
                    Button("Check availability again") { Task { await coach.refresh() } }
                    Text("Coach can make mistakes. Check source records and review workout changes before saving. It is not a diagnostic service.")
                        .font(StrandFont.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Coach settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .coachSettingsSheetEnvironment()
    }
}

struct LocalCoachSourcesView: View {
    @Environment(\.dismiss) private var dismiss
    let evidence: [LocalCoachEvidence]
    let title: String
    var body: some View {
        NavigationStack {
            NativeSettingsList {
                Section {
                    Text("These are the records supplied to Coach. Record dates can differ from today when your strap has not synced.")
                        .font(StrandFont.subhead).foregroundStyle(.secondary)
                }
                ForEach(evidence) { item in
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.title).font(StrandFont.headline)
                            Text(item.detail).font(StrandFont.subhead).textSelection(.enabled)
                            Text(item.source).font(StrandFont.caption).foregroundStyle(.secondary)
                            if let date = item.date { Text(date, format: .dateTime.year().month().day()).font(StrandFont.caption).foregroundStyle(.secondary) }
                        }.padding(.vertical, 4)
                    }
                }
                if evidence.isEmpty {
                    ContentUnavailableView("No records supplied", systemImage: "doc.text.magnifyingglass", description: Text("Allow local data and sync your source to build personal context."))
                }
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .coachSettingsSheetEnvironment()
    }
}
#endif
