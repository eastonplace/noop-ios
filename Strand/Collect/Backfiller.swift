import Foundation
import WhoopProtocol
import WhoopStore
import StrandAnalytics

// MARK: - BackfillStoreWriting protocol

/// The async subset the Backfiller needs. Plain async protocol (not @MainActor) so both the
/// real WhoopStore actor and a @MainActor SpyBackfillStore in tests can satisfy it.
protocol BackfillStoreWriting: AnyObject, Sendable {
    func commitHistoricalChunk(
        streams: Streams,
        deviceId: String,
        trim: Int,
        chunkEndUnix: Int,
        rawBatch: HistoricalRawBatch?,
        committedAt: Int,
        scope: HistoricalCursorScope,
        fingerprint: String,
        fingerprintInput: HistoricalReceivedFrameFingerprintInput,
        rawCaptureStatus: HistoricalRawCaptureStatus?,
        rawRange: HistoricalRawRangeEvidence?,
        burst: HistoricalDataCommitBurst?,
        timestampHeal: HistoricalTimestampHeal?,
        isFinal: Bool
    ) async throws -> HistoricalDataCommitReceipt
    func commitHistoricalChunkResult(
        streams: Streams,
        deviceId: String,
        trim: Int,
        chunkEndUnix: Int,
        rawBatch: HistoricalRawBatch?,
        committedAt: Int,
        scope: HistoricalCursorScope,
        fingerprint: String,
        fingerprintInput: HistoricalReceivedFrameFingerprintInput,
        rawCaptureStatus: HistoricalRawCaptureStatus?,
        rawRange: HistoricalRawRangeEvidence?,
        burst: HistoricalDataCommitBurst?,
        timestampHeal: HistoricalTimestampHeal?,
        isFinal: Bool
    ) async throws -> HistoricalCommitResult
    @discardableResult
    func insert(_ streams: Streams, deviceId: String) async throws
        -> (hr: Int, rr: Int, events: Int, battery: Int,
            spo2: Int, skinTemp: Int, resp: Int, gravity: Int)
    func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws
    func setCursor(_ name: String, _ value: Int) async throws
    func cursor(_ name: String) async throws -> Int?
}

extension BackfillStoreWriting {
    /// Existing test/import stores are inserts unless they explicitly model a replay. WhoopStore supplies
    /// the concrete race-safe implementation and reports `.replayed` for an exact durable receipt.
    func commitHistoricalChunkResult(
        streams: Streams,
        deviceId: String,
        trim: Int,
        chunkEndUnix: Int,
        rawBatch: HistoricalRawBatch?,
        committedAt: Int,
        scope: HistoricalCursorScope,
        fingerprint: String,
        fingerprintInput: HistoricalReceivedFrameFingerprintInput,
        rawCaptureStatus: HistoricalRawCaptureStatus?,
        rawRange: HistoricalRawRangeEvidence?,
        burst: HistoricalDataCommitBurst?,
        timestampHeal: HistoricalTimestampHeal?,
        isFinal: Bool
    ) async throws -> HistoricalCommitResult {
        let receipt = try await commitHistoricalChunk(
            streams: streams,
            deviceId: deviceId,
            trim: trim,
            chunkEndUnix: chunkEndUnix,
            rawBatch: rawBatch,
            committedAt: committedAt,
            scope: scope,
            fingerprint: fingerprint,
            fingerprintInput: fingerprintInput,
            rawCaptureStatus: rawCaptureStatus,
            rawRange: rawRange,
            burst: burst,
            timestampHeal: timestampHeal,
            isFinal: isFinal
        )
        return HistoricalCommitResult(receipt: receipt, outcome: .inserted)
    }
}

extension WhoopStore: BackfillStoreWriting {}

/// Receipt plus the durable source identity returned by the scoped commit.
struct HistoricalCommitContext: Equatable, Sendable {
    let receipt: HistoricalDataCommitReceipt
    let sourceIdentity: HistoricalReceiptWatermark.SourceIdentity
}

enum BackfillFailure: Equatable, Sendable {
    case integrity(trim: UInt32)
    case fingerprint(trim: UInt32)
    case commit(trim: UInt32)
    case acknowledgment(trim: UInt32)
    case rejectedArchive(trim: UInt32)
}

// MARK: - Backfiller

/// Historical-offload state machine (idle / backfilling).
///
/// Per-chunk local safe-trim invariant:
///   decode known → archive genuine rejects →
///   await commitHistoricalChunk (decoded rows + optional raw + strap_trim + receipt) →
///   ackTrim (link-layer confirmed ack to strap)
///
/// A chunk is forgotten only after its receipt is durable and the ack (.withResponse) is link-layer
/// confirmed. Never waits on the server.
@MainActor
final class Backfiller {
    /// (parsed frames, deviceClockRef, wallClockRef, sessionOldestUnix?, sessionNewestUnix?) → Streams.
    /// The trailing session-range markers are the strap's GET_DATA_RANGE oldest/newest for THIS sync
    /// (#547 session-relative gate); nil when the range isn't known yet (the absolute-only floor applies).
    typealias Extractor = @Sendable ([ParsedFrame], Int, Int, Int?, Int?) -> Streams
    typealias Parser = @Sendable ([UInt8], DeviceFamily) -> ParsedFrame

    private let store: BackfillStoreWriting
    /// Current device id for the next session. An admitted session never reads this after decode starts;
    /// `sourceIdentity` is frozen at `begin` so a source switch cannot re-attribute suspended work.
    var deviceId: String
    /// Source identity captured at session admission. The identity remains stable across every chunk in
    /// the session and is carried through the commit callback even when the mutable current id changes.
    private(set) var sourceIdentity: HistoricalReceiptWatermark.SourceIdentity
    /// Durable cursor scope captured at session admission. The caller resolves it from the registry before
    /// SEND_HISTORICAL. The store validates this unchanged scope, so a stale lineage or epoch fails closed.
    private(set) var historicalCursorScope: HistoricalCursorScope?
    /// Confirms one HISTORY_END chunk to the strap. Carries the admitted durable scope, the trim cursor
    /// (= first u32 of end_data, used for the `strap_trim` cursor), and the 8-byte `end_data` (= the raw
    /// HISTORY_END metadata.data[10:18]) that the high-freq-sync ack form requires verbatim. The caller
    /// returns only after CoreBluetooth confirms this exact write on the admitted connection.
    private let ackTrim: (_ scope: HistoricalCursorScope, _ trim: UInt32, _ endData: [UInt8]) async -> Bool
    private let extract: Extractor
    private let parse: Parser
    /// Research toggle. When false (DEFAULT) no raw frames are persisted — the chunk's
    /// decoded streams are still durable and the trim is still acked (decoded is the product of
    /// record). Injected for tests; backed by UserDefaults in the production init site.
    private let enableRawCapture: Bool

    /// The clock reference set by BLEManager when GET_CLOCK confirms (required for decoding).
    var clockRef: ClockRef?

    /// #547 SESSION-RELATIVE gate: the strap's own GET_DATA_RANGE oldest/newest banked-record markers for
    /// the CURRENT offload, set by BLEManager when the range reply lands. A record dated months outside this
    /// window is wandering-clock pollution even if it clears the absolute 2023-11 floor, so the ingest gate
    /// rejects it. nil (both) until the range is known — the gate then falls back to the absolute floor only,
    /// so behaviour is unchanged on the no-range / replay paths. Reset in `begin`.
    var sessionOldestUnix: Int?
    var sessionNewestUnix: Int?

    /// True while a historical offload session is active.
    private(set) var isBackfilling = false
    /// Monotonic admission token for this Backfiller instance. A decoded chunk may suspend while another
    /// session is admitted; that older task may commit its own scoped receipt, but it must never mutate or
    /// ACK through the newer session.
    private var sessionGeneration = 0

