import Foundation
import WhoopProtocol
import WhoopStore

/// The subset of WhoopStore the Collector needs. A protocol so tests can inject a spy
/// (WhoopStore is `final`). WhoopStore conforms via the extension below.
/// Not @MainActor — the WhoopStore actor's async methods satisfy the async requirements;
/// a @MainActor SpyStore in tests also conforms (async witnesses hop actors).
protocol StoreWriting: AnyObject, Sendable {
    @discardableResult
    func insert(_ streams: Streams, deviceId: String) async throws
        -> (hr: Int, rr: Int, events: Int, battery: Int,
            spo2: Int, skinTemp: Int, resp: Int, gravity: Int)
    func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws
}
extension WhoopStore: StoreWriting {}

/// Cadence: flush after this many buffered frames OR this many seconds since the last
/// flush — whichever first. Also flushed explicitly on disconnect/foreground.
struct CollectorPolicy {
    var maxFrames: Int
    var maxInterval: TimeInterval
    /// Defensive cap on the PRE-CLOCK buffer only (see `ingest`). Generous default —
    /// ~4096 frames at ~60 bytes/frame is ~240KB, far beyond the handful seen pre-clock
    /// normally. Custom init keeps `.init(maxFrames:maxInterval:)` call sites compiling.
    var maxPreClockFrames: Int
    /// BLE-11: cap on the post-clock frame buffer and on each standard HR/RR buffer, so a store that keeps
    /// failing cannot grow them without limit (the oldest entries are dropped and logged).
    var maxBufferedFrames: Int
    var maxStandardSamples: Int
    init(maxFrames: Int, maxInterval: TimeInterval, maxPreClockFrames: Int = 4096,
         maxBufferedFrames: Int = 8192, maxStandardSamples: Int = 4096) {
        self.maxFrames = maxFrames
        self.maxInterval = maxInterval
        self.maxPreClockFrames = maxPreClockFrames
        self.maxBufferedFrames = maxBufferedFrames
        self.maxStandardSamples = maxStandardSamples
    }
    static let `default` = CollectorPolicy(maxFrames: 64, maxInterval: 30, maxPreClockFrames: 4096)
}

/// Buffers complete (reassembled) frames and periodically persists them:
/// parse → extractStreams(clockRef) → store.insert (DECODED FIRST, durable) →
/// store.enqueueRawBatch (raw, transient outbox) → clear buffer.
/// Because decoded is committed before raw is queued, pruning raw never loses a metric.
@MainActor
final class Collector {
    private let store: StoreWriting
    /// Concrete store for prune + stats (the StoreWriting seam covers the hot insert/enqueue path;
    /// prune/stats are infrequent so a direct reference is clearer than widening the protocol).
    private let concreteStore: WhoopStore?
    /// A retarget affects only new intake. Buffered samples and suspended writes keep their owner.
    var deviceId: String {
        didSet {
            if deviceId != oldValue {
                intakeGeneration &+= 1
                clockRef = nil
            }
        }
    }
    private let policy: CollectorPolicy
    /// Research toggle. When false (DEFAULT) no raw frames are persisted at all — the app is
    /// decoded-only. Injected for tests; backed by UserDefaults in the production init site.
    private let enableRawCapture: Bool
    private let now: () -> Int
    private let monotonic: () -> TimeInterval

