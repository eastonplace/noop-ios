import Foundation
import GRDB
import StrandAnalytics
import WhoopProtocol
import WhoopStore
@testable import ReceiptLiftFeature
@testable import NOOP

/// Shared fixtures for the Strength Strain tests: a Lift envelope built from the starter bank, the rows the app
/// writes for it, and bit-exact readers for the two columns the feature may write.
enum StrengthStrainFixtures {
    static let owner = "my-whoop"
    static let canonical = "my-whoop-noop"
    static let sport = "Strength Training"

    struct Lift {
        var id = UUID()
        var start: Date
        var exercise = "Machine Chest Press"
        var kg = 60.0
        var sets = 5
        var warmups = 0
    }

    /// A stored `(strain, strainVersion)` compared by bit pattern, so a one-ulp drift fails.
    struct Bits: Equatable, CustomStringConvertible {
        let bits: UInt64?
        let version: Int?
        init(_ strain: Double?, _ version: Int?) { bits = strain?.bitPattern; self.version = version }
        var value: Double? { bits.map { Double(bitPattern: $0) } }
        var description: String { "(\(value.map { "\($0)" } ?? "nil"), \(version.map(String.init) ?? "nil"))" }
    }

    /// Noon on the civil day `daysAgo` before `reference`, away from the 04:00 day rollover.
    static func noon(daysAgo: Int, hour: Int = 12, reference: Date = Date()) -> Date {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: reference)) ?? reference
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
    }

    static func exercise(named name: String) -> LiftExercise {
        guard let found = LiftRoutineBank.make().exercises.first(where: { $0.name == name }) else {
            preconditionFailure("starter exercise \(name) is missing")
        }
        return found
    }

    /// A schema-2 envelope holding the lifts as finished sessions, encoded exactly as the app stores it.
    static func stateData(_ lifts: [Lift]) throws -> Data {
        let bank = LiftRoutineBank.make().exercises
        let sessions = lifts.map { lift -> LiftSession in
            let match = bank.first(where: { $0.name == lift.exercise }) ?? bank[0]
            var sets: [LiftSet] = []
            for index in 0..<lift.warmups {
                sets.append(LiftSet(
                    id: UUID(), exerciseID: match.id, setNumber: index + 1, weight: 20 / 0.45359237, reps: 8,
                    rpe: 5, isWarmup: true, completedAt: lift.start.addingTimeInterval(Double(index) * 60), notes: ""))
            }
            for index in 0..<lift.sets {
                sets.append(LiftSet(
                    id: UUID(), exerciseID: match.id, setNumber: index + 1, weight: lift.kg / 0.45359237, reps: 8,
                    rpe: 8, isWarmup: false,
                    completedAt: lift.start.addingTimeInterval(Double(lift.warmups + index) * 120), notes: ""))
            }
            return LiftSession(id: lift.id, routineID: nil, title: "Lift", startedAt: lift.start,
                               endedAt: lift.start.addingTimeInterval(3_000), sets: sets)
        }
        let envelope = LiftDataEnvelope(
            schemaVersion: LiftDataEnvelope.currentSchemaVersion,
            starterBankVersion: LiftDataEnvelope.currentStarterBankVersion, userExercises: bank,
            routines: [], scheduledWorkouts: [], sessions: sessions, activeSession: nil, restTimerEndDate: nil,
            workoutRestOverrideSeconds: nil, completedExerciseIDs: [], activeExerciseIDsOverride: nil,
            activePlanOverrides: [:], activeSupersetGroups: [:], settings: LiftSettings())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(envelope)
    }

    static func workouts(_ lifts: [Lift]) throws -> [ReceiptLiftWorkout] {
        try ReceiptLiftHistory.completedWorkouts(fromStateData: stateData(lifts))
    }

    static func dailyMetric(_ day: String, strain: Double?, version: Int? = 2, restingHr: Int = 52) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: 420, efficiency: 0.9, deepMin: 80, remMin: 90, lightMin: 250,
                    disturbances: 3, restingHr: restingHr, avgHrv: 61, recovery: 70, strain: strain, exerciseCount: 1,
                    steps: 9_000, activeKcalEst: 400, strainVersion: version)
    }

    static func register(_ store: WhoopStore, ids: [String]) throws {
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        for id in ids {
            try registry.add(PairedDevice(id: id, brand: "WHOOP", model: "WHOOP", sourceKind: .liveBLE,
                                          capabilities: [.hr], status: .paired, addedAt: 1, lastSeenAt: 1))
        }
    }

    /// Writes the Lift state and the workout rows the app writes for finished lifts, then gives every workout a
    /// heart-rate Strain (`workoutStrain`, version 2) and every lift day a day row (`dayStrain`, version 2) on the
    /// canonical computed id, the way the engine leaves them before Strength Strain runs. No `liftStrain` rows.
    @discardableResult
    static func seed(_ store: WhoopStore, owner: String = owner, lifts: [Lift],
                     workoutStrain: Double? = 30, dayStrain: Double? = 40) async throws -> [ReceiptLiftWorkout] {
        let data = try stateData(lifts)
        let workouts = try ReceiptLiftHistory.completedWorkouts(fromStateData: data)
        let payload = NoopReceiptLiftPayload.make(owner: owner, workouts: workouts)
        let scope = try await store.receiptLiftSourceOwner(deviceId: owner)
        try await store.saveReceiptLiftStateAndWorkout(
            sourceOwner: scope, data: data, sessions: payload.sessions, sets: payload.sets, workouts: payload.workouts)
        try await setWorkoutStrain(store, owner: owner, starts: payload.workouts.map(\.startTs), strain: workoutStrain)
        if let dayStrain {
            let days = Array(Set(workouts.map { Repository.logicalDayKey($0.startedAt) })).sorted()
            try await store.upsertDailyMetrics(days.map { dailyMetric($0, strain: dayStrain) }, deviceId: canonical)
        }
        return workouts
    }

    static func setWorkoutStrain(_ store: WhoopStore, owner: String = owner, starts: [Int],
                                 strain: Double?) async throws {
        try await store.registryWriter.write { db in
            for start in starts {
                let arguments: [(any DatabaseValueConvertible)?] = [strain, strain == nil ? nil : 2, owner, start, sport]
                try db.execute(sql: """
                    UPDATE workout SET strain = ?, strainVersion = ? WHERE deviceId = ? AND startTs = ? AND sport = ?
                    """, arguments: StatementArguments(arguments))
            }
        }
    }

    static func workoutBits(_ store: WhoopStore, owner: String = owner, start: Int) async throws -> Bits? {
        let row = try await store.registryWriter.read { db in
            try Row.fetchOne(db, sql: """
                SELECT strain, strainVersion FROM workout WHERE deviceId = ? AND startTs = ? AND sport = ?
                """, arguments: [owner, start, sport])
        }
        return row.map { Bits($0["strain"], $0["strainVersion"]) }
    }

    static func dayBits(_ store: WhoopStore, day: String, device: String = canonical) async throws -> Bits? {
        let row = try await store.registryWriter.read { db in
            try Row.fetchOne(db, sql: "SELECT strain, strainVersion FROM dailyMetric WHERE deviceId = ? AND day = ?",
                             arguments: [device, day])
        }
        return row.map { Bits($0["strain"], $0["strainVersion"]) }
    }

    /// Every workout and day row with its Strain columns, for whole-store comparisons.
    static func strainDump(_ store: WhoopStore) async throws -> [String] {
        try await store.registryWriter.read { db in
            let workouts = try Row.fetchAll(db, sql: """
                SELECT deviceId, startTs, sport, strain, strainVersion FROM workout ORDER BY deviceId, startTs, sport
                """).map { "w \($0["deviceId"] as String) \($0["startTs"] as Int) \(Bits($0["strain"], $0["strainVersion"]))" }
            let days = try Row.fetchAll(db, sql: """
                SELECT deviceId, day, strain, strainVersion FROM dailyMetric ORDER BY deviceId, day
                """).map { "d \($0["deviceId"] as String) \($0["day"] as String) \(Bits($0["strain"], $0["strainVersion"]))" }
            return workouts + days
        }
    }

    static func liftRow(_ store: WhoopStore, id: UUID, owner: String = owner) async throws -> LiftStrainRow? {
        try await store.liftStrainRows(deviceId: owner, liftSessionIds: [id.uuidString]).first
    }

    static func jobKey(owner: String = owner) -> String {
        "strength-strain-backfill-v\(StrengthStrain.version):\(owner)"
    }

    /// Polls `condition` for up to `seconds`, yielding to the run loop between reads.
    @MainActor
    static func eventually(seconds: Double = 15, _ condition: () async throws -> Bool) async rethrows -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if try await condition() { return true }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        return try await condition()
    }

    @MainActor
    static func makeEngine(store: WhoopStore, primary: Bool = true) -> (engine: IntelligenceEngine, repo: Repository) {
        let repo = Repository(deviceId: Repository.whoopSource)
        repo.setStoreForTesting(store)
        let engine = IntelligenceEngine(
            repo: repo, profile: ProfileStore(), deviceId: Repository.whoopSource, isPrimary: primary)
        return (engine, repo)
    }
}
