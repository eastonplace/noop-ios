#if os(iOS)
import Foundation
import GRDB
import WhoopStore

enum LocalCoachDataError: LocalizedError, Equatable {
    case consentRequired, sourceChanged, activeWorkout, conflictingPlan
    case invalidRequest(String), unavailable(String), unsupportedReceiptVersion(Int)

    var errorDescription: String? {
        switch self {
        case .consentRequired: return "Enable Coach and personal data access before reading your records."
        case .sourceChanged: return "The data source or its snapshot changed. Retry with the current source."
        case .activeWorkout: return "Finish or discard the active workout before saving this plan."
        case .conflictingPlan: return "This plan conflicts with a saved or edited routine. Create a new draft instead."
        case .invalidRequest(let message), .unavailable(let message): return message
        case .unsupportedReceiptVersion(let version): return "ReceiptLift version \(version) cannot be edited by this coach. Your routines were kept."
        }
    }
}

/// Gregorian civil dates in the user's time zone. Every tool has a bounded interval, even when
/// the model supplies malformed input. Explicit dates never silently fall back to today's date.
struct LocalCoachWindow: Sendable {
    let from: String
    let through: String
    let start: Date
    let endExclusive: Date

    init(query: String, days: Int, now: Date) throws {
        guard (1...365).contains(days), query.count <= 2_000, !query.contains("\0") else {
            throw LocalCoachDataError.invalidRequest("Use 1...365 days and a question of at most 2,000 characters.")
        }
        let cal = Self.calendar
        let today = cal.startOfDay(for: now)
        let pattern = try NSRegularExpression(pattern: #"\b\d{4}-\d{1,2}-\d{1,2}\b"#)
        let matches = pattern.matches(in: query, range: NSRange(query.startIndex..., in: query))
        guard matches.count <= 2 else {
            throw LocalCoachDataError.invalidRequest("Supply one date or one date range per tool call.")
        }
        let dates = try matches.map { match -> Date in
            guard let range = Range(match.range, in: query), let date = Self.date(String(query[range])) else {
                throw LocalCoachDataError.invalidRequest("Dates must be real calendar dates written YYYY-MM-DD.")
            }
            return date
        }
        let last = dates.last ?? today
        let first = dates.first ?? cal.date(byAdding: .day, value: 1 - days, to: last)!
        let span = cal.dateComponents([.day], from: first, to: last).day ?? Int.max
        guard first <= last, last <= today, (0..<365).contains(span) else {
            throw LocalCoachDataError.invalidRequest("Choose an ordered date range of at most 365 days ending today or earlier.")
        }
        start = first
        endExclusive = cal.date(byAdding: .day, value: 1, to: last)!
        from = Self.key(first)
        through = Self.key(last)
    }

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    private static var formatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }

    static func key(_ date: Date) -> String { formatter.string(from: date) }
    static func date(_ key: String) -> Date? {
        guard key.count == 10, let value = formatter.date(from: key), Self.key(value) == key else { return nil }
        return value
    }
    func contains(_ key: String) -> Bool { Self.date(key) != nil && key >= from && key <= through }
    var label: String { "\(from) through \(through)" }
}

@MainActor
final class LocalCoachDataService {
    private let repo: Repository
    private let access: @MainActor () throws -> Bool
    private let now: @MainActor () -> Date
    private let plans: LocalCoachPlanAdapter

    init(repo: Repository) {
        self.repo = repo
        self.access = {
            let preferences = try LocalCoachPersistence.appLocal().loadPreferences()
            return preferences.enabled && preferences.usePersonalData
        }
        self.now = Date.init
        self.plans = LocalCoachPlanAdapter(repo: repo)
    }

    #if DEBUG
    var afterReadForTesting: (@MainActor () async -> Void)?
    init(repo: Repository, access: @escaping @MainActor () throws -> Bool, now: @escaping @MainActor () -> Date) {
        self.repo = repo
        self.access = access
        self.now = now
        self.plans = LocalCoachPlanAdapter(repo: repo)
    }
    #endif

