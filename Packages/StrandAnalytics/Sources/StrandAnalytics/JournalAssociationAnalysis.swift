import Foundation

/// A descriptive, local comparison of explicit yes/no journal answers with recovery on the same
/// civil wake day. This type never reads records, changes answers, or accepts model-made metrics.
public enum JournalAssociationAnalysis {
    public static let minimumMatchedDays = 3
    /// Covers a normal multi-habit 90-day journal while keeping each source read strictly bounded.
    /// Readers fetch one extra row solely to distinguish an exact-size complete read from overflow.
    public static let maximumRowsPerSource = 4_096

    public struct Answer: Equatable, Sendable {
        public let day: String
        public let question: String
        public let answeredYes: Bool
        public let numericValue: Double?

        public init(day: String, question: String, answeredYes: Bool, numericValue: Double? = nil) {
            self.day = day
            self.question = question
            self.answeredYes = answeredYes
            self.numericValue = numericValue
        }
    }

    public struct SourceRead: Equatable, Sendable {
        public let source: String
        public let answers: [Answer]
        public let isTruncated: Bool

        public init(source: String, answers: [Answer], isTruncated: Bool = false) {
            self.source = source
            self.answers = Array(answers.prefix(JournalAssociationAnalysis.maximumRowsPerSource))
            self.isTruncated = isTruncated || answers.count > JournalAssociationAnalysis.maximumRowsPerSource
        }
    }

    public struct Recovery: Equatable, Sendable {
        public let day: String
        public let value: Double?

        public init(day: String, value: Double?) {
            self.day = day
            self.value = value
        }
    }

    public enum State: String, Codable, Equatable, Sendable {
        case available, insufficientData, truncated, noBooleanAnswers
    }

    public struct Insight: Codable, Equatable, Sendable {
        public let question: String?
        public let questionKey: String?
        public let state: State
        public let windowFrom: String
        public let windowThrough: String
        public let latestDay: String?
        /// Counts are nil when a bounded source read is incomplete; even merged group sizes could
        /// be biased by native overrides that fell beyond its read cap.
        public let loggedYesCount: Int?
        public let loggedNoCount: Int?
        public let matchedYesCount: Int?
        public let matchedNoCount: Int?
        public let missingRecoveryCount: Int?
        public let conflictingDayCount: Int?
        public let excludedNumericAnswerCount: Int
        public let sources: [String]
        public let sourcesRead: [String]
        public let recoverySource: String
        public let truncatedSources: [String]
        /// Nil unless both explicit groups have at least three matched days and all reads completed.
        public let yesMean: Double?
        public let noMean: Double?

        public var difference: Double? {
            guard state == .available, let yesMean, let noMean else { return nil }
            return yesMean - noMean
        }
    }