    /// Buffered data frames for the current open chunk (between START and END).
    private var chunk: [[UInt8]] = []
    /// Exact HISTORY_START metadata for the admitted protocol session. It is part of the received-frame
    /// identity but is kept separate from the data frames and exact HISTORY_END evidence.
    private var sessionProtocolMetadata = Data()
    /// Whether a START has been received and we're accumulating a chunk.
    private var chunkOpen = false
    /// Strap family for the current offload, set at begin(). Drives family-aware frame parsing (WHOOP 5/MG
    /// records sit at +4 offsets vs WHOOP 4.0) and the end_data slice the ack needs. Captured at begin()
    /// rather than init so it's correct even if the Backfiller was constructed before the strap was known.
    private var family: DeviceFamily = .whoop4

    /// Diagnostic sink (strap log). Surfaces historical records whose firmware layout we can't decode.
    private let log: ((String) -> Void)?
    /// Versions already reported this session, so the diagnostic logs each once (no spam).
    private var loggedUnmappedVersions: Set<Int> = []

    /// Per-session persistence tally — the success-side observability the log forensics flagged as the
    /// blind spot (#150): we logged FAILURES (decoded-to-0) but never SUCCESSES, so a strap log couldn't
    /// tell a banking strap from a broken one. Reset at begin(); read by BLEManager at session end to emit
    /// "persisted N rows (M with motion) across K night(s)". Nights are day-keys (ts / 86400).
    private(set) var sessionRowsPersisted = 0
    /// Valid V20/V21 records banked as one packed raw batch for deferred materialization. These records
    /// are durable sensor progress even though they intentionally do not expand into per-sample rows on
    /// the BLE/ACK path.
    private(set) var sessionMappedRawRecords = 0
    /// Fresh durable timestamps from receipts created in this session. Replayed receipts never update
    /// these fields, so the BLE continuation layer cannot mistake a lost-ACK retry for new progress.
    private(set) var sessionNormalizedMaxTs: Int?
    private(set) var sessionMappedRawMaxTs: Int?
    var sessionDurableMaxTs: Int? {
        [sessionNormalizedMaxTs, sessionMappedRawMaxTs].compactMap { $0 }.max()
    }
    /// Fingerprint of the final chunk whose exact trim ACK was confirmed in this session.
    private(set) var sessionLastAckedFingerprint: String?
    /// #42: set by `begin` when this session continues an auto-continue burst (#364) that already banked
    /// rows in an earlier session, so a trim=0xFFFFFFFF END here reads as "caught up", not "no history".
    /// Without it the fresh session's `sessionRowsPersisted` is 0 and the scary "charge to 100%" line
    /// false-fires on the empty tail of a sync that just offloaded real records.
    private(set) var continuedAfterRows = false
    /// #57: set true the moment ANY chunk's persist (decoded rows / reject archive / raw enqueue / trim
    /// cursor) fails this session. While set, `finishChunk` must NOT ack — not even a subsequent EMPTY END,
    /// which skips the insert and would otherwise advance the strap's trim PAST the held records-carrying
    /// chunks, freeing history we never stored. The offload stalls safely (strap keeps everything past the
    /// last GOOD ack); a fresh session (`begin`) clears it. Twin of the Android guard. Exposed read-only so
    /// the client can surface a "history isn't persisting" signal in the debug export (#57).
    private(set) var persistStalled = false
    private(set) var sessionMotionRows = 0
    /// #727: skin-temp samples banked this session. WHOOP 4.0 carries skin temp (and the raw SpO2 channel)
    /// ONLY in its full DSP sleep records; a strap banking HR/RR-only records reports 0 here even on a
    /// healthy-looking sync, so surfacing it makes "skin temp never appears" reports self-diagnosing.
    private(set) var sessionSkinTempRows = 0
    private(set) var sessionNightKeys: Set<Int> = []
    var sessionNights: Int { sessionNightKeys.count }

    /// #67 diag: the clock reference the offload ACTUALLY decoded with, captured on the first chunk of the
    /// session. Surfaces whether the stale-RTC timestamp correction (FIX #72's `correctedWall`) could even
    /// engage. `sessionUsedIdentityRef` = no clock correlation had landed when the first chunk decoded, so
    /// that decode fell back to an identity
    /// ref (device==wall==now) → clock offset 0 → correction OFF. On a strap whose RTC has reset, that
    /// silently stores the strap's stale (years-old) timestamps verbatim, so the night lands off the recent
    /// timeline and reads as "missed sleep". Paired with the persisted-nights DATE RANGE below, one strap
    /// log now shows both WHERE the rows landed and WHY. Reset in begin(). Log-only.
    private(set) var sessionClockDevice: Int?
    private(set) var sessionClockWall: Int?
    private(set) var sessionUsedIdentityRef = false
    /// Logged once per session when the strap reports trim=0xFFFFFFFF — the "no valid flash cursor"
    /// sentinel: it has no banked history to offload (a clock/charge state, not a decode bug).
    private var loggedNoCursor = false
    /// #773: logged once per session the first time a HISTORY_END's own timestamp is dated implausibly far
    /// in the FUTURE (a corrupt strap RTC). Distinct from #547's per-record drop tally: this fires on the
    /// chunk metadata's own clock, the earliest visible tell that the strap's RTC is bogus. Reset in begin().
    private var loggedFutureRtc = false

    /// #547: running count of historical records DROPPED this session for an implausible own-timestamp
    /// (a bad-clock strap — far-past / bogus-2027 / future-dated). Tallied across chunks and surfaced once
    /// at a session boundary so a clock-broken strap is visible in the strap log (observability only — the
    /// ingest gate already kept the garbage rows out of the DB).
    private(set) var sessionDroppedImplausible = 0

    /// The trim cursor of the LAST chunk this Backfiller acked (durably persisted + confirmed to the
    /// strap). Survives across sessions on the same connection so the auto-continue gate (#364) can ask
    /// "did the offload actually advance the strap's trim this session?" — the spin-detector signal that
    /// stops it re-kicking forever when the cursor is frozen. nil until the first ack. NOT reset in
    /// `begin()` (it's a cross-session high-water mark, not a per-session tally).
    private(set) var lastAckedTrim: UInt32?

    /// Distinct historical layout versions logged this session. Unlike `loggedUnmappedVersions` (which
    /// only fires for layouts NOOP can't decode), this surfaces the layout on a HEALTHY sync too, so a
    /// shared strap log always reveals what the strap emits (v18/v24/v25/v26). Mirrors the Android
    /// Backfiller (PR #241, ryanbr); reset per session in `begin`.
    private var loggedLayoutVersions: Set<Int> = []

    /// SpO2 RE dump (PR #945, reimplemented): how many full-record dumps this session emitted, bounded by
    /// `Spo2ReTrace.maxSamples`. Session-scoped so the cap spans chunks; reset per session in `begin`.
    private var spo2Dumped = 0

    /// Durably archives undecodable record frames BEFORE the trim ack (#77 / #91). Returns true once
    /// the bytes are safe (written OR cap-reached — either way the chunk may be acked) and false on a
    /// genuine write failure, in which case `finishChunk` holds the cursor/ack so the strap re-sends.
    /// nil in non-production inits (tests/preview) → archiving is skipped and acks proceed as before.
    private let rejectedSink: ((_ frames: [[UInt8]], _ trim: UInt32, _ family: DeviceFamily) -> Bool)?
    /// One durable receipt per atomically committed chunk. BLE owns coalescing so this hook never causes
    /// per-chunk Repository or SwiftUI work. It fires before the strap ACK.
    private let onHistoricalCommit: ((HistoricalDataCommitReceipt) -> Void)?
    /// Context-aware handoff seam. This is the producer-owned source identity until the receipt schema
    /// carries durable lineage/epoch fields itself.
    private let onHistoricalCommitContext: ((HistoricalCommitContext) -> Void)?
    /// Runs only after Core Bluetooth confirms the exact trim ACK. Deferred materialization is scheduled
    /// through this seam so large V20/V21 work can never move back onto the save-before-ACK path.
    private let onHistoricalAcknowledged: ((HistoricalDataCommitReceipt, HistoricalCommitOutcome) -> Void)?
    /// Deterministic async test seam. Production leaves this nil; tests can pause after detached decode
    /// and switch the mutable current source before the commit resumes.
    private let beforeHistoricalCommit: (() async -> Void)?
    /// Per-chunk outcome hook (#77 family): (didDecodeSensorRows, wasConsoleOnly). Lets BLEManager
    /// tally a session so a COMPLETED-but-empty offload (all console, no sensor records) can tell the
    /// user their strap isn't banking, without false-positiving a normal caught-up sync.
    private let onChunk: ((_ decoded: Bool, _ console: Bool) -> Void)?

