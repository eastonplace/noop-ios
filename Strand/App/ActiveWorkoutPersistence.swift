import Foundation
import WhoopProtocol

enum LiveStrainState: Codable, Equatable {
    case building(readings: Int, coverageSeconds: Int)
    case scored(storedValue: Double)
}

/// Durable persistence for an in-flight, manually-started workout (#529).
///
/// A manual workout used to live ONLY in `AppModel.activeWorkout` (in memory), so if iOS killed the app
/// mid-session — a backgrounded phone under memory pressure — the whole session was lost and could never
/// be ended + saved. (Apple has no GPS-route session like Android's `GpsSession`; every manual workout
/// here is the "non-GPS" case, so they all need this.) This is the Apple analogue of Android's
/// `ActiveWorkoutStore`/`ActiveWorkoutPersistence`: a tiny `Codable` snapshot (start time, sport, the
/// accumulated HR samples + running stats) is written to `UserDefaults` on start and on every captured
/// sample, and read back on launch so an interrupted session can still be ended and saved.
///
/// On-device only; mirrors the existing `moments` / `sleepMarks` `UserDefaults` persistence in `AppModel`.
/// The encode/decode is pure (no `UserDefaults` dependency on the codec itself) so the persist/rehydrate
/// round-trip is unit-testable — `store(into:)` / `load(from:)` just thread a `UserDefaults` through it.
enum ActiveWorkoutPersistence {

    /// The durable shape of an in-flight manual workout. A small, self-contained `Codable` value — the
    /// minimum needed to rebuild `AppModel.ActiveWorkout` on relaunch and still End + save it.
    struct Snapshot: Codable, Equatable {
        /// Workout start, as unix seconds (stable across encodings; `AppModel` maps to/from `Date`).
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

    /// The single `UserDefaults` key (JSON-encoded `Snapshot`). Namespaced like `moments`/`sleepMarks`.
    static let defaultsKey = "noop.activeWorkout"

    /// Encode a snapshot to JSON `Data`. Returns nil only if encoding somehow fails (never expected for
    /// this all-value shape) so the caller can no-op rather than write garbage.
    static func encode(_ snapshot: Snapshot) -> Data? {
        try? JSONEncoder().encode(snapshot)
    }

    /// Decode a snapshot from JSON `Data`, bound-checking the untrusted persisted values. Returns nil for
    /// nil/garbage/empty input or an implausible start time, so a corrupt write is treated as "no
    /// in-flight session" rather than reviving a broken card.
    static func decode(_ data: Data?) -> Snapshot? {
        guard let data, !data.isEmpty,
              let raw = try? JSONDecoder().decode(Snapshot.self, from: data) else { return nil }
        guard raw.startSec > 0 else { return nil }
        // Drop any out-of-range persisted HR samples (a real bpm + a positive ts only) — never trust the
        // blob to be clean. Parity with the Android decoder's 1...300 bpm / ts > 0 gate.
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

    /// Persist (overwrite) the snapshot. Cheap; called on start + each captured sample.
    static func store(_ snapshot: Snapshot, into defaults: UserDefaults = .standard) {
        guard let data = encode(snapshot) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    /// Read back the persisted snapshot, or nil if none is stored (or it was corrupt).
    static func load(from defaults: UserDefaults = .standard) -> Snapshot? {
        decode(defaults.data(forKey: defaultsKey))
    }

    /// Clear the snapshot only after the finished row has been written and read back.
    /// Failed/insufficient finishes retain the durable session so the user can retry.
    static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}
