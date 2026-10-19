import Foundation
import ReceiptLiftFeature
import StrandAnalytics
import WhoopProtocol
import WhoopStore

// MARK: - Strength Strain: app wiring (L2.2)
//
// The pure formula lives in StrandAnalytics (`StrengthStrain`), the storage and the apply in WhoopStore
// (`LiftStrainStore`). This file maps the app's lift data onto the formula, plans the one-time backfill, follows a
// save with a settle, and hands Lift's screens the numbers the app stored. Every type here is a plain nonisolated
// enum or struct (BF-R2-1) except where `@MainActor` is written.

extension Notification.Name {
    /// Stored Strain changed because a lift was scored, settled, rescored or backfilled.
    static let liftStrainDidChange = Notification.Name("noop.liftStrainDidChange")
}

enum StrengthStrainIntegration {
    /// The sport every Lift session's workout row is saved under (`NoopReceiptLiftPayload.make`).
    static let sport = "Strength Training"

    /// The combine the store applies: heart-rate Strain (stored 0...100) plus a muscular load.
    static let combine: LiftStrainCombine = { StrengthStrain.combine(hrStored: $0, muscularLoad: $1) }

    // MARK: Set mapping (one mapping for the completed-workout path, the live card and the backfill)

    /// A completed or in-progress set from the Lift package, as the formula reads it.
    static func input(for set: ReceiptLiftSet) -> StrengthStrain.SetInput {
        StrengthStrain.SetInput(
            exerciseName: set.exercise, equipment: set.equipment,
            primaryMuscle: set.muscleGroup.isEmpty ? nil : set.muscleGroup,
            secondaryMuscles: set.secondaryMuscles, reps: set.reps, weightKg: set.weightKg,
            rpe: set.rpe, isWarmup: set.isWarmup)
    }

    static func inputs(for workout: ReceiptLiftWorkout) -> [StrengthStrain.SetInput] {
        workout.sets.map(input(for:))
    }

    static func inputs(for sets: [ReceiptLiftSet]) -> [StrengthStrain.SetInput] {
        sets.map(input(for:))
    }

    /// Demo and store rows: no equipment label is stored on a `LiftSetRow`.
    static func inputs(for sets: [LiftSetRow]) -> [StrengthStrain.SetInput] {
        sets.map {
            StrengthStrain.SetInput(
                exerciseName: $0.exercise, equipment: nil, primaryMuscle: $0.primaryMuscle?.rawValue,
                secondaryMuscles: $0.secondaryMuscles.map(\.rawValue), reps: $0.reps ?? 0,
                weightKg: $0.weightKg, rpe: $0.rpe, isWarmup: $0.isWarmup)
        }
    }

    // MARK: Body weight

    /// The body weight a lift is scored with. A weight frozen with the lift is reused so a later profile change
    /// never rewrites an old score, except a frozen *default*: once the person has set a weight, that lift is scored
    /// with it (and stops saying it used the default). No frozen weight and no profile weight is 75 kg, flagged.
    static func bodyweight(frozen: LiftStrainFrozenBodyweight?, profileKg: Double?) -> LiftStrainFrozenBodyweight {
        let profile: Double? = {
            guard let profileKg, profileKg.isFinite, profileKg > 0 else { return nil }
            return StrengthStrain.bodyweight(profileKg)
        }()
        if let frozen, !(frozen.isDefault && profile != nil) { return frozen }
        if let profile { return LiftStrainFrozenBodyweight(kg: profile, isDefault: false) }
        return LiftStrainFrozenBodyweight(kg: StrengthStrain.defaultBodyweightKg, isDefault: true)
    }

    // MARK: Computed rows

    static func computed(for workout: ReceiptLiftWorkout, frozen: LiftStrainFrozenBodyweight?,
                         profileKg: Double?) -> LiftStrainComputed {
        build(sessionId: workout.id, startTs: Int(workout.startedAt.timeIntervalSince1970),
              dayKey: Repository.logicalDayKey(workout.startedAt), inputs: inputs(for: workout),
              bodyweight: bodyweight(frozen: frozen, profileKg: profileKg))
    }

    /// Demo and test rows built from stored sets.
    static func computed(sessionId: String, startTs: Int, sets: [LiftSetRow], bodyweightKg: Double) -> LiftStrainComputed {
        build(sessionId: sessionId, startTs: startTs,
              dayKey: Repository.logicalDayKey(Date(timeIntervalSince1970: TimeInterval(startTs))),
              inputs: inputs(for: sets),
              bodyweight: LiftStrainFrozenBodyweight(kg: bodyweightKg, isDefault: false))
    }