    /// Set once the GET_CLOCK correlation lands (E1). Until then, frames buffer un-persisted.
    var clockRef: ClockRef? {
        didSet {
            guard let clockRef else {
                if oldValue != nil { intakeGeneration &+= 1 }
                return
            }
            // A late GET_CLOCK may resolve only samples admitted by this source/session.
            let owner = intakeOwner
            for index in buffer.indices
                where buffer[index].context.owner == owner && buffer[index].context.clockRef == nil {
                buffer[index].context.clockRef = clockRef
            }
        }
    }
    /// Strap family for the LIVE decode path. WHOOP 4.0 (default) parses the 4.0 envelope; 5/MG
    /// parses the puffin envelope (records sit at +4 offsets). Set by BLEManager.configureCollector‐
    /// Family alongside an identity clockRef — 5/MG live timestamps are already real-unix seconds.
    var family: DeviceFamily = .whoop4 {
        didSet { if family != oldValue { intakeGeneration &+= 1 } }
    }
    private var intakeGeneration: UInt64 = 0
    private struct IntakeOwner: Hashable, Sendable {
        let deviceId: String
        let family: DeviceFamily
        let generation: UInt64
    }
    private var intakeOwner: IntakeOwner {
        IntakeOwner(deviceId: deviceId, family: family, generation: intakeGeneration)
    }
    private struct FrameContext: Equatable, Sendable {
        let owner: IntakeOwner
        var clockRef: ClockRef?
    }
    private struct BufferedFrame {
        let frame: [UInt8]
        let parsed: ParsedFrame
        var context: FrameContext
    }
    private struct OwnedSample<Sample: Sendable> {
        let sample: Sample
        let owner: IntakeOwner
    }
    /// On-demand bounded raw-capture window. ORs into the raw-persist gate so a "capture
    /// activity sample" action can persist raw even when `enableRawCapture` is off. The window's
    /// monotonic deadline auto-expires so a missed stop callback can't leak raw forever.
    private var rawCapture = RawCaptureWindow()
    /// #47: buffer the (raw frame, pre-parsed) pair. The raw bytes are still needed for the raw-capture
    /// outbox; the parse is the one the BLE seam already did, so `flush` doesn't re-decode the batch.
    private var buffer: [BufferedFrame] = []
    /// Standard 0x2A37 HR/RR buffer — the reliable, always-on stream, recorded continuously
    /// (independent of the custom realtime stream or which screen is open).
    private var stdHR: [OwnedSample<HRSample>] = []
    private var stdRR: [OwnedSample<RRInterval>] = []
    private var batchStartedAt: TimeInterval
    /// BLE-11 / CC-6: at most one cadence flush per buffer at a time, coalesced follow-ups, failure backoff.
    private var frameFlushScheduler = FlushScheduler()
    private var standardFlushScheduler = FlushScheduler()
    /// Diagnostics sink for dropped-buffer notices (wired to the strap log by BLEManager).
    var log: (@MainActor (String) -> Void)?
    var bufferedCount: Int { buffer.count }

