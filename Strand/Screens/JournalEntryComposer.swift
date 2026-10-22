import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

struct JournalEntryPresentation: Identifiable {
    let id = UUID()
    let day: String
    let sourceIdentity: String
}

/// Transient text and review state belong to this sheet. Typing/dictating/parsing never saves; the
/// repository receives only the explicitly included, edited values from the visible Save action.
struct JournalEntryComposer: View {
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var catalog: JournalCatalogStore
    let presentation: JournalEntryPresentation
    let importedQuestions: [String]
    let currentDay: String
    let onSaved: () -> Void

    @StateObject private var voice = JournalVoice()
    @State private var entryText = ""
    @State private var parsed: JournalEntryParser.Draft?
    @State private var review: JournalEntryReview?
    @State private var edits: [JournalEntryEditableValue] = []
    @State private var sourceContext: String?
    @State private var sourceChanged = false
    @State private var preparing = false
    @State private var saving = false
    @State private var message: String?
    @State private var operationID: UUID?
    @State private var operation: Task<Void, Never>?
    @State private var voiceOperation: Task<Void, Never>?
    @State private var presented = true

    private var fields: [JournalEntryParser.Field] {
        catalog.resolvedItems(imported: importedQuestions).map(\.entryParserField)
    }

    private var canReview: Bool {
        !entryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && entryText.utf8.count <= JournalEntryParser.maximumInputBytes
            && !preparing && !saving && !voice.isBusy && voice.transcript.isEmpty && !sourceChanged
    }

