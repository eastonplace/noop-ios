#if os(iOS)
import Foundation
import CryptoKit
import ReceiptLiftFeature
import WhoopStore

struct LocalCoachCatalogExercise: Equatable, Sendable {
    let id: String
    let name: String
    let equipment: String
    let target: String
    let instructions: String
}

struct LocalCoachRoutineTemplate: Decodable, Sendable {
    let id: String
    let name: String
    let exerciseIDs: [String]
}

/// Adapts a reviewed plan to ReceiptLift's actual v2 routines and scheduledWorkouts.
/// The host must register its CURRENT coordinator's mutation path. Writing the database envelope
/// independently would let that coordinator's next save erase the imported routines.
@MainActor
final class LocalCoachPlanAdapter {
    typealias ReceiptMutation = @MainActor (Data) throws -> Data?
    typealias ReceiptWriter = @MainActor (HistoricalCursorScope, ReceiptMutation) async throws -> Void

    private struct Binding {
        weak var repo: Repository?
        let write: ReceiptWriter
    }
    private static var writers: [ObjectIdentifier: Binding] = [:]
    private let repo: Repository
    private var saving = false

    init(repo: Repository) { self.repo = repo }

    /// Parent integration calls this once for the Repository used by the local coach.
    /// The writer must load/flush the active coordinator, check its owner and active workouts,
    /// run the mutation on its current in-memory envelope without an intervening await, apply
    /// the result in memory, and await its existing generation-ordered durable save.
    /// A nil mutation result means already saved and must cause no write. Keep weak host captures.
    static func registerReceiptWriter(repo: Repository, writer: @escaping ReceiptWriter) {
        writers = writers.filter { $0.value.repo != nil }
        writers[ObjectIdentifier(repo)] = Binding(repo: repo, write: writer)
    }

    static func unregisterReceiptWriter(repo: Repository) {
        writers.removeValue(forKey: ObjectIdentifier(repo))
    }

    func save(_ plan: LocalCoachPlan, validateSource: @escaping @MainActor () throws -> Void) async throws {
        try validateSource()
        guard plan.sourceID == repo.deviceId else { throw LocalCoachDataError.sourceChanged }
        guard !saving else { throw LocalCoachDataError.unavailable("A plan save is already in progress.") }
        guard let binding = Self.writers[ObjectIdentifier(repo)], binding.repo === repo else {
            throw LocalCoachDataError.unavailable("The active Lift routine writer is not connected to Coach. The plan remains a draft; no workouts were changed.")
        }
        saving = true
        defer { saving = false }
        let store = await repo.storeHandle()
        try validateSource()
        guard let store else { throw LocalCoachDataError.unavailable("The local workout database is unavailable.") }
        let owner = try await store.receiptLiftSourceOwner(deviceId: plan.sourceID)
        try validateSource()
        // The host receives a lineage/epoch token, not just a potentially reused device ID.
        try await binding.write(owner) { current in
            try validateSource()
            return try Self.merging(plan, into: current, catalog: Self.catalog(in: current))
        }
        try validateSource()
        guard let saved = try await store.loadReceiptLiftState(sourceOwner: owner) else {
            throw LocalCoachDataError.unavailable("Lift did not confirm a durable save. The plan remains available for review.")
        }
        try validateSource()
        guard try Self.isPersisted(plan, in: saved, catalog: Self.catalog(in: saved)) else {
            throw LocalCoachDataError.unavailable("The saved Lift routines did not match the reviewed plan. Open Lift before retrying.")
        }
    }

    // MARK: Catalog and existing presets

    private struct CatalogRecord: Decodable {
        let id: String
        let name: String
        let equipment: String
        let target: String
        let instructions: [String: String]
    }

    private static var catalogCache: [LocalCoachCatalogExercise]?

