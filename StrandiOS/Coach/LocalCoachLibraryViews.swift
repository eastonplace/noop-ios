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
            List {
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
                                Text(conversation.title).font(.headline).foregroundStyle(StrandPalette.textPrimary).lineLimit(2)
                                Text(conversation.messages.last?.text ?? "No messages yet")
                                    .font(.subheadline).foregroundStyle(StrandPalette.textSecondary).lineLimit(2)
                                Text(conversation.updatedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                                    .font(.caption).foregroundStyle(StrandPalette.textTertiary)
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
        }.tint(StrandPalette.accent).preferredColorScheme(.dark)
    }
}

struct LocalCoachMemoryView: View {
    @EnvironmentObject private var coach: LocalCoachEngine
    @State private var editing: LocalCoachMemory?
    @State private var adding = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if coach.isPreview { LocalCoachFixtureLabel() }
                VStack(alignment: .leading, spacing: 15) {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 34, weight: .ultraLight)).foregroundStyle(StrandPalette.accent)
                    Text("A coach that\nknows your context.")
                        .font(.system(size: 29, weight: .medium, design: .rounded))
                    Text("Your goals, routines and preferences. You decide what is remembered, and you can edit or remove it at any time.")
                        .font(.subheadline).foregroundStyle(StrandPalette.textSecondary).lineSpacing(3)
                }
                Toggle("Use my memory", isOn: $coach.preferences.memoryEnabled)
                    .font(.subheadline).tint(StrandPalette.accent)
                if !coach.preferences.usePersonalData {
                    Text("Allow local records in Coach settings to add and use personal memory.")
                        .font(.footnote).foregroundStyle(StrandPalette.warning)
                }
                ForEach(LocalCoachMemory.Category.allCases) { category in
                    let entries = coach.memories.filter { $0.category == category }
                    if !entries.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(category.title.uppercased()).font(.system(size: 10, weight: .medium, design: .monospaced))
                                .tracking(1.2).foregroundStyle(StrandPalette.textTertiary)
                            ForEach(entries) { memory in
                                Button { editing = memory } label: {
                                    HStack(alignment: .top, spacing: 14) {
                                        Circle().fill(memory.enabled ? StrandPalette.accent : StrandPalette.textTertiary)
                                            .frame(width: 6, height: 6).padding(.top, 6)
                                        Text(memory.text).font(.system(size: 14)).lineSpacing(3)
                                            .foregroundStyle(StrandPalette.textSecondary).multilineTextAlignment(.leading)
                                        Spacer(minLength: 0)
                                        Image(systemName: "pencil").font(.footnote).foregroundStyle(StrandPalette.textTertiary)
                                    }.modifier(LocalCoachPanel())
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                Button { adding = true } label: {
                    Label("Add something about you", systemImage: "plus")
                }.buttonStyle(LocalCoachPrimaryButtonStyle())
                    .disabled(!coach.preferences.usePersonalData || !coach.preferences.memoryEnabled)
                    .accessibilityIdentifier("coach.addMemory")
                Label("Saved locally. Never added automatically.", systemImage: "lock")
                    .font(.caption).foregroundStyle(StrandPalette.textTertiary)
            }.padding(22)
        }
        .sheet(isPresented: $adding) { LocalCoachMemoryEditor(memory: nil) }
        .sheet(item: $editing) { LocalCoachMemoryEditor(memory: $0) }
        .accessibilityIdentifier("coach.memory")
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
            Form {
                Section("What should Coach know?") {
                    TextField("A goal, routine or preference", text: $text, axis: .vertical).lineLimit(4...10)
                    Picker("Category", selection: $category) {
                        ForEach(LocalCoachMemory.Category.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Use in conversations", isOn: $enabled)
                }
                if memory != nil {
                    Section { Button("Delete memory", role: .destructive) { confirmDelete = true } }
                }
                if let error = coach.errorText { Text(error).foregroundStyle(StrandPalette.warning) }
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
        }.tint(StrandPalette.accent).preferredColorScheme(.dark)
    }
}

struct LocalCoachSettingsView: View {
    @EnvironmentObject private var coach: LocalCoachEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
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
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Coach settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.tint(StrandPalette.accent).preferredColorScheme(.dark)
    }
}

struct LocalCoachSourcesView: View {
    @Environment(\.dismiss) private var dismiss
    let evidence: [LocalCoachEvidence]
    let title: String
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("These are the records supplied to Coach. Record dates can differ from today when your strap has not synced.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(evidence) { item in
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.title).font(.headline)
                            Text(item.detail).font(.subheadline).textSelection(.enabled)
                            Text(item.source).font(.caption).foregroundStyle(.secondary)
                            if let date = item.date { Text(date, format: .dateTime.year().month().day()).font(.caption).foregroundStyle(.secondary) }
                        }.padding(.vertical, 4)
                    }
                }
                if evidence.isEmpty {
                    ContentUnavailableView("No records supplied", systemImage: "doc.text.magnifyingglass", description: Text("Allow local data and sync your source to build personal context."))
                }
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.tint(StrandPalette.accent).preferredColorScheme(.dark)
    }
}
#endif