    private var selectedValues: [JournalEntryParser.Suggestion]? {
        let included = edits.filter(\.included)
        guard !included.isEmpty else { return nil }
        let values = included.compactMap(\.suggestion)
        return values.count == included.count ? values : nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Wake day: \(presentation.day)")
                            .font(StrandFont.headline)
                        Text("Describe the night and day leading into this morning. Review the suggested answers before saving.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    entryEditor
                    PaperCard { dictationSection }
                    if let message {
                        Text(message)
                            .font(StrandFont.subhead)
                            .foregroundStyle(sourceChanged ? StrandPalette.error : StrandPalette.textSecondary)
                            .accessibilityIdentifier("journal-entry-message")
                    }
                    Button(action: prepareReview) {
                        HStack {
                            if preparing { ProgressView() }
                            Text(review == nil ? "Review entries" : "Review again")
                        }.frame(maxWidth: .infinity)
                    }
                    .buttonStyle(NoopButtonStyle(review == nil ? .primary : .secondary, fullWidth: true))
                    .disabled(!canReview)
                    .accessibilityIdentifier("journal-entry-review")

                    if let parsed { unmatchedSection(parsed) }
                    if let review { reviewSection(review) }
                }
                .padding(NoopMetrics.screenPadding)
            }
            .background(StrandPalette.canvas)
            .navigationTitle("Journal entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(saving)
                }
            }
            .interactiveDismissDisabled(saving)
        }
        .tint(StrandPalette.accent)
        .font(StrandFont.body)
        .onAppear { presented = true }
        .onChange(of: entryText) { _, _ in
            guard !saving else { return }
            invalidateReview()
        }
        .onChange(of: fields) { _, _ in
            invalidateReview()
            cancelDictation()
            message = "Your journal catalog changed. Review the entry again with the current items."
        }
        .onChange(of: currentDay) { _, day in
            if day != presentation.day { invalidateContext() }
        }
        .onChange(of: repo.journalEntrySourceIdentity) { _, identity in
            if presentation.sourceIdentity != identity { invalidateContext() }
        }
        .onChange(of: repo.journalEntrySourceContext) { _, context in
            if let sourceContext, sourceContext != context { invalidateContext() }
        }
        .onDisappear {
            presented = false
            operationID = nil
            operation?.cancel()
            cancelDictation()
        }
    }

    private var entryEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your entry").font(StrandFont.headline)
            PaperCard(padding: 8) {
                TextEditor(text: $entryText)
                    .frame(minHeight: 150)
                    .scrollContentBackground(.hidden)
                    .disabled(saving)
                    .accessibilityLabel("Journal entry text")
                    .accessibilityIdentifier("journal-entry-text")
            }
            Text("For example: “I took magnesium and felt stressed.” For quantities, include a unit and an existing journal item, such as “Caffeine: 200 mg.”")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
            if entryText.utf8.count > JournalEntryParser.maximumInputBytes {
                Text("This entry is too long. Shorten it before reviewing.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.error)
            }
        }
    }

    private var dictationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                switch voice.phase {
                case .idle:
                    Button {
                        voiceOperation = Task { await voice.start() }
                    } label: { Label(voice.transcript.isEmpty ? "Dictate" : "Dictate again", systemImage: "mic") }
                        .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
                        .disabled(saving || sourceChanged)
                        .accessibilityIdentifier("journal-entry-dictate")
                case .requestingPermission:
                    HStack { ProgressView(); Text("Preparing dictation…") }
                    Button("Cancel dictation", action: cancelDictation)
                        .buttonStyle(NoopButtonStyle(.tertiary, fullWidth: true))
                case .recording:
                    Label("Listening…", systemImage: "mic.fill")
                    Button("Finish dictation") { voice.finish() }
                        .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
                case .finishing:
                    HStack { ProgressView(); Text("Finishing transcript…") }
                    Button("Cancel dictation", action: cancelDictation)
                        .buttonStyle(NoopButtonStyle(.tertiary, fullWidth: true))
                }
            }
            Text("Dictation runs on this iPhone when your language and device support it. Typing is always available.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
            if !voice.transcript.isEmpty {
                Text(voice.transcript)
                    .font(StrandFont.body)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("journal-entry-transcript")
                if !voice.isBusy {
                    VStack(spacing: 8) {
                        Button("Use captured text", action: useTranscript)
                            .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
                        Button("Discard dictation", action: cancelDictation)
                            .buttonStyle(NoopButtonStyle(.tertiary, fullWidth: true))
                    }
                }
            }
            if let error = voice.errorText {
                Text(error).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .disabled(saving)
    }

    @ViewBuilder private func unmatchedSection(_ draft: JournalEntryParser.Draft) -> some View {
        if !draft.unmatched.isEmpty {
            PaperCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Unmatched details").font(StrandFont.headline)
                    Text("These words remain in this draft. Saving adds only the checked journal answers below.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    ForEach(Array(draft.unmatched.enumerated()), id: \.offset) { _, text in
                        Text(text).font(StrandFont.subhead).textSelection(.enabled)
                    }
                    if !draft.conflictingFields.isEmpty {
                        Text("Some statements disagree. Edit those statements and review again.")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.warning)
                    }
                    if draft.suggestions.isEmpty {
                        Text("No answers matched yet. Use a journal item's name followed by an explicit value, such as “Magnesium: yes”.")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
            }
        }
    }

    private func reviewSection(_ review: JournalEntryReview) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            Text("Review answers").font(StrandFont.title2)
            Text("Edit each value or uncheck an item to leave its saved answer as it is. Quantities use the unit shown in your journal.")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            ForEach($edits) { $edit in
                JournalEntryReviewRow(edit: $edit, existing: review.existing[edit.id])
                    .disabled(saving)
            }
            Button(action: save) {
                HStack {
                    if saving { ProgressView() }
                    Text("Save \(edits.filter(\.included).count) answers to \(review.day)")
                }.frame(maxWidth: .infinity)
            }
            .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
            .disabled(selectedValues == nil || saving || preparing || voice.isBusy || sourceChanged)
            .accessibilityIdentifier("journal-entry-save")
        }
    }

    private func prepareReview() {
        guard canReview, currentDay == presentation.day else { return }
        cancelDictation()
        let text = entryText
        let snapshot = fields
        let draft = JournalEntryParser.parse(text, fields: snapshot)
        parsed = draft
        review = nil
        edits = []
        message = nil
        guard !draft.exceedsLimit else {
            message = "Shorten this entry or reduce the journal catalog before reviewing it."
            return
        }
        guard !draft.suggestions.isEmpty else { return }
        operation?.cancel()
        let token = UUID()
        operationID = token
        preparing = true
        operation = Task { @MainActor in
            do {
                let context: String
                if let sourceContext { context = sourceContext }
                else { context = try await repo.journalEntryContext() }
                guard presentation.sourceIdentity == repo.journalEntrySourceIdentity else {
                    throw JournalEntryReviewError.contextChanged
                }
                guard isCurrent(token), entryText == text, fields == snapshot, currentDay == presentation.day else { return }
                sourceContext = context
                let loaded = try await repo.reviewJournalEntry(day: presentation.day, sourceContext: context,
                                                              fields: snapshot, suggestions: draft.suggestions)
                guard isCurrent(token), entryText == text, fields == snapshot,
                      currentDay == presentation.day, repo.journalEntrySourceContext == context else { return }
                review = loaded
                edits = loaded.suggestions.compactMap { suggestion in
                    snapshot.first(where: { $0.canonical == suggestion.canonical }).map {
                        JournalEntryEditableValue(field: $0, suggestion: suggestion)
                    }
                }
                preparing = false
            } catch is CancellationError {
                if operationID == token { preparing = false }
            } catch {
                guard isCurrent(token) else { return }
                preparing = false
                message = error.localizedDescription
            }
        }
    }

    private func save() {
        guard let review, let values = selectedValues, !saving, !sourceChanged else { return }
        let snapshot = fields
        let token = UUID()
        operationID = token
        saving = true
        message = nil
        operation = Task { @MainActor in
            do {
                try await repo.saveJournalEntry(review: review, values: values,
                                                currentDay: currentDay, currentFields: snapshot)
                // A successful transaction is authoritative, even if a context change cancelled the
                // UI task while SQLite committed. Report that success without reviving an old draft.
                guard presented else { return }
                saving = false
                onSaved()
                guard isCurrent(token), currentDay == presentation.day, fields == snapshot,
                      repo.journalEntrySourceContext == review.sourceContext else {
                    message = "Saved \(values.count) answers to \(review.day). The journal context changed; open a new entry to continue."
                    return
                }
                dismiss()
            } catch is CancellationError {
                if operationID == token { saving = false }
            } catch {
                guard isCurrent(token) else { return }
                saving = false
                message = error.localizedDescription
            }
        }
    }

    private func useTranscript() {
        guard !voice.isBusy, !voice.transcript.isEmpty else { return }
        let prefix = entryText.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = prefix.isEmpty ? voice.transcript : prefix + "\n" + voice.transcript
        guard combined.utf8.count <= JournalEntryParser.maximumInputBytes else {
            message = "The captured text would exceed the entry limit. Shorten your entry before adding it."
            return
        }
        entryText = combined
        cancelDictation()
    }

    private func cancelDictation() {
        voiceOperation?.cancel()
        voiceOperation = nil
        voice.cancel()
    }

    private func isCurrent(_ token: UUID) -> Bool {
        operationID == token && !Task.isCancelled && !sourceChanged
    }

    private func invalidateReview() {
        operationID = nil
        operation?.cancel()
        operation = nil
        preparing = false
        saving = false
        review = nil
        parsed = nil
        edits = []
    }

    private func invalidateContext() {
        sourceChanged = true
        saving = false
        invalidateReview()
        cancelDictation()
        message = "The journal date or data source changed. Copy any text you want to keep, then open a new entry for the current context."
    }
}