    static var tools: [LocalCoachToolDescriptor] {
        [
            .init(id: "app_diagnostics", title: "App diagnostics", description: "Read app build, OS, local-model availability and protected-storage status. Use for bugs or testing questions. No private logs, health records or automatic bug submissions.", symbol: "ladybug"),
            .init(id: "current_day", title: "Current day", description: "Latest canonical daily metrics, actual record date, and missing fields. Does not assume the latest record is today.", symbol: "sun.horizon"),
            .init(id: "readiness", title: "Readiness", description: "Recorded recovery, HRV, resting heart rate and sleep. No medical clearance or invented readiness score.", symbol: "heart.circle"),
            .init(id: "sleep_history", title: "Sleep history", description: "Dated sleep duration, stages and efficiency from the canonical cache; missing nights remain missing.", symbol: "moon.stars"),
            .init(id: "metric_trends", title: "Metric trends", description: "Bounded daily recovery, effort, sleep, HRV and resting heart rate with units and observed-day averages.", symbol: "chart.xyaxis.line"),
            .init(id: "workout_history", title: "Workout history", description: "Up to 60 local workouts with duration, recorded heart rate, energy and source provenance.", symbol: "figure.run"),
            .init(id: "workout_zones", title: "Workout zones", description: "Stored heart-rate zone percentages for recent workouts, without guessing a missing zone format.", symbol: "chart.bar"),
            .init(id: "training_load", title: "Training load", description: "Observed workout count and duration plus canonical daily effort. Does not add nonlinear effort scores or invent fitness/fatigue indices.", symbol: "figure.strengthtraining.traditional"),
            .init(id: "nutrition", title: "Recorded nutrition", description: "Locally imported nutrition-csv calories and macros only. Missing intake is not zero; expenditure is not intake.", symbol: "leaf"),
            .init(id: "journal_associations", title: "Journal associations", description: "Explicit yes versus explicit no journal answers matched to same-day recovery, with group sizes. Association is not causation.", symbol: "book.closed"),
            .init(id: "data_freshness", title: "Data freshness", description: "Actual latest cached record dates and repository source coverage. Does not claim a sync happened at request time.", symbol: "clock.arrow.circlepath"),
            .init(id: "exercise_catalog", title: "Exercise catalog", description: "Up to 24 matching exercises and stable identifiers from the installed ReceiptLift catalog.", symbol: "dumbbell"),
            .init(id: "existing_routines", title: "Saved routines", description: "Up to 20 routines in the selected source's actual ReceiptLift v2 envelope.", symbol: "list.bullet.rectangle"),
            .init(id: "metric_explanations", title: "Metric guide", description: "Explain the stored units and limitations of recovery, effort, sleep, HRV, resting heart rate and workout zones. Reads no personal data.", symbol: "info.circle")
        ]
    }

    private struct Scope: Equatable {
        let source: String
        let lineage: String
        let context: String
        let invalidationEpoch: UInt64
        let importedIDs: [String]
        let computedIDs: [String]
        var draftContext: String { [source, lineage, context].joined(separator: "|") }
    }

    private func scope() -> Scope {
        Scope(source: repo.deviceId, lineage: repo.liveSourceState.lineageComponent,
              context: repo.todayHealthSnapshotScopeId,
              invalidationEpoch: repo.externalSurfaceInvalidationEpoch,
              importedIDs: repo.importedReadIds, computedIDs: repo.computedReadIds)
    }

    private func check(_ expected: Scope) throws {
        try Task.checkCancellation()
        guard try access() else { throw LocalCoachDataError.consentRequired }
        guard scope() == expected, !repo.verifiedExternalSurfaceFenced else {
            throw LocalCoachDataError.sourceChanged
        }
    }

    private func checkedStore(_ expected: Scope) async throws -> WhoopStore {
        try check(expected)
        let store = await repo.storeHandle()
        try check(expected)
        guard let store else { throw LocalCoachDataError.unavailable("The local database is unavailable. No records were read.") }
        return store
    }

    private func finishRead(_ expected: Scope) async throws {
        #if DEBUG
        await afterReadForTesting?()
        #endif
        try check(expected)
    }