    static func bundledCatalog() throws -> [LocalCoachCatalogExercise] {
        if let catalogCache { return catalogCache }
        // SwiftPM copies ExerciseCatalog into this package's resource bundle. Search only installed
        // app bundles; never read an absolute development path, phone database, or network catalog.
        let hosts = [Bundle.main, Bundle(for: ReceiptLiftCoordinator.self)]
        let packages = hosts.compactMap { host in
            host.url(forResource: "ReceiptLiftFeature_ReceiptLiftFeature", withExtension: "bundle").flatMap(Bundle.init(url:))
        }
        let bundles = packages + Bundle.allBundles.filter { $0.bundleURL.lastPathComponent == "ReceiptLiftFeature_ReceiptLiftFeature.bundle" }
        guard let url = bundles.compactMap({ $0.url(forResource: "exercises", withExtension: "json", subdirectory: "ExerciseCatalog/data") }).first else {
            throw LocalCoachDataError.unavailable("The installed ReceiptLift exercise catalog is unavailable. No exercises were invented.")
        }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= maximumBytes else { throw LocalCoachDataError.unavailable("The exercise catalog exceeds the local read limit.") }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else { throw LocalCoachDataError.unavailable("The exercise catalog exceeds the local read limit.") }
        let records = try JSONDecoder().decode([CatalogRecord].self, from: data)
        guard !records.isEmpty, records.count <= 5_000 else {
            throw LocalCoachDataError.unavailable("The installed exercise catalog is empty or exceeds the local row limit.")
        }
        let result = records.map { record in
            LocalCoachCatalogExercise(id: receiptCatalogID(record.id), name: record.name,
                equipment: record.equipment, target: record.target, instructions: record.instructions["en"] ?? "")
        }
        guard Set(result.map(\.id)).count == result.count else {
            throw LocalCoachDataError.unavailable("The installed exercise catalog contains conflicting identifiers.")
        }
        catalogCache = result
        return result
    }

    /// Exact stable-ID algorithm used by ReceiptLiftFeature/LiftExerciseCatalog.swift.
    static func receiptCatalogID(_ sourceID: String) -> String {
        let value: UInt64
        if let numeric = UInt64(sourceID) { value = numeric }
        else {
            var hash: UInt64 = 14_695_981_039_346_656_037
            for byte in sourceID.utf8 { hash ^= UInt64(byte); hash &*= 1_099_511_628_211 }
            value = hash
        }
        return "00000000-0000-4000-8000-" + String(format: "%012llx", value & 0x0000_FFFF_FFFF_FFFF)
    }

    static func catalog(in data: Data?) throws -> [LocalCoachCatalogExercise] {
        let bundled = try bundledCatalog()
        guard let data else { return bundled }
        let root = try envelope(data)
        let user = try dictionaries(root, "userExercises").map { row -> LocalCoachCatalogExercise in
            guard let id = row["id"] as? String, UUID(uuidString: id) != nil,
                  let name = row["name"] as? String, let equipment = row["equipment"] as? String,
                  let target = row["muscleGroup"] as? String, let instructions = row["instructions"] as? String else {
                throw LocalCoachDataError.unavailable("ReceiptLift contains an unreadable saved exercise. Its data was kept.")
            }
            return .init(id: id.lowercased(), name: name, equipment: equipment, target: target, instructions: instructions)
        }
        guard user.count <= 5_000 else { throw LocalCoachDataError.unavailable("Saved exercises exceed the local row limit.") }
        // Match LiftStore's custom-first, normalized-name deduplication.
        var names = Set<String>()
        var ids = Set<String>()
        return (user + bundled).filter { names.insert(normalize($0.name)).inserted && ids.insert($0.id.lowercased()).inserted }
    }

    static func routines(in data: Data) throws -> [LocalCoachRoutineTemplate] {
        let root = try envelope(data)
        let rows = try dictionaries(root, "routines")
        guard rows.count <= 500 else { throw LocalCoachDataError.unavailable("Saved routines exceed the local row limit.") }
        return try JSONDecoder().decode([LocalCoachRoutineTemplate].self, from: JSONSerialization.data(withJSONObject: rows))
    }

    // MARK: Drafting

