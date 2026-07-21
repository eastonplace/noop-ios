import Foundation

/// Pure decision engine for NOOP's conditional wake modes. The strap is always armed
/// for `windowEnd`; this evaluator can only request an earlier, best-effort wake.
public enum SmartAlarmEvaluator {
    public static let modelVersion = "smart-alarm-evaluator-v1.0"
    public static let adaptiveWindowMinutes = 30
    public static let greenRecoveryFloor = 67.0

    public enum Mode: String, Codable, CaseIterable, Sendable {
        case exactTime
        case sleepGoal
        case inTheGreen
    }

    public enum Trigger: String, Codable, Sendable {
        case configured, foreground, bluetoothReconnect, backgroundRefresh, dataRefresh
    }

    public enum Decision: String, Codable, Sendable {
        case wait
        case wakeNow
        case endpoint
        case unavailable
    }

    public struct Input: Equatable, Sendable {
        public let mode: Mode
        public let now: Date
        public let windowStart: Date
        public let windowEnd: Date
        public let bankedSleepMinutes: Double?
        public let sleepNeedMinutes: Double?
        public let recoveryForecastLow: Double?
        public let inputObservedAt: Date?

        public init(mode: Mode, now: Date, windowStart: Date, windowEnd: Date,
                    bankedSleepMinutes: Double? = nil, sleepNeedMinutes: Double? = nil,
                    recoveryForecastLow: Double? = nil, inputObservedAt: Date? = nil) {
            self.mode = mode; self.now = now; self.windowStart = windowStart; self.windowEnd = windowEnd
            self.bankedSleepMinutes = bankedSleepMinutes; self.sleepNeedMinutes = sleepNeedMinutes
            self.recoveryForecastLow = recoveryForecastLow; self.inputObservedAt = inputObservedAt
        }
    }

    public struct Evaluation: Equatable, Sendable {
        public let decision: Decision
        public let reason: String
        public let evaluatedAt: Date
        public let inputAgeSeconds: TimeInterval?
        public let modelVersion: String
    }

    public static func evaluate(_ input: Input) -> Evaluation {
        let age = input.inputObservedAt.map { max(0, input.now.timeIntervalSince($0)) }
        func result(_ decision: Decision, _ reason: String) -> Evaluation {
            Evaluation(decision: decision, reason: reason, evaluatedAt: input.now,
                       inputAgeSeconds: age, modelVersion: modelVersion)
        }
        guard input.windowStart <= input.windowEnd else { return result(.unavailable, "invalidWindow") }
        if input.now >= input.windowEnd { return result(.endpoint, "latestEndpointReached") }
        if input.now < input.windowStart { return result(.wait, "beforeAdaptiveWindow") }

        switch input.mode {
        case .exactTime:
            return result(.wait, "exactTimeUsesEndpoint")
        case .sleepGoal:
            guard let banked = input.bankedSleepMinutes, banked.isFinite,
                  let need = input.sleepNeedMinutes, need.isFinite, need > 0 else {
                return result(.unavailable, "missingCanonicalSleepGoalInput")
            }
            return banked >= need ? result(.wakeNow, "sleepGoalMet") : result(.wait, "sleepGoalNotMet")
        case .inTheGreen:
            guard let low = input.recoveryForecastLow, low.isFinite else {
                return result(.unavailable, "missingRecoveryForecast")
            }
            return low >= greenRecoveryFloor ? result(.wakeNow, "forecastBandIsGreen")
                                             : result(.wait, "forecastBandBelowGreen")
        }
    }
}
