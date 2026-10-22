import Foundation

/// Receipt ownership for one retained non-WHOOP provider. Callback tokens are bound to the actual
/// discovered characteristic, so a queued callback from an old connection cannot acquire a new session.
@MainActor
final class LiveHeartRateProviderSession {
    private let live: LiveState
    private let deviceId: String
    private var generation = 0
    private var characteristics: [ObjectIdentifier: LiveHeartRateSource] = [:]
    private(set) var source: LiveHeartRateSource?

    init(live: LiveState, deviceId: String) {
        self.live = live
        self.deviceId = deviceId
    }

    @discardableResult
    func begin(peripheralID: UUID) -> LiveHeartRateSource {
        if let source, source.peripheralID == peripheralID, live.currentHeartRateSource == source { return source }
        generation &+= 1
        let source = LiveHeartRateSource(deviceId: deviceId, peripheralID: peripheralID,
                                        connectionGeneration: generation, providerSessionID: UUID())
        self.source = source
        characteristics.removeAll(keepingCapacity: true)
        // WHOOP proof and fallback state cannot authorize or describe this provider's new link.
        live.bonded = false
        live.encryptedBond = false
        live.standardHRMode = nil
        live.connectedAt = Date().timeIntervalSince1970
        live.activateHeartRateSource(source)
        if !live.connected { live.connected = true }
        live.streamingLiveHR = false
        return source
    }

    func bind(_ characteristic: AnyObject) {
        guard let source, live.currentHeartRateSource == source else { return }
        characteristics[ObjectIdentifier(characteristic)] = source
    }

    func source(for characteristic: AnyObject, peripheralID: UUID) -> LiveHeartRateSource? {
        guard let captured = characteristics[ObjectIdentifier(characteristic)],
              captured.peripheralID == peripheralID, captured == source,
              live.currentHeartRateSource == captured else { return nil }
        return captured
    }

    @discardableResult
    func receive(bpm: Int, observedAt: Date, source: LiveHeartRateSource, now: Date = Date()) -> Bool {
        guard self.source == source, live.currentHeartRateSource == source else { return false }
        let accepted = live.receiveHeartRate(bpm: bpm, observedAt: observedAt, source: source,
                                             transport: .standard, now: now)
        if accepted, !live.streamingLiveHR { live.streamingLiveHR = true }
        return accepted
    }

    @discardableResult
    func end() -> Bool {
        defer {
            source = nil
            characteristics.removeAll(keepingCapacity: true)
        }
        guard let source, live.deactivateHeartRateSource(ifCurrent: source) else { return false }
        live.connected = false
        live.streamingLiveHR = false
        return true
    }
}
