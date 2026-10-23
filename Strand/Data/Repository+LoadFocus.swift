import Foundation
import NoopPhase34Core
import StrandAnalytics
import WhoopProtocol
import WhoopStore

struct WorkoutFocusReadScope: Hashable, Sendable {
    let importedIDs: [String]
    let computedIDs: [String]
    let sourceContext: String
    let lineage: String
    let invalidationEpoch: UInt64
    let revision: Int
    let trendsRevision: Int64
    let dataVersion: Int
    let profileMaxHR: Int
    let isFenced: Bool

    var owner: String {
        (importedIDs + computedIDs + [sourceContext, lineage, String(invalidationEpoch)])
            .map { "\($0.utf8.count):\($0)" }.joined()
    }
}

struct WorkoutFocusTaskKey: Equatable {
    let scope: WorkoutFocusReadScope
    let anchorDay: String
    let timeZoneIdentifier: String
    var starts: [Int] = []
}

struct WorkoutFocusZoneKey: Hashable {
    let start: Int
    let end: Int
    let sport: String
    let hrMax: Int
    let owner: String
    let input: String
    let pauses: String
}

enum WorkoutFocusReadError: Error { case storeUnavailable, invalidWindow }

@MainActor
extension Repository {
    var workoutFocusReadScope: WorkoutFocusReadScope {
        WorkoutFocusReadScope(importedIDs: importedReadIds, computedIDs: computedReadIds,
            sourceContext: notificationSourceContext, lineage: liveSourceState.lineageComponent,
            invalidationEpoch: externalSurfaceInvalidationEpoch, revision: refreshSeq,
            trendsRevision: canonicalHealth.trendsRevision, dataVersion: dataVersion,
            profileMaxHR: ProfileStore.hrMax(age: ProfileStore.storedAge(), override: ProfileStore.storedHrMaxOverride()),
            isFenced: verifiedExternalSurfaceFenced)
    }

