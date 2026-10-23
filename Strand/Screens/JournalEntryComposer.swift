import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

/// The one way into the composer from a journal screen: a plain row with a glyph, no capsule.
struct JournalComposeRow: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: NoopMetrics.space3) {
                Image(systemName: "mic")
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.journalAccent)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text("Write or dictate a note")
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: NoopMetrics.space2)
                Image(systemName: "chevron.right")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("journal-compose-entry")
    }
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
    @FocusState private var editorFocused: Bool
    /// Bumped whenever Review produces something to look at, so the results are brought into view.
    @State private var resultsTick = 0
    @State private var contentHeight: CGFloat = 0

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

    private var dayLabel: String {
        JournalBehaviorDay.label(forStorageKey: presentation.day)
    }

    private var includedCount: Int { edits.filter(\.included).count }

    private var saveTitle: String {
        let details = dayDetails.canIncludeInSave && review?.dayDetails != nil
        if details { return includedCount == 0 ? String(localized: "Save note and mood") : String(localized: "Save answers, note and mood") }
        if includedCount == 0 { return String(localized: "Save") }
        return includedCount == 1
            ? String(localized: "Save answer")
            : String(localized: "Save \(includedCount) answers")
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScreenScaffold(title: "Journal note", subtitle: LocalizedStringKey(dayLabel)) {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    entryEditor
                    VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                        if let message {
                            Text(message)
                                .font(StrandFont.subhead)
                                .foregroundStyle(sourceChanged ? StrandPalette.error : StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("journal-entry-message")
                        }
                        if let parsed { unmatchedSection(parsed) }
                        if let review {
                            reviewSection(review)
                        } else if dayDetails.hasVisibleDraft {
                            retainedDayDetailsSection
                        }
                    }
                    .id(Self.resultsAnchor)
                }
                .frame(maxWidth: .infinity, minHeight: 520, alignment: .topLeading)
                // Behind the content, so a tap on empty space puts the keyboard away without stealing the editor's taps.
                .background {
                    Color.clear.contentShape(Rectangle()).onTapGesture { editorFocused = false }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) { footer }
            .onChange(of: resultsTick) { _, _ in
                // Let the keyboard finish leaving before measuring, or the results land under it.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    withAnimation { proxy.scrollTo(Self.resultsAnchor, anchor: .top) }
                }
            }
        }
        .sheetScreenScaffoldEnvironment(onClose: { if !saving { dismiss() } })
        .background(StrandPalette.appCanvas.ignoresSafeArea())
        .interactiveDismissDisabled(saving)
        .tint(StrandPalette.accent)
        .font(StrandFont.body)
        .onAppear { presented = true }
        .onChange(of: draft.text) { _, _ in
            guard !saving else { return }
            invalidateReview()
            if !sourceChanged { message = nil }
        }
        .onChange(of: fields) { _, _ in
            // The catalog loads just after the sheet opens. That is not a change to anything the person
            // reviewed, so only say so once a Review has started or produced results.
            let hadReview = parsed != nil || review != nil || preparing
            invalidateReview()
            cancelDictation()
            if hadReview {
                message = String(localized: "Your journal items changed. Review your note again.")
            }
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

    private static let resultsAnchor = "journal-entry-results"

    /// The one primary action: Review first, then Save once there are answers to save.
    private var footer: some View {
        Group {
            if review == nil {
                Button(action: prepareReview) {
                    HStack {
                        if preparing { ProgressView() }
                        Text("Review")
                    }.frame(maxWidth: .infinity)
                }
                .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
                .disabled(!canReview)
                .accessibilityIdentifier("journal-entry-review")
            } else {
                Button(action: save) {
                    HStack {
                        if saving { ProgressView() }
                        Text(verbatim: saveTitle).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity)
                }
                .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
                .disabled(selectedValues == nil || !validDayDetails || saving || preparing
                          || voice.isBusy || !voice.transcript.isEmpty || sourceChanged)
                .accessibilityIdentifier("journal-entry-save")
            }
        }
        .sheetFooterBar()
    }

    private func textAction(_ title: LocalizedStringKey, tint: Color = StrandPalette.accent,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(StrandFont.subhead.weight(.semibold))
                .foregroundStyle(tint)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
    }

    private var entryEditor: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            TextEditor(text: $draft.text)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .scrollContentBackground(.hidden)
                .frame(height: min(max(contentHeight, Self.editorMinHeight), Self.editorMaxHeight))
                .background(alignment: .topLeading) { contentMeasure }
                .onPreferenceChange(EditorContentHeightKey.self) { contentHeight = $0 }
                .focused($editorFocused)
                .overlay(alignment: .topLeading) {
                    if draft.text.isEmpty {
                        Text("Write or dictate a note")
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .disabled(saving)
                .journalFieldSurface()
                .accessibilityLabel("Journal entry text")
                .accessibilityIdentifier("journal-entry-text")
            dictationRow
            if !voice.transcript.isEmpty { transcriptBlock }
            if let error = voice.errorText {
                Text(error).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The same examples appear in the "Nothing matched" message, so the hint steps aside once Review has run.
            if parsed == nil && review == nil {
                Text("Try “I took magnesium” or “I felt stressed”. Leave it blank to log just a note or mood.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            if !draft.canReviewText {
                Text("This note is too long. Shorten it before reviewing.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.error)
            }
        }
    }

    private static let editorMinHeight: CGFloat = 150
    private static let editorMaxHeight: CGFloat = 280

    /// An invisible copy of the note, laid out at the editor's width, so the field can grow with its content
    /// (between the min and max above) instead of filling whatever room the sheet offers.
    private var contentMeasure: some View {
        Text(verbatim: draft.text + "\n")
            .font(StrandFont.body)
            .padding(.horizontal, 5)
            .padding(.vertical, 8)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(GeometryReader { Color.clear.preference(key: EditorContentHeightKey.self, value: $0.size.height) })
            .hidden()
            .accessibilityHidden(true)
    }

    /// One bare mic glyph. It turns red while recording, so the live state is visible at a glance.
    private var dictationRow: some View {
        HStack(spacing: NoopMetrics.space3) {
            Button {
                switch voice.phase {
                case .idle: voiceOperation = Task { await voice.start() }
                case .recording: voice.finish()
                case .requestingPermission, .finishing: cancelDictation()
                }
            } label: {
                ZStack {
                    switch voice.phase {
                    case .requestingPermission, .finishing:
                        ProgressView()
                    case .recording:
                        Image(systemName: "mic.fill").foregroundStyle(StrandPalette.error)
                    case .idle:
                        Image(systemName: "mic").foregroundStyle(StrandPalette.accent)
                    }
                }
                .font(StrandFont.title2)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(voice.phase == .idle && (saving || sourceChanged))
            .accessibilityLabel(micLabel)
            .accessibilityHint("Dictation stays on this iPhone.")
            .accessibilityIdentifier("journal-entry-dictate")
            if let status = dictationStatus {
                Text(status).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer(minLength: 0)
            if voice.phase != .idle {
                textAction("Cancel", tint: StrandPalette.textSecondary, action: cancelDictation)
            }
        }
        .disabled(saving)
    }

    private var micLabel: LocalizedStringKey {
        switch voice.phase {
        case .idle: voice.transcript.isEmpty ? "Dictate" : "Dictate again"
        case .recording: "Finish dictation"
        case .requestingPermission, .finishing: "Cancel dictation"
        }
    }

    private var dictationStatus: String? {
        switch voice.phase {
        case .idle: nil
        case .requestingPermission: String(localized: "Getting ready…")
        case .recording: String(localized: "Listening…")
        case .finishing: String(localized: "Finishing…")
        }
    }

    private var transcriptBlock: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            Text(voice.transcript)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("journal-entry-transcript")
            if !voice.isBusy {
                HStack(spacing: NoopMetrics.space5) {
                    textAction("Add to note", action: useTranscript)
                        .accessibilityIdentifier("journal-entry-use-transcript")
                    textAction("Discard", tint: StrandPalette.textSecondary, action: cancelDictation)
                    Spacer(minLength: 0)
                }
                .disabled(saving)
            }
        }
    }

    @ViewBuilder private func unmatchedSection(_ draft: JournalEntryParser.Draft) -> some View {
        if !draft.unmatched.isEmpty {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text("Not matched").font(StrandFont.headline)
                Text("These won’t be saved as answers.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                ForEach(Array(draft.unmatched.enumerated()), id: \.offset) { _, text in
                    Text(text).font(StrandFont.subhead).textSelection(.enabled)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                if !draft.conflictingFields.isEmpty {
                    Text("Some lines disagree. Edit them and review again.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.warning)
                }
            }
        }
    }

    private func reviewSection(_ review: JournalEntryReview) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            if !edits.isEmpty {
                Text("Review answers").font(StrandFont.title2)
                Text("Uncheck anything you don't want saved.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            }
            ForEach($edits) { $edit in
                if edit.id != edits.first?.id { Divider().overlay(StrandPalette.hairline) }
                JournalEntryReviewRow(edit: $edit, existing: review.existing[edit.id])
                    .disabled(saving)
            }
            if review.dayDetails != nil {
                if !edits.isEmpty { Divider().overlay(StrandPalette.hairline) }
                dayDetailsRow
            }
        }
    }

    // MARK: Day note and mood

    private var dayDetailsIncluded: Bool { dayDetails.canIncludeInSave }

    /// Note and mood read like one more review row: a checkmark, a name, and the values. Editing either
    /// checks the row, so the person never has to find a separate switch; unchecking leaves what is saved.
    private var dayDetailsRow: some View {
        HStack(alignment: .top, spacing: NoopMetrics.space2) {
            Button { dayDetails.included.toggle() } label: {
                Image(systemName: dayDetails.included ? "checkmark.circle.fill" : "circle")
                    .font(StrandFont.title2)
                    .foregroundStyle(dayDetails.included ? StrandPalette.accent : StrandPalette.textTertiary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(dayDetails.reviewedValues == nil)
            .accessibilityLabel("Include")
            .accessibilityValue(dayDetails.included ? "Included" : "Not included")
            .accessibilityIdentifier("journal-entry-include-day-details")
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text("Day note and mood")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(minHeight: 44, alignment: .leading)
                moodMenu
                dayNoteField
                if let caption = dayDetailsCaption {
                    Text(caption)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    textAction("Add entry to note", action: appendEntryToDayNote)
                        .disabled(dayDetails.reviewedValues == nil)
                        .accessibilityIdentifier("journal-entry-add-to-day-note")
                }
                if !validDayDetails {
                    Text("Shorten the note or remove unsupported characters before saving.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.error)
                }
            }
        }
        .padding(.vertical, NoopMetrics.space1)
        .disabled(saving || sourceChanged)
    }

    private var moodBinding: Binding<Int?> {
        Binding(get: { dayDetails.mood },
                set: { value in
                    dayDetails.mood = value
                    dayDetails.markEdited()
                })
    }

    private var noteBinding: Binding<String> {
        Binding(get: { dayDetails.note },
                set: { value in
                    dayDetails.note = value
                    dayDetails.markEdited()
                })
    }

    /// "Mood · Okay ⌄": a plain row that opens a menu, the same shape as the Day row.
    private var moodMenu: some View {
        Menu {
            Picker("Mood", selection: moodBinding) {
                Text("Not logged").tag(Int?.none)
                ForEach(Array(MoodStore.scale), id: \.self) { value in
                    Text(verbatim: MoodStore.label(for: value)).tag(Int?.some(value))
                }
            }
        } label: {
            HStack(spacing: NoopMetrics.space2) {
                Text("Mood").foregroundStyle(StrandPalette.textSecondary)
                Text(verbatim: "·").foregroundStyle(StrandPalette.textTertiary)
                Text(verbatim: dayDetails.mood.map(MoodStore.label(for:)) ?? String(localized: "Not logged"))
                    .foregroundStyle(StrandPalette.textPrimary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
            }
            .font(StrandFont.body)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("journal-entry-mood")
    }

    private var dayNoteField: some View {
        TextField("Add a note for this day", text: noteBinding, axis: .vertical)
            .lineLimit(1...4)
            .font(StrandFont.body)
            .foregroundStyle(StrandPalette.textPrimary)
            .textFieldStyle(.plain)
            .journalFieldSurface()
            .accessibilityLabel("Day note")
            .accessibilityIdentifier("journal-entry-day-note")
    }

    /// Says so only when saving would replace or clear something already saved for the day.
    private var dayDetailsCaption: String? {
        guard dayDetails.included, let saved = dayDetails.reviewedValues else { return nil }
        let noteChanged = !saved.note.isEmpty && saved.note != dayDetails.note
        let moodChanged = saved.mood != nil && saved.mood != dayDetails.mood
        switch (noteChanged, moodChanged) {
        case (true, true): return String(localized: "Replaces your saved note and mood")
        case (true, false): return String(localized: "Replaces your saved note")
        case (false, true): return String(localized: "Replaces your saved mood")
        case (false, false): return nil
        }
    }

    /// The words and mood the person wrote stay on screen while a review is stale, loading or fenced.
    private var retainedDayDetailsSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            Text("Note and mood draft").font(StrandFont.headline)
            Text(sourceChanged
                 ? "This draft stays with its original day and data source. Copy it before closing; it can’t be saved."
                 : "Your draft is kept. Review again to save it.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if !dayDetails.note.isEmpty {
                Text(dayDetails.note)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("journal-entry-retained-note")
            }
            if let mood = dayDetails.mood {
                Text(verbatim: MoodStore.label(for: mood))
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("journal-entry-retained-mood")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("journal-entry-retained-day-details")
    }

    private func appendEntryToDayNote() {
        guard !saving, !sourceChanged, dayDetails.reviewedValues != nil, review?.dayDetails != nil else { return }
        guard dayDetails.appendEntryText(draft.text, maximumNoteBytes: JournalEntryDayDetails.maximumNoteBytes) else {
            message = String(localized: "That would make the note too long. Your existing note is unchanged.")
            return
        }
        dayDetails.markEdited()
        message = nil
    }

    private func prepareReview() {
        guard canReview, currentDay == presentation.day else { return }
        editorFocused = false
        cancelDictation()
        let text = draft.text
        let snapshot = fields
        let parsedDraft = JournalEntryParser.parse(text, fields: snapshot)
        let suggestions = draft.reviewSuggestions(from: parsedDraft)
        parsed = parsedDraft
        review = nil
        edits = []
        message = nil
        dayDetails.invalidateReview()
        guard !parsedDraft.exceedsLimit else {
            message = String(localized: "Shorten this note or reduce your journal items before reviewing.")
            resultsTick += 1
            return
        }
        // Nothing matched is not a dead end: the review still opens so the words can become the day note.
        if suggestions.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message = String(localized: "Nothing matched your journal questions. You can still save it as a note.")
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
                resultsTick += 1
            } catch is CancellationError {
                if operationID == token { preparing = false }
            } catch {
                guard isCurrent(token) else { return }
                preparing = false
                message = error.localizedDescription
                resultsTick += 1
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
                    message = String(localized: "Saved. Your journal changed in the meantime; open a new note to continue.")
                    return
                }
                dismiss()
            } catch is CancellationError {
                // An invalidated or dismissed draft does not publish a late cancellation result.
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
            message = String(localized: "That would make the note too long. Shorten it first.")
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
        invalidateReview()
        dayDetails.invalidateContext()
        cancelDictation()
        message = String(localized: "Your journal date or data source changed. Copy anything you want to keep, then open a new note.")
    }
}

private struct EditorContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct JournalEntryReviewRow: View {
    @Binding var edit: JournalEntryEditableValue
    let existing: JournalEntry?

    var body: some View {
        HStack(alignment: .top, spacing: NoopMetrics.space2) {
            includeButton
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text(edit.field.display)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 44, alignment: .leading)
                answerControl
                    .disabled(!edit.included)
                    .opacity(edit.included ? 1 : 0.4)
                if let replaced = replacedDescription {
                    Text(replaced)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, NoopMetrics.space1)
    }

    private var includeButton: some View {
        Button { edit.included.toggle() } label: {
            Image(systemName: edit.included ? "checkmark.circle.fill" : "circle")
                .font(StrandFont.title2)
                .foregroundStyle(edit.included ? StrandPalette.accent : StrandPalette.textTertiary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Include")
        .accessibilityValue(edit.included ? "Included" : "Not included")
    }

    @ViewBuilder private var answerControl: some View {
        switch edit.field.kind {
        case .boolean:
            Picker("Answer", selection: $edit.boolean) {
                Text("Yes").tag(true)
                Text("No").tag(false)
            }.pickerStyle(.segmented)
        case .quantity(let unit):
            HStack {
                TextField("Quantity", text: $edit.quantity)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.plain)
                    .font(StrandFont.body)
                    .frame(minHeight: 24)
                    .journalFieldSurface()
                    .accessibilityLabel("\(edit.field.display) quantity")
                if let unit, !unit.isEmpty { Text(unit).font(StrandFont.subhead) }
            }
            if edit.included && edit.suggestion == nil {
                Text("Enter a number, zero or more.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.error)
            }
        }
    }

    /// Only a row that would overwrite something already saved says so; a new answer needs no caption.
    private var replacedDescription: String? {
        guard let existing else { return nil }
        let value: String
        if let number = existing.numericValue {
            let unit: String
            if case .quantity(let label) = edit.field.kind { unit = label.map { " " + $0 } ?? "" }
            else { unit = "" }
            value = number.formatted(.number.precision(.significantDigits(1...17))) + unit
        } else { value = existing.answeredYes ? String(localized: "Yes") : String(localized: "No") }
        return String(localized: "Replaces your saved answer: \(value)")
    }
}

private extension View {
    /// The app's field surface: an inset fill with a hairline edge, as the other sheets' text fields wear.
    func journalFieldSurface() -> some View {
        let shape = RoundedRectangle(cornerRadius: NoopMetrics.radius2, style: .continuous)
        return padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(StrandPalette.surfaceInset, in: shape)
            .overlay(shape.strokeBorder(StrandPalette.hairline, lineWidth: 1))
    }
}