    /// Connection & Sync test mode (Test Centre): the cheap gate + tagged sink for the .connection
    /// diagnostic lines (offload progress / firmware layout / trim sentinel). `connectionActive` is one
    /// UserDefaults bool read; we ALWAYS check it BEFORE building any connection line, so the Backfiller
    /// pays nothing when the mode is off. `connectionLog` appends the already-built line tagged .connection.
    /// Both default inert (always-off / nil) so tests + non-prod inits get the byte-identical untraced path.
    private let connectionActive: () -> Bool
    private let connectionLog: ((String) -> Void)?
    /// UNIVERSAL clock-drift wiring (RTC cluster): banks the strap's historical record-layout version
    /// (hist_version) onto LiveState so the export assembler's universal clock-drift line is firmware-aware
    /// on EVERY export, not only in Connection mode. Called UNCONDITIONALLY (it is observability, not gated)
    /// once per distinct layout this session. Default nil (inert) so tests / non-prod inits are untouched.
    private let firmwareLayout: ((Int) -> Void)?
    private let onFailure: ((BackfillFailure) -> Void)?

    init(store: BackfillStoreWriting,
         deviceId: String,
         ackTrim: @escaping (_ scope: HistoricalCursorScope, _ trim: UInt32, _ endData: [UInt8]) async -> Bool,
         enableRawCapture: Bool = false,
         log: ((String) -> Void)? = nil,
         rejectedSink: ((_ frames: [[UInt8]], _ trim: UInt32, _ family: DeviceFamily) -> Bool)? = nil,
         onHistoricalCommit: ((HistoricalDataCommitReceipt) -> Void)? = nil,
         onHistoricalCommitContext: ((HistoricalCommitContext) -> Void)? = nil,
         onHistoricalAcknowledged: ((HistoricalDataCommitReceipt, HistoricalCommitOutcome) -> Void)? = nil,
         beforeHistoricalCommit: (() async -> Void)? = nil,
         onChunk: ((_ decoded: Bool, _ console: Bool) -> Void)? = nil,
         sourceIdentity: HistoricalReceiptWatermark.SourceIdentity? = nil,
         connectionActive: @escaping () -> Bool = { false },
         connectionLog: ((String) -> Void)? = nil,
         firmwareLayout: ((Int) -> Void)? = nil,
         onFailure: ((BackfillFailure) -> Void)? = nil,
         // The default (prod) Extractor reads the opt-in HR-from-PPG sub-lag interpolation flag (Test Centre →
         // Experimental algorithms) at decode time and threads it into the pure decoder, so the pure package
         // never reaches for UserDefaults. Default OFF = byte-identical to today. Tests inject their own seam.
         extract: @escaping Extractor = { extractHistoricalStreams($0, deviceClockRef: $1, wallClockRef: $2,
                                                                    sessionOldestUnix: $3, sessionNewestUnix: $4,
                                                                    subLagInterp: PuffinExperiment.ppgHrSubLagInterpEnabled) },
         parse: @escaping Parser = { parseFrame($0, family: $1) }) {
        self.store = store
        let admittedSource = sourceIdentity ?? HistoricalReceiptWatermark.SourceIdentity(deviceId: deviceId)
        self.deviceId = deviceId
        self.sourceIdentity = admittedSource
        self.historicalCursorScope = nil
        self.ackTrim = ackTrim
        self.enableRawCapture = enableRawCapture
        self.log = log
        self.rejectedSink = rejectedSink
        self.onHistoricalCommit = onHistoricalCommit
        self.onHistoricalCommitContext = onHistoricalCommitContext
        self.onHistoricalAcknowledged = onHistoricalAcknowledged
        self.beforeHistoricalCommit = beforeHistoricalCommit
        self.onChunk = onChunk
        self.connectionActive = connectionActive
        self.connectionLog = connectionLog
        self.firmwareLayout = firmwareLayout
        self.onFailure = onFailure
        self.extract = extract
        self.parse = parse
    }

    private func fail(_ failure: BackfillFailure) {
        persistStalled = true
        isBackfilling = false
        chunk.removeAll(keepingCapacity: true)
        chunkOpen = false
        onFailure?(failure)
    }

    /// Emit one Connection & Sync test-mode line iff the mode is on. The cheap `connectionActive()` gate is
    /// checked BEFORE `build()` runs, so the line string is never constructed when the mode is off (the
    /// @autoclosure defers it). Diagnostic only - it never changes the offload path.
    private func emitConnection(_ build: @autoclosure () -> String) {
        guard connectionActive(), let connectionLog else { return }
        connectionLog(build())
    }

    /// Called by BLEManager when the strap signals a historical offload is beginning.
    /// chunkOpen starts TRUE: the high-freq-sync biometric replay streams records immediately and
    /// sends one HISTORY_START then repeated HISTORY_ENDs, so we must accumulate from the outset.
    func begin(
        family: DeviceFamily,
        continuedAfterRows: Bool = false,
        sourceIdentity: HistoricalReceiptWatermark.SourceIdentity? = nil,
        historicalCursorScope: HistoricalCursorScope
    ) {
        sessionGeneration &+= 1
        self.family = family
        self.historicalCursorScope = historicalCursorScope
        if let sourceIdentity {
            self.sourceIdentity = sourceIdentity
        } else if self.sourceIdentity.deviceId != deviceId {
            // Preserve the old convenience call for tests and replay paths while still freezing the id
            // before the first decode of a newly admitted session.
            self.sourceIdentity = HistoricalReceiptWatermark.SourceIdentity(deviceId: deviceId)
        }
        self.continuedAfterRows = continuedAfterRows
        isBackfilling = true
        persistStalled = false   // #57: fresh session starts un-stalled
        chunk.removeAll(keepingCapacity: true)
        sessionProtocolMetadata.removeAll(keepingCapacity: true)
        chunkOpen = true
        sessionRowsPersisted = 0
        sessionMappedRawRecords = 0
        sessionNormalizedMaxTs = nil
        sessionMappedRawMaxTs = nil
        sessionLastAckedFingerprint = nil
        sessionMotionRows = 0
        sessionSkinTempRows = 0
        sessionNightKeys.removeAll(keepingCapacity: true)
        sessionClockDevice = nil          // #67: re-capture the decode clock ref for this session
        sessionClockWall = nil
        sessionUsedIdentityRef = false
        loggedNoCursor = false
        loggedFutureRtc = false
        sessionDroppedImplausible = 0
        loggedLayoutVersions.removeAll(keepingCapacity: true)
        spo2Dumped = 0
        // #547: the range markers belong to a connection's GET_DATA_RANGE, which BLEManager re-sets per
        // connect; clear them here so a fresh session never reuses a previous strap's window. BLEManager
        // re-publishes them as soon as the range reply arrives.
        sessionOldestUnix = nil
        sessionNewestUnix = nil
    }

