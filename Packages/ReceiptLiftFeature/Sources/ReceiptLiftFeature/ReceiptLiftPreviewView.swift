#if DEBUG
import SwiftUI

/// Uses the production views with isolated sample data; never reads or writes NOOP health data.
public struct ReceiptLiftPreviewView: View {
    @StateObject private var store: LiftStore
    private let screen: String
    @State private var ready = false
    public init(screen: String) {
        self.screen = screen
        _store = StateObject(wrappedValue: LiftStore(dataURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-lift-preview-\(UUID().uuidString).json")))
    }
    public var body: some View {
        Group {
            if ready {
                switch screen {
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
