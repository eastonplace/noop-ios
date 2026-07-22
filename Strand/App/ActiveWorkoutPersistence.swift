import Foundation
import WhoopProtocol
#if os(iOS) && canImport(UIKit)
import UIKit
#elseif os(macOS) && canImport(AppKit)
import AppKit
#endif

enum LiveStrainState: Codable, Equatable {
    case building(readings: Int, coverageSeconds: Int)
    case scored(storedValue: Double)
}

/// Durable persistence for an in-flight, manually-started workout (#529).
///
/// Production snapshots are coalesced through one utility queue. During an active workout, repeated
/// snapshots replace older pending work so JSON encoding and UserDefaults I/O never build a backlog on
/// MainActor. The first snapshot and any background/inactive flush remain synchronous for durability.
/// `clear()` invalidates pending generations and waits for the writer before removing the key, preventing
/// a stale delayed write from resurrecting an already-finished workout.
enum ActiveWorkoutPersistence {

    struct Snapshot: Codable, Equatable {
        var startSec: Int
        var sport: String
        var samples: [HRSample]
        var avgHr: Int
        var peakHr: Int
        var liveStrainState: LiveStrainState

        private enum CodingKeys: String, CodingKey {
            case startSec, sport, samples, avgHr, peakHr, liveStrainState, liveStrain
        }

        init(startSec: Int, sport: String, samples: [HRSample], avgHr: Int, peakHr: Int,
             liveStrainState: LiveStrainState) {
            self.startSec = startSec; self.sport = sport; self.samples = samples
            self.avgHr = avgHr; self.peakHr = peakHr; self.liveStrainState = liveStrainState
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            startSec = try values.decode(Int.self, forKey: .startSec)
            sport = try values.decode(String.self, forKey: .sport)
            samples = try values.decode([HRSample].self, forKey: .samples)
            avgHr = try values.decode(Int.self, forKey: .avgHr)
            peakHr = try values.decode(Int.self, forKey: .peakHr)
            if let state = try values.decodeIfPresent(LiveStrainState.self, forKey: .liveStrainState) {
                liveStrainState = state
            } else if let legacy = try values.decodeIfPresent(Double.self, forKey: .liveStrain), legacy > 0 {
                liveStrainState = .scored(storedValue: legacy)
            } else {
                liveStrainState = .building(readings: samples.count, coverageSeconds: 0)
            }
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(startSec, forKey: .startSec)
            try values.encode(sport, forKey: .sport)
            try values.encode(samples, forKey: .samples)
            try values.encode(avgHr, forKey: .avgHr)
            try values.encode(peakHr, forKey: .peakHr)
            try values.encode(liveStrainState, forKey: .liveStrainState)
        }
    }

    static let defaultsKey = "noop.activeWorkout"
    private static let writer = SnapshotWriter()
    /// Reading the growing Data value merely to ask whether it exists would itself copy/materialize that
    /// blob on MainActor every five seconds. Cache only the existence bit for the production suite and
    /// reset it when the ordered production clear completes.
    @MainActor private static var productionSnapshotEstablished =
        UserDefaults.standard.object(forKey: defaultsKey) != nil

    static func encode(_ snapshot: Snapshot) -> Data? {
        try? JSONEncoder().encode(snapshot)
    }

    static func decode(_ data: Data?) -> Snapshot? {
        guard let data, !data.isEmpty,
              let raw = try? JSONDecoder().decode(Snapshot.self, from: data) else { return nil }
        guard raw.startSec > 0 else { return nil }
        let samples = raw.samples.filter { $0.ts > 0 && (1...300).contains($0.bpm) }
        let state: LiveStrainState
        switch raw.liveStrainState {
        case .building(let readings, let coverage):
            state = .building(readings: max(0, readings), coverageSeconds: max(0, coverage))
        case .scored(let stored) where stored.isFinite:
            state = .scored(storedValue: min(100, max(0, stored)))
        case .scored:
            state = .building(readings: samples.count, coverageSeconds: 0)
        }
        return Snapshot(
            startSec: raw.startSec,
            sport: raw.sport,
            samples: samples,
            avgHr: max(0, raw.avgHr),
            peakHr: max(0, raw.peakHr),
            liveStrainState: state
        )
    }

    /// Production path. Normal foreground snapshots are latest-wins and encoded off MainActor. The first
    /// snapshot is synchronous so a kill immediately after Start cannot erase the session. A lifecycle
    /// owner can force an ordered synchronous flush before suspension on either Apple platform.
    @MainActor
    static func store(_ snapshot: Snapshot, synchronously: Bool = false) {
        let defaults = UserDefaults.standard
        let isFirstSnapshot = !productionSnapshotEstablished
        if isFirstSnapshot { productionSnapshotEstablished = true }
        #if os(iOS) && canImport(UIKit)
        let applicationRequiresImmediateFlush = UIApplication.shared.applicationState != .active
        #elseif os(macOS) && canImport(AppKit)
        let applicationRequiresImmediateFlush = !NSApplication.shared.isActive
        #else
        let applicationRequiresImmediateFlush = false
        #endif
        writer.store(
            snapshot,
            into: defaults,
            synchronously: synchronously || isFirstSnapshot || applicationRequiresImmediateFlush
        )
    }