    static func draft(focus: String, minutes: Int, days: Int, sourceID: String, now: Date,
                      catalog: [LocalCoachCatalogExercise], routines: [LocalCoachRoutineTemplate]) throws -> LocalCoachPlan {
        guard !focus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, focus.count <= 500,
              !focus.contains("\0"), (10...180).contains(minutes), (1...14).contains(days) else {
            throw LocalCoachDataError.invalidRequest("Use a focus of 1...500 characters, 10...180 minutes and 1...14 training sessions.")
        }
        let text = normalize(focus)
        let words = Set(text.split(separator: " ").map(String.init))
        if !words.isDisjoint(with: ["marathon", "running", "swimming", "cycling", "yoga", "rehab"]) {
            throw LocalCoachDataError.unavailable("This planner supports repetition-based strength routines. Timed cardio, yoga and rehabilitation need a different plan format.")
        }
        let equipment = EquipmentRequest(text: text)
        let pool = catalog.filter { equipment.allows($0) && isRepetitionExercise($0) }
        guard !pool.isEmpty else { throw LocalCoachDataError.unavailable("No supported catalog exercises match this equipment. No routine was generated.") }
        let mode = words.contains("strength") ? "strength" : words.contains("endurance") ? "endurance" : "hypertrophy"
        let reps = mode == "strength" ? 6 : mode == "endurance" ? 15 : 10
        let rest = mode == "strength" ? 120 : mode == "endurance" ? 45 : 75
        let sets = minutes < 15 ? 1 : minutes < 25 ? 2 : 3
        let split: [String]
        if text.contains("ppl") || (words.contains("push") && words.contains("pull")) { split = ["push", "pull", "legs"] }
        else if words.contains("upper") && words.contains("lower") { split = ["upper", "legs"] }
        else if words.contains("pull") { split = ["pull"] }
        else if words.contains("push") { split = ["push"] }
        else if !words.isDisjoint(with: ["legs", "lower", "glutes"]) { split = ["legs"] }
        else if words.contains("upper") { split = ["upper"] }
        else { split = ["full body"] }
        var planned: [LocalCoachPlanDay] = []
        var reused = Set<String>()
        var uses: [String: Int] = [:]
        for index in 0..<days {
            let group = split[index % split.count]
            let targets = targetGroups(group)
            let allowed = pool.filter { targets.joined().contains(normalize($0.target)) }
            let ids = Set(allowed.map { $0.id.lowercased() })
            let preset = routines.first { routine in
                let name = normalize(routine.name)
                let matchesGroup = group == "full body" ? name.contains("full") : name.contains(group == "legs" ? "lower" : group)
                return matchesGroup && routine.exerciseIDs.filter { ids.contains($0.lowercased()) }.count >= 2
            }
            let presetIDs = preset?.exerciseIDs.map { $0.lowercased() } ?? []
            var selected: [LocalCoachCatalogExercise] = []
            // Preserve usable preset order; otherwise cover separate movement/muscle groups.
            if !presetIDs.isEmpty {
                selected = presetIDs.compactMap { id in allowed.first { $0.id.lowercased() == id } }
            } else {
                for targetGroup in targets {
                    let candidates = allowed.filter { targetGroup.contains(normalize($0.target)) && !selected.contains($0) }
                    if let best = candidates.sorted(by: { rank($0, uses: uses) > rank($1, uses: uses) }).first { selected.append(best) }
                }
            }
            let budget = (minutes - 5) * 60
            var cost = 0
            var exercises: [LocalCoachPlannedExercise] = []
            for exercise in selected.prefix(8) {
                let seconds = estimatedSeconds(sets: sets, reps: reps, rest: rest)
                guard cost + seconds <= budget else { break }
                cost += seconds
                uses[exercise.id, default: 0] += 1
                exercises.append(.init(catalogID: exercise.id, name: exercise.name, equipment: exercise.equipment,
                    sets: sets, reps: reps, restSeconds: rest,
                    note: "Use controlled repetitions and a load you can manage. No working weight was inferred."))
            }
            guard exercises.count >= 2 else {
                throw LocalCoachDataError.unavailable("The catalog cannot form a balanced \(group) session within this equipment and time limit. Add equipment or allow more time.")
            }
            if let preset { reused.insert(preset.name) }
            // Full-body or one-focus sessions have a rest day between. A split uses two days on,
            // one day off. These are proposed schedule choices, not readiness-based prescriptions.
            let offset = split.count == 1 ? index * 2 : index + index / 2
            planned.append(.init(dayOffset: offset, title: "\(group.capitalized) \(index + 1)",
                focus: focus, minutes: minutes, exercises: exercises))
        }
        let presetBasis = reused.isEmpty ? "Exercise order comes from the installed catalog." : "Exercise order uses saved presets: \(reused.sorted().joined(separator: ", "))."
        let summary = "\(days) proposed strength sessions. \(equipment.basis) \(presetBasis) Targets use \(mode) repetitions and an estimated time budget with 5 minutes for warm-up. Actual duration varies. Review exercise suitability and dates before saving; no medical clearance or current readiness was inferred."
        let plan = LocalCoachPlan(title: "\(days)-session \(split.count > 1 ? "split" : split[0]) plan", summary: summary,
            createdAt: now, sourceID: sourceID, days: planned)
        try validate(plan, catalog: catalog)
        return plan
    }

