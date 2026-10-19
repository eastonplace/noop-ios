import Foundation
import Combine
import UIKit

public struct ReceiptLiftSet: Codable, Equatable, Sendable {
    public let id: String
    public let exercise: String
    public let muscleGroup: String
    public var secondaryMuscles: [String] = []
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
        let data = try await loadData()
        guard !invalidated else { throw CancellationError() }
        guard let data else { return nil }
        let envelope = try await Task.detached(priority: .userInitiated) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let value = try decoder.decode(LiftDataEnvelope.self, from: data)
            guard value.schemaVersion == LiftDataEnvelope.currentSchemaVersion else {
                throw LiftPersistenceError.unsupportedSchema(value.schemaVersion)
            }
            return value
        }.value
        guard !invalidated else { throw CancellationError() }
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
                    let metadata = exercise.flatMap { LiftExerciseCatalog.metadata(for: $0) }
                    return ReceiptLiftSet(id: set.id.uuidString, exercise: exercise?.name ?? "Exercise",
                        muscleGroup: metadata?.target ?? exercise?.muscleGroup ?? "",
                        secondaryMuscles: metadata?.secondaryMuscles ?? [], setIndex: set.setNumber,
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
    private var backgroundSaveTask: Task<Void, Never>?
    private var backgroundLease: UIBackgroundTaskIdentifier = .invalid
    /// UIKit seam so a test can fire the expiration handler and watch the lease end. Production uses `UIApplication`.
    var beginBackgroundTask: (String, @escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier = { name, expiration in
        UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: expiration)
    }
    var endBackgroundTask: (UIBackgroundTaskIdentifier) -> Void = { UIApplication.shared.endBackgroundTask($0) }
    public var hasActiveSession: Bool { store.activeSession != nil }
    public var saveError: String? { store.databaseSaveError }

    /// `weightUnit` is the person's unit setting. The store needs it before `load()`: loading a restored session redraws
    /// its Live Activity, and that is a bare number in this unit, with no view around to say which.
    public init(load: @escaping @Sendable () async throws -> Data?,
                save: @escaping @Sendable (Data, [ReceiptLiftWorkout]) async throws -> Void,
                canStart: @escaping @MainActor () -> Bool = { true },
                weightUnit: LiftWeightUnit = .pounds) {
        let database = ReceiptLiftDatabase(load: load, save: save)
        self.database = database
        store = LiftStore(database: database, canStart: canStart)
        store.setWeightUnit(weightUnit)
        observation = store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    public func load() async { await store.loadAndWait() }

    /// Follows the person's unit setting. The host calls this whenever the setting changes, whether or not Lift is on
    /// screen: a running session's Live Activity is redrawn at once, so it never lags a unit change made elsewhere.
    public func setWeightUnit(_ unit: LiftWeightUnit) { store.setWeightUnit(unit) }

    public func applyReviewedRoutineChange(
        validate: @MainActor () throws -> Void = {},
        transform: @MainActor (Data) throws -> Data?
    ) async throws {
        try await store.applyReviewedRoutineChange(validate: validate, transform: transform)
    }

    public func applicationDidEnterBackground() {
        guard backgroundSaveTask == nil else { return }
        // iOS kills the app if the task is still open when this handler returns, so end it inline rather than
        // hopping to a later actor turn. The save Task keeps running; its own end is then a no-op.
        backgroundLease = beginBackgroundTask("Save Lift workout") { [weak self] in
            self?.endBackgroundLease()
        }
        store.applicationDidEnterBackground()
        backgroundSaveTask = Task { [weak self] in
            guard let self else { return }
            await store.waitForPendingSave()
            endBackgroundLease()
            backgroundSaveTask = nil
        }
    }

    private func endBackgroundLease() {
        guard backgroundLease != .invalid else { return }
        endBackgroundTask(backgroundLease)
        backgroundLease = .invalid
    }

    public func discard() {
        store.cancelDatabasePersistence()
        Task { await database.invalidate() }
    }
}
