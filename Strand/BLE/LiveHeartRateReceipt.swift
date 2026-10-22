import Foundation

/// A live observation belongs to one physical link and one persistence source. Reconnecting the same
/// strap creates a different source session; a queued observation cannot acquire the new ownership.
public struct LiveHeartRateSource: Equatable, Hashable, Sendable {
    public let deviceId: String
    public let peripheralID: UUID
    public let connectionGeneration: Int

    public init(deviceId: String, peripheralID: UUID, connectionGeneration: Int) {
        self.deviceId = deviceId
        self.peripheralID = peripheralID
        self.connectionGeneration = connectionGeneration
    }
}

public struct LiveHeartRateReceipt: Equatable, Sendable {
    public enum Transport: Equatable, Sendable { case standard, realtime, raw, rrFallback }

    public let bpm: Int
    /// Callback observation time, never the time a UI reads the cached display value.
    public let observedAt: Date
    public let source: LiveHeartRateSource
    public let transport: Transport

    public init(bpm: Int, observedAt: Date, source: LiveHeartRateSource, transport: Transport) {
        self.bpm = bpm
        self.observedAt = observedAt
        self.source = source
        self.transport = transport
    }

    public var observedSecond: Int { Int(observedAt.timeIntervalSince1970.rounded(.down)) }
}

/// One accepted observation per second across both WHOOP transports. Raw persistence keeps its own
/// unmodified provenance; this gate bounds only the live smoothing/workout/coaching cadence.
struct LiveHeartRateReceiptGate {
    static let maximumReceiptAge: TimeInterval = 5
    private(set) var source: LiveHeartRateSource?
    private(set) var latest: LiveHeartRateReceipt?
    private var lastObservedAt: Date?
    private var lastDirectAt: Date?

    mutating func activate(_ source: LiveHeartRateSource?) {
        self.source = source
        latest = nil
        lastObservedAt = nil
        lastDirectAt = nil
    }

    mutating func admit(_ receipt: LiveHeartRateReceipt, now: Date) -> Bool {
        let age = now.timeIntervalSince(receipt.observedAt)
        guard receipt.source == source, (30...220).contains(receipt.bpm),
              receipt.observedAt.timeIntervalSince1970 > 0,
              age >= 0, age <= Self.maximumReceiptAge,
              lastObservedAt.map({ receipt.observedAt > $0 }) ?? true else { return false }
        if receipt.transport == .rrFallback {
            guard lastDirectAt.map({ receipt.observedAt.timeIntervalSince($0) > Self.maximumReceiptAge }) ?? true
            else { return false }
        } else {
            lastDirectAt = receipt.observedAt
        }
        lastObservedAt = receipt.observedAt
        guard latest.map({ receipt.observedSecond > $0.observedSecond }) ?? true else { return false }
        latest = receipt
        return true
    }
}

struct RealtimeHRLeaseToken: Hashable, Sendable { private let id = UUID() }
enum RealtimeHRConsumer: Equatable, Sendable { case visible, workout, liveSession, lift }

struct RealtimeHRDemand: Equatable {
    let visible: Bool
    let recording: Bool
    var isWanted: Bool { visible || recording }
}

/// Lease removal requires the acquisition's identity. A disconnected view, duplicate disappearance,
/// or cancelled consumer can never decrement another consumer's recording demand.
struct RealtimeHRLeaseSet {
    private var leases: [RealtimeHRLeaseToken: RealtimeHRConsumer] = [:]
    var isEmpty: Bool { leases.isEmpty }

    mutating func acquire(_ consumer: RealtimeHRConsumer) -> RealtimeHRLeaseToken {
        let token = RealtimeHRLeaseToken()
        leases[token] = consumer
        return token
    }

    @discardableResult
    mutating func release(_ token: RealtimeHRLeaseToken) -> Bool { leases.removeValue(forKey: token) != nil }

    func demand(applicationIsActive: Bool) -> RealtimeHRDemand {
        RealtimeHRDemand(visible: applicationIsActive && leases.values.contains { $0 == .visible },
                         recording: leases.values.contains { $0 != .visible })
    }
}
