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

This PR keeps the existing six-pass continuation ceiling. Each burst also has one 180-second monotonic
radio deadline; every next session timeout is capped by the time remaining. Exact replays contribute no
fresh progress, repeated trim + fingerprint + source-scoped durable-frontier signatures stop immediately,
and empty/stalled attempts back off the periodic floor from 15 to 30 to 60 minutes. A 24-pass experiment
remains blocked until physical energy and radio measurements qualify it.

## Upstream comparison

The protocol mapping follows RyanBR's captured-device evidence: V21 contains six-axis IMU data, and V20
contains five repeated optical blocks whose channel wavelengths are not yet established. NOOP therefore
retains both layouts without inventing biometric meaning. It adopts RyanBR's progress-based continuation
budget while keeping the local PR #29 content-version receipt identity and shared database pool.

This PR does not copy Goose's eager per-sample ingestion path because that keeps large sensor expansion on
the transfer path. It uses the safer rule seen in OpenStrap instead: bank the received bytes before ACK,
then schedule interpretation separately. Production health formulas do not consume V20/V21 in this PR.

## Verification log

The immutable head of draft PR #37 is the qualification SHA. The PR body records that literal SHA and
the matching local/hosted/device evidence; moving the head invalidates these results until rerun.

- Final local mixed 35-frame V18/V20/V21 Debug fixture: p50 3.411 ms, p95 3.583 ms,
  max 3.660 ms.
- Final local suites: WhoopProtocol 326/326, WhoopStore 436/436, and NOOPiOS 430 passed,
  0 failed, 1 expected iOS source-contract skip.
- V55 migration proof: a missing compressed archive is reconstructed from V54 `exactFrame` rows, read
  back from SQLite, decompressed, and compared byte-for-byte before the duplicate table is removed.
  Existing-archive mismatch and partial-conversion mismatch both roll back the full migration, preserving
  the V54 schema, bytes, state, and migration ledger.
- iOS signposts: `history_chunk_decode`, `history_chunk_commit`, and `history_chunk_ack`.
- Simulator proof: V20 commits as `materializationRequired`, produces zero normalized rows, never calls the
  rejected-frame archive, and ACKs after commit. Its decoded structural view exposes active samples only;
  the exact retained/materialized frame is the lossless representation, including unused slot capacity.
- Physical-device Release trace, locked/background wake, termination/restoration, and AccessorySetupKit
  qualification remain separate gates. Simulator timing is not a claim of device UI smoothness.
