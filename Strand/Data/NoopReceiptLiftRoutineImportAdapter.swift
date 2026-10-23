import Foundation
import ReceiptLiftFeature
import StrandImport
import WhoopStore

/// Explicit mapping into ReceiptLift's schema-2 routines. This path creates plans only; completed
/// workouts continue through NoopReceiptLiftPayload and the existing Strength Strain transaction.
enum NoopReceiptLiftRoutineImportAdapter {
    static func parse(_ data: Data) throws -> ReceiptLiftRoutineImportDraft {
        let document = try RoutineSpreadsheetImporter.parse(data: data)
        var hasPlannedLoad = false
        let routines = document.routines.map { routine in
            ReceiptLiftRoutineImportRoutine(name: routine.name, notes: routine.notes, trainingMode: routine.trainingMode,
                exercises: routine.exercises.map { line in
                    var notes = line.notes
                    if let load = line.load {
                        hasPlannedLoad = true
                        let prescription = "Planned load: \(number(load.value)) \(load.unit.rawValue)"
                        notes = notes.isEmpty ? prescription : notes + "\n" + prescription
                    }
                    return ReceiptLiftRoutineImportExercise(name: line.name, muscleGroup: muscle(line.muscleGroup), equipment: line.equipment,
                        sets: line.sets.map(String.init) ?? "", reps: line.reps ?? "",
                        rest: line.restSeconds.map { "\($0) s" } ?? "",
                        targetEffort: line.rpe.map { "\(number($0)) RPE" } ?? "", notes: notes)
                })
        }
        var warnings = document.warnings
        if hasPlannedLoad { warnings.append("Planned loads are saved in exercise notes.") }
        return ReceiptLiftRoutineImportDraft(routines: routines, warnings: warnings)
    }

    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    /// Preserve broad or unfamiliar labels as written. Only exact known tokens receive canonical
    /// spelling, so a sheet saying "shoulders" never invents a front-delt classification.
    private static func muscle(_ raw: String) -> String {
        func key(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
        if let known = LiftMuscle.allCases.first(where: { key($0.rawValue) == key(raw) }) { return known.rawValue }
        return raw
    }
}

enum NoopRoutineImportSourceError: LocalizedError {
    case changed, activeWorkout
    var errorDescription: String? {
        switch self {
        case .changed: return "Your data source changed. Reopen Lift and choose the spreadsheet again."
        case .activeWorkout: return "Finish your active workout before importing routines."
        }
    }
}