    /// Deterministic direct seam for isolated unit tests and migrations.
    static func store(_ snapshot: Snapshot, into defaults: UserDefaults) {
        guard let data = encode(snapshot) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    /// Internal stress-test seam: same coalescing writer as production, with an isolated defaults suite.
    static func storeCoalesced(
        _ snapshot: Snapshot,
        into defaults: UserDefaults,
        synchronously: Bool = false
    ) {
        writer.store(snapshot, into: defaults, synchronously: synchronously)
    }

    static func flushPendingWrites() {
        writer.flush()
    }

    static func load(from defaults: UserDefaults = .standard) -> Snapshot? {
        decode(defaults.data(forKey: defaultsKey))
    }

    /// Production clear is ordered after/invalidation-safe against every pending snapshot.
    @MainActor
    static func clear() {
        writer.clear(from: .standard)
        productionSnapshotEstablished = false
    }

    /// Isolated-suite seam. It still routes through the ordered writer so a queued coalesced test write
    /// cannot resurrect the key after the clear.
    static func clear(from defaults: UserDefaults) {
        writer.clear(from: defaults)
    }

    private final class SnapshotWriter: @unchecked Sendable {
        private struct Pending: @unchecked Sendable {
            let key: ObjectIdentifier
            let snapshot: Snapshot
            let defaults: UserDefaults
            let generation: UInt64
        }

        private let queue = DispatchQueue(label: "com.noop.active-workout-persistence", qos: .utility)
        private let queueKey = DispatchSpecificKey<UInt8>()
        private let lock = NSLock()
        private var generations: [ObjectIdentifier: UInt64] = [:]
        private var pendingByStore: [ObjectIdentifier: Pending] = [:]
        private var workerScheduled = false

        init() {
            queue.setSpecific(key: queueKey, value: 1)
        }

        func store(_ snapshot: Snapshot, into defaults: UserDefaults, synchronously: Bool) {
            let key = ObjectIdentifier(defaults)
            let item: Pending
            lock.lock()
            let nextGeneration = (generations[key] ?? 0) &+ 1
            generations[key] = nextGeneration
            item = Pending(
                key: key,
                snapshot: snapshot,
                defaults: defaults,
                generation: nextGeneration
            )
            // Every newer snapshot supersedes any not-yet-encoded older one for the same store.
            if synchronously {
                pendingByStore.removeValue(forKey: key)
            } else {
                pendingByStore[key] = item
            }
            let shouldSchedule = !synchronously && !workerScheduled
            if shouldSchedule { workerScheduled = true }
            lock.unlock()

            if synchronously {
                syncOnQueue { [self] in writeIfCurrent(item) }
            } else if shouldSchedule {
                queue.async { [self] in drain() }
            }
        }

        func clear(from defaults: UserDefaults) {
            let key = ObjectIdentifier(defaults)
            lock.lock()
            generations[key] = (generations[key] ?? 0) &+ 1
            pendingByStore.removeValue(forKey: key)
            lock.unlock()

            syncOnQueue { [self] in
                lock.lock()
                defaults.removeObject(forKey: ActiveWorkoutPersistence.defaultsKey)
                lock.unlock()
            }
        }

        func flush() {
            syncOnQueue { }
        }

        private func drain() {
            while true {
                let item: Pending?
                lock.lock()
                if let entry = pendingByStore.first {
                    item = entry.value
                    pendingByStore.removeValue(forKey: entry.key)
                } else {
                    item = nil
                    workerScheduled = false
                }
                lock.unlock()

                guard let item else { return }
                writeIfCurrent(item)
            }
        }

        private func writeIfCurrent(_ item: Pending) {
            guard let data = ActiveWorkoutPersistence.encode(item.snapshot) else { return }
            // Keep the generation check and write atomic relative to clear/newer stores. UserDefaults I/O
            // happens on the utility queue, so holding this short lock never blocks MainActor on encoding.
            lock.lock()
            if generations[item.key] == item.generation {
                item.defaults.set(data, forKey: ActiveWorkoutPersistence.defaultsKey)
            }
            lock.unlock()
        }

        private func syncOnQueue(_ operation: () -> Void) {
            if DispatchQueue.getSpecific(key: queueKey) != nil {
                operation()
            } else {
                queue.sync(execute: operation)
            }
        }
    }
}