private struct JournalEntryReviewRow: View {
    @Binding var edit: JournalEntryEditableValue
    let existing: JournalEntry?

    var body: some View {
        PaperCard {
          VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $edit.included) { Text(edit.field.display).font(StrandFont.headline) }
                .accessibilityLabel("Include \(edit.field.display) in save")
            switch edit.field.kind {
            case .boolean:
                Picker("Answer", selection: $edit.boolean) {
                    Text("Yes").tag(true)
                    Text("No").tag(false)
                }.pickerStyle(.segmented).disabled(!edit.included)
            case .quantity(let unit):
                HStack {
                    TextField("Quantity", text: $edit.quantity)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("\(edit.field.display) quantity")
                    if let unit, !unit.isEmpty { Text(unit).font(StrandFont.subhead) }
                }.disabled(!edit.included)
                if edit.included && edit.suggestion == nil {
                    Text("Enter a nonnegative number in the unit shown.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.error)
                }
            }
            Text(existingDescription)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
            Text("From: \(edit.excerpt)")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
          }
        }
    }

    private var existingDescription: String {
        guard let existing else { return "Currently unanswered. This adds a new answer." }
        let value: String
        if let number = existing.numericValue {
            let unit: String
            if case .quantity(let label) = edit.field.kind { unit = label.map { " " + $0 } ?? "" }
            else { unit = "" }
            value = number.formatted(.number.precision(.significantDigits(1...17))) + unit
        } else { value = existing.answeredYes ? "Yes" : "No" }
        return "Currently saved: \(value). Saving replaces this answer and keeps its notes."
    }
}