    /// Feed one raw BLE frame into the state machine. May trigger async store operations.
    func ingest(_ frame: [UInt8]) async {
        switch classifyHistoricalMeta(parseFrame(frame, family: family)) {
        case .start:
            sessionProtocolMetadata = Data(frame)
            isBackfilling = true
            chunk.removeAll(keepingCapacity: true)
            chunkOpen = true
        case .end(let unix, let trim):
            await finishChunk(unix: unix, trim: trim, endFrame: frame)
        case .complete:
            isBackfilling = false
            chunk.removeAll(keepingCapacity: true)
            chunkOpen = false
        case .other:
            if chunkOpen { chunk.append(frame) }
        }
    }

    /// The 8-byte `end_data` the high-freq-sync ack requires: metadata.data[10:18].
    /// metadata.data begins at frame[7] (after [type,seq,cmd]), so end_data = frame[17:25].
    /// trim cursor = the first u32 of end_data (data[10:14]). Returns nil if the frame is too
    /// short to contain the field (shouldn't happen for a real HISTORY_END, which is >=14 data
    /// bytes, but guards against a malformed frame).
    static func endData(from frame: [UInt8], family: DeviceFamily) -> [UInt8]? {
        // metadata.data begins at frame[7] (WHOOP4) / frame[11] (WHOOP5, the +4 puffin envelope); the
        // ack's end_data = data[10:18] → frame[17:25] (WHOOP4) or frame[21:29] (WHOOP5). The WHOOP5 slice
        // is verified on a real HISTORY_END (trim=112193 = frame[21..25]) in Whoop5HistoricalTests.
        let start = family == .whoop5 ? 21 : 17
        guard frame.count >= start + 8 else { return nil }
        return Array(frame[start..<(start + 8)])
    }

    /// Pure per-chunk persistence tally (#150). `rows` = biometric rows actually inserted (HR, R-R, SpO2,
    /// skin-temp, resp, gravity, steps, sleep state, and PPG — battery/events are housekeeping, not biometric
    /// history). `motion` =
    /// gravity rows (the sleep-critical signal). `nights` = the distinct day-keys (ts / 86400) the chunk's
    /// records covered. Summed across a session by finishChunk to drive the success summary line.
    nonisolated static func chunkTally(
        counts: HistoricalStreamInsertCounts,
        timestamps: [Int]
    ) -> (rows: Int, motion: Int, nights: Set<Int>) {
        let biometricRows = counts.hr
            + counts.rr
            + counts.spo2
            + counts.skinTemp
            + counts.resp
            + counts.gravity
            + counts.steps
            + counts.sleepState
            + counts.ppgHr
            + counts.ppgWaveform
        return (biometricRows, counts.gravity, Set(timestamps.map { $0 / 86400 }))
    }

    /// The one-line session success summary (#150) — the success-side log that never existed. Returns nil
    /// when nothing persisted (so a console-only / caught-up session stays quiet and the existing
    /// empty-banking diagnostics speak instead).
    nonisolated static func sessionSummaryLine(
        rows: Int,
        motion: Int,
        skinTemp: Int,
        nights: Int,
        mappedRawRecords: Int = 0
    ) -> String? {
        guard rows > 0 || mappedRawRecords > 0 else { return nil }
        let rawClause = mappedRawRecords > 0 ? ", \(mappedRawRecords) mapped raw record(s)" : ""
        return "Backfill: session persisted \(rows) rows (\(motion) with motion, \(skinTemp) skin-temp\(rawClause)) across \(nights) night(s)."
    }

    /// #67 diag: the persisted-nights DATE RANGE plus the offload's effective clock state — the two facts
    /// the summary above omits. `nightKeys` are UTC day-keys (ts / 86400); their min/max are the day(s) the
    /// rows LANDED on. When those days sit years in the past while the clock ref reads ~now (an identity
    /// fallback, or an in-sync ref on a strap that banked stale), the night is misdated off the recent
    /// timeline — the "missed sleep" signature (#67). Returns nil when nothing landed. Log-only, pure.
    nonisolated static func sessionClockDiagLine(nightKeys: Set<Int>,
                                                 device: Int?, wall: Int?, usedIdentityRef: Bool) -> String? {
        guard let lo = nightKeys.min(), let hi = nightKeys.max() else { return nil }
        let day: (Int) -> String = { key in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")   // fixed Gregorian yyyy — not the device calendar
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = TimeZone(identifier: "UTC")
            return f.string(from: Date(timeIntervalSince1970: Double(key) * 86_400))
        }
        let range = lo == hi ? day(lo) : "\(day(lo))…\(day(hi))"
        var line = "Backfill: rows landed on \(range)"
        if let device, let wall {
            let offset = wall - device
            let days = offset / 86_400
            if usedIdentityRef {
                line += " · clock ref: IDENTITY fallback (no clock correlation at decode) - stale-record correction OFF"
            } else if abs(offset) > 86_400 {
                line += " · strap clock \(days >= 0 ? "\(days)d behind" : "\(-days)d ahead") wall - correction engaged"
            } else {
                line += " · clock ref in sync"
            }
        }
        return line
    }

    /// The trim=0xFFFFFFFF sentinel line (#783). 0xFFFFFFFF means two different things depending on whether
    /// THIS run already banked rows. On the first end of a fresh offload it's the "no valid flash cursor"
    /// state (no banked history, a clock/charge problem). But the #364 auto-continuation re-kicks
    /// SEND_HISTORICAL after a run that DID persist rows, and the next end then carries 0xFFFFFFFF to mean
    /// "caught up, nothing left past the last trim", NOT "no history". Emitting the alarming "fully charge
    /// it" line there falsely scared users whose strap had just synced fine. So pick by `rowsPersisted`:
    /// > 0 gives a neutral caught-up line; 0 gives the genuine no-history guidance. Pure so a fixture pins both.
    nonisolated static func noCursorLine(
        rowsPersisted: Int,
        mappedRawRecords: Int = 0,
        continuedAfterRows: Bool = false
    ) -> String {
        if rowsPersisted > 0 || mappedRawRecords > 0 {
            let rawClause = mappedRawRecords > 0 ? " and banking \(mappedRawRecords) mapped raw record(s)" : ""
            return "Backfill: reached the end of available history (trim=0xFFFFFFFF) - caught up after persisting \(rowsPersisted) row(s)\(rawClause) this run. Nothing more to offload."
        }
        // #42: the empty tail of an auto-continue burst (#364) that banked rows in an EARLIER session. The
        // strap synced fine — this pass just confirms we're caught up — so DON'T false-alarm "no banked
        // history / charge to 100%".
        if continuedAfterRows {
            return "Backfill: reached the end of available history (trim=0xFFFFFFFF) - caught up; the strap handed over its banked history earlier this sync. Nothing more to offload."
        }
        return "Backfill: strap reported no flash cursor (trim=0xFFFFFFFF) - it has no banked history to offload. This is a clock/charge state on the strap, not a decode problem; fully charge it and reconnect so it starts banking."
    }

    /// #773: how far ahead of the wall clock a HISTORY_END's own timestamp may sit before we call the strap
    /// RTC corrupt. The strap RTC and the phone normally agree within seconds; a genuine offload is always
    /// dated in the PAST (it's banked history). A timestamp dated days into the FUTURE can only be a corrupt
    /// strap clock. Generous (1 day) so ordinary skew or a timezone confusion never trips it.
    nonisolated static let futureRtcToleranceSeconds = 86_400

    /// #773: is this HISTORY_END timestamp an implausible FUTURE date (a corrupt strap RTC)? `endUnix` and
    /// `wallNowUnix` are unix seconds in the same wall domain. Pure so a fixture pins the boundary.
    nonisolated static func isCorruptFutureRtc(endUnix: Int, wallNowUnix: Int) -> Bool {
        endUnix > wallNowUnix + futureRtcToleranceSeconds
    }

