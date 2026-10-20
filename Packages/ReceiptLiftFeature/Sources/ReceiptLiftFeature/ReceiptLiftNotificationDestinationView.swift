import SwiftUI

/// Resolves a saved schedule identity without a start action or mutation of the linked routine.
public struct ReceiptLiftNotificationDestinationView: View {
    @ObservedObject private var coordinator: ReceiptLiftCoordinator
    private let plannedWorkoutID: String

    public init(coordinator: ReceiptLiftCoordinator, plannedWorkoutID: String) {
        self.coordinator = coordinator
        self.plannedWorkoutID = plannedWorkoutID
    }

    public var body: some View {
        Group {
            if !coordinator.store.isLoaded {
                if let error = coordinator.saveError {
                    ContentUnavailableView("Plan unavailable", systemImage: "calendar", description: Text(error))
                } else { ProgressView("Opening your plan…") }
            } else if let id = UUID(uuidString: plannedWorkoutID),
                      let planned = coordinator.store.scheduledWorkouts.first(where: { $0.id == id }),
                      let routine = coordinator.store.routines.first(where: { $0.id == planned.routineID }) {
                List {
                    Section {
                        Text(routine.name).font(.headline)
                        LabeledContent("Scheduled", value: planned.plannedAt.formatted(date: .abbreviated, time: .shortened))
                        if planned.completedSessionID != nil { Text("This planned workout has already been completed.") }
                        if !planned.note.isEmpty { Text(planned.note) }
                    }
                    Section("Exercises") {
                        ForEach(RoutinePreviewRow.rows(for: routine, exercises: coordinator.store.exercises)) { row in
                            VStack(alignment: .leading) {
                                Text(row.title).font(.headline)
                                Text(row.prescription)
                                Text(row.detail).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView("Plan no longer available", systemImage: "calendar", description: Text("This workout or its routine was removed. Your other plans are unchanged."))
            }
        }
        .navigationTitle("Scheduled workout")
        .task { await coordinator.load() }
    }
}
