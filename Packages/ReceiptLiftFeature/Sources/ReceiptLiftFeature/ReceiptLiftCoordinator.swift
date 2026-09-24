import Foundation
import Combine

public struct ReceiptLiftSet: Codable, Equatable, Sendable {
    public let id: String
    public let exercise: String
    public let muscleGroup: String
    public let setIndex: Int
    public let weightKg: Double
    public let reps: Int
    public let rpe: Double?
    public let isWarmup: Bool
    public let completedAt: Date
    public let note: String?
}

public struct ReceiptLiftWorkout: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let startedAt: Date
    public let endedAt: Date
    public let sets: [ReceiptLiftSet]
}

/// Serializes database writes and only advances the delivery cache after an atomic commit succeeds.
actor ReceiptLiftDatabase {
    typealias Load = @Sendable () async throws -> Data?
    typealias Save = @Sendable (Data, [ReceiptLiftWorkout]) async throws -> Void
    private let loadData: Load
    private let saveData: Save
    private var tail: Task<Void, Error>?
    private var newestGeneration = 0
    private var delivered: [String: ReceiptLiftWorkout] = [:]
    private var invalidated = false

    init(load: @escaping Load, save: @escaping Save) { loadData = load; saveData = save }

    func load() async throws -> LiftDataEnvelope? {
        guard !invalidated else { throw CancellationError() }
        guard let data = try await loadData() else { return nil }
        let envelope = try await Task.detached(priority: .userInitiated) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let value = try decoder.decode(LiftDataEnvelope.self, from: data)
            guard value.schemaVersion == LiftDataEnvelope.currentSchemaVersion else {
                throw LiftPersistenceError.unsupportedSchema(value.schemaVersion)
            }
            return value
        }.value
        delivered = Dictionary(Self.workouts(envelope).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        return envelope
    }

    func save(_ envelope: LiftDataEnvelope, generation: Int) async throws {
        guard !invalidated else { throw CancellationError() }
        guard generation > newestGeneration else { if let tail { try await tail.value }; return }
        newestGeneration = generation
        let previous = tail
        let task = Task { [weak self] in
            // A failed earlier write must not prevent retrying the newest complete state.
            if let previous { _ = try? await previous.value }
            guard let self else { throw CancellationError() }
            try await self.commit(envelope)
        }
        tail = task
        try await task.value
    }

    private func commit(_ envelope: LiftDataEnvelope) async throws {
        guard !invalidated else { throw CancellationError() }
        let previous = delivered
        let payload = try await Task.detached(priority: .userInitiated) {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let workouts = Self.workouts(envelope)
            let changed = workouts.filter { previous[$0.id] != $0 }
            return (try encoder.encode(envelope), workouts, changed)
        }.value
        guard !invalidated else { throw CancellationError() }
        try await saveData(payload.0, payload.2)
        delivered = Dictionary(payload.1.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    func invalidate() { invalidated = true }

    nonisolated private static func workouts(_ envelope: LiftDataEnvelope) -> [ReceiptLiftWorkout] {
        let exercises = Dictionary((envelope.userExercises + LiftExerciseCatalog.catalogExercises()).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return envelope.sessions.compactMap { session in
            guard let end = session.endedAt else { return nil }
            return ReceiptLiftWorkout(id: session.id.uuidString, title: session.title,
                startedAt: session.startedAt, endedAt: end,
                sets: session.sets.map { set in
                    let exercise = exercises[set.exerciseID]
                    return ReceiptLiftSet(id: set.id.uuidString, exercise: exercise?.name ?? "Exercise",
                        muscleGroup: exercise?.muscleGroup ?? "", setIndex: set.setNumber,
                        weightKg: set.weight * 0.45359237, reps: set.reps, rpe: set.rpe,
                        isWarmup: set.isWarmup, completedAt: set.completedAt,
                        note: set.notes.isEmpty ? nil : set.notes)
                })
        }
    }
}

@MainActor
public final class ReceiptLiftCoordinator: ObservableObject {
    let store: LiftStore
    private let database: ReceiptLiftDatabase
    private var observation: AnyCancellable?
    public var hasActiveSession: Bool { store.activeSession != nil }
    public var saveError: String? { store.databaseSaveError }

    public init(load: @escaping @Sendable () async throws -> Data?,
                save: @escaping @Sendable (Data, [ReceiptLiftWorkout]) async throws -> Void,
                canStart: @escaping @MainActor () -> Bool = { true }) {
        let database = ReceiptLiftDatabase(load: load, save: save)
        self.database = database
        store = LiftStore(database: database, canStart: canStart)
        observation = store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    public func load() async { await store.loadAndWait() }

    public func discard() {
        store.cancelDatabasePersistence()
        Task { await database.invalidate() }
    }
}
