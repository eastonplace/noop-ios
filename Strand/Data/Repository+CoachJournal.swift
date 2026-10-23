#if os(iOS)
import Foundation
import GRDB
import StrandAnalytics
import WhoopStore

/// Values for one selected wake day. A widget never derives answers from Coach prose.
struct CoachJournalSnapshot: Equatable {
    let day: String
    let sourceContext: String
    let importedQuestions: [String]
    let answers: [String: Bool]
    let numericAnswers: [String: Double]
    let details: JournalEntryDayDetails
    let catalogWasTruncated: Bool
    /// What an import brought for the day. It counts as answered and shows its value until a tap here replaces it.
    var importedAnswers: [String: Bool] = [:]
    var importedNumeric: [String: Double] = [:]
}

@MainActor
extension Repository {
    /// Used by the manual Journal destination and by the consent-gated Coach host. Reads only one
    /// native day plus bounded distinct labels. It never fetches thousands of days of answer values.
    func coachJournalSnapshot(day: String) async throws -> CoachJournalSnapshot {
        guard LocalCoachWindow.date(day) != nil else { throw JournalEntryReviewError.invalidValues }
        let context = try await journalEntryContext()
        let owners = importedReadIds
        guard owners.count <= 8 else { throw JournalEntryReviewError.unavailable }
        func check() throws {
            try Task.checkCancellation()
            guard !verifiedExternalSurfaceFenced, journalEntrySourceContext == context,
                  importedReadIds == owners else {
                throw JournalEntryReviewError.contextChanged
            }
        }
        let review = try await reviewJournalEntry(day: day, sourceContext: context,
                                                 fields: [], suggestions: [], includeDayDetails: true)
        try check()
        guard let store = await storeHandle(), let details = review.dayDetails else {
            throw JournalEntryReviewError.unavailable
        }
        try check()
        var labels = Set<String>()
        var truncated = false
        for owner in owners {
            let names = try await store.coachJournalQuestionNames(deviceID: owner)
            try check()
            truncated = truncated || names.count > 256
            labels.formUnion(names.prefix(256))
        }
        truncated = truncated || labels.count > 256
        let questions = Array(labels.sorted().prefix(256))
        let answers = review.existing.mapValues(\.answeredYes)
        let numbers = review.existing.compactMapValues(\.numericValue)
        var importedRows: [JournalEntry] = []
        for owner in owners {
            let rows = try await store.journalEntries(deviceId: owner, from: day, to: day)
            try check()
            importedRows += rows
        }
        try check()
        let imported = JournalQuickLog.values(from: Self.mergeJournal(imported: importedRows, native: []), day: day)
        return .init(day: day, sourceContext: context, importedQuestions: questions,
                     answers: answers, numericAnswers: numbers, details: details,
                     catalogWasTruncated: truncated,
                     importedAnswers: imported.answers, importedNumeric: imported.numeric)
    }
}

extension WhoopStore {
    /// One extra label reports truncation. Parameters cannot change the query or source namespace.
    fileprivate func coachJournalQuestionNames(deviceID: String) async throws -> [String] {
        try await registryWriter.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT question FROM journal
                WHERE deviceId = ? ORDER BY question ASC LIMIT 257
                """, arguments: [deviceID])
        }
    }
}
#endif
