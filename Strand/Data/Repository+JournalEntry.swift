import Foundation
import StrandAnalytics
import WhoopStore

/// Optional, explicit day-level details. These are distinct from each journal answer's notes.
/// Passing this value to Save replaces both details for the reviewed day; omitting it preserves them.
struct JournalEntryDayDetails: Equatable, Sendable {
    static let maximumNoteBytes = ReviewedJournalDayDetailsChange.maximumNoteBytes
    var note: String
    var mood: Int?
}

struct JournalEntryReview: Equatable {
    let day: String
    let sourceContext: String
    let databaseInstanceId: String
    let fields: [JournalEntryParser.Field]
    let suggestions: [JournalEntryParser.Suggestion]
    let existing: [String: JournalEntry]
    let dayDetails: JournalEntryDayDetails?
    fileprivate let dayDetailsSnapshot: JournalDayDetailsSnapshot?
}

enum JournalEntryReviewError: Error, LocalizedError, Equatable {
    case contextChanged
    case unavailable
    case invalidValues

    var errorDescription: String? {
        switch self {
        case .contextChanged: return String(localized: "The journal date, catalog, or data source changed. Open a new entry and review it before saving.")
        case .unavailable: return String(localized: "The journal store is unavailable. Your entry is still here; try reviewing it again.")
        case .invalidValues: return String(localized: "Choose an answer or reviewed day details, and check the quantities, note, and mood before saving.")
        }
    }
}

@MainActor
extension Repository {
    /// Available before the database first opens; lets dictation follow source/privacy changes
    /// without treating discovery of the initial database identity as a different user context.
    var journalEntrySourceIdentity: String {
        "\(deviceId)|\(liveSourceState.lineageComponent)|\(externalSurfaceInvalidationEpoch)"
    }

    /// Database replacement, source lifecycle changes, and admission fences invalidate old drafts.
    /// Ordinary new readings do not invalidate a journal review; native answer conflicts are checked
    /// inside the save transaction instead of relying on a broad dashboard refresh counter.
    var journalEntrySourceContext: String {
        notificationSourceContext + "|journal|\(externalSurfaceInvalidationEpoch)"
    }

    func journalEntryContext() async throws -> String {
        let owner = journalEntrySourceIdentity
        guard !verifiedExternalSurfaceFenced, await storeHandle() != nil else {
            throw JournalEntryReviewError.unavailable
        }
        try Task.checkCancellation()
        guard !verifiedExternalSurfaceFenced, owner == journalEntrySourceIdentity else {
            throw JournalEntryReviewError.contextChanged
        }
        return journalEntrySourceContext
    }

    func reviewJournalEntry(day: String, sourceContext: String,
                            fields: [JournalEntryParser.Field],
                            suggestions: [JournalEntryParser.Suggestion],
                            includeDayDetails: Bool = false) async throws -> JournalEntryReview {
        try checkJournalEntryContext(sourceContext)
        guard WhoopStore.isValidJournalDay(day),
              Self.validJournalEntryValues(suggestions, fields: fields, allowEmpty: includeDayDetails) else {
            throw JournalEntryReviewError.invalidValues
        }
        guard let store = await storeHandle() else { throw JournalEntryReviewError.unavailable }
        try checkJournalEntryContext(sourceContext)
        let databaseInstanceId = try await store.databaseInstanceId()
        try checkJournalEntryContext(sourceContext)
        let rows = try await store.journalEntries(deviceId: Self.journalDeviceId, from: day, to: day)
        try checkJournalEntryContext(sourceContext)
        let details: JournalDayDetailsSnapshot?
        if includeDayDetails {
            details = try await store.journalDayDetails(day: day)
            try checkJournalEntryContext(sourceContext)
        } else { details = nil }
        return JournalEntryReview(day: day, sourceContext: sourceContext, databaseInstanceId: databaseInstanceId, fields: fields,
                                  suggestions: suggestions,
                                  existing: Dictionary(rows.map { ($0.question, $0) }, uniquingKeysWith: { _, last in last }),
                                  dayDetails: try details.map(Self.journalEntryDayDetails), dayDetailsSnapshot: details)
    }

    /// Source-guarded, read-only projection for the widget. A read does not authorize a later save;
    /// the visible review action must still capture its own exact persisted snapshot.
    func journalDayDetails(day: String, sourceContext: String) async throws -> JournalEntryDayDetails {
        try checkJournalEntryContext(sourceContext)
        guard let store = await storeHandle() else { throw JournalEntryReviewError.unavailable }
        try checkJournalEntryContext(sourceContext)
        let snapshot = try await store.journalDayDetails(day: day)
        try checkJournalEntryContext(sourceContext)
        return try Self.journalEntryDayDetails(snapshot)
    }

