import Foundation

/// The host supplies a spreadsheet parser without making the UI package depend on database/import packages.
public typealias ReceiptLiftRoutineImportParser = @Sendable (Data) throws -> ReceiptLiftRoutineImportDraft

public struct ReceiptLiftRoutineImportDraft: Equatable, Sendable {
    public let routines: [ReceiptLiftRoutineImportRoutine]
    public let warnings: [String]
    public init(routines: [ReceiptLiftRoutineImportRoutine], warnings: [String] = []) {
        self.routines = routines; self.warnings = warnings
    }
}

public struct ReceiptLiftRoutineImportRoutine: Equatable, Sendable {
    public let name: String
    public let notes: String
    public let trainingMode: String
    public let exercises: [ReceiptLiftRoutineImportExercise]
    public init(name: String, notes: String = "", trainingMode: String = "hypertrophy", exercises: [ReceiptLiftRoutineImportExercise]) {
        self.name = name; self.notes = notes; self.trainingMode = trainingMode; self.exercises = exercises
    }
}

public struct ReceiptLiftRoutineImportExercise: Equatable, Sendable {
    public let name: String
    public let muscleGroup: String
    public let equipment: String
    public let sets: String
    public let reps: String
    public let rest: String
    public let targetEffort: String
    public let notes: String
    public init(name: String, muscleGroup: String = "", equipment: String = "", sets: String = "", reps: String = "", rest: String = "", targetEffort: String = "", notes: String = "") {
        self.name = name; self.muscleGroup = muscleGroup; self.equipment = equipment
        self.sets = sets; self.reps = reps; self.rest = rest; self.targetEffort = targetEffort; self.notes = notes
    }
}

struct LiftRoutineImportPreview: Identifiable, Sendable {
    let id = UUID()
    let routines: [LiftRoutine]
    let newExercises: [LiftExercise]
    let matchedExercises: [LiftExercise]
    let warnings: [String]
    private let exercisesByID: [UUID: LiftExercise]

