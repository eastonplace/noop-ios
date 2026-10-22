import Foundation
import StrandAnalytics

struct JournalEntryPresentation: Identifiable {
    let id = UUID()
    let day: String
    let sourceIdentity: String
    let initialText: String
    let initialSuggestions: [JournalEntryParser.Suggestion]

    init(day: String, sourceIdentity: String, initialText: String = "",
         initialSuggestions: [JournalEntryParser.Suggestion] = []) {
        self.day = day
        self.sourceIdentity = sourceIdentity
        self.initialText = initialText
        self.initialSuggestions = initialSuggestions
    }
}

/// Pure transient state. Exact quick-action proposals never need a lossy text round trip, but a
/// genuine text edit permanently gives control back to the parser for this draft.
struct JournalEntryComposerDraft {
    var text: String {
        didSet {
            if text != oldValue { invalidateSeedSuggestions() }
        }
    }
    private var seededSuggestions: [JournalEntryParser.Suggestion]

    init(text: String = "", suggestions: [JournalEntryParser.Suggestion] = []) {
        self.text = text
        seededSuggestions = suggestions
    }

    var canReviewText: Bool {
        text.utf8.count <= JournalEntryParser.maximumInputBytes
    }

    func reviewSuggestions(from parsed: JournalEntryParser.Draft) -> [JournalEntryParser.Suggestion] {
        seededSuggestions.isEmpty ? parsed.suggestions : seededSuggestions
    }

    mutating func invalidateSeedSuggestions() { seededSuggestions = [] }

    static func valuesForSave(_ edits: [JournalEntryEditableValue],
                              includesDayDetails: Bool) -> [JournalEntryParser.Suggestion]? {
        let included = edits.filter(\.included)
        guard !included.isEmpty || includesDayDetails else { return nil }
        let values = included.compactMap(\.suggestion)
        return values.count == included.count ? values : nil
    }
}

/// Authored values outlive the read snapshot that authorizes a save. Invalidating a review revokes
/// its opt-in, never the draft; a fresh review updates only fields the user has not edited.
struct JournalEntryDayDetailsDraft {
    struct Values: Equatable {
        var note: String
        var mood: Int?
    }

    var included = false
    private(set) var reviewedValues: Values?
    private var values: Values
    private var noteWasEdited = false
    private var moodWasEdited = false
    private var hasLoadedReview = false
    private var contextInvalidated = false

    var note: String {
        get { values.note }
        set {
            if newValue != values.note { noteWasEdited = true }
            values.note = newValue
        }
    }

    var mood: Int? {
        get { values.mood }
        set {
            if newValue != values.mood { moodWasEdited = true }
            values.mood = newValue
        }
    }

    init(note: String = "", mood: Int? = nil) {
        values = Values(note: note, mood: mood)
    }

    var hasVisibleDraft: Bool {
        hasLoadedReview || noteWasEdited || moodWasEdited || !note.isEmpty || mood != nil
    }

    var canIncludeInSave: Bool {
        included && reviewedValues != nil && !contextInvalidated
    }

    @discardableResult
    mutating func receiveReview(note: String, mood: Int?) -> Bool {
        guard !contextInvalidated else { return false }
        included = false
        reviewedValues = Values(note: note, mood: mood)
        if !noteWasEdited { values.note = note }
        if !moodWasEdited { values.mood = mood }
        hasLoadedReview = true
        return true
    }

    mutating func invalidateReview() {
        included = false
        reviewedValues = nil
    }

    mutating func invalidateContext() {
        contextInvalidated = true
        invalidateReview()
    }

    func isValid(maximumNoteBytes: Int) -> Bool {
        guard included else { return true }
        return note.utf8.count <= maximumNoteBytes && !note.utf8.contains(0)
            && mood.map { (1...5).contains($0) } != false
    }

    /// Appends the exact narrative without trimming the saved note, silently truncating either
    /// value, or changing the separate opt-in. The separator counts toward the UTF-8 byte limit.
    mutating func appendEntryText(_ text: String, maximumNoteBytes: Int) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let combined = note.isEmpty ? text : note + "\n\n" + text
        guard combined.utf8.count <= maximumNoteBytes, !combined.utf8.contains(0) else { return false }
        note = combined
        return true
    }
}