    private struct EquipmentRequest {
        let text: String
        let fullGym: Bool
        let bodyOnly: Bool
        let stated: [String]
        init(text: String) {
            self.text = text
            bodyOnly = text.contains("no equipment") || text.contains("bodyweight only") || text.contains("body weight only")
            fullGym = !bodyOnly && (text.contains("full gym") || text.contains("gym equipment") || text.contains("commercial gym"))
            stated = ["dumbbell", "barbell", "kettlebell", "band", "cable", "machine"].filter { text.contains($0) }
        }
        var basis: String {
            if fullGym { return "Equipment: full gym, as requested." }
            if bodyOnly || stated.isEmpty { return "Equipment assumption: body weight with floor space; a bench or pull-up bar is used only when stated." }
            return "Equipment: \(stated.joined(separator: ", ")) plus floor-based body-weight exercises."
        }
        func allows(_ exercise: LocalCoachCatalogExercise) -> Bool {
            let tool = normalize(exercise.equipment)
            let name = normalize(exercise.name)
            if fullGym { return true }
            let auxiliary = ["bench", "pull up", "chin up", "dip", "hanging", "hang", "inverted row", "step up", "box", "ball", "roller", "wheel", "suspended"]
            if auxiliary.contains(where: { name.contains($0) && !text.contains($0) }) { return false }
            if tool == "body weight" || tool == "bodyweight" { return true }
            guard !bodyOnly else { return false }
            return stated.contains { tool.contains($0) }
        }
    }

    private static func targetGroups(_ focus: String) -> [[String]] {
        let push = [["pectorals", "chest"], ["delts", "shoulders"], ["triceps"]]
        let pull = [["lats"], ["upper back", "back"], ["biceps"]]
        let legs = [["quads", "quadriceps", "legs"], ["hamstrings"], ["glutes"], ["calves"]]
        switch focus {
        case "push": return push
        case "pull": return pull
        case "legs": return legs
        case "upper": return [push[0], pull[0], pull[1], push[1], pull[2], push[2]]
        default: return [legs[0], push[0], pull[1], legs[2], ["abs", "abdominals"], legs[3]]
        }
    }

    private static func isRepetitionExercise(_ exercise: LocalCoachCatalogExercise) -> Bool {
        let name = normalize(exercise.name)
        guard normalize(exercise.target) != "cardiovascular system" else { return false }
        let words = Set(name.split(separator: " ").map(String.init))
        return words.isDisjoint(with: ["stretch", "stretching", "plank", "hold", "hang", "isometric", "carry", "run", "running", "roller"])
    }

    private static func rank(_ exercise: LocalCoachCatalogExercise, uses: [String: Int]) -> Int {
        let preferred = ["push up", "bodyweight squat", "squat", "glute bridge", "crunch", "standing calf raise",
            "dumbbell bench press", "dumbbell bent over row", "dumbbell goblet squat", "dumbbell biceps curl",
            "dumbbell shoulder press", "barbell bench press", "barbell full squat", "barbell romanian deadlift",
            "pull up", "cable lat pulldown", "leg press", "seated leg curl", "machine chest press"]
        let name = normalize(exercise.name)
        let simple = preferred.contains(name) ? 1_000 : 0
        let complex = ["one arm", "one leg", "single leg", "bosu", "explosive", "plyo", "jump", "kipping", "handstand"].filter { name.contains($0) }.count * 100
        return simple - complex - min(name.count, 120) - (uses[exercise.id] ?? 0) * 20
    }

    // MARK: Validation and lossless v2 envelope merge