    init(routines: [LiftRoutine], newExercises: [LiftExercise], matchedExercises: [LiftExercise], warnings: [String]) {
        self.routines = routines; self.newExercises = newExercises
        self.matchedExercises = matchedExercises; self.warnings = warnings
        exercisesByID = Dictionary((matchedExercises + newExercises).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var exerciseCount: Int { routines.reduce(0) { $0 + $1.exerciseIDs.count } }
    func exercise(_ id: UUID) -> LiftExercise? { exercisesByID[id] }
}

enum LiftRoutineImportError: LocalizedError {
    case unavailable, invalidDraft, needsCustomExerciseConsent, stalePreview, activeWorkout, busy
    case repeatedExercise(String)
    case conflictingExercise(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Routine import is unavailable. Reopen Lift and try again."
        case .invalidDraft: return "This routine draft is invalid. Check the spreadsheet and choose the file again."
        case .needsCustomExerciseConsent: return "Review and allow the new custom exercises before importing."
        case .stalePreview: return "Your routines or exercise library changed during review. Choose the file again to refresh the preview."
        case .activeWorkout: return "Finish your active workout before importing routines."
        case .busy: return "Another workout plan is being saved. Try again when it finishes."
        case .repeatedExercise(let name): return "\(name) appears twice in one routine. Use one row per exercise and put the set count in sets."
        case .conflictingExercise(let name): return "\(name) has different muscle or equipment labels in this file. Use the same labels for the same custom exercise."
        }
    }
}

/// Makes the exact objects shown in the preview. IDs and collision names are fixed before confirmation.
/// Existing exercises win only on exact normalized names; near matches are never guessed.
enum LiftRoutineImportBuilder {
    static func prepare(_ draft: ReceiptLiftRoutineImportDraft, routines: [LiftRoutine], exercises: [LiftExercise]) throws -> LiftRoutineImportPreview {
        guard (1...50).contains(draft.routines.count),
              draft.routines.reduce(0, { $0 + $1.exercises.count }) <= 5_000 else { throw LiftRoutineImportError.invalidDraft }
        var exerciseByName = exercises.reduce(into: [String: LiftExercise]()) { result, exercise in
            let key = LiftExerciseCatalog.normalizedName(exercise.name)
            if result[key] == nil { result[key] = exercise }
        }
        let originalIDs = Set(exercises.map(\.id))
        var usedNames = Set(routines.map { LiftExerciseCatalog.normalizedName($0.name) })
        var created: [LiftExercise] = []
        var matched: [UUID: LiftExercise] = [:]
        var imported: [LiftRoutine] = []
        var warnings = Array(draft.warnings.prefix(49))
        func warn(_ message: String) {
            guard !warnings.contains(message) else { return }
            if warnings.count < 49 { warnings.append(message) }
            else if warnings.count == 49 { warnings.append("Additional exercise metadata differences use the existing library values.") }
        }
        for source in draft.routines {
            let originalName = source.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !LiftExerciseCatalog.normalizedName(originalName).isEmpty, originalName.count <= 120,
                  source.notes.count <= 2_000, (1...200).contains(source.exercises.count),
                  let mode = TrainingMode(rawValue: source.trainingMode) else { throw LiftRoutineImportError.invalidDraft }
            var name = originalName
            var suffix = 1
            while usedNames.contains(LiftExerciseCatalog.normalizedName(name)) {
                name = "\(originalName) (imported\(suffix == 1 ? "" : " \(suffix)"))"
                suffix += 1
            }
            usedNames.insert(LiftExerciseCatalog.normalizedName(name))
            if name != originalName { warn("\(originalName) already exists. The new routine will be named \(name).") }
            var plans: [LiftRoutineExercisePlan] = []
            var usedExerciseIDs = Set<UUID>()
            for line in source.exercises {
                let name = line.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = LiftExerciseCatalog.normalizedName(name)
                guard !key.isEmpty, name.count <= 120, line.muscleGroup.count <= 80, line.equipment.count <= 80,
                      [line.sets, line.reps, line.rest, line.targetEffort].allSatisfy({ $0.count <= 80 }),
                      line.notes.count <= 2_200 else { throw LiftRoutineImportError.invalidDraft }
                let exercise: LiftExercise
                if let existing = exerciseByName[key] {
                    exercise = existing
                    if originalIDs.contains(existing.id) {
                        matched[existing.id] = existing
                        if (!line.muscleGroup.isEmpty && LiftExerciseCatalog.normalizedName(line.muscleGroup) != LiftExerciseCatalog.normalizedName(existing.muscleGroup))
                            || (!line.equipment.isEmpty && LiftExerciseCatalog.normalizedName(line.equipment) != LiftExerciseCatalog.normalizedName(existing.equipment)) {
                            warn("\(existing.name) will keep its existing muscle and equipment labels.")
                        }
                    } else if existing.muscleGroup != line.muscleGroup || existing.equipment != line.equipment {
                        throw LiftRoutineImportError.conflictingExercise(name)
                    }
                } else {
                    exercise = LiftExercise(id: UUID(), name: name, muscleGroup: line.muscleGroup, equipment: line.equipment, instructions: "")
                    created.append(exercise)
                    exerciseByName[key] = exercise
                }
                guard usedExerciseIDs.insert(exercise.id).inserted else { throw LiftRoutineImportError.repeatedExercise(name) }
                plans.append(LiftRoutineExercisePlan(id: UUID(), exerciseID: exercise.id, sets: line.sets, reps: line.reps,
                    rest: line.rest, targetEffort: line.targetEffort, notes: line.notes))
            }
            imported.append(LiftRoutine(id: UUID(), name: name, notes: source.notes, trainingMode: mode,
                exerciseIDs: plans.map(\.exerciseID), exercisePlans: plans))
        }
        return LiftRoutineImportPreview(routines: imported, newExercises: created,
            matchedExercises: matched.values.sorted { $0.id.uuidString < $1.id.uuidString }, warnings: warnings)
    }

    static func validate(_ preview: LiftRoutineImportPreview, routines: [LiftRoutine], exercises: [LiftExercise]) throws {
        let routineIDs = Set(routines.map(\.id))
        let names = Set(routines.map { LiftExerciseCatalog.normalizedName($0.name) })
        let exerciseIDs = Set(exercises.map(\.id))
        let exerciseNames = Set(exercises.map { LiftExerciseCatalog.normalizedName($0.name) })
        guard preview.routines.allSatisfy({ !routineIDs.contains($0.id) && !names.contains(LiftExerciseCatalog.normalizedName($0.name)) }),
              preview.newExercises.allSatisfy({ !exerciseIDs.contains($0.id) && !exerciseNames.contains(LiftExerciseCatalog.normalizedName($0.name)) }),
              preview.matchedExercises.allSatisfy({ exercises.contains($0) }) else { throw LiftRoutineImportError.stalePreview }
    }
}

/// Reads inside the selected security scope, with a running byte limit before allocating the whole file.
enum LiftRoutineImportFile {
    static let maxBytes = 8 * 1_024 * 1_024
    static func read(_ url: URL) throws -> Data {
        guard ["csv", "xlsx"].contains(url.pathExtension.lowercased()) else {
            throw LiftRoutineImportError.invalidDraft
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let properties = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard properties.isRegularFile == true, (properties.fileSize ?? 0) <= maxBytes else {
            throw LiftRoutineImportFileError.tooLarge
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let part = try handle.read(upToCount: min(64 * 1_024, maxBytes - data.count + 1)), !part.isEmpty {
            try Task.checkCancellation()
            guard part.count <= maxBytes - data.count else { throw LiftRoutineImportFileError.tooLarge }
            data.append(part)
        }
        return data
    }
}

private enum LiftRoutineImportFileError: LocalizedError {
    case tooLarge
    var errorDescription: String? { "Choose a CSV or Excel file smaller than 8 MB." }
}