    func snapshot() async throws -> LocalCoachSnapshot {
        let expected = scope()
        try check(expected)
        let date = now()
        let rows = canonicalRows().filter { $0.day <= LocalCoachWindow.key(date) }
        let latest = rows.last
        let latestDate = latest.flatMap { LocalCoachWindow.date($0.day) }
        let age = latestDate.flatMap { LocalCoachWindow.calendar.dateComponents([.day], from: $0,
            to: LocalCoachWindow.calendar.startOfDay(for: date)).day }
        let summary: String
        if let latest, let age {
            summary = age == 0 ? "Latest canonical records are dated today (\(latest.day)); today's records may be incomplete."
                : "Latest canonical records: \(latest.day), \(age) calendar days ago. These are stale for today's readiness."
        } else {
            summary = "No canonical daily records are available for this source. Missing metrics are not zero."
        }
        let chartWindow = latestDate.flatMap { try? LocalCoachWindow(query: "", days: 14, now: $0) }
        let recent = rows.filter { chartWindow?.contains($0.day) == true }
        let metrics = Metric.core.map { metric in
            let value = latest.flatMap { metric.value($0) }
            let points = recent.compactMap { row -> (String, Double)? in metric.value(row).map { (row.day, $0) } }
            return LocalCoachMetric(id: metric.id, title: metric.title,
                value: value.map { Self.number($0) } ?? "Not recorded", unit: metric.unit,
                detail: "\(latest?.day ?? "No record date"). \(points.count) observed days; gaps are omitted, never zero-filled.",
                samples: points.map(\.1))
        }
        let source = sourceDescription(expected)
        let context = ([summary, "Source context: \(source). Chart points use actual dates; absent days are omitted."]
            + recent.map { Self.dayLine($0) }).joined(separator: "\n")
        var evidence = [LocalCoachEvidence(id: "canonical:\(expected.source)", title: "Canonical daily records",
            detail: context, source: source, date: latestDate)]
        evidence.append(freshnessEvidence(expected))
        try await finishRead(expected)
        return LocalCoachSnapshot(generatedAt: date, sourceID: expected.source, latestDay: latest?.day,
            summary: summary, metrics: metrics, evidence: evidence, context: context)
    }