    static func validate(_ plan: LocalCoachPlan, catalog: [LocalCoachCatalogExercise]) throws {
        guard !plan.sourceID.isEmpty, plan.sourceID.count <= 512,
              !plan.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, plan.title.count <= 120,
              plan.summary.count <= 2_000, plan.createdAt.timeIntervalSince1970.isFinite,
              (0...32_503_680_000).contains(plan.createdAt.timeIntervalSince1970), (1...14).contains(plan.days.count),
              Set(plan.days.map(\.id)).count == plan.days.count,
              Set(plan.days.map(\.dayOffset)).count == plan.days.count else {
            throw LocalCoachDataError.invalidRequest("The plan has an invalid source, title, date, or session count.")
        }
        let known = Dictionary(catalog.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        for day in plan.days {
            guard (0...364).contains(day.dayOffset), (10...180).contains(day.minutes),
                  !day.title.isEmpty, day.title.count <= 120, day.focus.count <= 500,
                  (1...8).contains(day.exercises.count),
                  Set(day.exercises.map(\.id)).count == day.exercises.count,
                  Set(day.exercises.map { $0.catalogID.lowercased() }).count == day.exercises.count else {
                throw LocalCoachDataError.invalidRequest("Each session needs a distinct date, 10...180 minutes and 1...8 different exercises.")
            }
            var seconds = 5 * 60
            for exercise in day.exercises {
                guard UUID(uuidString: exercise.catalogID) != nil,
                      let item = known[exercise.catalogID.lowercased()], item.name == exercise.name,
                      item.equipment == exercise.equipment, isRepetitionExercise(item),
                      (1...8).contains(exercise.sets), (1...30).contains(exercise.reps),
                      (0...300).contains(exercise.restSeconds), exercise.note.count <= 1_000 else {
                    throw LocalCoachDataError.invalidRequest("Use a known repetition-based exercise, 1...8 sets, 1...30 repetitions and 0...300 seconds rest.")
                }
                seconds += estimatedSeconds(sets: exercise.sets, reps: exercise.reps, rest: exercise.restSeconds)
            }
            guard seconds <= day.minutes * 60 else {
                throw LocalCoachDataError.invalidRequest("The planned sets and rest exceed the session time budget. Reduce them or increase minutes.")
            }
        }
    }

    /// Nil means the exact routine payload has already been saved. A changed plan with the same
    /// identity fails instead of overwriting subsequent user edits. Unknown envelope fields survive.
    static func merging(_ plan: LocalCoachPlan, into data: Data, catalog: [LocalCoachCatalogExercise]) throws -> Data? {
        try validate(plan, catalog: catalog)
        var root = try envelope(data)
        if try isPersisted(plan, root: root) { return nil }
        guard root["activeSession"] == nil || root["activeSession"] is NSNull else { throw LocalCoachDataError.activeWorkout }
        var existing = try dictionaries(root, "routines")
        var scheduled = try dictionaries(root, "scheduledWorkouts", optional: true)
        guard existing.count + plan.days.count <= 500, scheduled.count + plan.days.count <= 1_000 else {
            throw LocalCoachDataError.unavailable("ReceiptLift has reached the routine or schedule limit for a coach import.")
        }
        for (index, day) in plan.days.enumerated() {
            let routineID = persistentID(plan.id, slot: index, kind: "routine")
            let scheduleID = persistentID(plan.id, slot: index, kind: "schedule")
            guard !scheduled.contains(where: { ($0["id"] as? String)?.lowercased() == scheduleID }) else {
                throw LocalCoachDataError.conflictingPlan
            }
            existing.append(routine(plan, day: day, index: index))
            guard let date = LocalCoachWindow.calendar.date(byAdding: .day, value: day.dayOffset,
                to: LocalCoachWindow.calendar.startOfDay(for: plan.createdAt)) else {
                throw LocalCoachDataError.invalidRequest("The workout date is invalid.")
            }
            scheduled.append(["id": scheduleID, "routineID": routineID,
                "plannedAt": ISO8601DateFormatter().string(from: date), "note": "Coach plan reviewed before saving."])
        }
        root["routines"] = existing
        root["scheduledWorkouts"] = scheduled
        let merged = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        guard merged.count <= maximumBytes else { throw LocalCoachDataError.unavailable("The updated workout state exceeds the local size limit.") }
        return merged
    }

    static func isPersisted(_ plan: LocalCoachPlan, in data: Data, catalog: [LocalCoachCatalogExercise]) throws -> Bool {
        try validate(plan, catalog: catalog)
        return try isPersisted(plan, root: envelope(data))
    }

    private static func isPersisted(_ plan: LocalCoachPlan, root: [String: Any]) throws -> Bool {
        let rows = try dictionaries(root, "routines")
        let possibleIDs = Set((0..<14).map { persistentID(plan.id, slot: $0, kind: "routine") })
        let matching = rows.filter { ($0["id"] as? String).map { possibleIDs.contains($0.lowercased()) } == true }
        guard !matching.isEmpty else { return false }
        guard matching.count == plan.days.count else { throw LocalCoachDataError.conflictingPlan }
        for (index, day) in plan.days.enumerated() {
            let expected = routine(plan, day: day, index: index)
            let id = persistentID(plan.id, slot: index, kind: "routine")
            guard let actual = matching.first(where: { ($0["id"] as? String)?.lowercased() == id }),
                  canonicalRoutineObject(actual).isEqual(canonicalRoutineObject(expected)) else {
                throw LocalCoachDataError.conflictingPlan
            }
        }
        // A user may have completed or removed a schedule after saving. An idempotent retry must not
        // restore that schedule or duplicate a completed workout.
        return true
    }

    private static func canonicalRoutineObject(_ object: [String: Any]) -> NSDictionary {
        var result = object
        if let id = result["id"] as? String { result["id"] = id.lowercased() }
        if let ids = result["exerciseIDs"] as? [String] { result["exerciseIDs"] = ids.map { $0.lowercased() } }
        if let plans = result["exercisePlans"] as? [[String: Any]] {
            result["exercisePlans"] = plans.map { item -> [String: Any] in
                var value = item
                for key in ["id", "exerciseID"] { if let id = value[key] as? String { value[key] = id.lowercased() } }
                return value
            }
        }
        return result as NSDictionary
    }

    private static func routine(_ plan: LocalCoachPlan, day: LocalCoachPlanDay, index: Int) -> [String: Any] {
        let focus = normalize(day.focus)
        let mode = focus.contains("strength") ? "strength" : focus.contains("endurance") ? "endurance" : "hypertrophy"
        let items: [[String: Any]] = day.exercises.enumerated().map { offset, exercise in
            ["id": persistentID(plan.id, slot: index * 8 + offset, kind: "exercise-plan"),
             "exerciseID": exercise.catalogID.lowercased(), "sets": String(exercise.sets), "reps": String(exercise.reps),
             "rest": "\(exercise.restSeconds)s", "targetEffort": "", "notes": exercise.note]
        }
        return ["id": persistentID(plan.id, slot: index, kind: "routine"), "name": day.title,
            "notes": plan.summary + "\nRequested session: \(day.minutes) minutes. Focus: \(day.focus)",
            "trainingMode": mode, "exerciseIDs": day.exercises.map { $0.catalogID.lowercased() }, "exercisePlans": items]
    }

    private static let maximumBytes = 8 * 1_024 * 1_024
    private static func envelope(_ data: Data) throws -> [String: Any] {
        guard data.count <= maximumBytes,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = root["schemaVersion"] as? Int else {
            throw LocalCoachDataError.unavailable("ReceiptLift state is too large or unreadable. The original data was kept.")
        }
        guard version == 2 else { throw LocalCoachDataError.unsupportedReceiptVersion(version) }
        _ = try dictionaries(root, "userExercises")
        _ = try dictionaries(root, "routines")
        _ = try dictionaries(root, "sessions")
        _ = try dictionaries(root, "scheduledWorkouts", optional: true)
        return root
    }

    private static func dictionaries(_ root: [String: Any], _ key: String, optional: Bool = false) throws -> [[String: Any]] {
        if optional && root[key] == nil { return [] }
        guard let values = root[key] as? [[String: Any]] else {
            throw LocalCoachDataError.unavailable("ReceiptLift's \(key) field cannot be read. The original data was kept.")
        }
        return values
    }

    private static func persistentID(_ id: UUID, slot: Int, kind: String) -> String {
        let bytes = SHA256.hash(data: Data("noop-coach-v1:\(id.uuidString):\(kind):\(slot)".utf8))
        var hex = bytes.prefix(16).map { String(format: "%02x", $0) }.joined()
        hex.insert("-", at: hex.index(hex.startIndex, offsetBy: 20))
        hex.insert("-", at: hex.index(hex.startIndex, offsetBy: 16))
        hex.insert("-", at: hex.index(hex.startIndex, offsetBy: 12))
        hex.insert("-", at: hex.index(hex.startIndex, offsetBy: 8))
        return hex
    }

    private static func estimatedSeconds(sets: Int, reps: Int, rest: Int) -> Int { sets * (reps * 3 + rest) + 45 }
    nonisolated private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0).lowercased() : " " }
            .joined().split(separator: " ").joined(separator: " ")
    }
}
#endif
