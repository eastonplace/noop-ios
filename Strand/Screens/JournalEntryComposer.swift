import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

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
    @State private var draft: JournalEntryComposerDraft
    @State private var dayDetails = JournalEntryDayDetailsDraft()
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

    init(catalog: JournalCatalogStore, presentation: JournalEntryPresentation,
         importedQuestions: [String], currentDay: String, onSaved: @escaping () -> Void) {
        self._catalog = ObservedObject(wrappedValue: catalog)
        self.presentation = presentation
        self.importedQuestions = importedQuestions
        self.currentDay = currentDay
        self.onSaved = onSaved
        self._draft = State(initialValue: JournalEntryComposerDraft(
            text: presentation.initialText, suggestions: presentation.initialSuggestions))
    }

    private var fields: [JournalEntryParser.Field] {
        catalog.resolvedItems(imported: importedQuestions).map(\.entryParserField)
    }

    private var canReview: Bool {
        draft.canReviewText
            && !preparing && !saving && !voice.isBusy && voice.transcript.isEmpty && !sourceChanged
    }

    private var selectedValues: [JournalEntryParser.Suggestion]? {
        JournalEntryComposerDraft.valuesForSave(
            edits, includesDayDetails: dayDetails.canIncludeInSave && review?.dayDetails != nil)
    }

    private var validDayDetails: Bool {
        dayDetails.isValid(maximumNoteBytes: JournalEntryDayDetails.maximumNoteBytes)
            && (!dayDetails.included || dayDetails.canIncludeInSave)
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
                        Text("This wake day stays fixed. Words such as “yesterday” do not change it; cancel and choose another date if needed.")
                            .font(StrandFont.caption)
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
                    if let review {
                        reviewSection(review)
                    } else if dayDetails.hasVisibleDraft {
                        retainedDayDetailsSection
                    }
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
        .onChange(of: draft.text) { _, _ in
            guard !saving else { return }
            invalidateReview()
        }
        .onChange(of: fields) { _, _ in
            draft.invalidateSeedSuggestions()
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
                TextEditor(text: $draft.text)
                    .frame(minHeight: 150)
                    .scrollContentBackground(.hidden)
                    .disabled(saving)
                    .accessibilityLabel("Journal entry text")
                    .accessibilityIdentifier("journal-entry-text")
            }
            Text("For example: “I took magnesium and felt stressed.” For quantities, include a unit and an existing journal item, such as “Caffeine: 200 mg.”")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
            Text("You can also leave this blank and review just your day note and mood.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
            if !draft.canReviewText {
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
                    Text("These words are not saved as journal answers. To keep them, turn on “Update note and mood” below, then choose “Add entry text to day note”.")
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
            Text("Review journal entry").font(StrandFont.title2)
            if edits.isEmpty {
                Text("No answers matched. You can still turn on “Update note and mood” to save a day note or mood.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            } else {
                Text("Edit each value or uncheck an item to leave its saved answer as it is. Quantities use the unit shown in your journal.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            }
            ForEach($edits) { $edit in
                JournalEntryReviewRow(edit: $edit, existing: review.existing[edit.id])
                    .disabled(saving)
            }
            if review.dayDetails != nil { dayDetailsSection }
            Button(action: save) {
                HStack {
                    if saving { ProgressView() }
                    Text(saveLabel(day: review.day))
                }.frame(maxWidth: .infinity)
            }
            .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
            .disabled(selectedValues == nil || !validDayDetails || saving || preparing
                      || voice.isBusy || !voice.transcript.isEmpty || sourceChanged)
            .accessibilityIdentifier("journal-entry-save")
        }
    }

    private var dayDetailsSection: some View {
        PaperCard {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Update note and mood", isOn: $dayDetails.included)
                    .font(StrandFont.headline)
                    .disabled(dayDetails.reviewedValues == nil)
                    .accessibilityIdentifier("journal-entry-include-day-details")
                Text("Off keeps your saved note and mood unchanged. On saves the values below; an empty note clears it, and “Not logged” clears mood.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                if let saved = dayDetails.reviewedValues {
                    if saved.note != dayDetails.note {
                        Text("Currently saved note:").font(StrandFont.caption)
                        Text(saved.note.isEmpty ? "No saved note" : saved.note)
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .textSelection(.enabled)
                    }
                    if saved.mood != dayDetails.mood {
                        Text(saved.mood.map { "Currently saved mood: \($0)/5" } ?? "Currently saved mood: Not logged")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                Text("Day note").font(StrandFont.subhead)
                TextEditor(text: $dayDetails.note)
                    .frame(minHeight: 110)
                    .scrollContentBackground(.hidden)
                    .disabled(!dayDetails.included)
                    .accessibilityLabel("Day note")
                    .accessibilityIdentifier("journal-entry-day-note")
                Text("\(dayDetails.note.utf8.count)/\(JournalEntryDayDetails.maximumNoteBytes) bytes")
                    .font(StrandFont.caption)
                    .foregroundStyle(validDayDetails ? StrandPalette.textTertiary : StrandPalette.error)
                Picker("Mood", selection: $dayDetails.mood) {
                    Text("Not logged").tag(Int?.none)
                    Text("1 · Rough").tag(Int?.some(1))
                    Text("2 · Low").tag(Int?.some(2))
                    Text("3 · Okay").tag(Int?.some(3))
                    Text("4 · Good").tag(Int?.some(4))
                    Text("5 · Great").tag(Int?.some(5))
                }
                .pickerStyle(.menu)
                .disabled(!dayDetails.included)
                .accessibilityIdentifier("journal-entry-mood")
                Button("Add entry text to day note", action: appendEntryToDayNote)
                    .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
                    .disabled(!dayDetails.canIncludeInSave || draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("journal-entry-add-to-day-note")
                if !validDayDetails {
                    Text("Shorten the note or remove unsupported characters before saving. Mood must be 1–5 or Not logged.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.error)
                }
            }
        }
        .disabled(saving || sourceChanged)
    }

    /// Retain a selectable, explicitly pinned copy even while a review is stale, loading, or fenced.
    /// These values cannot become a new source/day's draft simply because the surrounding UI moved.
    private var retainedDayDetailsSection: some View {
        PaperCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Note and mood draft").font(StrandFont.headline)
                Text("Wake day: \(presentation.day)").font(StrandFont.caption)
                Text(sourceChanged
                     ? "This draft stays with its original wake day and data source. Copy it before closing; saving is disabled."
                     : "Your draft is kept. Review again, then turn on “Update note and mood” if you want to save it.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text(dayDetails.note.isEmpty ? "Day note: empty" : dayDetails.note)
                    .font(StrandFont.subhead)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("journal-entry-retained-note")
                Text(dayDetails.mood.map { "Mood: \($0)/5" } ?? "Mood: Not logged")
                    .font(StrandFont.subhead)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("journal-entry-retained-mood")
            }
        }
        .accessibilityIdentifier("journal-entry-retained-day-details")
    }

    private func saveLabel(day: String) -> String {
        let count = edits.filter(\.included).count
        if dayDetails.included {
            return count == 0 ? "Save note and mood to \(day)" : "Save \(count) answers, note and mood to \(day)"
        }
        return "Save \(count) answers to \(day)"
    }

    private func appendEntryToDayNote() {
        guard !saving, !sourceChanged, dayDetails.canIncludeInSave, review?.dayDetails != nil else { return }
        guard dayDetails.appendEntryText(draft.text, maximumNoteBytes: JournalEntryDayDetails.maximumNoteBytes) else {
            message = "The entry could not be added without exceeding the note limit or including an unsupported character. Your existing note is unchanged."
            return
        }
        message = "Entry text added to the draft day note. Review it below; nothing is saved until you tap Save."
    }

    private func prepareReview() {
        guard canReview, currentDay == presentation.day else { return }
        cancelDictation()
        let text = draft.text
        let snapshot = fields
        let parsedDraft = JournalEntryParser.parse(text, fields: snapshot)
        let suggestions = draft.reviewSuggestions(from: parsedDraft)
        parsed = parsedDraft
        review = nil
        edits = []
        dayDetails.invalidateReview()
        message = nil
        guard !parsedDraft.exceedsLimit else {
            message = "Shorten this entry or reduce the journal catalog before reviewing it."
            return
        }
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
                guard isCurrent(token), draft.text == text, fields == snapshot, currentDay == presentation.day else { return }
                sourceContext = context
                let loaded = try await repo.reviewJournalEntry(day: presentation.day, sourceContext: context,
                                                              fields: snapshot, suggestions: suggestions,
                                                              includeDayDetails: true)
                guard isCurrent(token), draft.text == text, fields == snapshot,
                      currentDay == presentation.day, repo.journalEntrySourceContext == context else { return }
                if let savedDetails = loaded.dayDetails {
                    guard dayDetails.receiveReview(note: savedDetails.note, mood: savedDetails.mood) else {
                        preparing = false
                        return
                    }
                }
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
        guard let review, let values = selectedValues, validDayDetails, !saving, !preparing,
              !voice.isBusy, voice.transcript.isEmpty, !sourceChanged,
              currentDay == presentation.day else { return }
        let includedDetails: JournalEntryDayDetails? = dayDetails.included
            ? JournalEntryDayDetails(note: dayDetails.note, mood: dayDetails.mood) : nil
        let snapshot = fields
        let token = UUID()
        operationID = token
        saving = true
        message = nil
        operation = Task { @MainActor in
            // Context invalidation cancels UI publication but must not unlock the sheet while an
            // admitted transaction is still finishing. Every exit releases this single-save lock.
            defer { saving = false }
            do {
                try await repo.saveJournalEntry(review: review, values: values,
                                                currentDay: currentDay, currentFields: snapshot,
                                                dayDetails: includedDetails)
                // A successful transaction is authoritative, even if a context change cancelled the
                // UI task while SQLite committed. Report that success without reviving an old draft.
                guard presented else { return }
                onSaved()
                guard isCurrent(token), currentDay == presentation.day, fields == snapshot,
                      repo.journalEntrySourceContext == review.sourceContext else {
                    message = "Saved your journal entry to \(review.day). The journal context changed; open a new entry to continue."
                    return
                }
                dismiss()
            } catch is CancellationError {
                // An invalidated/dismissed draft does not publish a late cancellation result.
            } catch {
                guard isCurrent(token) else { return }
                message = error.localizedDescription
            }
        }
    }

    private func useTranscript() {
        guard !saving, !sourceChanged, !voice.isBusy, !voice.transcript.isEmpty else { return }
        let prefix = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = prefix.isEmpty ? voice.transcript : prefix + "\n" + voice.transcript
        guard combined.utf8.count <= JournalEntryParser.maximumInputBytes else {
            message = "The captured text would exceed the entry limit. Shorten your entry before adding it."
            return
        }
        draft.text = combined
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
        review = nil
        parsed = nil
        edits = []
        dayDetails.invalidateReview()
    }

    private func invalidateContext() {
        sourceChanged = true
        dayDetails.invalidateContext()
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
