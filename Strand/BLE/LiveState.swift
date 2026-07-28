import Foundation
import Combine
import StrandAnalytics
import WhoopProtocol

/// Cheap, value-only observation after a historical session has durably persisted rows. It deliberately
/// excludes analysis and Repository work: those expensive operations run exactly once when the complete
/// continuation burst is finalized.
struct HistoricalSyncPassProgress: Equatable, Sendable {
    let rowsPersisted: Int
    let passNumber: Int
    let latestFrontierUnix: Int?
    let publishedAt: TimeInterval
}

/// Converts the Backfiller's per-session ACK count into one monotonic count for the complete logical burst.
/// Auto-continuation resets the low-level counter to zero between slices; treating that as user-visible progress
/// made Home look as though sync restarted repeatedly. A durable-data publication explicitly closes the burst.
/// The long-gap fallback separates a later empty/metadata-only periodic sync that has no publication edge.
struct HistoricalBurstProgress: Equatable, Sendable {
    static let newBurstGapSeconds: TimeInterval = 120

    private(set) var completedSessionChunks = 0
    private(set) var lastSessionCount = 0
    private(set) var finalized = true
    private(set) var lastReportAt: TimeInterval?

    mutating func record(sessionCount rawCount: Int, at timestamp: TimeInterval) -> Int {
        let count = max(0, rawCount)
        let gap = lastReportAt.map { max(0, timestamp - $0) } ?? .infinity

        if finalized || (count == 0 && gap > Self.newBurstGapSeconds) {
            completedSessionChunks = 0
            lastSessionCount = 0
            finalized = false
        } else if count < lastSessionCount {
            // The Backfiller began the next auto-continued session. Preserve the completed slice and add the
            // new session's local count on top instead of showing 0 again.
            completedSessionChunks = Self.saturatingAdd(completedSessionChunks, lastSessionCount)
        }

        lastSessionCount = count
        lastReportAt = timestamp
        return Self.saturatingAdd(completedSessionChunks, count)
    }

    mutating func markFinalized() {
        finalized = true
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }
}

/// Observable live connection and biometric state. High-frequency in-memory updates remain MainActor-owned;
/// expensive durable/log work is delegated to focused serial helpers in the accompanying extensions.
@MainActor
public final class LiveState: ObservableObject {
    @Published public var connected = false
    @Published public private(set) var connectedAt: TimeInterval?
    @Published public var bonded = false
    @Published public var encryptedBond = false
    @Published public var connectSettled = 0
    @Published public var streamingLiveHR = false
    @Published public var bluetoothUnavailableMessage: String?
    @Published public var liveFeedActive = false
    @Published public var pairingHint: String?
    @Published public var reconnectGuide: String?
    @Published public var standardHRMode: String?
    @Published public var rebootInProgress = false

    @Published public var heartRate: Int?
    @Published public var rr: [Int] = []
    @Published public internal(set) var rrRecent: [Int] = []
    @Published public var lastFrameType: String?
    @Published public var lastEvent: String?
    public internal(set) var lastFrameAtUnix: Int?
    /// The latest device-side clock captured at the BLE correlation seam. This is application state,
    /// not a presentation-derived value: diagnostics and Devices must never scan the growing strap log
    /// just to rediscover a correlation that BLEManager already established.
    @Published public private(set) var correlatedDeviceClockUnix: Int?
    @Published public var worn = true
    @Published public var historySyncExperimental = false

    @Published public var batteryPct: Double?
    @Published public var charging: Bool?
    @Published public internal(set) var batterySamples: [(ts: Int, soc: Double)] = []
    @Published public var batteryRatedHours = BatteryEstimator.ratedLifeHoursWhoop4
    @Published public var advertisingName: String?
    @Published public var strapFirmware: String?
    @Published public var renameStatus: String?
    static let maxBatterySamples = 400

    @Published public internal(set) var recentHrSamples: [HRSample] = []
    @Published public internal(set) var recentGravitySamples: [GravitySample] = []
    static let maxSleepReadoutSamples = 2_000

    public struct StrapRange: Equatable, Sendable {
        public var newestUnix: Int
        public var oldestUnix: Int?
        public var firmwareLayout: Int?

        public init(newestUnix: Int, oldestUnix: Int? = nil, firmwareLayout: Int? = nil) {
            self.newestUnix = newestUnix
            self.oldestUnix = oldestUnix
            self.firmwareLayout = firmwareLayout
        }
    }

