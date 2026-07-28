import Foundation

/// Durable, value-only companion to `ActiveWorkoutPersistence`. The route uses the same compact polyline
/// format as `RouteStore`, so route checkpoints never rewrite the growing HR journal.
enum ActiveGpsWorkoutPersistence {
    struct Snapshot: Codable, Equatable, Sendable {
        static let currentVersion = 1
        let version: Int
        let sessionID: UUID
        let workoutStartMs: Int64
        let encodedPolyline: String
        let distanceM: Double
        let rawFixCount: Int
        let acceptedPointCount: Int
        let recordingWasActive: Bool
        let hadTerminatedGap: Bool

        init(sessionID: UUID, workoutStartMs: Int64, encodedPolyline: String, distanceM: Double,
             rawFixCount: Int, acceptedPointCount: Int, recordingWasActive: Bool, hadTerminatedGap: Bool) {
            version = Self.currentVersion
            self.sessionID = sessionID
            self.workoutStartMs = workoutStartMs
            self.encodedPolyline = encodedPolyline
            self.distanceM = distanceM
            self.rawFixCount = rawFixCount
            self.acceptedPointCount = acceptedPointCount
            self.recordingWasActive = recordingWasActive
            self.hadTerminatedGap = hadTerminatedGap
        }

        var isValid: Bool {
            guard version == Self.currentVersion, workoutStartMs > 0, distanceM.isFinite, distanceM >= 0,
                  rawFixCount >= acceptedPointCount, acceptedPointCount >= 0 else { return false }
            let points = RouteMath.decode(encodedPolyline)
            return encodedPolyline.isEmpty ? acceptedPointCount == 0 : points.count == acceptedPointCount
        }
    }

    static let defaultsKey = "noop.activeGpsWorkout.v1"

    static func store(_ snapshot: Snapshot, into defaults: UserDefaults = .standard) {
        guard snapshot.isValid, let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    static func load(from defaults: UserDefaults = .standard) -> Snapshot? {
        guard let data = defaults.data(forKey: defaultsKey),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data), snapshot.isValid else { return nil }
        return snapshot
    }

    static func clear(from defaults: UserDefaults = .standard) { defaults.removeObject(forKey: defaultsKey) }
}
