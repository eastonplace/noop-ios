#if os(iOS)
import Foundation
import ActivityKit

/// Live Activity attributes for an active live-HR / workout session. Shared between the app (which
/// starts/updates the activity) and the widget extension (which renders it on the Lock Screen and in
/// the Dynamic Island).
public struct NOOPActivityAttributes: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        public var bpm: Int?
        public var recovery: Int?
        public var bonded: Bool
        // Canonical 0–21 Strain display value (#446) — one more stat in the Dynamic Island expanded
        // region. OPTIONAL with a nil default so an activity started by an older build still decodes.
        public var effort: Double?
        public var sport: String?
        public var workoutStartedAt: Date?
        public var strainBuilding: Bool?
        public var calories: Int?
        public var hrTrace: [Int]?
        public var zoneSeconds: [Int]?

        public var isWorkout: Bool { sport != nil && workoutStartedAt != nil }

        public init(bpm: Int?, recovery: Int?, bonded: Bool, effort: Double? = nil,
                    sport: String? = nil, workoutStartedAt: Date? = nil,
                    strainBuilding: Bool? = nil, calories: Int? = nil,
                    hrTrace: [Int]? = nil, zoneSeconds: [Int]? = nil) {
            self.bpm = bpm
            self.recovery = recovery
            self.bonded = bonded
            self.effort = effort
            self.sport = sport
            self.workoutStartedAt = workoutStartedAt
            self.strainBuilding = strainBuilding
            self.calories = calories
            self.hrTrace = hrTrace.map { Array($0.filter { (30...240).contains($0) }.suffix(48)) }
            self.zoneSeconds = zoneSeconds.map { Array($0.prefix(5)).map { max(0, $0) } }
        }
    }

    /// Static title shown for the session.
    public var title: String

    public init(title: String = "Live HR") {
        self.title = title
    }
}
#endif