    /// A month (or a bounded driver window), pinned to one store/source/input generation. Raw arrays
    /// and zone math stay off the main actor. A failed or obsolete read never seeds the memo.
    func workoutLoadFocus(from: Int, to: Int, age: Int) async throws -> [LoadFocus.Workout] {
        try Task.checkCancellation()
        guard to > from else { throw WorkoutFocusReadError.invalidWindow }
        guard !verifiedExternalSurfaceFenced else { throw CancellationError() }
        guard let store = await storeHandle() else { throw WorkoutFocusReadError.storeUnavailable }
        let scope = workoutFocusReadScope
        func check() throws {
            try Task.checkCancellation()
            guard !scope.isFenced, scope == workoutFocusReadScope else { throw CancellationError() }
        }
        try check()
        let override = ProfileStore.storedHrMaxOverride()
        let hrMax = ProfileStore.hrMax(age: age > 0 ? age : 30, override: override)
        let pauseMap = WorkoutPauseStore.loadMap()
        let witness = try await store.analysisInputWitness()
        try check()
        let controls = ["workout", "device", "pairedDevice", "dayOwnership"]
        let rawTables = ["hrSample", "ppgHrSample", "device", "pairedDevice", "dayOwnership"]
        let controlIdentity = witness.signature(tables: controls)
        // Keep the Workouts facade's namespace priority, natural-key/cross-source dedup and dismissals.
        // Required reads throw, so a database error cannot masquerade as zero recorded workouts.
        var rows: [WorkoutRow] = []
        for id in scope.importedIDs + scope.computedIDs + [Self.appleHealthSource, "lifting", "activity-file"] {
            try check()
            rows += try await store.workouts(deviceId: id, from: from, to: to, limit: 5_000)
        }
        try check()
        let dismissed = workoutFocusDismissedSpans
        let spans = WorkoutSource.parseDismissedSpans(dismissed)
        let visible = WorkoutSource.dedupCrossSource(Self.dedupWorkoutsByNaturalKey(rows)
            .filter { !WorkoutSource.isDismissed($0, spans: spans) }).sorted { $0.startTs > $1.startTs }
        var pending = workoutZoneMemo
        var usedKeys: [WorkoutFocusZoneKey] = []
        var result: [LoadFocus.Workout] = []
        for row in visible where row.endTs > row.startTs {
            try check()
            let pauses = pauseMap[WorkoutPauseStore.key(startTs: row.startTs, sport: row.sport)] ?? []
            let pauseKey = pauses.map { "\($0.start.bitPattern)-\($0.end.bitPattern)" }.joined(separator: ",")
            let key = WorkoutFocusZoneKey(start: row.startTs, end: row.endTs, sport: row.sport, hrMax: hrMax,
                owner: scope.owner, input: witness.dayScanSignature(tables: rawTables, from: row.startTs, to: row.endTs),
                pauses: pauseKey)
            usedKeys.append(key)
            var minutes = pending[key]
            if minutes == nil {
                let sources = scope.importedIDs
                let worker = Task.detached(priority: .utility) {
                    var bySecond: [Int: HRSample] = [:]
                    for source in sources {
                        try Task.checkCancellation()
                        let raw = try await store.hrSamples(deviceId: source, from: row.startTs,
                            to: row.endTs, limit: Self.workoutZoneSampleLimit)
                        try Task.checkCancellation()
                        for sample in raw where bySecond[sample.ts] == nil { bySecond[sample.ts] = sample }
                    }
                    let raw = bySecond.values.filter { HRValidity.isPlausible($0.bpm) }.sorted { $0.ts < $1.ts }
                    let active = WorkoutPauseLedger(intervals: pauses).activeSamples(raw)
                    try Task.checkCancellation()
                    return Self.zoneMinutes(samples: active, age: age, hrMaxOverride: override)
                }
                minutes = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                #if DEBUG
                workoutFocusRawReadCountForTesting += 1
                await workoutFocusAfterRawReadForTesting?()
                #endif
                try check()
                pending[key] = minutes
            }
            result.append(.init(start: Date(timeIntervalSince1970: TimeInterval(row.startTs)), zoneMinutes: minutes))
        }
        let current = try await store.analysisInputWitness()
        try check()
        guard current.signature(tables: controls) == controlIdentity,
              usedKeys.allSatisfy({ $0.input == current.dayScanSignature(tables: rawTables, from: $0.start, to: $0.end) }),
              WorkoutPauseStore.loadMap() == pauseMap,
              let currentStore = await storeHandle(), currentStore === store else { throw CancellationError() }
        try check()
        guard WorkoutPauseStore.loadMap() == pauseMap, workoutFocusDismissedSpans == dismissed else { throw CancellationError() }
        // The source may have thousands of workouts; keep RAM reuse bounded independently of history size.
        if pending.count > 256 {
            var bounded: [WorkoutFocusZoneKey: [Double]] = [:]
            for key in usedKeys.prefix(256) { bounded[key] = pending[key] }
            pending = bounded
        }
        workoutZoneMemo = pending
        return result
    }

    func loadFocus(anchorDay: String, timeZoneIdentifier: String) async throws -> LoadFocus.Result {
        guard let civil = try? CivilDay(key: anchorDay),
              let zone = TimeZone(identifier: timeZoneIdentifier) else { throw WorkoutFocusReadError.invalidWindow }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = civil.key.split(separator: "-").compactMap { Int($0) }
        guard let day = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              let end = calendar.date(byAdding: .day, value: 1, to: day),
              let start = calendar.date(byAdding: .day, value: -LoadFocus.windowDays, to: end)
        else { throw WorkoutFocusReadError.invalidWindow }
        let workouts = try await workoutLoadFocus(from: Int(start.timeIntervalSince1970), to: Int(end.timeIntervalSince1970),
                                                  age: ProfileStore.storedAge())
        try Task.checkCancellation()
        return LoadFocus.evaluate(workouts: workouts, through: end, calendar: calendar)
    }
}