    @Published public internal(set) var strapRange: StrapRange?
    @Published public var strapNeedsReboot = false
    @Published public var lastSyncedAt: TimeInterval?
    /// A backfill burst ended with durable raw data (or a timestamp-heal request). This is deliberately
    /// separate from `lastSyncedAt`: partial/offload-timeout data must become visible and get scored, but
    /// must never be presented as a completed sync.
    @Published public var backfillDataAvailableAt: TimeInterval? {
        didSet {
            if let value = backfillDataAvailableAt, value != oldValue {
                historicalBurstProgress.markFinalized()
            }
        }
    }
    @Published private(set) var historicalSyncPassProgress: HistoricalSyncPassProgress?
    @Published public var lastSyncError: String?
    @Published public var backfilling = false

    /// User-visible progress for the COMPLETE logical burst. BLEManager writes each session-local ACK count
    /// through this setter; only the monotonic cumulative value is ever published. The previous `@Published`
    /// `didSet` implementation emitted the raw zero first and corrected it in a second mutation, allowing the
    /// UI to flash back to zero at every auto-continued slice—the exact UX regression this model is meant to
    /// remove. Manual publication keeps the public property/API intact while guaranteeing one visible edge.
    private var visibleSyncChunks = 0
    public var syncChunksThisSession: Int {
        get { visibleSyncChunks }
        set {
            let cumulative = historicalBurstProgress.record(
                sessionCount: newValue,
                at: Date().timeIntervalSince1970)
            guard cumulative != visibleSyncChunks else { return }
            objectWillChange.send()
            visibleSyncChunks = cumulative
        }
    }

    @Published public var rejectedFramesThisSession = 0
    @Published public var rejectedFramesUnarchived = 0
    @Published public var decodedChunksThisSession = 0
    @Published public var consoleChunksThisSession = 0
    @Published public var r22FlagsAccepted = 0
    @Published public var deepPacketsThisSession = 0
    @Published public var puffinCaptureCount = 0
    @Published public var puffinCaptureURL: URL?

    @Published public var sensorSpeedKmh: Double?
    @Published public var sensorCadence: Double?
    @Published public var sensorPowerWatts: Int?

    @Published public var log: [String] = []
    public var onDoubleTap: (() -> Void)?
    public var onWristChange: ((Bool) -> Void)?
    public var onSmartAlarmFired: (() -> Void)?
    public var onBatteryUpdate: ((Double) -> Void)?

    static let maxLogLines = 5_000

    private var historicalBurstProgress = HistoricalBurstProgress()

    lazy var logTailPersistence = DebouncedLogTailPersistence(
        debounceInterval: 3,
        tailLimit: Self.tailLimit,
        loadPersisted: { Self.persistedLogTail() },
        persist: { Self.persistTail($0) }
    )

    public init() {
        #if DEBUG
        if CommandLine.arguments.contains("--demo-bluetooth-off") {
            bluetoothUnavailableMessage = "Bluetooth is off. Turn it on in Settings to connect a device."
        }
        #endif
    }

    public func markConnected(at timestamp: TimeInterval = Date().timeIntervalSince1970) {
        if !connected || connectedAt == nil { connectedAt = timestamp }
        connected = true
    }

    public func markDisconnected() {
        connected = false
        connectedAt = nil
        historicalBurstProgress.markFinalized()
        Task { await flushLogPersistence() }
    }

    /// Records the device clock once BLE has proved a wall-clock correlation. Keeping this explicit lets
    /// the tiny clock readout leaves update without tying command-center rendering to log publication.
    public func noteClockCorrelation(deviceUnix: Int) {
        guard correlatedDeviceClockUnix != deviceUnix else { return }
        correlatedDeviceClockUnix = deviceUnix
    }

    /// Publishes a compact persisted-pass receipt without asking AppModel to score or rebuild Repository.
    /// That keeps long oldest-first bursts visibly alive while preserving the single heavy finalization edge.
    func publishHistoricalSyncProgress(_ progress: HistoricalSyncPassProgress) {
        historicalSyncPassProgress = progress
    }

    public var connectionStatusLabel: String {
        if connected && bonded { return "Bonded · streaming" }
        if connected { return "Connected" }
        if bonded { return "Bonded · idle" }
        return "Disconnected"
    }

    public var connectionStatusIsActive: Bool { connected }
    public var connectionStatusIsIdle: Bool { !connected && bonded }
}
