# Reconciliation Report

## Final baseline

- Repository: `eastonplace-ai/noop`
- Phase 1 PR: `#26`
- Phase 2 PR: `#27`
- Exact Phase 2 head: `976d7d48df6930046eb38cb2f46febb18a986a48`
- Commit: `merge: retain verified Phase 2 handoff`
- Hosted Phase 2 workflow: passed source audits, app/extensions build, iOS tests, and retained package tests
- GitHub mutations during this reconciliation: none

Phase 2 did commit while the longer QA work was in progress. Both the earlier package and the independent
package were already aimed at the final `976d7d48` head. This reconciliation re-read PR #27 and its final
changed files against that SHA. No later Phase 2 implementation commit was missed.

## Inputs reconciled

1. The independent `noop_phase3_4_bundle` uploaded by the user.
2. The earlier `noop_phase3_phase4_patchset` produced in this conversation.
3. The final GitHub Phase 2 branch and hosted workflow state.

The independent bundle supplied the stronger durable-work and exact-day base. The earlier bundle supplied
several screen/publication root causes that the independent report did not fully close. This package combines
both, then corrects conflicts and defects found inside the proposed code itself.

## Findings retained from the independent audit

- One canonical Sleep authority for Today, Sleep, Trends, widgets, Watch, and exports.
- Sparse timestamp evidence instead of global minimum/maximum expansion.
- Durable receipt admission, leased analysis work, retries, quarantine, and crash recovery.
- Exact changed-day Repository publication.
- Bounded recent history plus full-history extent metadata.
- Durable external publication outbox.
- BLE confirmed-write generation identity.
- Cursor, raw outbox, device lifecycle, and restore hardening.

## Findings retained from the earlier audit

- A Sleep-score-only update can leave UI revision unchanged.
- Today can publish a candidate before the snapshot save and read-back complete.
- The old post-backfill owner remains active beside the receipt path.
- Trends combines independent reads that can come from different WAL generations.
- Today, Sleep, and Trends still use different production Sleep-score paths.
- Current-day and post-backfill work still reaches 4,000-day Repository reads.

## Reconciliation corrections

### 1. Historical trim ACK ordering

One earlier plan incorrectly tied strap trim acknowledgement to scoring and downstream publication. The final
rule is:

```text
raw rows + cursor + receipt commit atomically
→ SQLite transaction commits
→ send trim ACK
→ scoring, snapshot, Repository, and external publication resume from the receipt
```

The trim ACK must not wait for Recovery scoring, Repository publication, widgets, Watch, or HealthKit. Those
stages are crash-resumable from the committed receipt.

### 2. Shadow Sleep precedence

The independent code used legacy, then provisional, then V2 in shadow mode. The corrected order is:

```text
imported WHOOP
→ legacy production when present
→ persisted V2 when legacy is absent
→ provisional only when no persisted candidate exists
```

### 3. Stable source authority

Source identifiers are not precedence. The final model carries an explicit authority rank from the ordered
active/canonical source list. A lexicographically larger source cannot win by accident.

### 4. Durable generation domains

Receipt, analysis, Repository, and snapshot generations are independent. The package adds a separate
`analysisMutationJournal` AUTOINCREMENT domain. Cross-domain numeric comparisons are prohibited.

### 5. Work and projection replay identity

- Durable work coalescing uses `workKindKey`, not JSON-encoded enum bytes.
- Verified projection replay compares decoded semantic values, not JSON byte order.
- Projection pruning retains recent generations per context, not globally.

### 6. Lease ownership

Long analysis, verification, HealthKit, and Watch operations can outlive an initial lease. The final workers
renew leases while suspended. Destination retries never keep or recover an analysis lease after the exact
projection and outbox rows commit.

### 7. Source transitions

A re-pair or source replacement now retires the old receipt scope transactionally:

- consumer watermark advances through the old scope,
- nonterminal work is quarantined,
- receipts remain available for audit,
- only the new scope returns from runtime admission context discovery.

## Additional defects corrected in the reconciled code

- Metadata-only snapshot changes no longer rebuild value-fed surfaces.
- Timestamp range evidence alone no longer creates analysis work.
- Empty legacy receipts advance without forcing a full-history repair.
- Decoder-only dropped rows do not claim that stored projections changed.
- Raw decompression validates the advertised length before allocation.
- Raw frame count is structurally bounded before `reserveCapacity`.
- External outbox batch limits self-signal instead of stranding ready work.
- Pending-work read failures are reported as unknown, not silently converted to zero.
- Analysis work completes after exact projection/outbox persistence. Destination retries are separate.

### 8. Calendar rollover across DST

The combined draft originally subtracted four elapsed hours to determine the physiological day. That changes
the boundary on daylight-saving transition days. The corrected `HealthCalendar` compares the local civil hour
and moves by one calendar day only when local time is before 04:00. Tests cover spring-forward and the repeated
fall-back hour.

### 9. Analysis-to-snapshot replay identity

The durable work and outbox layers still needed one crash seam. The final package adds
`verifiedSnapshotCommit(contextId, analysisGeneration)`. A restart after snapshot commit reuses the accepted
snapshot generation instead of writing another generation for the same analysis mutation.

### 10. Destination-specific replay identity

Widget, Live Activity, and Watch are latest-state sinks. Older pending snapshots can be superseded. HealthKit
is mutation delivery. It is keyed by analysis generation and exact changed days, so one historical mutation
cannot disappear behind a newer Today snapshot.

## Confirmed risks intentionally deferred

Two existing storage keys can theoretically collapse legitimate records:

- RR: `(deviceId, ts, rrMs, seq)` can still need stronger cross-chunk protocol identity.
- Event: `(deviceId, ts, kind)` cannot represent two same-kind records in the same second.

The repository does not yet expose a proven stable protocol sequence, frame offset, or record ordinal for both
cases. This package requires collision diagnostics and raw evidence retention. It does not include a guessed
schema migration that could create a different form of duplication.

## Final implementation shape

Codex receives one combined Phase 3 + Phase 4 package. Internal commits remain useful for bisecting, but there
is one implementation pass and one final QA gate. The final PR must remove the superseded owners before it is
returned for review.