    func query(_ name: String, query: String, days: Int) async throws -> LocalCoachToolResult {
        if name == "app_diagnostics" {
            try Task.checkCancellation()
            return .init(text: LocalCoachDiagnostics.operationalSummary, evidence: [
                .init(id: "app-diagnostics", title: "App runtime status", detail: "Build, OS and model availability read from this process. No automatic tests were run.", source: "NOOP runtime", date: nil)
            ])
        }
        let window = try LocalCoachWindow(query: query, days: days, now: now())
        guard Self.tools.contains(where: { $0.id == name }) else {
            throw LocalCoachDataError.invalidRequest("Unknown local coach tool. Choose a named tool from the catalog.")
        }
        try Task.checkCancellation()
        if name == "metric_explanations" {
            return .init(text: Self.metricGuide, evidence: [.init(id: "metric-guide", title: "NOOP metric definitions",
                detail: "Definitions describe the app's stored units; this is not a personal assessment.", source: "NOOP local metric model", date: nil)])
        }
        if name == "exercise_catalog" {
            let catalog = try LocalCoachPlanAdapter.bundledCatalog()
            let terms = query.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
            let matching = catalog.filter { exercise in
                terms.isEmpty || terms.allSatisfy { "\(exercise.name) \(exercise.equipment) \(exercise.target)".lowercased().contains($0) }
            }
            let lines = matching.prefix(24).map { "\($0.id) | \($0.name) | \($0.equipment) | \($0.target)" }
            return .init(text: (["Installed ReceiptLift catalog; showing \(min(24, matching.count)) of \(matching.count) matches."]
                + (lines.isEmpty ? ["No matching catalog exercises. Try an exercise, muscle or equipment name."] : lines)).joined(separator: "\n"),
                evidence: [.init(id: "receipt-catalog", title: "Installed exercise catalog", detail: "Actual stable ReceiptLift identifiers; no generated exercises.", source: "ReceiptLift bundled ExerciseCatalog", date: nil)])
        }
        let expected = scope()
        try check(expected)
        let rows = canonicalRows().filter { window.contains($0.day) }
        var lines = ["Window: \(window.label). Source: \(sourceDescription(expected))."]
        var evidence = [freshnessEvidence(expected)]
        switch name {
        case "current_day", "readiness":
            let recent = rows.suffix(name == "readiness" ? 7 : 1)
            lines += recent.map(Self.dayLine)
            if let latest = recent.last {
                lines.append("Latest requested record: \(latest.day). \(latest.day == LocalCoachWindow.key(now()) ? "Today's record may be incomplete." : "This record is stale for today's readiness.")")
            } else {
                lines.append("No canonical daily records in this window. Older cached records or records outside the cache do not establish current readiness.")
            }
            if name == "readiness" { lines.append("These are recorded indicators, not medical clearance or a new readiness calculation.") }
        case "sleep_history":
            lines += rows.map { row in
                let efficiency = row.efficiency.flatMap { raw -> Double? in
                    let percent = raw <= 1.5 ? raw * 100 : raw
                    return percent.isFinite && (0...100).contains(percent) ? percent : nil
                }
                return "\(row.day): sleep \(Self.measured(row.totalSleepMin, unit: "min")), deep \(Self.measured(row.deepMin, unit: "min")), REM \(Self.measured(row.remMin, unit: "min")), light \(Self.measured(row.lightMin, unit: "min")), efficiency \(Self.measured(efficiency, unit: "%"))"
            }
            if rows.isEmpty { lines.append("No canonical sleep records in this window. The cache is bounded; this does not prove the database contains no older sleep.") }
        case "metric_trends":
            lines += rows.map(Self.dayLine)
            lines += Metric.all.map { metric in
                let values = rows.compactMap { metric.value($0) }
                return "\(metric.title): \(Self.mean(values).map { Self.number($0) + " " + metric.unit } ?? "not recorded"); \(values.count) observed days, not a complete calendar-day average."
            }
        case "data_freshness":
            lines += [freshnessEvidence(expected).detail, "Request time is not data observation time. Last device sync timestamp is unavailable here."]
        case "workout_history", "workout_zones", "training_load":
            let read = try await workouts(window, expected: expected)
            try check(expected)
            let workouts = read.rows
            let shown = Array(workouts.prefix(60))
            if name == "training_load" {
                let durations = workouts.compactMap { Self.valid($0.row.durationS, range: 0...604_800) }
                lines.append("Observed workouts: \(workouts.count) (read cap: 200). Recorded duration: \(Self.number(durations.reduce(0, +) / 60)) min across \(durations.count) workouts with duration. Missing durations are excluded.")
                let strain = rows.compactMap { Metric.effort.value($0) }
                lines.append("Mean canonical daily effort: \(Self.mean(strain).map { Self.number($0) + " /100" } ?? "not recorded") across \(strain.count) observed days. Effort is nonlinear and is not summed. No acute/chronic load ratio or injury-risk estimate was calculated.")
            } else {
                lines += shown.map { item in
                    let row = item.row
                    let prefix = "\(LocalCoachWindow.key(Date(timeIntervalSince1970: Double(row.startTs)))) | \(Self.clean(row.sport)) | \(item.owner) / \(Self.clean(row.source))"
                    if name == "workout_zones" { return prefix + " | " + Self.zoneDescription(row.zonesJSON) }
                    let effort = row.strainVersion == 2 ? Self.valid(row.strain, range: 0...100) : nil
                    return prefix + " | duration \(Self.measured(row.durationS.map { $0 / 60 }, unit: "min")) | mean HR \(Self.measured(row.avgHr.map(Double.init), unit: "bpm")) | energy \(Self.measured(row.energyKcal, unit: "kcal")) | canonical effort \(Self.measured(effort, unit: "/100"))"
                }
            }
            if workouts.isEmpty { lines.append("No stored workouts in the allowed sources and date window.") }
            if read.truncated { lines.append("The 200-workout read cap was reached. Totals describe only the returned rows.") }
            lines.append("Only identical records across namespaces were collapsed. Distinct overlapping records remain and may describe the same activity.")
            evidence += shown.prefix(8).map { item in .init(id: "workout:\(item.owner):\(item.row.startTs):\(item.row.sport)", title: Self.clean(item.row.sport), detail: "Stored workout; \(Self.measured(item.row.durationS, unit: "seconds")).", source: "\(item.owner) / \(Self.clean(item.row.source))", date: Date(timeIntervalSince1970: Double(item.row.startTs))) }
        case "nutrition":
            let store = try await checkedStore(expected)
            // This is a separately labelled, user-level import. Never attribute food intake to a strap.
            for (key, unit) in [("calories_in", "kcal"), ("protein_g", "g"), ("carbs_g", "g"), ("fat_g", "g")] {
                let points = try await store.metricSeries(deviceId: "nutrition-csv", key: key, from: window.from, to: window.through)
                try check(expected)
                let valid = points.prefix(365).filter { window.contains($0.day) && $0.value.isFinite && $0.value >= 0 }
                lines += valid.map { "\($0.day): \(key) \(Self.number($0.value)) \(unit) [nutrition-csv]" }
                if valid.isEmpty { lines.append("\(key): not recorded in nutrition-csv for this window.") }
            }
            lines.append("Only stored CSV intake is available. Missing food logs cannot establish intake or a calorie deficit.")
            evidence.append(.init(id: "nutrition:\(window.from)", title: "Local nutrition import", detail: window.label, source: "nutrition-csv (independent local import)", date: LocalCoachWindow.date(window.through)))
        case "journal_associations":
            let store = try await checkedStore(expected)
            let owners = Array(Set(expected.importedIDs + [Repository.journalDeviceId])).sorted()
            guard owners.count <= 8 else { throw LocalCoachDataError.unavailable("Too many source namespaces to read safely.") }
            var entries: [(String, JournalEntry)] = []
            for owner in owners {
                let records = try await store.localCoachJournal(deviceID: owner, from: window.from, through: window.through, limit: 200)
                try check(expected)
                entries += records.map { (owner, $0) }
                if records.count == 200 { lines.append("Journal cap reached for \(owner); associations use a truncated sample.") }
            }
            // Prefer native explicit answers to imported answers on the same question and day.
            struct AnswerKey: Hashable { let day: String; let question: String }
            var keyedAnswers: [AnswerKey: (String, JournalEntry)] = [:]
            for entry in entries.sorted(by: { $0.0 != Repository.journalDeviceId && $1.0 == Repository.journalDeviceId }) {
                keyedAnswers[AnswerKey(day: entry.1.day, question: entry.1.question)] = entry
            }
            let outcomes = Dictionary(rows.compactMap { row in Metric.recovery.value(row).map { (row.day, $0) } }, uniquingKeysWith: { _, last in last })
            let grouped = Dictionary(grouping: keyedAnswers.values, by: { $0.1.question })
            for question in grouped.keys.sorted().prefix(12) {
                let values = grouped[question] ?? []
                let yes = values.filter { $0.1.answeredYes }.compactMap { outcomes[$0.1.day] }
                let no = values.filter { !$0.1.answeredYes }.compactMap { outcomes[$0.1.day] }
                guard yes.count >= 3, no.count >= 3, let yesMean = Self.mean(yes), let noMean = Self.mean(no) else {
                    lines.append("\(Self.clean(question)): insufficient matched data (yes \(yes.count), no \(no.count)); at least 3 each are required.")
                    continue
                }
                lines.append("\(Self.clean(question)): same-day recovery yes mean \(Self.number(yesMean))/100 (n=\(yes.count)), explicit-no mean \(Self.number(noMean))/100 (n=\(no.count)), difference \(Self.number(yesMean - noMean)) points. Sources: \(Set(values.map(\.0)).sorted().joined(separator: ", ")).")
            }
            if grouped.isEmpty { lines.append("No explicit journal answers in the allowed sources and window.") }
            lines.append("Descriptive association only, with no causal or statistical-significance claim. Unlogged days are excluded, not treated as no. Other habits and timing can confound the comparison.")
            evidence.append(.init(id: "journal:\(window.from)", title: "Journal and recovery comparison", detail: window.label + "; explicit answers only, same-day alignment.", source: owners.joined(separator: ", "), date: LocalCoachWindow.date(window.through)))
        case "existing_routines":
            let store = try await checkedStore(expected)
            let owner = try await store.receiptLiftSourceOwner(deviceId: expected.source)
            try check(expected)
            let bytes = try await store.loadReceiptLiftState(sourceOwner: owner)
            try check(expected)
            if let bytes {
                let routines = try LocalCoachPlanAdapter.routines(in: bytes)
                lines += routines.prefix(20).map { "\($0.id) | \(Self.clean($0.name)) | \($0.exerciseIDs.count) exercises" }
                if routines.isEmpty { lines.append("ReceiptLift is available, but this source has no saved routines.") }
                evidence.append(.init(id: "routines:\(expected.source)", title: "ReceiptLift routines", detail: "\(routines.count) saved routines; showing at most 20.", source: expected.source, date: nil))
            } else { lines.append("This source has no stored ReceiptLift state. Open Lift to initialize its routine bank.") }
        default: break
        }
        if ["current_day", "readiness", "sleep_history", "metric_trends", "training_load"].contains(name) {
            evidence.append(.init(id: "daily:\(expected.source):\(window.from):\(window.through)",
                title: "Canonical daily cache", detail: "\(window.label); \(rows.count) observed daily rows. Missing dates are excluded. The cache can contain less history than requested.",
                source: sourceDescription(expected), date: rows.last.flatMap { LocalCoachWindow.date($0.day) }))
        }
        try await finishRead(expected)
        let text = lines.joined(separator: "\n")
        let bounded = text.count > 32_000 ? String(text.prefix(31_800)) + "\n[Output truncated at the local text limit. Request a smaller date window.]" : text
        return .init(text: bounded, evidence: Array(evidence.prefix(20)))
    }

