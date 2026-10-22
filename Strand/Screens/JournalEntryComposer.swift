import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

struct JournalEntryPresentation: Identifiable {
    let id = UUID()
    let day: String
    let sourceIdentity: String
}

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
    @FocusState private var editorFocused: Bool
    /// Bumped whenever Review produces something to look at, so the results are brought into view.
    @State private var resultsTick = 0

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

    private var dayLabel: String {
        FriendlyDayLabel.label(forDayKey: presentation.day)
    }

    private var includedCount: Int { edits.filter(\.included).count }

    private var saveTitle: String {
        includedCount == 1
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
                        if let review { reviewSection(review) }
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
        .onChange(of: entryText) { _, _ in
            guard !saving else { return }
            invalidateReview()
            if !sourceChanged { message = nil }
        }
        .onChange(of: fields) { _, _ in
            invalidateReview()
            cancelDictation()
            message = String(localized: "Your journal items changed. Review your note again.")
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
                .disabled(selectedValues == nil || saving || preparing || voice.isBusy || sourceChanged)
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
            TextEditor(text: $entryText)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 180)
                .focused($editorFocused)
                .overlay(alignment: .topLeading) {
                    if entryText.isEmpty {
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
                Text("Try “I took magnesium” or “I felt stressed”.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            if entryText.utf8.count > JournalEntryParser.maximumInputBytes {
                Text("This note is too long. Shorten it before reviewing.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.error)
            }
        }
    }

    /// One mic glyph. It sits in a filled circle only while recording, so the live state is visible at a glance.
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
                    if voice.phase == .recording {
                        Circle().fill(StrandPalette.error).frame(width: 40, height: 40)
                    }
                    switch voice.phase {
                    case .requestingPermission, .finishing:
                        ProgressView()
                    case .recording:
                        Image(systemName: "mic.fill").foregroundStyle(StrandPalette.onInk)
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
                Text("These won’t be saved.")
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
            Text("Review answers").font(StrandFont.title2)
            Text("Edit a value, or uncheck it to keep your saved answer.")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            ForEach($edits) { $edit in
                if edit.id != edits.first?.id { Divider().overlay(StrandPalette.hairline) }
                JournalEntryReviewRow(edit: $edit, existing: review.existing[edit.id])
                    .disabled(saving)
            }
        }
    }

    private func prepareReview() {
        guard canReview, currentDay == presentation.day else { return }
        editorFocused = false
        cancelDictation()
        let text = entryText
        let snapshot = fields
        let draft = JournalEntryParser.parse(text, fields: snapshot)
        parsed = draft
        review = nil
        edits = []
        message = nil
        guard !draft.exceedsLimit else {
            message = String(localized: "Shorten this note or reduce your journal items before reviewing.")
            resultsTick += 1
            return
        }
        guard !draft.suggestions.isEmpty else {
            message = String(localized: "Nothing matched your journal questions. Try “I took magnesium” or “I felt stressed”.")
            resultsTick += 1
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
                    message = String(localized: "Saved. Your journal changed in the meantime; open a new note to continue.")
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
            message = String(localized: "That would make the note too long. Shorten it first.")
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
        message = String(localized: "Your journal date or data source changed. Copy anything you want to keep, then open a new note.")
    }
}

private struct JournalEntryReviewRow: View {
    @Binding var edit: JournalEntryEditableValue
    let existing: JournalEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Toggle(isOn: $edit.included) {
                Text(edit.field.display).font(StrandFont.headline).fixedSize(horizontal: false, vertical: true)
            }
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
                        .textFieldStyle(.plain)
                        .font(StrandFont.body)
                        .frame(minHeight: 24)
                        .journalFieldSurface()
                        .accessibilityLabel("\(edit.field.display) quantity")
                    if let unit, !unit.isEmpty { Text(unit).font(StrandFont.subhead) }
                }.disabled(!edit.included)
                if edit.included && edit.suggestion == nil {
                    Text("Enter a number, zero or more.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.error)
                }
            }
            Text(existingDescription)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, NoopMetrics.space2)
    }

    private var existingDescription: String {
        guard let existing else { return String(localized: "Not logged yet. This adds a new answer.") }
        let value: String
        if let number = existing.numericValue {
            let unit: String
            if case .quantity(let label) = edit.field.kind { unit = label.map { " " + $0 } ?? "" }
            else { unit = "" }
            value = number.formatted(.number.precision(.significantDigits(1...17))) + unit
        } else { value = existing.answeredYes ? String(localized: "Yes") : String(localized: "No") }
        return String(localized: "Saved as \(value). Saving replaces it.")
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
