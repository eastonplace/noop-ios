#if DEBUG
import SwiftUI

/// Uses the production views with isolated sample data; never reads or writes NOOP health data.
public struct ReceiptLiftPreviewView: View {
    @StateObject private var store: LiftStore
    private let screen: String
    @State private var ready = false
    public init(screen: String) {
        self.screen = screen
        let previewURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-lift-preview-\(UUID().uuidString).json")
        // Exercise identity, names, metadata, and images come unchanged from Lift Receipt.
        let bench = LiftExerciseCatalog.records.first { $0.id == "0025" }!.liftExercise
        let row = LiftExerciseCatalog.records.first { $0.id == "0180" }!.liftExercise
        let moves = [bench, row]
        let routine = LiftRoutine(id: UUID(), name: "Upper Body", notes: "Press and pull", trainingMode: .hypertrophy,
            exerciseIDs: moves.map(\.id), exercisePlans: moves.map {
                LiftRoutineExercisePlan(id: UUID(), exerciseID: $0.id, sets: "3", reps: "8–12", rest: "90", targetEffort: "8", notes: "Controlled reps")
            })
        let now = Date()
        let sessions = (1...12).map { week in
            let date = Calendar.current.date(byAdding: .day, value: -7 * (13 - week), to: now)!
            let sets = (1...3).map { index in
                LiftSet(id: UUID(), exerciseID: bench.id, setNumber: index,
                    weight: 95 + Double(week) * 5, reps: 8 + week % 3, rpe: 7.5,
                    isWarmup: false, completedAt: date.addingTimeInterval(Double(index) * 120), notes: "Sample training data")
            }
            return LiftSession(id: UUID(), routineID: routine.id, title: routine.name, startedAt: date,
                endedAt: date.addingTimeInterval(1800), sets: sets)
        }
        let envelope = LiftDataEnvelope(schemaVersion: LiftDataEnvelope.currentSchemaVersion,
            starterBankVersion: LiftDataEnvelope.currentStarterBankVersion, userExercises: [],
            routines: [routine], scheduledWorkouts: [], sessions: sessions, activeSession: nil,
            restTimerEndDate: nil, workoutRestOverrideSeconds: nil, completedExerciseIDs: [],
            activeExerciseIDsOverride: nil, activePlanOverrides: [:], activeSupersetGroups: [:], settings: LiftSettings())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(envelope) { try? data.write(to: previewURL, options: .atomic) }
        _store = StateObject(wrappedValue: LiftStore(dataURL: previewURL))
    }
    public var body: some View {
        Group {
            if ready {
                switch screen {
                case "routine":
                    if let routine = store.routines.first {
                        NavigationStack { RoutinePreviewView(routine: routine, onBegin: {}, onCancel: {}) }
                    }
                case "detail":
                    if let exercise = store.activeExercises.first {
                        NavigationStack { ExerciseProgressView(exerciseID: exercise.id, showsInformation: true) }
                    }
                case "workout": LiveWorkoutView(onDismiss: {})
                case "library": NavigationStack { ExerciseLibraryView() }
                case "schedule": NavigationStack { ScheduleView(onStartRoutine: { _ in }) }
                case "progress":
                    if let exercise = store.activeExercises.first { NavigationStack { ExerciseProgressView(exerciseID: exercise.id) } }
                case "receipt":
                    if let session = store.sessions.first { CompletedReceiptView(session: session, onClose: {}) }
                default: LiftRootView()
                }
            } else { ProgressView("Preparing sample workout…") }
        }
        .environmentObject(store)
        .preferredColorScheme(.dark)
        .task {
            guard !ready else { return }
            await store.loadAndWait()
            store.startRoutine(store.routines.first)
            for exercise in store.activeExercises.prefix(2) {
                _ = store.logSet(exercise: exercise, weight: 135, reps: 8, rpe: 7, isWarmup: false)
                _ = store.logSet(exercise: exercise, weight: 135, reps: 8, rpe: 8, isWarmup: false)
            }
            if screen == "receipt" || screen == "progress" {
                _ = store.finishActiveSession()
                store.startRoutine(store.routines.first)
            }
            ready = true
        }
    }
}
#endif