    /// #773: the recovery-hint line for a corrupt future-dated strap RTC. Names the cause plainly (the
    /// strap's clock, not a NOOP bug) and gives the fix (charge + reconnect re-syncs the RTC). Byte-identical
    /// to the Android twin. No em-dash (project rule).
    nonisolated static func futureRtcLine(endUnix: Int, wallNowUnix: Int) -> String {
        let aheadDays = max(0, (endUnix - wallNowUnix)) / 86_400
        return "Backfill: the strap reported a record dated about \(aheadDays) day(s) in the FUTURE - its clock (RTC) is corrupt, not a NOOP problem. Those records can't be filed onto the right day. Fully charge the strap to 100% and reconnect so it re-syncs its clock; if it persists, forget and re-pair the strap."
    }

    /// Commit one HISTORY_END chunk: (persist decoded → enqueueRaw when present) → setCursor → ackTrim.
    /// Early-returns on any throw to preserve the safe-trim invariant.
    ///
    /// CRITICAL: high-freq-sync sends ONE HISTORY_START then REPEATED HISTORY_ENDs (a chunk-close
    /// every ~50 records). So we must ack EVERY end and keep accumulating afterwards — NOT close
    /// the chunk after the first. We snapshot+clear the accumulated frames but leave `chunkOpen`
    /// TRUE so the records following this END become the next chunk. An END with no accumulated
    /// records is still acked (it advances the strap's trim) — that's how the offload progresses.
    /// `endFrame` carries the 8-byte `end_data` the ack requires.
    /// The pure decode result of one offload chunk, produced OFF the main actor (see finishChunk).
    private struct DecodedChunk: Sendable {
        struct MappedRawFrame: Sendable {
            let originalIndex: Int
            let bytes: [UInt8]
            let version: Int
            let unix: Int
        }

        let parsed: [ParsedFrame]
        let decoded: Streams
        let rejected: [[UInt8]]
        let integrityFailures: [[UInt8]]
        let mappedRawFrames: [MappedRawFrame]
        let fingerprintInput: HistoricalReceivedFrameFingerprintInput
        let fingerprint: String
    }

    nonisolated private static func receivedTimestampRange(
        from parsed: [ParsedFrame]
    ) -> (min: Int?, max: Int?) {
        let timestamps = parsed.compactMap { $0.parsed["unix"]?.intValue }
        return (timestamps.min(), timestamps.max())
    }