    public static func analyze(reads: [SourceRead], recovery: [Recovery], nativeSource: String,
                               recoverySource: String, windowFrom: String, windowThrough: String,
                               numericQuestions: Set<String> = []) -> [Insight] {
        let sourcesRead = Set(reads.map(\.source)).sorted()
        let truncatedSources = Set(reads.filter(\.isTruncated).map(\.source)).sorted()

        func summary(_ state: State, numericCount: Int = 0) -> Insight {
            let count: Int? = state == .truncated ? nil : 0
            return Insight(question: nil, questionKey: nil, state: state,
                windowFrom: windowFrom, windowThrough: windowThrough, latestDay: nil,
                loggedYesCount: count, loggedNoCount: count, matchedYesCount: count, matchedNoCount: count,
                missingRecoveryCount: count, conflictingDayCount: count,
                excludedNumericAnswerCount: numericCount, sources: [], sourcesRead: sourcesRead,
                recoverySource: recoverySource, truncatedSources: truncatedSources, yesMean: nil, noMean: nil)
        }

        // Do not merge a partial native read with complete imports: an unseen native answer could
        // override any older imported answer. Suppressing averages alone would leave biased counts.
        guard truncatedSources.isEmpty else { return [summary(.truncated)] }
        func inWindow(_ day: String) -> Bool {
            day >= windowFrom && day <= windowThrough && isCivilDay(day)
        }
        let answers = reads.flatMap { read in
            read.answers.filter { inWindow($0.day) && !questionKey($0.question).isEmpty }
                .map { SourcedAnswer(source: read.source, answer: $0) }
        }

        // A quantity uses answeredYes=true in storage; it is not a boolean observation. Exclude the
        // entire question when any returned row or the catalog identifies it as numeric, including
        // legacy boolean rows for a question the user has since retyped.
        let numericKeys = Set(numericQuestions.map(questionKey)).union(
            answers.filter { $0.answer.numericValue != nil }.map { questionKey($0.answer.question) })
        let numericCount = answers.filter { numericKeys.contains(questionKey($0.answer.question)) }.count
        let booleanAnswers = answers.filter { !numericKeys.contains(questionKey($0.answer.question)) }
        let questions = Dictionary(grouping: booleanAnswers, by: { questionKey($0.answer.question) })
        guard !questions.isEmpty else { return [summary(.noBooleanAnswers, numericCount: numericCount)] }

        var outcomes: [String: Double] = [:]
        for (day, rows) in Dictionary(grouping: recovery.filter { inWindow($0.day) }, by: \.day) {
            let values = Set(rows.compactMap(\.value).filter { $0.isFinite && (0...100).contains($0) })
            // Canonical days should already be unique. If they disagree, never choose by read order.
            if values.count == 1 { outcomes[day] = values.first }
        }

        return questions.keys.sorted().compactMap { key in
            guard let values = questions[key] else { return nil }
            let ordered = values.sorted {
                if ($0.source == nativeSource) != ($1.source == nativeSource) { return $0.source == nativeSource }
                if $0.source != $1.source { return $0.source < $1.source }
                return $0.answer.question < $1.answer.question
            }
            let question = ordered.first?.answer.question.trimmingCharacters(in: .whitespacesAndNewlines)
            var yes: [Double] = []
            var no: [Double] = []
            var loggedYes = 0
            var loggedNo = 0
            var missing = 0
            var conflicts = 0
            var sources = Set<String>()
            for (day, rows) in Dictionary(grouping: values, by: { $0.answer.day }) {
                let native = rows.filter { $0.source == nativeSource }
                let selected = native.isEmpty ? rows : native
                guard Set(selected.map { $0.answer.answeredYes }).count == 1,
                      let answer = selected.first?.answer else {
                    conflicts += 1
                    continue
                }
                sources.formUnion(selected.map(\.source))
                if answer.answeredYes { loggedYes += 1 } else { loggedNo += 1 }
                guard let outcome = outcomes[day] else { missing += 1; continue }
                if answer.answeredYes { yes.append(outcome) } else { no.append(outcome) }
            }
            let enough = yes.count >= minimumMatchedDays && no.count >= minimumMatchedDays
            return Insight(question: question, questionKey: key, state: enough ? .available : .insufficientData,
                windowFrom: windowFrom, windowThrough: windowThrough, latestDay: values.map { $0.answer.day }.max(),
                loggedYesCount: loggedYes, loggedNoCount: loggedNo, matchedYesCount: yes.count, matchedNoCount: no.count,
                missingRecoveryCount: missing, conflictingDayCount: conflicts,
                excludedNumericAnswerCount: numericCount, sources: sources.sorted(), sourcesRead: sourcesRead,
                recoverySource: recoverySource, truncatedSources: [],
                yesMean: enough ? yes.sorted().reduce(0, +) / Double(yes.count) : nil,
                noMean: enough ? no.sorted().reduce(0, +) / Double(no.count) : nil)
        }
    }

    private struct SourcedAnswer {
        let source: String
        let answer: Answer
    }

    /// Matches JournalCatalogStore's identity rule, without changing the stored/displayed question.
    private static func questionKey(_ value: String) -> String {
        value.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            .joined(separator: " ").lowercased()
    }

    private static func isCivilDay(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard value.count == 10, parts.count == 3, parts[0].count == 4, parts[1].count == 2,
              parts[2].count == 2, let year = Int(parts[0]), let month = Int(parts[1]),
              let day = Int(parts[2]), (1...9999).contains(year) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components) else { return false }
        return calendar.dateComponents([.year, .month, .day], from: date) == components
    }
}