    func makeWorkoutDraft(focus: String, minutes: Int, days: Int) async throws -> LocalCoachPlan {
        let expected = scope()
        try check(expected)
        let store = try await checkedStore(expected)
        let owner = try await store.receiptLiftSourceOwner(deviceId: expected.source)
        try check(expected)
        let data = try await store.loadReceiptLiftState(sourceOwner: owner)
        try check(expected)
        var draft = try LocalCoachPlanAdapter.draft(focus: focus, minutes: minutes, days: days,
            sourceID: expected.source, now: now(), catalog: LocalCoachPlanAdapter.catalog(in: data),
            routines: data.map { try LocalCoachPlanAdapter.routines(in: $0) } ?? [])
        try await finishRead(expected)
        draft.sourceContext = expected.draftContext
        return draft
    }

    /// Called by the engine only from the visible review/confirmation action; never advertised as a tool.
    func savePlan(_ plan: LocalCoachPlan) async throws {
        let expected = scope()
        try check(expected)
        guard plan.sourceID == expected.source else { throw LocalCoachDataError.sourceChanged }
        guard plan.sourceContext == expected.draftContext else {
            throw LocalCoachDataError.unavailable("Recreate this draft for the current data source before saving. The draft's original source context is unavailable or changed.")
        }
        try await plans.save(plan, validateSource: { [weak self] in
            guard let self else { throw CancellationError() }
            try self.check(expected)
        })
        try check(expected)
    }

