import Combine
import Foundation
import StrandAnalytics

/// A value-only adapter for the Device Command Center.
///
/// `LiveState` publishes heart rate, R-R intervals, logs, sensors, and other high-frequency values that
/// this sheet never renders. Bind only the fields the sheet needs, and suppress repeated assignments before
/// they can invalidate SwiftUI.
@MainActor
final class DeviceCommandCenterLiveSnapshot: ObservableObject {
    struct Value: Equatable {
        var connected: Bool
        var connectedAt: TimeInterval?
        var encryptedBond: Bool
        var bluetoothUnavailableMessage: String?
        var reconnectGuide: String?
        var pairingHint: String?
        var correlatedDeviceClockUnix: Int?
        var strapRange: LiveState.StrapRange?
        var lastSyncError: String?
        var strapNeedsReboot: Bool
        var batteryPct: Double?
        var batteryRuntimeLabel: String?
        var charging: Bool?
        var historySyncExperimental: Bool
        var standardHRMode: String?
        var backfilling: Bool
        var syncChunksThisSession: Int
        var lastSyncedAt: TimeInterval?
        var rejectedFramesThisSession: Int
        var rejectedFramesUnarchived: Int
        var r22FlagsAccepted: Int
        var strapFirmware: String?
        var worn: Bool
        var historicalSyncPassProgress: HistoricalSyncPassProgress?
    }

    @Published private(set) var value: Value

    private var cancellables = Set<AnyCancellable>()

    init(live: LiveState) {
        value = Value(
            connected: live.connected,
            connectedAt: live.connectedAt,
            encryptedBond: live.encryptedBond,
            bluetoothUnavailableMessage: live.bluetoothUnavailableMessage,
            reconnectGuide: live.reconnectGuide,
            pairingHint: live.pairingHint,
            correlatedDeviceClockUnix: live.correlatedDeviceClockUnix,
            strapRange: live.strapRange,
            lastSyncError: live.lastSyncError,
            strapNeedsReboot: live.strapNeedsReboot,
            batteryPct: live.batteryPct,
            batteryRuntimeLabel: live.batteryEstimate.map { BatteryEstimator.label(hours: $0.remainingHours) },
            charging: live.charging,
            historySyncExperimental: live.historySyncExperimental,
            standardHRMode: live.standardHRMode,
            backfilling: live.backfilling,
            syncChunksThisSession: live.syncChunksThisSession,
            lastSyncedAt: live.lastSyncedAt,
            rejectedFramesThisSession: live.rejectedFramesThisSession,
            rejectedFramesUnarchived: live.rejectedFramesUnarchived,
            r22FlagsAccepted: live.r22FlagsAccepted,
            strapFirmware: live.strapFirmware,
            worn: live.worn,
            historicalSyncPassProgress: live.historicalSyncPassProgress
        )

        bind(live.$connected, to: \.connected)
        bind(live.$connectedAt, to: \.connectedAt)
        bind(live.$encryptedBond, to: \.encryptedBond)
        bind(live.$bluetoothUnavailableMessage, to: \.bluetoothUnavailableMessage)
        bind(live.$reconnectGuide, to: \.reconnectGuide)
        bind(live.$pairingHint, to: \.pairingHint)
        bind(live.$correlatedDeviceClockUnix, to: \.correlatedDeviceClockUnix)
        bind(live.$strapRange, to: \.strapRange)
        bind(live.$lastSyncError, to: \.lastSyncError)
        bind(live.$strapNeedsReboot, to: \.strapNeedsReboot)
        bind(live.$batteryPct, to: \.batteryPct)
        bind(live.$charging, to: \.charging)
        bind(live.$historySyncExperimental, to: \.historySyncExperimental)
        bind(live.$standardHRMode, to: \.standardHRMode)
        bind(live.$backfilling, to: \.backfilling)
        bind(live.syncChunksPublisher, to: \.syncChunksThisSession)
        bind(live.$lastSyncedAt, to: \.lastSyncedAt)
        bind(live.$rejectedFramesThisSession, to: \.rejectedFramesThisSession)
        bind(live.$rejectedFramesUnarchived, to: \.rejectedFramesUnarchived)
        bind(live.$r22FlagsAccepted, to: \.r22FlagsAccepted)
        bind(live.$strapFirmware, to: \.strapFirmware)
        bind(live.$worn, to: \.worn)
        bind(live.$historicalSyncPassProgress, to: \.historicalSyncPassProgress)

        let batteryRuntime = Publishers.CombineLatest(live.$batterySamples, live.$batteryRatedHours)
            .map { samples, ratedHours in
                BatteryEstimator.estimate(samples: samples, ratedHours: ratedHours)
                    .map { BatteryEstimator.label(hours: $0.remainingHours) }
            }
        bind(batteryRuntime, to: \.batteryRuntimeLabel)
    }

    private func bind<P: Publisher, Output: Equatable>(
        _ publisher: P,
        to keyPath: WritableKeyPath<Value, Output>
    ) where P.Output == Output, P.Failure == Never {
        publisher
            .removeDuplicates()
            .sink { [weak self] output in
                guard let self else { return }
                var next = value
                next[keyPath: keyPath] = output
                guard next != value else { return }
                value = next
            }
            .store(in: &cancellables)
    }
}