    private static func build(sessionId: String, startTs: Int, dayKey: String, inputs: [StrengthStrain.SetInput],
                              bodyweight: LiftStrainFrozenBodyweight) -> LiftStrainComputed {
        let result = StrengthStrain.evaluate(sets: inputs, bodyweightKg: bodyweight.kg)
        return LiftStrainComputed(
            liftSessionId: sessionId, workoutStartTs: startTs, workoutSport: sport, dayKey: dayKey,
            formulaVersion: result.formulaVersion, bodyweightKg: result.bodyweightKg,
            bodyweightIsDefault: bodyweight.isDefault, dose: result.dose, volume: result.volume,
            muscularLoad: result.muscularLoad, workingSets: result.workingSets, warmupSets: result.warmupSets,
            countedSets: result.countedSets, skippedJSON: skippedJSON(result.skipped),
            unmappedSets: result.unmappedSets)
    }

    /// `{"warmup":3,"noWeight":1}` with sorted keys, so the same skips always give the same bytes.
    static func skippedJSON(_ skipped: [StrengthStrain.SkipReason: Int]) -> String {
        let counts = Dictionary(uniqueKeysWithValues: skipped.map { ($0.key.rawValue, $0.value) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(counts), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    // MARK: Day combine (A7): one function for the stored value and the shown value

    /// The most a day's parts may differ from the heart-rate-only score they are combined for (display scale) and
    /// still be that score. Equal to the day detail's agreement tolerance.
    static let dayPartsTolerance = 0.05

    /// A day's heart-rate-only stored score with the day's muscular load added. With the day's parts it is
    /// `max(step floor, energy floor, combine(cardio, M))`; without parts, or with parts that are not this score
    /// (they differ by more than ``dayPartsTolerance``), the whole score is treated as heart-rate load
    /// (`StrengthStrain.combine`), the documented stored-score inversion. The stored settle, the live day Strain and
    /// the day detail all call this, so the three agree. The parts are anchored to `hrStored`, so a day whose parts
    /// were rebuilt from the readings (equal to the stored score within a rounding) still combines from the stored bits.
    static func dayCombine(hrStored h: Double, muscularLoad m: Double,
                           components: StrainScorerV2.DayStrainComponents?) -> Double {
        if let components, let score = components.score, h.isFinite,
           abs(StrainScorerV2.displayValue(fromStored: score) - StrainScorerV2.displayValue(fromStored: h))
               <= dayPartsTolerance {
            let anchored = StrainScorerV2.DayStrainComponents(
                cardio: components.cardio, steps: components.steps, energy: components.energy,
                score: h, dominant: components.dominant)
            if let combined = StrengthStrain.combineDay(components: anchored, muscularLoad: m) { return combined }
        }
        return StrengthStrain.combine(hrStored: h, muscularLoad: m)
    }

    /// The stored-score inversion for a day whose parts are not known, with the day's per-lift loads.
    static func settledDay(hrStored: Double, loads: [Double]) -> Double {
        StrengthStrain.combine(hrStored: hrStored, muscularLoad: StrengthStrain.dayMuscularLoad(loads))
    }
}

/// Holds the parts of the days a settle will combine, and hands the store a synchronous day combine over them
/// (the store calls it inside its write transaction, so it cannot read anything itself). A day whose parts were
/// never looked for is recorded as missed, so the caller can load it and settle that day again.
final class StrengthStrainDayCombiner: @unchecked Sendable {
    private let lock = NSLock()
    private var parts: [String: StrainScorerV2.DayStrainComponents] = [:]
    private var attempted: Set<String> = []
    private var missed: Set<String> = []

    /// Looks up each day not yet attempted with `parts` (nil is a final answer: the day has no usable parts).
    @MainActor
    func load(_ days: [String], using parts: (String) async -> StrainScorerV2.DayStrainComponents?) async {
        for day in Set(days).sorted() {
            let known = locked { attempted.contains(day) }
            if known { continue }
            let found = await parts(day)
            locked {
                attempted.insert(day)
                missed.remove(day)
                self.parts[day] = found
            }
        }
    }

    /// Days the store asked about that were never loaded.
    var missedDays: [String] { locked { missed.sorted() } }

    var dayCombine: LiftStrainDayCombine {
        { [self] day, hrStored, muscularLoad in
            let components: StrainScorerV2.DayStrainComponents? = locked {
                if !attempted.contains(day) { missed.insert(day) }
                return parts[day]
            }
            return StrengthStrainIntegration.dayCombine(
                hrStored: hrStored, muscularLoad: muscularLoad, components: components)
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

extension LiftStrainApplyResult {
    /// The sum of two applies (a settle and the follow-up settle of the days it missed).
    mutating func add(_ other: LiftStrainApplyResult) {
        rowsVisited += other.rowsVisited
        workoutWrites += other.workoutWrites
        dayWrites += other.dayWrites
        applied += other.applied
        notScored += other.notScored
        detached += other.detached
        conflicts += other.conflicts
    }
}

// MARK: - One-time backfill planning

enum StrengthStrainBackfill {
    static let maxDaysPerChunk = 7
    static let maxLiftsPerChunk = 30

    /// Sorts by start, groups by logical day, keeps days after `cursorDay`, and cuts a chunk at 7 days or 30 lifts,
    /// whichever comes first. A day is never split, so a day with more than 30 lifts is a chunk of its own.
    static func chunks(workouts: [ReceiptLiftWorkout], cursorDay: String?,
                       dayKey: (Date) -> String) -> [[ReceiptLiftWorkout]] {
        let sorted = workouts.sorted {
            ($0.startedAt, $0.id) < ($1.startedAt, $1.id)
        }
        var days: [(day: String, lifts: [ReceiptLiftWorkout])] = []
        for workout in sorted {
            let day = dayKey(workout.startedAt)
            if let cursorDay, day <= cursorDay { continue }
            if let last = days.last, last.day == day {
                days[days.count - 1].lifts.append(workout)
            } else {
                days.append((day, [workout]))
            }
        }
        var chunks: [[ReceiptLiftWorkout]] = []
        var current: [ReceiptLiftWorkout] = []
        var currentDays = 0
        for entry in days {
            if currentDays > 0,
               currentDays + 1 > maxDaysPerChunk || current.count + entry.lifts.count > maxLiftsPerChunk {
                chunks.append(current)
                current = []
                currentDays = 0
            }
            current += entry.lifts
            currentDays += 1
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Decodes the stored Lift envelope, plans the chunks and computes their rows. Pure and nonisolated: it takes
    /// only values and returns values, so it can run off the main actor. Throws on a decode failure.
    static func plan(stateData: Data, cursorDay: String?, frozen: [String: LiftStrainFrozenBodyweight],
                     profileKg: Double?) throws -> [LiftStrainChunkInput] {
        let workouts = try ReceiptLiftHistory.completedWorkouts(fromStateData: stateData)
        let planned = chunks(workouts: workouts, cursorDay: cursorDay) { Repository.logicalDayKey($0) }
        return planned.map { chunk in
            let rows = chunk.map {
                StrengthStrainIntegration.computed(for: $0, frozen: frozen[$0.id], profileKg: profileKg)
            }
            let dayKeys = Array(Set(rows.map(\.dayKey))).sorted()
            return LiftStrainChunkInput(rows: rows, dayKeys: dayKeys, lastDay: dayKeys.last ?? cursorDay ?? "")
        }
    }
}

// MARK: - Save follow-up

enum LiftStrainSaveFollowUp {
    /// After a lift is saved: analyze (the coordinator pass can return false when the app is backgrounded or HR is
    /// not offloaded yet, which is not an error here), then settle always, then refresh. Settle moves a pending
    /// lift to applied, or to the provisional notScored state when no heart-rate Strain exists yet.
    @MainActor
    static func run(analyze: @MainActor () async -> Bool,
                    settle: @MainActor () async -> Void,
                    refresh: @MainActor () async -> Void) async {
        _ = await analyze()
        await settle()
        await refresh()
    }
}

// MARK: - Snapshot mapping (stored values only)

enum LiftStrainSnapshotMapper {
    /// What a finished session's Strain shows. `workoutStored` is the workout's resolved canonical stored Strain
    /// (0...100), nil when the workout has none.
    static func snapshot(row: LiftStrainRow?, workoutStored: Double?) -> LiftStrainSnapshot? {
        guard let row else { return nil }
        func make(_ state: LiftStrainSummaryState, hr: Double?, combined: Double?) -> LiftStrainSnapshot {
            LiftStrainSnapshot(
                state: state, heartRateDisplay: hr, combinedDisplay: combined, workingSets: row.workingSets,
                warmupSets: row.warmupSets, countedSets: row.countedSets,
                bodyweightIsDefault: row.bodyweightIsDefault)
        }
        func display(_ stored: Double?) -> Double? { stored.map { StrainScorerV2.displayValue(fromStored: $0) } }

        switch row.state {
        case .pending:
            return make(.pending, hr: nil, combined: nil)
        case .notScored:
            return make(.notScored, hr: nil, combined: nil)
        case .detached where workoutStored == nil:
            return make(.notScored, hr: nil, combined: nil)
        case .applied, .detached:
            break
        }
        if row.countedSets == 0 {
            let value = display(workoutStored)
            return make(.noSets, hr: value, combined: value)
        }
        if row.state == .applied, let combined = row.combinedStrain, let workoutStored,
           combined.bitPattern == workoutStored.bitPattern {
            return make(.scored, hr: display(row.hrOnlyStrain), combined: display(combined))
        }
        // Applied but the workout row no longer holds the combined value: the next settle heals it.
        return make(.pending, hr: nil, combined: nil)
    }
}

extension Repository {
    /// Every owner's applied lifts on a logical day (the day's muscular load input). Empty on any error.
    func liftStrainAppliedLoads(dayKey: String) async -> [LiftStrainAppliedLoad] {
        guard let store = await storeHandle() else { return [] }
        return (try? await store.liftStrainAppliedLoads(dayKey: dayKey)) ?? []
    }

    /// The Strength Strain summary of the lift whose workout starts at `startTs`, from stored values only.
    func liftStrainSummary(startTs: Int, sport: String) async -> LiftStrainSnapshot? {
        guard let store = await storeHandle() else { return nil }
        return await LiftStrainStoredReader.summary(store: store, startTs: startTs, sport: sport,
                                                    preferredDeviceId: deviceId)
    }
}

enum LiftStrainStoredReader {
    static func summary(store: WhoopStore, startTs: Int, sport: String, preferredDeviceId: String) async -> LiftStrainSnapshot? {
        guard let row = try? await store.liftStrainRow(
            workoutStartTs: startTs, sport: sport, preferredDeviceId: preferredDeviceId) else { return nil }
        return LiftStrainSnapshotMapper.snapshot(row: row, workoutStored: await workoutStored(store: store, row: row))
    }

    static func summary(store: WhoopStore, deviceId: String, sessionId: String) async -> LiftStrainSnapshot? {
        guard let row = (try? await store.liftStrainRows(deviceId: deviceId, liftSessionIds: [sessionId]))?.first
        else { return nil }
        return LiftStrainSnapshotMapper.snapshot(row: row, workoutStored: await workoutStored(store: store, row: row))
    }

    /// The workout's canonical stored Strain (D4: always from the stored value).
    static func workoutStored(store: WhoopStore, row: LiftStrainRow) async -> Double? {
        let workouts = (try? await store.workouts(
            deviceId: row.deviceId, from: row.workoutStartTs, to: row.workoutStartTs, limit: 16)) ?? []
        guard let workout = workouts.first(where: { $0.sport == row.workoutSport }) else { return nil }
        return StrainResolver.canonicalWorkout(workout)?.storedValue
    }
}

// MARK: - Provider handed to Lift

struct AppLiftStrainProvider: LiftStrainProviding {
    let store: WhoopStore
    /// The lift owner, re-read on every call so a re-pair is followed.
    let deviceId: @Sendable @MainActor () -> String
    let bpm: @Sendable @MainActor () -> Int?
    let startHR: @Sendable @MainActor () -> Void
    let stopHR: @Sendable @MainActor () -> Void
    let maxHR: @Sendable @MainActor () -> Double
    let restingHR: @Sendable @MainActor () -> Double
    let hrSamples: @Sendable (Int, Int) async -> [HRSample]

    func summary(sessionID: String) async -> LiftStrainSnapshot? {
        await LiftStrainStoredReader.summary(store: store, deviceId: await deviceId(), sessionId: sessionID)
    }

    func updates() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task {
                for await _ in NotificationCenter.default.notifications(named: .liftStrainDidChange) {
                    continuation.yield()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func recentStrains(sessionIDs: [String]) async -> [String: Double] {
        guard !sessionIDs.isEmpty else { return [:] }
        let owner = await deviceId()
        let rows = (try? await store.liftStrainRows(deviceId: owner, liftSessionIds: sessionIDs)) ?? []
        var out: [String: Double] = [:]
        for row in rows {
            if let stored = await LiftStrainStoredReader.workoutStored(store: store, row: row) {
                out[row.liftSessionId] = StrainScorerV2.displayValue(fromStored: stored)
            }
        }
        return out
    }

    func liveVitals(start: Date, sets: [ReceiptLiftSet]) async -> LiftLiveVitals? {
        let now = Int(Date().timeIntervalSince1970)
        let from = Int(start.timeIntervalSince1970)
        let currentBpm = await bpm()
        let maxHR = await maxHR()
        let restingHR = await restingHR()
        let samples = await hrSamples(from, now).filter { $0.ts >= from && $0.ts <= now }
        guard let hrStored = StrainScorerV2.strain(samples, maxHR: maxHR, restingHR: restingHR, mode: .activity) else {
            return LiftLiveVitals(bpm: currentBpm, heartRateDisplay: nil, combinedDisplay: nil)
        }
        // The same set mapping and the same body-weight rule as a saved lift, so the card and the stored score agree.
        let weight = StrengthStrainIntegration.bodyweight(frozen: nil, profileKg: ProfileStore.storedWeightKg())
        let load = StrengthStrain.evaluate(
            sets: StrengthStrainIntegration.inputs(for: sets), bodyweightKg: weight.kg).muscularLoad
        let split = StrengthStrain.split(hrStored: hrStored, muscularLoad: load)
        return LiftLiveVitals(bpm: currentBpm, heartRateDisplay: split.heartRateDisplay,
                              combinedDisplay: split.combinedDisplay)
    }

    func beginLiveHeartRate() async { await startHR() }
    func endLiveHeartRate() async { await stopHR() }
}

#if DEBUG
/// Simulator QA: `--noop-lift-strain-demo <scored|pending|not-scored|no-sets|unavailable>` and
/// `--noop-lift-vitals none`. The numbers are mockup values, not formula output.
struct DemoLiftStrainProvider: LiftStrainProviding {
    enum Scenario: String, Sendable {
        case scored, pending, notScored = "not-scored", noSets = "no-sets", unavailable
    }

    let scenario: Scenario
    let vitalsOff: Bool

    /// The scenario named on the command line, if any.
    static func requested(arguments: [String] = CommandLine.arguments) -> DemoLiftStrainProvider? {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        let scenario = value("--noop-lift-strain-demo").flatMap(Scenario.init(rawValue:))
        let vitalsOff = value("--noop-lift-vitals") == "none"
        guard scenario != nil || vitalsOff else { return nil }
        return DemoLiftStrainProvider(scenario: scenario ?? .unavailable, vitalsOff: vitalsOff)
    }

    func summary(sessionID: String) async -> LiftStrainSnapshot? {
        switch scenario {
        case .scored:
            return LiftStrainSnapshot(state: .scored, heartRateDisplay: 6.4, combinedDisplay: 11.6,
                                      workingSets: 18, warmupSets: 3, countedSets: 18, bodyweightIsDefault: false)
        case .pending:
            return LiftStrainSnapshot(state: .pending, heartRateDisplay: nil, combinedDisplay: nil,
                                      workingSets: 18, warmupSets: 3, countedSets: 18, bodyweightIsDefault: false)
        case .notScored:
            return LiftStrainSnapshot(state: .notScored, heartRateDisplay: nil, combinedDisplay: nil,
                                      workingSets: 18, warmupSets: 3, countedSets: 18, bodyweightIsDefault: false)
        case .noSets:
            return LiftStrainSnapshot(state: .noSets, heartRateDisplay: 6.4, combinedDisplay: 6.4,
                                      workingSets: 0, warmupSets: 0, countedSets: 0, bodyweightIsDefault: false)
        case .unavailable:
            return nil
        }
    }

    func updates() -> AsyncStream<Void> { AsyncStream { $0.finish() } }

    /// Fixed Strain for the last three sessions, so a recent row shows a number like the mockup.
    func recentStrains(sessionIDs: [String]) async -> [String: Double] {
        let values = [12.4, 13.1, 11.8]
        return Dictionary(uniqueKeysWithValues: zip(sessionIDs.suffix(3), values).map { ($0, $1) })
    }

    func liveVitals(start: Date, sets: [ReceiptLiftSet]) async -> LiftLiveVitals? {
        vitalsOff ? nil : LiftLiveVitals(bpm: 128, heartRateDisplay: 5.0, combinedDisplay: 7.9)
    }

    func beginLiveHeartRate() async {}
    func endLiveHeartRate() async {}
}
#endif