    private func finishChunk(unix: UInt32, trim: UInt32, endFrame: [UInt8]) async {
        guard let endData = Backfiller.endData(from: endFrame, family: family) else { return }

        // Capture every mutable admission input before the detached decode can suspend. In particular,
        // never read `deviceId` again for this chunk: SourceCoordinator may switch the active strap while
        // the detached task is running.
        guard let admittedScope = historicalCursorScope else {
            log?("Backfill: no durable cursor scope was admitted for this session — holding ack for trim=\(trim).")
            fail(.commit(trim: trim))
            return
        }
        let admittedSessionGeneration = sessionGeneration
        let protocolMetadata = sessionProtocolMetadata

        // #773: corrupt future-RTC detection. A HISTORY_END carries the strap's own clock; a genuine offload
        // is always PAST-dated (it's banked history), so an end dated days into the future can only be a
        // corrupt strap RTC. Surface it ONCE per session with a recovery hint so the cause (the strap clock,
        // not a NOOP bug) is named and the fix (charge + reconnect re-syncs the RTC) is given. Observability
        // only - the ack still proceeds and the #547 ingest gate already keeps the bad-dated rows out of the
        // DB. The 0xFFFFFFFF sentinel above is a different state (it isn't a real date), so skip it here.
        if trim != 0xFFFFFFFF, !loggedFutureRtc {
            let wallNow = Int(Date().timeIntervalSince1970)
            if Backfiller.isCorruptFutureRtc(endUnix: Int(unix), wallNowUnix: wallNow) {
                loggedFutureRtc = true
                log?(Backfiller.futureRtcLine(endUnix: Int(unix), wallNowUnix: wallNow))
            }
        }

        let frames = chunk
        chunk.removeAll(keepingCapacity: true)   // next records accumulate into the next chunk
        var decodedForCommit = Streams()
        var rawBatchForCommit: HistoricalRawBatch?
        var rawClockRef: ClockRef?
        var receivedMinTs: Int?
        var receivedMaxTs: Int?
        var mappedRawVersions: Set<Int> = []
        var mappedRawRecordCount = 0
        var mappedRawFrames: [DecodedChunk.MappedRawFrame] = []
        var preparedFingerprintInput: HistoricalReceivedFrameFingerprintInput?
        var preparedFingerprint: String?
        var chunkHadSensorContent = false
        var chunkWasConsoleOnly = false

        if !frames.isEmpty {
            // type-47 HISTORICAL_DATA carries its OWN real-unix timestamp — extractHistoricalStreams
            // ignores the clock offset for it — so the historical offload does NOT need GET_CLOCK.
            // If the (device,wall) correlation isn't established yet (e.g. GET_CLOCK silent), fall back
            // to an identity ref (device==wall==now): the offset math becomes a no-op, type-47 still
            // decodes to correct wall time, and we can persist + ack + upload. The correlation is only
            // truly required to map REALTIME (type-40/43) device-epoch timestamps, never in a hist chunk.
            let ref = clockRef ?? { let now = Int(Date().timeIntervalSince1970); return ClockRef(device: now, wall: now) }()
            rawClockRef = ref
            // #67 diag: remember the ref (and whether it was the identity fallback) for the session summary,
            // so a strap log shows whether stale-RTC correction could engage. Captured on the first chunk.
            if sessionClockDevice == nil {
                sessionClockDevice = ref.device
                sessionClockWall = ref.wall
                sessionUsedIdentityRef = (clockRef == nil)
            }
            // The heavy decode runs off the main actor. Classification consumes the same ParsedFrame values;
            // it must never call parseFrame a second time because V20/V21 allocate large sample arrays.
            // Every @Published write, the store insert, and the ack/cursor sequence below stay on the main
            // actor in the SAME order, so the persist→archive→cursor→ack trim-safety is untouched.
            let fam = family
            let dev = ref.device, wall = ref.wall
            let oldest = sessionOldestUnix, newest = sessionNewestUnix
            let extractFn = extract   // keep the injected Extractor seam (tests override it); prod == extractHistoricalStreams
            let parseFn = parse
            let decodeTrace = PerformanceTrace.begin("history_chunk_decode")
            let d: DecodedChunk
            do {
                d = try await Task.detached(priority: .utility) { () throws -> DecodedChunk in
                    let parsed = frames.map { parseFn($0, fam) }
                    let decoded = extractFn(parsed, dev, wall, oldest, newest)
                    let dispositions = zip(parsed, frames).map {
                        historicalRecordDisposition(parsed: $0.0, rawFrame: $0.1, family: fam)
                    }
                    let rejected = zip(frames, dispositions).compactMap { frame, disposition in
                        disposition.isRejected ? frame : nil
                    }
                    // Integrity protects the complete received chunk, not only type-47 sensor records.
                    // A damaged START/console frame can otherwise be classified as non-sensor metadata
                    // and get washed away by a later valid END. Keep the reject archive type-specific,
                    // but fail the durable receipt/ACK gate for every unverifiable inbound envelope.
                    let integrityFailures = zip(frames, parsed).compactMap { frame, parsed in
                        guard parsed.ok,
                              parsed.envelopeOK,
                              parsed.headerCRCOK == true,
                              parsed.payloadCRCOK == true else { return frame }
                        return nil
                    }
                    let mappedRawFrames = dispositions.enumerated().compactMap { index, disposition
                        -> DecodedChunk.MappedRawFrame? in
                        guard case .mappedRaw(let version) = disposition,
                              let unix = parsed[index].parsed["unix"]?.intValue else { return nil }
                        return DecodedChunk.MappedRawFrame(
                            originalIndex: index,
                            bytes: frames[index],
                            version: version,
                            unix: unix
                        )
                    }
                    let range = Backfiller.receivedTimestampRange(from: parsed)
                    let fingerprintInput = HistoricalReceivedFrameFingerprintInput(
                        orderedFrames: frames,
                        protocolMetadata: protocolMetadata,
                        historyEndFrame: Data(endFrame),
                        minReceivedTs: range.min,
                        maxReceivedTs: range.max)
                    let fingerprint = try WhoopStore.historicalReceivedFrameFingerprint(
                        input: fingerprintInput,
                        scope: admittedScope,
                        trim: Int(trim))
                    return DecodedChunk(
                        parsed: parsed,
                        decoded: decoded,
                        rejected: rejected,
                        integrityFailures: integrityFailures,
                        mappedRawFrames: mappedRawFrames,
                        fingerprintInput: fingerprintInput,
                        fingerprint: fingerprint
                    )
                }.value
            } catch {
                PerformanceTrace.end(decodeTrace)
                log?("Backfill: failed to fingerprint historical chunk (trim=\(trim)): \(error) — holding ack so the strap re-sends this chunk.")
                fail(.fingerprint(trim: trim))
                return
            }
            PerformanceTrace.end(decodeTrace, changedRows: frames.count)
            guard sessionGeneration == admittedSessionGeneration else {
                log?("Backfill: dropped decoded trim=\(trim) from a superseded session before commit.")
                return
            }
            let parsed = d.parsed
            mappedRawFrames = d.mappedRawFrames
            mappedRawVersions = Set(mappedRawFrames.map(\.version))
            mappedRawRecordCount = mappedRawFrames.count
            preparedFingerprintInput = d.fingerprintInput
            preparedFingerprint = d.fingerprint
            receivedMinTs = d.fingerprintInput.minReceivedTs
            receivedMaxTs = d.fingerprintInput.maxReceivedTs
            // Observability (PR #241): log which layout this strap emits on a HEALTHY sync too — the
            // unmapped-version path below only fires for layouts NOOP can't decode, so a normal log
            // never revealed v18/v24/v25/v26. Once per distinct layout this session.
            if let v = parsed.lazy.compactMap({ $0.parsed["hist_version"]?.intValue }).first,
               loggedLayoutVersions.insert(v).inserted {
                log?("Backfill: historical records use layout v\(v)")
                // UNIVERSAL clock-drift: bank the layout so the export's universal clock-drift line is
                // firmware-aware on every export (not only Connection mode). Unconditional observability.
                firmwareLayout?(v)
                // Connection test mode: the firmware layout as a compact tagged line. A layout that decoded
                // a signature field (heart_rate / gravity_x / ppg_waveform) is decodable; otherwise the
                // unmapped-version path below fires too. Gated zero-cost.
                emitConnection({
                    let decodable = parsed.contains {
                        $0.parsed["heart_rate"] != nil || $0.parsed["gravity_x"] != nil
                            || $0.parsed["ppg_waveform"] != nil
                            || $0.parsed["sensor_block_count"] != nil
                            || $0.parsed["gyro_x"] != nil
                    }
                    return ConnectionTrace.firmwareLine(version: v, decodable: decodable)
                }())
            }
            // SpO2 RE dump (PR #945, reimplemented): while the Connection test mode is on, dump a few FULL
            // historical records + their mapped raw SpO2 channels so an offline pass can tell whether the
            // strap banks a COMPUTED SpO2 (a byte tracking the WHOOP app's nightly %) vs only the raw
            // red/IR ADC we already decode. Log-only and bounded per session across chunks (`spo2Dumped`,
            // reset in begin); zero-cost when the mode is off (one Bool short-circuit). Only genuine
            // historical records (a decoded `unix`) spend the sample budget - the strap's type-50 console
            // frames carry no record bytes to correlate. Records dump whether or not they carry SpO2
            // channels, so "nothing banked" is provable too. Never a user-facing number (never-fabricate;
            // the #194 lesson). Twin of the Android Backfiller emit.
            if spo2Dumped < Spo2ReTrace.maxSamples, connectionActive(), let connectionLog {
                for (raw, p) in zip(frames, parsed) where spo2Dumped < Spo2ReTrace.maxSamples {
                    guard let unix = p.parsed["unix"]?.intValue else { continue }
                    connectionLog(Spo2ReTrace.recordLine(
                        frame: raw,
                        version: p.parsed["hist_version"]?.intValue,
                        unix: unix,
                        red: p.parsed["spo2_red"]?.intValue,
                        ir: p.parsed["spo2_ir"]?.intValue,
                        skinRaw: p.parsed["skin_temp_raw"]?.intValue))
                    spo2Dumped += 1
                }
            }
            // Diagnostic (#30): a historical record whose firmware version we don't have a field map for
            // bails out of decode entirely — no HR, no R-R, no GRAVITY — so sleep (which is gravity/
            // motion-driven) can never be computed from it, even though the offload "completes". Surface
            // each unmapped version once so the user's strap log reveals what their firmware emits.
            // "Decoded nothing" must cover every mapped layout's signature field: v18 emits heart_rate,
            // v25 emits gravity_x (no per-second HR — it's PPG-derived), v26 emits ppg_waveform (no HR
            // either) — checking heart_rate alone false-flagged v25/v26 as unmapped (#156, sudden-break).
            for p in parsed {
                guard let v = p.parsed["hist_version"]?.intValue,
                      !mappedRawVersions.contains(v),
                      p.parsed["heart_rate"] == nil,
                      p.parsed["gravity_x"] == nil,
                      p.parsed["ppg_waveform"] == nil,
                      !loggedUnmappedVersions.contains(v) else { continue }
                loggedUnmappedVersions.insert(v)
                log?("Historical records use firmware layout v\(v), which NOOP doesn't decode yet — no motion data, so sleep can't be computed from the strap. Please report this (issue #30).")
            }
            let decoded = d.decoded
            decodedForCommit = decoded
            // #547: surface a bad-clock strap. extractHistoricalStreams DROPPED any record whose own unix
            // timestamp was implausible (far-past / bogus-2027 / future-dated) before it could pollute the
            // DB. Log it (once it's accrued at least one this session, on the first chunk that sees it) so
            // the user's strap log explains why a clock-broken strap banks fewer rows than expected — this
            // is the strap's clock, not a NOOP decode bug. Observability only; the gate already did the work.
            if decoded.droppedImplausible > 0 {
                let wasZero = sessionDroppedImplausible == 0
                sessionDroppedImplausible += decoded.droppedImplausible
                if wasZero {
                    // #324: append the epoch SPAN of the dropped block + how far off it sits, so the strap log
                    // shows WHETHER the whole banked range is future-dated (safe to fast-forward-discard) or
                    // just a slice. `droppedImplausibleOldestTs/NewestTs` are the records' OWN dated values
                    // (the strap's wrong clock), captured by the #547 gate as it dropped them.
                    let span = BadClockDiagnostics.droppedSpanClause(
                        oldest: decoded.droppedImplausibleOldestTs,
                        newest: decoded.droppedImplausibleNewestTs,
                        now: Int(Date().timeIntervalSince1970))
                    log?("Backfill: dropped record(s) with an implausible timestamp (trim=\(trim))\(span) — the strap's clock is wrong (records dated far in the past or future), so those samples were skipped rather than misfiled onto the wrong day. Fully charge and reconnect the strap so its clock re-syncs.")
                }
            }
            // #324: the strap RTC-state events (RTC_LOST / BOOT / SET_RTC) the #547 gate dropped for a bad
            // own-timestamp — the GROUND TRUTH that the clock reset. Sparse (not per-record), so log each as
            // it appears; the bad `rawTs` is the future/past base the RTC jumped to.
            let nowForRtc = Int(Date().timeIntervalSince1970)
            for ev in decoded.droppedRtcEvents {
                log?("Backfill: strap reported \(ev.kind) with an implausible own-timestamp \(BadClockDiagnostics.isoDay(ev.rawTs)) (\(BadClockDiagnostics.hoursOffset(ev.rawTs, now: nowForRtc)) vs now) — the strap's RTC reset to a wrong base (#324/#928); this is the ground-truth cause of the future-dated banking, not a NOOP decode bug.")
            }
            // Diagnostic (#77): the AGGREGATE silent-loss case — frames arrived but produced no rows at
            // all (CRC fail / unmapped layout / out-of-range timestamp), so this chunk persists nothing
            // yet still acks below and the strap trims past it. The per-version log above only catches
            // unmapped layouts; this catches CRC drops too. Observability only — behaviour unchanged
            // (not acking would wedge the offload on a re-send loop). Surfaces in the user's strap log.
            // Classify FIRST: separate genuinely-undecodable SENSOR records from the strap's own
            // type-50 console/diagnostic frames, which decode to 0 rows by design and are NOT a loss
            // (the "rejected frames" red herring users kept reporting — #77/#120). Drives both the
            // log wording below and the archive guard further down.
            let rejected = d.rejected
            // Tally this chunk's outcome so a completed-but-empty session is distinguishable from a
            // caught-up one (#77 family): did it decode sensor rows, and was it console-only?
            let storedMappedRaw = !mappedRawVersions.isEmpty
            chunkHadSensorContent = !decoded.isEmpty || storedMappedRaw
            chunkWasConsoleOnly = decoded.isEmpty && !storedMappedRaw && rejected.isEmpty
            // A chunk that produced no rows AND held no genuine rejects was pure console output — say
            // so calmly so it doesn't read as data loss (the "rejected frames" red herring, #77/#120).
            if decoded.isEmpty && !storedMappedRaw && rejected.isEmpty {
                log?("Backfill: \(frames.count) frame(s) this chunk carried no sensor records (strap console/diagnostic output) — normal, nothing to persist (trim=\(trim)).")
            }
            if storedMappedRaw {
                let versions = mappedRawVersions.sorted().map { "v\($0)" }.joined(separator: ", ")
                log?("Backfill: mapped \(versions) sensor records will be retained packed for background materialization (trim=\(trim)).")
            }
            // Log + hex-sample the GENUINE rejects whenever there are any — INCLUDING a partially-decoded
            // chunk (some good rows alongside CRC-failed / unmapped records), which used to archive those
            // raw bytes with no log line at all (only the all-empty case was observable). (ryanbr, PR #123)
            if !rejected.isEmpty {
                log?("Backfill: \(rejected.count) undecodable sensor record(s) of \(frames.count) frame(s) (trim=\(trim)) — archiving raw bytes before ack (CRC/unmapped layout).")
                // #91 / #30: dump a hex sample of the genuine rejects so an unmapped firmware's record
                // layout can be mapped from a user's strap log. Dump the FULL frame (not a 64-byte
                // prefix — v25/v26 records run ~84 B and the truncated tail is exactly where the
                // unmapped motion/HR fields sit), and sample a few more so one log carries enough
                // records to triangulate offsets. These only ever fire for unmapped firmware.
                for (i, f) in rejected.prefix(8).enumerated() {
                    let hex = f.map { String(format: "%02x", $0) }.joined()
                    log?("Backfill: rejected frame[\(i)] \(f.count)B: \(hex)")
                }
            }
            // #77 / #91: any genuinely-undecodable type-47 record in this chunk must be ARCHIVED
            // before we ack — the ack frees the strap's copy, so the archive is the only remaining
            // copy of an unmapped firmware's records. A genuine archive write FAILURE aborts the
            // chunk (no setCursor, no ack) so the strap re-sends it next session — no data loss
            // either way. (A full archive is reported as success by the sink; we still ack.)
            if !rejected.isEmpty, let rejectedSink {
                guard rejectedSink(rejected, trim, family) else {
                    log?("Backfill: rejected-frame archive failed (trim=\(trim)) — holding ack so the strap re-sends.")
                    fail(.rejectedArchive(trim: trim))
                    return
                }
            }
            // A valid but unknown firmware layout may be archived and ACKed: its exact bytes are durable.
            // A corrupt or unverifiable envelope is different. Archiving it is diagnostic only; it cannot
            // authorize the durable receipt or make the strap release its sole trusted copy.
            if !d.integrityFailures.isEmpty {
                log?("Backfill: \(d.integrityFailures.count) frame(s) failed complete envelope integrity "
                    + "(trim=\(trim)) — NOT committing or acking this chunk.")
                fail(.integrity(trim: trim))
                return
            }
        }

        // #57: an earlier failure means this logical offload no longer has a contiguous durable frontier.
        // Do not write a later trim or receipt, even for an empty END: that would make a missing chunk look
        // committed before the strap has been told to retain it. A fresh session re-offers from the last ACK.
        if persistStalled {
            log?("Backfill: persist stalled earlier this session — NOT committing or acking trim=\(trim) so the strap can't trim past un-stored history. Reconnect once the store is healthy (#57).")
            return
        }

        // Raw metadata needs a concrete range even when its frames carry no decodable unix field, so the
        // retained batch may use the HISTORY_END timestamp as a fallback. The fingerprint must preserve
        // the actual range decoded from the received frames, including nil when no timestamp was present.
        let fingerprintInput = preparedFingerprintInput ?? HistoricalReceivedFrameFingerprintInput(
            orderedFrames: frames,
            protocolMetadata: protocolMetadata,
            historyEndFrame: Data(endFrame),
            minReceivedTs: receivedMinTs,
            maxReceivedTs: receivedMaxTs)
        let fingerprint: String
        if let preparedFingerprint {
            fingerprint = preparedFingerprint
        } else {
            do {
                fingerprint = try WhoopStore.historicalReceivedFrameFingerprint(
                    input: fingerprintInput,
                    scope: admittedScope,
                    trim: Int(trim))
            } catch {
                log?("Backfill: failed to fingerprint historical chunk (trim=\(trim)): \(error) — holding ack so the strap re-sends this chunk.")
                fail(.fingerprint(trim: trim))
                return
            }
        }

        // Raw evidence uses content-version identity too. A retry with different valid data at the same
        // trim must not collide with a prior batch ID, while an exact replay resolves to the same batch.
        let requiresMappedRawRetention = !mappedRawVersions.isEmpty
        if (enableRawCapture || requiresMappedRawRetention), !frames.isEmpty, let rawClockRef {
            let retainedFrames = requiresMappedRawRetention ? mappedRawFrames.map(\.bytes) : frames
            let retainedIndexes = requiresMappedRawRetention
                ? mappedRawFrames.map(\.originalIndex)
                : Array(frames.indices)
            let retainedTimestamps = requiresMappedRawRetention ? mappedRawFrames.map(\.unix) : []
            let meta = RawBatchMeta(
                batchId: "hist-\(admittedScope.key)-\(trim)-\(fingerprint.prefix(16))",
                deviceId: admittedScope.deviceId,
                clockRef: rawClockRef,
                capturedAt: Int(Date().timeIntervalSince1970),
                startTs: retainedTimestamps.min() ?? receivedMinTs ?? Int(unix),
                endTs: retainedTimestamps.max() ?? receivedMaxTs ?? Int(unix),
                frameCount: retainedFrames.count,
                byteSize: retainedFrames.reduce(0) { $0 + $1.count },
                lineage: admittedScope.lineage,
                cursorEpoch: admittedScope.cursorEpoch)
            rawBatchForCommit = HistoricalRawBatch(
                meta: meta,
                frames: retainedFrames,
                originalFrameIndexes: retainedIndexes,
                protocolMetadata: protocolMetadata,
                historyEndFrame: Data(endFrame))
        }

        let rawCaptureStatus: HistoricalRawCaptureStatus
        let rawRange: HistoricalRawRangeEvidence
        if let rawBatch = rawBatchForCommit {
            rawCaptureStatus = requiresMappedRawRetention
                ? .materializationRequired(batchId: rawBatch.meta.batchId)
                : .captured(batchId: rawBatch.meta.batchId)
            rawRange = HistoricalRawRangeEvidence(
                source: .retainedRawBatch,
                minReceivedTs: rawBatch.meta.startTs,
                maxReceivedTs: rawBatch.meta.endTs,
                frameCount: rawBatch.meta.frameCount,
                byteCount: rawBatch.meta.byteSize,
                hasHistoryEnd: rawBatch.historyEndFrame != nil)
        } else {
            rawCaptureStatus = .disabled
            rawRange = fingerprintInput.rawRangeEvidence
        }

        if let beforeHistoricalCommit {
            await beforeHistoricalCommit()
        }
        guard sessionGeneration == admittedSessionGeneration else {
            log?("Backfill: dropped trim=\(trim) because its session was superseded before commit.")
            return
        }

        // Rows, optional raw capture, the trim cursor, and this receipt commit as one SQLite unit. The
        // receipt is the only object later Phase 2 stages may use to trigger analysis or UI publication.
        let commitResult: HistoricalCommitResult
        let commitTrace = PerformanceTrace.begin("history_chunk_commit")
        do {
            commitResult = try await store.commitHistoricalChunkResult(
                streams: decodedForCommit,
                deviceId: admittedScope.deviceId,
                trim: Int(trim),
                chunkEndUnix: Int(unix),
                rawBatch: rawBatchForCommit,
                committedAt: Int(Date().timeIntervalSince1970),
                scope: admittedScope,
                fingerprint: fingerprint,
                fingerprintInput: fingerprintInput,
                rawCaptureStatus: rawCaptureStatus,
                rawRange: rawRange,
                burst: nil,
                timestampHeal: HistoricalTimestampHeal(
                    droppedRecordCount: decodedForCommit.droppedImplausible),
                isFinal: trim == UInt32.max
            )
        } catch {
            PerformanceTrace.end(commitTrace)
            guard sessionGeneration == admittedSessionGeneration else { return }
            log?("Backfill: failed to atomically commit historical chunk (trim=\(trim)): \(error) — holding ack so the strap re-sends this chunk; history won't advance until the local commit succeeds.")
            fail(.commit(trim: trim))
            return
        }
        let receipt = commitResult.receipt
        let inserted = commitResult.outcome == .inserted
        PerformanceTrace.end(commitTrace, changedRows: inserted ? receipt.insertedRows.total : 0)
        guard sessionGeneration == admittedSessionGeneration else {
            // The receipt is durable under its original scope, but a newer session now owns the strap.
            // Never publish its state or ACK it through the new session.
            log?("Backfill: committed trim=\(trim) from a superseded session — leaving it unacked for safe replay.")
            return
        }
        if inserted {
            onChunk?(chunkHadSensorContent, chunkWasConsoleOnly)
            onHistoricalCommit?(receipt)
            let durableSource = HistoricalReceiptWatermark.SourceIdentity(
                deviceId: receipt.deviceId,
                lineage: receipt.lineage,
                epoch: Int64(receipt.cursorEpoch),
                trimScope: receipt.trimScope)
            onHistoricalCommitContext?(HistoricalCommitContext(receipt: receipt, sourceIdentity: durableSource))
        } else {
            log?("Backfill: exact durable receipt replay at trim=\(trim) — ACKing safely with zero fresh progress.")
        }

        // Success-side observability (#150): tally only receipt-backed rows. This includes every
        // persisted stream, including WHOOP 5 step, sleep-state, and PPG samples.
        let freshCounts = inserted ? receipt.insertedRows : HistoricalStreamInsertCounts()
        let freshTimestamps = inserted
            ? decodedForCommit.gravity.map(\.ts) + decodedForCommit.hr.map(\.ts)
            : []
        let tally = Backfiller.chunkTally(counts: freshCounts, timestamps: freshTimestamps)
        sessionRowsPersisted += tally.rows
        sessionMappedRawRecords += inserted ? mappedRawRecordCount : 0
        if inserted {
            sessionNormalizedMaxTs = [sessionNormalizedMaxTs, receipt.maxDecodedTs]
                .compactMap { $0 }.max()
            if case .materializationRequired = receipt.rawStatus {
                sessionMappedRawMaxTs = [sessionMappedRawMaxTs, receipt.rawRange.maxReceivedTs]
                    .compactMap { $0 }.max()
            }
        }
        sessionMotionRows += tally.motion
        sessionSkinTempRows += freshCounts.skinTemp
        sessionNightKeys.formUnion(tally.nights)

        // Connection test mode: per-chunk offload PROGRESS (running session totals), so a report shows
        // the offload advancing rather than only its final outcome. Gated zero-cost.
        emitConnection("offload progress trim=\(trim) chunkRows=\(tally.rows) "
            + "sessionRows=\(sessionRowsPersisted) sessionMotion=\(sessionMotionRows) nights=\(sessionNights)")

        // #150 / #783 / #1: trim=0xFFFFFFFF is the strap's "no valid flash cursor" sentinel. Its MEANING
        // depends on whether this run already banked anything. On the FIRST end of a fresh offload it means
        // "no banked history" (a clock/charge state). But the auto-continuation (#364) re-kicks
        // SEND_HISTORICAL after a run that DID persist rows, and the very next end then carries 0xFFFFFFFF
        // to mean "you are caught up, nothing left past the last trim", NOT "no history". Emitting the scary
        // "fully charge it" line there was wrong and alarmed users whose strap had just synced fine (#783).
        // We gate this AFTER the persist block (#1): a bad-clock/flash strap can emit records on the SAME
        // 0xFFFFFFFF END, so `sessionRowsPersisted` must already include THIS end's own rows before the
        // pick, otherwise a records-bearing no-cursor END false-alarms "no banked history". So gate on
        // `sessionRowsPersisted == 0` HERE: if rows landed (this run or this END), log the neutral caught-up
        // line; a genuinely empty session (0 rows) still gets the real no-history guidance. Logs once per
        // session (loggedNoCursor) and the ack still proceeds below.
        if trim == 0xFFFFFFFF, !loggedNoCursor {
            loggedNoCursor = true
            log?(Backfiller.noCursorLine(
                rowsPersisted: sessionRowsPersisted,
                mappedRawRecords: sessionMappedRawRecords,
                continuedAfterRows: continuedAfterRows))
            // Connection test mode: the no-cursor sentinel as a compact tagged line (gated zero-cost).
            emitConnection(ConnectionTrace.noCursorLine())
        }

        let ackTrace = PerformanceTrace.begin("history_chunk_ack")
        let ackConfirmed = await ackTrim(admittedScope, trim, endData)
        PerformanceTrace.end(ackTrace)
        guard sessionGeneration == admittedSessionGeneration else {
            log?("Backfill: ignored ACK result for trim=\(trim) after its session was superseded.")
            return
        }
        guard ackConfirmed else {
            // A receipt is durable, but the strap did not confirm the exact ACK on the admitted BLE
            // session. Hold every later ACK: a fresh session can replay the idempotent receipt safely,
            // while the strap retains this chunk rather than trimming beyond the unconfirmed frontier.
            log?("Backfill: historical ACK was not confirmed for admitted scope \(admittedScope.key), trim=\(trim) — holding later ACKs so the strap re-sends this frontier.")
            fail(.acknowledgment(trim: trim))
            return
        }
        lastAckedTrim = trim   // #364: record the advanced cursor for the auto-continue spin-detector
        sessionLastAckedFingerprint = fingerprint
        onHistoricalAcknowledged?(receipt, commitResult.outcome)
    }

    /// Called when a backfill watchdog timer fires (strap went silent mid-offload).
    /// Clears state without acking — the chunk was never durably committed.
    func timeoutFired() {
        sessionGeneration &+= 1
        isBackfilling = false
        chunk.removeAll(keepingCapacity: true)
        chunkOpen = false
    }
}