    private func canonicalRows() -> [DailyMetric] {
        guard repo.loaded, !repo.verifiedExternalSurfaceFenced else { return [] }
        let rows = repo.canonicalDays.filter { LocalCoachWindow.date($0.day) != nil }
        return Dictionary(rows.map { ($0.day, $0) }, uniquingKeysWith: { _, last in last }).values.sorted { $0.day < $1.day }.suffix(365).map { $0 }
    }

    private func sourceDescription(_ expected: Scope) -> String {
        "selected \(expected.source); canonical merge contributors \(Array(Set(expected.importedIDs + expected.computedIDs + [Repository.appleHealthSource])).sorted().joined(separator: ", "))"
    }

    private func freshnessEvidence(_ expected: Scope) -> LocalCoachEvidence {
        let fresh = repo.freshness
        return .init(id: "freshness:\(expected.source)", title: "Recorded data coverage",
            detail: "Latest repository history day: \(fresh.latestDay ?? "unknown"). Earliest: \(fresh.earliestDay ?? "unknown"). Imported days: \(fresh.importedDays); computed days: \(fresh.computedDays); Apple days: \(fresh.appleDays). Overlapping source counts are not distinct calendar days. This is cache coverage, not a last-sync timestamp.",
            source: sourceDescription(expected), date: fresh.latestDay.flatMap(LocalCoachWindow.date))
    }