    init(store: StoreWriting, deviceId: String,
         policy: CollectorPolicy = .default,
         enableRawCapture: Bool = false,
         now: @escaping () -> Int = { Int(Date().timeIntervalSince1970) },
         monotonic: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }) {
        self.store = store; self.deviceId = deviceId; self.policy = policy
        self.enableRawCapture = enableRawCapture
        self.now = now; self.monotonic = monotonic
        self.batchStartedAt = monotonic()
        self.concreteStore = store as? WhoopStore
    }

    /// Light storage summary for the UI. nil if there's no concrete store or the read throws.
    func storageStats() async -> (decodedRows: Int, rawBatches: Int, rawBytes: Int)? {
        guard let s = concreteStore else { return nil }
        return try? await s.storageStats()
    }

    /// Max persisted HR sample ts (the biometric "data frontier" for the stuck-strap watchdog).
    /// nil if there's no concrete store or nothing persisted yet. Mirrors storageStats().
    func latestHRSampleTs() async -> Int? {
        guard let s = concreteStore else { return nil }
        return try? await s.latestHRSampleTs(deviceId: deviceId)
    }

    /// Receipt-backed history frontier across normalized streams and mapped V20/V21 raw records.
    /// This is the continuation signal; the HR-only read above remains the stuck-strap watchdog signal.
    func latestHistoricalDurableFrontier() async -> HistoricalDurableFrontier? {
        guard let s = concreteStore else { return nil }
        return try? await s.latestHistoricalDurableFrontier(deviceId: deviceId)
    }

    /// Recent gravity samples for the inactivity reminder (#419): the strap's motion over `[from, to]`,
    /// the input to the shipped `SedentaryDetector`. Empty if there's no concrete store or the read
    /// throws. Mirrors latestHRSampleTs() — the BLE offload hook reads gravity through the Collector
    /// because the Collector owns the concrete store.
    func recentGravity(from: Int, to: Int, limit: Int = 100_000) async -> [GravitySample] {
        guard let s = concreteStore else { return [] }
        return (try? await s.gravitySamples(deviceId: deviceId, from: from, to: to, limit: limit)) ?? []
    }

    /// Apply the raw-retention policy. Returns rows pruned (0 if no concrete store).
    @discardableResult
    func prune() async -> Int {
        guard let s = concreteStore else { return 0 }
        return (try? await s.pruneRaw(now: now(),
                                keepWindowSeconds: PrunePolicy.keepWindowSeconds,
                                maxUnsyncedBytes: PrunePolicy.maxUnsyncedBytes)) ?? 0
    }

    /// Parse-then-buffer shim (#47). Kept for callers/tests that pass raw bytes; the live seam calls
    /// `ingest(frame:parsed:)` with the parse it already did.
    func ingest(_ frame: [UInt8]) {
        ingest(frame: frame, parsed: parseFrame(frame, family: family))
    }

    /// Buffer one complete frame + its pre-parsed decode (synchronous: preserves delegate arrival order).
    /// Auto-flushes via a detached Task when the cadence threshold is hit (flush is async). (#47)
    func ingest(frame: [UInt8], parsed: ParsedFrame) {
        #if DEBUG
        assert(parsed == parseFrame(frame, family: family),
               "Collector.ingest: threaded ParsedFrame != fresh parse (#47 parse-once invariant)")
        #endif
        // BLE-4: frames `extractStreams` ignores (chiefly the type-43 R10/R11 raw stream) decode to no
        // rows, so hold them only while raw capture will persist them.
        guard LiveFrameRetention.shouldBuffer(typeName: parsed.typeName,
                                              rawCaptureActive: enableRawCapture
                                                  || rawCapture.isActive(at: monotonic())) else { return }
        buffer.append(BufferedFrame(
            frame: frame, parsed: parsed,
            context: FrameContext(owner: intakeOwner, clockRef: clockRef)))
        // Pre-clock only: bound memory if GET_CLOCK never lands while data keeps flowing.
        // Drop OLDEST beyond the cap (keep most recent). Post-clock this branch is skipped —
        // the cadence flush below bounds the buffer instead.
        if clockRef == nil {
            let uncorrelated = buffer.reduce(0) { $0 + ($1.context.clockRef == nil ? 1 : 0) }
            var drop = max(0, uncorrelated - policy.maxPreClockFrames)
            buffer.removeAll { entry in
                guard drop > 0, entry.context.clockRef == nil else { return false }
                drop -= 1
                return true
            }
        }
        trimFrameBuffer()
        guard clockRef != nil || buffer.contains(where: { $0.context.clockRef != nil }) else { return }
        let readyCount = buffer.reduce(0) { $0 + ($1.context.clockRef == nil ? 0 : 1) }
        if readyCount >= policy.maxFrames || (monotonic() - batchStartedAt) >= policy.maxInterval {
            requestFrameFlush()
        }
    }

    /// BLE-11: start a cadence flush only when none is running and no failure backoff is pending; a
    /// request made meanwhile becomes one follow-up pass instead of one more concurrent flush per frame.
    private func requestFrameFlush() {
        guard frameFlushScheduler.request(now: monotonic()) else { return }
        Task { @MainActor in
            var again = true
            while again {
                let ok = await self.flushFrames()
                again = self.frameFlushScheduler.finish(success: ok, now: self.monotonic())
            }
        }
    }

    private func trimFrameBuffer() {
        let drop = FlushScheduler.overflow(count: buffer.count, cap: policy.maxBufferedFrames)
        guard drop > 0 else { return }
        buffer.removeFirst(drop)
        log?("Collector: dropped \(drop) oldest buffered live frame(s) (store not keeping up)")
    }

    /// Persist + queue everything buffered. No-op when empty or before a clock ref exists.
    /// Buffer is snapshotted and cleared SYNCHRONOUSLY before the first await so that any
    /// concurrent ingest() calls during persistence accumulate into the NEXT batch cleanly.
    func flush() async {
        await flushFrames()
    }

    /// One flush pass; false when the decoded insert failed (the batch is re-buffered).
    @discardableResult
    private func flushFrames() async -> Bool {
        let pending = buffer.filter { $0.context.clockRef != nil }
        guard !pending.isEmpty else { return true }
        // SNAPSHOT + CLEAR before any await: decoded-before-raw ordering AND the
        // buffer-snapshot-before-await invariant are both satisfied here.
        buffer.removeAll { $0.context.clockRef != nil }
        // CC-6: the interval restarts when the batch is taken, not after the insert succeeds; retries
        // after a failure are paced by the FlushScheduler backoff instead of firing on every frame.
        batchStartedAt = monotonic()

        let captureRaw = enableRawCapture || rawCapture.isActive(at: monotonic())
        var start = 0
        while start < pending.count {
            let context = pending[start].context
            var end = start + 1
            while end < pending.count, pending[end].context == context { end += 1 }
            let batch = pending[start..<end]
            guard let ref = context.clockRef else { preconditionFailure("ready batch has no clock") }
            let frames = batch.map(\.frame)
            let parsed = batch.map(\.parsed)
            let family = context.owner.family
            let streams = await Task.detached(priority: .utility) {
                extractStreams(parsed, family: family, deviceClockRef: ref.device, wallClockRef: ref.wall)
            }.value
            do {
                try await store.insert(streams, deviceId: context.owner.deviceId)
            } catch {
                // Retry only uncommitted batches, retaining each original owner, family and clock.
                buffer.insert(contentsOf: pending[start...], at: 0)
                trimFrameBuffer()
                return false
            }
            if captureRaw {
                let wall = now()
                let tsValues = streams.hr.map(\.ts) + streams.rr.map(\.ts)
                    + streams.events.map(\.ts) + streams.battery.map(\.ts)
                let meta = RawBatchMeta(
                    batchId: UUID().uuidString, deviceId: context.owner.deviceId,
                    clockRef: ref, capturedAt: wall,
                    startTs: tsValues.min() ?? wall, endTs: tsValues.max() ?? wall,
                    frameCount: frames.count, byteSize: frames.reduce(0) { $0 + $1.count })
                try? await store.enqueueRawBatch(meta, frames: frames)
            }
            start = end
        }
        return true
    }

    // MARK: - Standard 0x2A37 HR/RR (continuous recording)

    /// Buffer one standard Heart-Rate-Measurement reading. No clock correlation needed —
    /// these carry a wall-clock `ts` directly. Auto-flushes ~every 30 readings (~30s).
    func ingestStandardHR(hr: Int, rr: [Int], at ts: Int,
                          source: RRSource = .standardBLE) {
        let owner = intakeOwner
        if hr >= 30, hr <= 220 { stdHR.append(OwnedSample(sample: HRSample(ts: ts, bpm: hr), owner: owner)) }
        for (ordinal, r) in rr.enumerated() where r >= 250 && r <= 3000 {
            stdRR.append(OwnedSample(
                sample: RRInterval(ts: ts, rrMs: r, sourceOrdinal: ordinal, source: source), owner: owner))
        }
        trimStandardBuffers()
        if stdHR.count + stdRR.count >= 30, standardFlushScheduler.request(now: monotonic()) {
            // BLE-11: one standard-HR flush at a time (coalesced follow-up, failure backoff).
            Task { @MainActor in
                var again = true
                while again {
                    let ok = await self.flushStandardSamples()
                    again = self.standardFlushScheduler.finish(success: ok, now: self.monotonic())
                }
            }
        }
    }

    /// Persist the buffered standard HR/RR. Re-buffers on failure so nothing is lost.
    func flushStandardHR() async {
        await flushStandardSamples()
    }

    @discardableResult
    private func flushStandardSamples() async -> Bool {
        guard !stdHR.isEmpty || !stdRR.isEmpty else { return true }
        let hr = stdHR, rr = stdRR
        stdHR.removeAll(keepingCapacity: true)
        stdRR.removeAll(keepingCapacity: true)
        let hrByOwner = Dictionary(grouping: hr, by: \.owner)
        let rrByOwner = Dictionary(grouping: rr, by: \.owner)
        let owners = Set(hrByOwner.keys).union(rrByOwner.keys).sorted { $0.generation < $1.generation }
        for (index, owner) in owners.enumerated() {
            do {
                try await store.insert(Streams(
                    hr: hrByOwner[owner, default: []].map(\.sample),
                    rr: rrByOwner[owner, default: []].map(\.sample)), deviceId: owner.deviceId)
            } catch {
                let remaining = Set(owners[index...])
                stdHR.insert(contentsOf: hr.filter { remaining.contains($0.owner) }, at: 0)
                stdRR.insert(contentsOf: rr.filter { remaining.contains($0.owner) }, at: 0)
                trimStandardBuffers()
                return false
            }
        }
        return true
    }

    private func trimStandardBuffers() {
        let dropHR = FlushScheduler.overflow(count: stdHR.count, cap: policy.maxStandardSamples)
        let dropRR = FlushScheduler.overflow(count: stdRR.count, cap: policy.maxStandardSamples)
        guard dropHR > 0 || dropRR > 0 else { return }
        stdHR.removeFirst(dropHR)
        stdRR.removeFirst(dropRR)
        log?("Collector: dropped \(dropHR) HR / \(dropRR) R-R oldest buffered standard sample(s) (store not keeping up)")
    }

    // MARK: - On-demand raw capture

    /// Open a bounded raw-capture window so the next flushes persist raw even with the global
    /// research toggle off. Auto-expires at the (clamped) monotonic deadline.
    func beginRawCapture(seconds: TimeInterval) {
        rawCapture.open(at: monotonic(), duration: seconds)
    }

    /// Flush WHILE the window is still active so the just-captured frames get persisted as raw,
    /// THEN close the window.
    func endRawCapture() async {
        await flush()
        rawCapture.close()
    }
}
