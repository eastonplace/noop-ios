# History ingestion performance design

Tracked by GitHub issue #36.

## Product objective

History sync must not make the app freeze, skip, or feel slower. Background work should reduce the
foreground backlog, but it must not add expensive interpretation to the BLE notification or ACK path.

## Durable hot-path contract

1. Reassemble and validate the frame.
2. Parse each historical frame once off the main actor.
3. Classify the parsed result without reparsing raw bytes.
4. Prepare the receipt fingerprint and packed raw batch outside the SQLite writer.
5. Commit decoded rows, required mapped raw bytes, the receipt, and cursor in one short transaction.
6. ACK only after the transaction commits.
7. Materialize large V20/V21 sensor arrays and publish analysis later.

## Outcome vocabulary

- `materializedKnown`: decoded into a current production stream.
- `mappedRaw`: valid V20/V21 data retained for later materialization.
- `consoleOrMetadata`: valid protocol traffic with no sensor row.
- `invalidCRC`: historical data whose payload integrity failed.
- `invalidEnvelope`: a malformed historical data envelope.
- `unmappedLayout`: a valid historical layout with no mapped durable representation.

Only invalid or genuinely unmapped sensor records count as rejected. Valid V20/V21 records never use
the rejection JSONL archive and never produce the unrecognised-firmware banner.

## Performance gates

- One `parseFrame` call per historical frame in the chunk decode path.
- No full-frame hexadecimal formatting for mapped V20/V21 traffic.
- No rejection JSONL append or `synchronize()` for mapped V20/V21 traffic.
- No per-sample V20/V21 SQLite expansion before ACK.
- Record p50, p95, and max for representative V18/V20/V21 mixed chunks.
- Compare a Release device Instruments trace before and after using the same sync interaction.

## Background boundary

iOS background execution is best effort. Core Bluetooth restoration and short BLE wakes may bank bounded
chunks. `BGProcessingTask` may resume durable materialization, but it is not a periodic timer. Process
relaunch on current iOS also requires the accessory setup path to satisfy Apple's restoration rules.
Those device/runtime cases stay unqualified until tested on a locked physical iPhone.

This PR increases the existing progress-gated continuation budget from 6 to 24 passes. It does not add a
timer or an unbounded loop: connection, advancing trim, plausible strap clock, and remaining-backlog checks
still gate every pass. That lets an already-connected foreground or Core Bluetooth background opportunity
bank more history before the app returns to the 15-minute floor.

## Upstream comparison

The protocol mapping follows RyanBR's captured-device evidence: V21 contains six-axis IMU data, and V20
contains five repeated optical blocks whose channel wavelengths are not yet established. NOOP therefore
retains both layouts without inventing biometric meaning. It adopts RyanBR's progress-based continuation
budget while keeping the local PR #29 content-version receipt identity and shared database pool.

This PR does not copy Goose's eager per-sample ingestion path because that keeps large sensor expansion on
the transfer path. It uses the safer rule seen in OpenStrap instead: bank the received bytes before ACK,
then schedule interpretation separately. Production health formulas do not consume V20/V21 in this PR.

## Verification log

- Mixed 35-frame V18/V20/V21 Debug fixture: p50 3.524 ms, p95 3.789 ms, max 3.857 ms.
- iOS signposts: `history_chunk_decode`, `history_chunk_commit`, and `history_chunk_ack`.
- Simulator proof: V20 commits as `materializationRequired`, produces zero normalized rows, never calls the
  rejected-frame archive, and ACKs after commit.
- Physical-device Release trace, locked/background wake, termination/restoration, and AccessorySetupKit
  qualification remain separate gates. Simulator timing is not a claim of device UI smoothness.
