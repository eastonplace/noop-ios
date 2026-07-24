import Foundation

/// A transport-agnostic plan for RyanBR NOOP v9.1's GET_CLOCK recovery policy.
///
/// The live BLE layer owns actual command writes and `ClockRef` installation. This pure state machine owns
/// the safety decisions: at most three retries, then one explicitly approximate correlation from the newest
/// banked Data Range timestamp when one exists. It never falls back while a precise correlation is present.
public struct StrapClockRecoveryPlanner: Equatable, Sendable {
    public static let defaultMaximumRetries = 3
    /// Absorb benign response/clock jitter without accepting a Data Range marker materially in the future.
    public static let maximumFutureSkewSeconds = 300

    public enum Action: Equatable, Sendable {
        case none
        case retryGetClock(attempt: Int, maximum: Int)
        case installDataRangeFallback(deviceUnix: Int, wallUnix: Int)
    }

    public let maximumRetries: Int
    public private(set) var retryCount: Int
    public private(set) var fallbackIssued: Bool

    public init(
        maximumRetries: Int = defaultMaximumRetries,
        retryCount: Int = 0,
        fallbackIssued: Bool = false
    ) {
        self.maximumRetries = max(0, maximumRetries)
        self.retryCount = min(max(0, retryCount), max(0, maximumRetries))
        self.fallbackIssued = fallbackIssued
    }

    public mutating func nextAction(
        hasPreciseCorrelation: Bool,
        newestBankedUnix: Int?,
        wallUnix: Int
    ) -> Action {
        guard !hasPreciseCorrelation else { return .none }
        if retryCount < maximumRetries {
            retryCount += 1
            return .retryGetClock(attempt: retryCount, maximum: maximumRetries)
        }
        guard !fallbackIssued,
              let newestBankedUnix,
              newestBankedUnix > 0,
              wallUnix > 0,
              newestBankedUnix <= wallUnix + Self.maximumFutureSkewSeconds
        else { return .none }

        fallbackIssued = true
        return .installDataRangeFallback(
            deviceUnix: newestBankedUnix,
            wallUnix: wallUnix
        )
    }

    public mutating func reset() {
        retryCount = 0
        fallbackIssued = false
    }
}