    private struct OwnedWorkout { let owner: String; let row: WorkoutRow }
    private func workouts(_ window: LocalCoachWindow, expected: Scope) async throws -> (rows: [OwnedWorkout], truncated: Bool) {
        let store = try await checkedStore(expected)
        var seenOwners = Set<String>()
        let owners = ([expected.source] + expected.importedIDs + [Repository.appleHealthSource, Repository.activityFileSource])
            .filter { seenOwners.insert($0).inserted }
        guard owners.count <= 8 else { throw LocalCoachDataError.unavailable("Too many workout source namespaces to read safely.") }
        var result: [OwnedWorkout] = []
        var truncated = false
        for owner in owners {
            let rows = try await store.localCoachWorkouts(deviceID: owner, from: Int(window.start.timeIntervalSince1970),
                through: Int(min(window.endExclusive.timeIntervalSince1970 - 1, now().timeIntervalSince1970)))
            try check(expected)
            truncated = truncated || rows.count > 200
            result += rows.prefix(200).filter { $0.endTs >= $0.startTs }.map { .init(owner: owner, row: $0) }
        }
        // Only exact duplicates are collapsed. Do not guess that overlapping workouts are identical.
        var seen: [String: [WorkoutRow]] = [:]
        let distinct = result.sorted { $0.row.startTs > $1.row.startTs }.filter { item in
            let key = "\(item.row.startTs)|\(item.row.endTs)|\(item.row.sport)|\(item.row.source)"
            guard seen[key]?.contains(item.row) != true else { return false }
            seen[key, default: []].append(item.row)
            return true
        }
        return (Array(distinct.prefix(200)), truncated || distinct.count > 200)
    }

    @MainActor private struct Metric {
        let id: String
        let title: String
        let unit: String
        let value: @MainActor (DailyMetric) -> Double?
        static let recovery = Metric(id: "recovery", title: "Recovery", unit: "/100", value: { valid($0.recovery, range: 0...100) })
        static let effort = Metric(id: "strain", title: "Effort", unit: "/100", value: { valid($0.strain, range: 0...100) })
        static let core: [Metric] = [recovery, effort,
            .init(id: "sleep", title: "Sleep", unit: "h", value: { valid($0.totalSleepMin, range: 0...1_440).map { $0 / 60 } }),
            .init(id: "hrv", title: "HRV", unit: "ms", value: { valid($0.avgHrv, range: 0...1_000) })]
        static let all: [Metric] = core + [.init(id: "rhr", title: "Resting heart rate", unit: "bpm", value: { valid($0.restingHr.map(Double.init), range: 1...300) })]
    }

    private static func valid(_ value: Double?, range: ClosedRange<Double>) -> Double? {
        guard let value, value.isFinite, range.contains(value) else { return nil }
        return value
    }
    private static func mean(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
    private static func number(_ value: Double) -> String { String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value) }
    private static func measured(_ value: Double?, unit: String) -> String {
        guard let value, value.isFinite, value >= 0 else { return "not recorded" }
        return number(value) + " " + unit
    }
    private static func clean(_ text: String) -> String { String(text.replacingOccurrences(of: "\n", with: " ").prefix(300)) }
    private static func dayLine(_ day: DailyMetric) -> String {
        day.day + ": " + Metric.all.map { metric in
            "\(metric.title) \(measured(metric.value(day), unit: metric.unit))"
        }.joined(separator: "; ")
    }