    /// The only write used by the composer. Call from its visible Save action after review.
    /// Admission pins the reviewed day and values in the global journal namespace. After admission,
    /// a source switch does not undo a successful commit; SQLite checks database identity and the
    /// exact reviewed rows, and the composer reports success without reviving an obsolete draft.
    func saveJournalEntry(review: JournalEntryReview, values: [JournalEntryParser.Suggestion],
                          currentDay: String, currentFields: [JournalEntryParser.Field],
                          dayDetails: JournalEntryDayDetails? = nil) async throws {
        try checkJournalEntryContext(review.sourceContext)
        guard review.day == currentDay, review.fields == currentFields else {
            throw JournalEntryReviewError.contextChanged
        }
        let detailChange: ReviewedJournalDayDetailsChange?
        if let dayDetails {
            guard let snapshot = review.dayDetailsSnapshot,
                  ReviewedJournalDayDetailsChange.isValid(note: dayDetails.note, mood: dayDetails.mood) else {
                throw JournalEntryReviewError.invalidValues
            }
            detailChange = .init(day: review.day, note: dayDetails.note, mood: dayDetails.mood, expected: snapshot)
        } else { detailChange = nil }
        let reviewedKeys = Set(review.suggestions.map(\.canonical))
        guard Self.validJournalEntryValues(values, fields: currentFields, allowEmpty: detailChange != nil),
              values.allSatisfy({ reviewedKeys.contains($0.canonical) }) else {
            throw JournalEntryReviewError.invalidValues
        }
        guard let store = await storeHandle() else { throw JournalEntryReviewError.unavailable }
        try checkJournalEntryContext(review.sourceContext)
        let changes = values.map { item -> ReviewedJournalChange in
            let yes: Bool
            let number: Double?
            switch item.value {
            case .boolean(let value): yes = value; number = nil
            case .quantity(let value): yes = true; number = value
            }
            return ReviewedJournalChange(day: review.day, question: item.canonical, answeredYes: yes,
                                         numericValue: number, expected: review.existing[item.canonical])
        }
        _ = try await store.saveReviewedJournal(changes, expectedDatabaseInstanceId: review.databaseInstanceId,
                                                dayDetails: detailChange)
        // A successful commit always invalidates the journal cache, even if the presenting view was
        // dismissed while SQLite finished. The view's operation token separately fences its UI result.
        journalDidChange()
    }

    private func checkJournalEntryContext(_ expected: String) throws {
        try Task.checkCancellation()
        guard !verifiedExternalSurfaceFenced, expected == journalEntrySourceContext else {
            throw JournalEntryReviewError.contextChanged
        }
    }

    private static func validJournalEntryValues(_ values: [JournalEntryParser.Suggestion],
                                                fields: [JournalEntryParser.Field], allowEmpty: Bool = false) -> Bool {
        guard (allowEmpty || !values.isEmpty), values.count <= JournalEntryParser.maximumFields,
              fields.count <= JournalEntryParser.maximumFields,
              Set(fields.map(\.canonical)).count == fields.count,
              Set(values.map(\.canonical)).count == values.count else { return false }
        for item in values {
            guard let field = fields.first(where: { $0.canonical == item.canonical }) else { return false }
            switch (field.kind, item.value) {
            case (.boolean, .boolean): break
            case (.quantity, .quantity(let value)) where value.isFinite && (0...1_000_000_000).contains(value): break
            default: return false
            }
        }
        return true
    }

    private static func journalEntryDayDetails(_ snapshot: JournalDayDetailsSnapshot) throws -> JournalEntryDayDetails {
        let mood: Int?
        if let raw = snapshot.mood {
            guard raw.isFinite, (1...5).contains(raw), raw.rounded() == raw else {
                throw JournalEntryReviewError.invalidValues
            }
            mood = Int(raw)
        } else { mood = nil }
        let note = snapshot.note ?? ""
        guard ReviewedJournalDayDetailsChange.isValid(note: note, mood: mood) else {
            throw JournalEntryReviewError.invalidValues
        }
        return JournalEntryDayDetails(note: note, mood: mood)
    }
}

extension JournalCatalogItem {
    var entryParserField: JournalEntryParser.Field {
        let parserKind: JournalEntryParser.Kind
        switch kind {
        case .bool: parserKind = .boolean
        case .numeric(let unit): parserKind = .quantity(unit: unit)
        }
        return .init(canonical: canonical, display: display, kind: parserKind)
    }
}