    static func zoneDescription(_ json: String?) -> String {
        guard let json, json.utf8.count <= 8_192, let bytes = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: bytes) else { return "Heart-rate zones not recorded." }
        // The repository's importers store named zone percentages. Missing keys stay missing.
        if let dictionary = object as? [String: Double] {
            let keys = (1...5).map { "z\($0)" }
            let longKeys = (1...5).map { "zone\($0)" }
            let recognized = Set(keys + longKeys)
            guard Set(dictionary.keys).isSubset(of: recognized), !dictionary.isEmpty,
                  dictionary.values.allSatisfy({ $0.isFinite && (0...100).contains($0) }) else {
                return "A zone payload exists, but its unit/shape is not supported. No zone totals inferred."
            }
            var values: [Double?] = []
            for zone in 1...5 {
                if let short = dictionary["z\(zone)"], let long = dictionary["zone\(zone)"], short != long {
                    return "The stored zone labels conflict. No zone totals inferred."
                }
                values.append(dictionary["z\(zone)"] ?? dictionary["zone\(zone)"])
            }
            guard values.compactMap({ $0 }).reduce(0, +) <= 101 else { return "Stored zone percentages exceed 100%; no zone totals inferred." }
            return values.enumerated().map { "Zone \($0.offset + 1): \(measured($0.element, unit: "%"))" }.joined(separator: "; ")
                + ". Source-defined thresholds are unavailable."
        }
        // Unlabelled arrays retain their source order. Do not infer thresholds or zone minutes.
        if let values = object as? [Double], (5...6).contains(values.count),
           values.allSatisfy({ $0.isFinite && (0...100).contains($0) }), values.reduce(0, +) <= 101 {
            return "Stored zone percentages (source order): " + values.map { number($0) + "%" }.joined(separator: ", ") + ". Zone thresholds not supplied."
        }
        return "A zone payload exists, but its unit/shape is not supported. No zone totals inferred."
    }

    private static let metricGuide = """
    Recovery: recorded 0...100 score, not medical clearance. Interpretation depends on its recorded inputs and date.
    Effort: NOOP canonical Strain V2, 0...100. Legacy/imported strain is excluded from the canonical metric. Do not add daily effort scores.
    Sleep: recorded duration in hours or minutes. A missing night is unknown, not zero sleep. Stages are wearable estimates.
    HRV: stored daily variability in milliseconds. Compare the same measurement method and source over time.
    Resting heart rate: beats per minute. A missing value is not zero.
    Workout zones: stored source-defined percentages. Without known thresholds and units, do not convert to time or compare different zone systems.
    Nutrition: nutrition-csv is recorded food intake; active energy expenditure is a different measurement.
    Journal comparisons: explicit yes/no observations describe associations, not causes or a diagnosis.
    """
}

private extension WhoopStore {
    func localCoachWorkouts(deviceID: String, from: Int, through: Int) async throws -> [WorkoutRow] {
        try await registryWriter.read { db in
            try Row.fetchAll(db, sql: """
                SELECT startTs, endTs, sport, source, durationS, energyKcal, avgHr, maxHr,
                       strain, distanceM, zonesJSON, notes, strainVersion FROM workout
                WHERE deviceId = ? AND startTs >= ? AND startTs <= ?
                ORDER BY startTs DESC, sport ASC LIMIT 201
                """, arguments: [deviceID, from, through]).map {
                    WorkoutRow(startTs: $0["startTs"], endTs: $0["endTs"], sport: $0["sport"], source: $0["source"],
                        durationS: $0["durationS"], energyKcal: $0["energyKcal"], avgHr: $0["avgHr"], maxHr: $0["maxHr"],
                        strain: $0["strain"], distanceM: $0["distanceM"], zonesJSON: $0["zonesJSON"], notes: $0["notes"],
                        strainVersion: $0["strainVersion"])
                }
        }
    }

    /// Fixed, parameterized, source-scoped read. No SQL or column names are accepted from the model.
    func localCoachJournal(deviceID: String, from: String, through: String, limit: Int) async throws -> [JournalEntry] {
        try await registryWriter.read { db in
            try Row.fetchAll(db, sql: """
                SELECT day, question, answeredYes, numericValue FROM journal
                WHERE deviceId = ? AND day >= ? AND day <= ?
                ORDER BY day DESC, question ASC LIMIT ?
                """, arguments: [deviceID, from, through, min(200, max(1, limit))]).map {
                    JournalEntry(day: $0["day"], question: $0["question"], answeredYes: ($0["answeredYes"] as Int) != 0,
                        notes: nil, numericValue: $0["numericValue"])
                }
        }
    }
}
#endif
