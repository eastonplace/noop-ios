# Phase 1 + Phase 2 Release-Candidate QA at `976d7d48`

## Verdict

**Request changes before shipping.** The current code is materially safer than PR #25 and earlier Phase 2 drafts, but the release candidate still violates the core product guarantees:

- The same night can show different Sleep scores on Today, Sleep, and Trends.
- Exact receipt processing can skip required analysis when rows already exist.
- Sparse receipts can expand into every day between distant timestamps.
- Exact analysis is followed by a 4,000-day Repository refresh, negating the latency work.
- Snapshot persistence can make a successful authoritative Repository refresh report failure.
- Current external surfaces independently reconstruct health state instead of consuming one verified generation.

Hosted CI passed at the pinned commit. Green CI proves the committed Phase 2 branch builds and its current tests pass. It does not test the cross-screen authority, sparse-analysis, exact-publication, or crash seams below. Several current tests encode behavior that must be replaced.

See `00_RECONCILIATION_REPORT.md` for the independent-agent comparison and corrections applied to this final package.

## Audit scope and limitation

The GitHub connector was used to inspect:

- Every source file changed by PR #26 (Phase 1).
- Every source file changed by PR #27 (Phase 2).
- The complete producer → persistence → analysis → Repository → Today/Sleep/Trends → widget/Live Activity paths.
- Database migrations, source/device lifecycle, BLE acknowledgement, raw replay, cursor, recovery verification, and current tests.
- Repo-wide high-risk seams discovered while tracing those paths.

The repository is private and the connector did not expose a local Xcode checkout. Claims below are tied to source files read through the GitHub connector at exact commit `976d7d48df6930046eb38cb2f46febb18a986a48`. The bundled static audit must run inside the real checkout to enforce removal mechanically across every remaining caller.

---

# Release blockers

## P0-1 — Sleep score authority is split across three read paths

### Symptom

- Today can show a Sleep score.
- Sleep can show blank or a different score for the same wake day.
- Trends can show another value or omit it.

### Root cause

There is no canonical production Sleep score read model:

- Today reads imported `sleep_performance`, then V2, then legacy.
- Sleep builds its model from imported performance or recomputes `AnalyticsEngine.Rest.composite` locally.
- Trends calls the generic `exploreSeries("sleep_performance")`, which reads imported/legacy sources and DailyMetric-derived fallback but not the same V2 authority used by Today.
- `SleepPerformanceV2Prefs` defaults to `.shadow`, but the surfaces disagree on what shadow mode means.

### Root fix

Create one `CanonicalHealthReadModel` during Repository publication. Every production surface reads the exact same `CanonicalSleepScorePoint` for a day. Views do not recompute scores or implement precedence.

### Required deletion

- SleepView local production score precedence.
- Trends generic `sleep_performance` query for the production series.
- Today’s private independent score-selection helper after the canonical model is wired.
- Widget/Watch independent score reconstruction.

---

## P0-2 — Analysis is triggered from inserted rows instead of decoded evidence

### Symptom

A valid replay or pre-existing row set can advance the durable receipt edge without rescoring.

### Root cause

`HistoricalReceiptAnalysisPlanner` treats a receipt as productive only when `insertedRows.total > 0`. Insert counts describe storage mutation, not whether the committed bytes are analysis evidence. Rows can already exist while scores/snapshots are missing or stale.

### Root fix

Analysis obligation comes from:

- decoded physiological evidence,
- explicit affected-day evidence,
- exact timestamp-heal days,
- a durable full-history repair work item.

Insert counts remain diagnostics only.

---

## P0-3 — Sparse receipt evidence is widened into a global contiguous range

### Symptom

Receipts touching two distant dates can schedule every intervening day, recreate multi-year latency, or exceed the 4,000-day cap and remain pending forever.

### Root cause

The planner collapses all productive receipts into one global minimum and maximum timestamp. `CommittedAnalysisWindow.affectedDays` then enumerates every civil day inside that range.

### Root fix

Store timestamp evidence as independent buckets. Expand each bucket separately and union exact touched/heal days. Never enumerate the empty space between sparse buckets.

---

## P0-4 — Exact analysis is followed by a 4,000-day refresh

### Symptom

The current pipeline does precise receipt planning and scoring, then pays the dominant latency cost anyway.

### Root cause

`RepositoryRefreshIntent.currentDay`, `.postBackfill`, and `.initialLoad` still map to 4,000 days. The post-analysis publication path uses that broad replacement model.

### Root fix

Add exact-day Repository publication and separate:

- durable Today first paint,
- exact changed days,
- bounded recent dashboard cache,
- full-history extent metadata,
- on-demand historical day loading.

No current-day or post-backfill path may execute a 4,000-day read.

---

## P0-5 — Snapshot persistence gates authoritative Repository success

### Symptom

A snapshot write failure can make a refresh report failure even after authoritative caches were published.

### Root cause

The refresh contract returns one Boolean for several different outcomes. The first-paint snapshot is a derivative cache but is coupled to source publication success.

### Root fix

Return a typed outcome:

- authoritative data published,
- deferred by publication fence,
- failed source read/merge,
- derivative snapshot status.

Snapshot failures mark the snapshot writer dirty and retry. They never roll back or invalidate authoritative Repository publication.

---

## P0-6 — External surfaces reconstruct a different generation

### Symptom

Today, widget, Live Activity, Watch, and Apple Health can temporarily disagree.

### Root cause

`StrandiOSApp` rebuilds an external projection from `repo.days` and `canonicalStrainByDay`. That is a second projection path, independent of the verified snapshot generation.

### Root fix

Persist and publish one `VerifiedHealthProjection`. Enqueue downstream destinations in a durable outbox keyed by `(contextId, snapshotGeneration, destination)`. Every surface consumes that projection generation.

---
## P0-7 — Today can publish a snapshot candidate before it is durable

### Symptom

The running screen can show a newer value, then return to an older value after process termination or relaunch.

### Root cause

The current enrichment path calls `publishTodayHealthSnapshot(resolved, persist: false)` before `saveTodayHealthSnapshot` and read-back verification complete.

### Root fix

Save, read back, verify, then publish. A failed save retains the last committed in-memory snapshot and marks the writer dirty. No uncommitted candidate reaches an authoritative surface.

---

# High-severity correctness findings

## P1-1 — Snapshot presentation equality includes nonvisual evidence

`hasSamePresentation` compares metric objects whose raw frontier, observation time, and generation can change without changing the screen. This produces unnecessary snapshot revisions and SwiftUI invalidation.

**Fix:** compare only logical day, visible values, metric day, display provenance, model label, and freshness state.

## P1-2 — Fixed 86,400-second date arithmetic remains in health read paths

Repository date ranges, Trends/Sleep history windows, Apple rows, journal and workout lookbacks still contain fixed elapsed-day arithmetic. DST days and timezone travel are not always 86,400 seconds.

**Fix:** route health-day ranges through `HealthCalendar`/`CivilDay` and calendar addition. Fixed seconds remain acceptable only for explicit elapsed durations, not day identity.

## P1-3 — First-paint staleness can be visually dishonest

Recovery/Sleep may correctly carry from the latest scored night, but an arbitrarily old snapshot can appear without a stale label. Strain must never carry to a new physiological day.

**Fix:** metric-specific carry policy and `fresh / aging / stale` presentation. Labels compare the metric day with the current logical day, not with the snapshot’s old display day.

## P1-4 — Sleep screen provenance can reference the wrong day

The Sleep screen’s provenance helper checks the latest Repository day instead of the displayed/navigated wake day.

**Fix:** use the canonical score point for `wakeDay`; its source/model is the provenance.

## P1-5 — Sleep loads all history on each Repository revision

`SleepView` calls `allSleepSessions()` and other broad helpers whenever `refreshSeq` changes. With a large database, current-day sync can trigger expensive full-history work.

**Fix:** recent page projection plus paginated/on-demand older nights. Editing/navigation loads exact day/session groups.

## P1-6 — Trends pull-to-refresh invokes the broad current-day refresh

The UI asks for “current day,” but that intent currently means 4,000 days.

**Fix:** refresh exact current physiological day plus a bounded recent Trends window; full history is loaded only for explicit “All” or report export and should be streamed/paginated.

## P1-7 — Generic `exploreSeries` is not a safe canonical health API

It blends in-memory `self.days`, imported metric series, computed metric series, and derived fallbacks. Its meaning changes by key and cache extent. It is useful for exploratory metrics but unsafe for headline production score authority.

**Fix:** retain it for noncanonical exploration; production Recovery/Strain/Sleep use typed APIs.

## P1-8 — Fingerprint identity contains derived range evidence

The current fingerprint envelope contains `minReceivedTs`/`maxReceivedTs`. A parser or clock-correlation correction can change those values for identical received bytes, producing a false replay conflict and holding the strap ACK.

**Fix:** fingerprint V2 hashes only immutable source scope, cursor epoch, trim/protocol metadata, exact ordered frame bytes, and exact HISTORY_END bytes. Derived timestamps and raw-retention policy are excluded.

## P1-9 — Timestamp heal can remain deferred indefinitely

The planner rejects a heal that deleted rows without explicit affected days. Current durable state has no separate full-history repair job.

**Fix:** exact heal days when known; otherwise enqueue a durable low-priority full-history repair work item. Never leave the same checkpoint retrying forever without classification.

## P1-10 — Checkpoint consumer lacks operational state

The current consumer has staged/not-staged and catches errors as `deferred`. It lacks lease ownership, attempt count, retry time, terminal error, quarantine, verification generation, downstream status, and visible diagnostics.

**Fix:** replace it with `historicalAnalysisWork` plus a durable reducer/state machine.

## P1-11 — Stale source work can remain pending forever

After a re-pair or source lineage change, `scopeIsCurrent` returns false and the consumer defers the work indefinitely.

**Fix:** quarantine incompatible lineage work with a reason, or delete it transactionally when the user deletes that source’s data. Do not repeatedly retry impossible work.

## P1-12 — Receipt drains are bounded but not guaranteed to re-signal

A single drain covers at most 16 batches × 100 receipts. A deeper backlog can remain until another lifecycle signal.

**Fix:** the active worker loops until no due work or budget/expiration, then persists `nextAttemptAt` and schedules a follow-up signal.

## P1-13 — Empty final receipt can obscure productive earlier receipts

The in-memory burst publication holds a latest/watermark shape. Downstream work must never analyze only one final receipt, because the final receipt can contain zero rows.

**Fix:** in-memory signal carries only a through-generation watermark. Durable admission drains every receipt after the consumer watermark.

## P1-14 — BLE confirmed-write callback queue can consume the wrong generation

A stale callback can return before its queued token is retired. That stale token can later consume a callback from the replacement connection.

**Fix:** consume/retire the matching token before applying current-peripheral/generation guards. The included tested FIFO demonstrates the ordering.

## P1-15 — Equal-generation cursor updates can rewrite trim

The cursor upsert accepts `excluded.watermarkGeneration >= existing`. An equal-generation write with a different trim can rewrite the cursor edge.

**Fix:** exact replay must match the stored receipt; cursor writes advance only on a greater generation. Equal generation is idempotent only when trim/fingerprint match.

## P1-16 — Relative contiguous-run adapter is still an unnecessary widening seam

Exact days are converted back into start offsets and contiguous runs because `analyzeRecent` accepts only relative windows. It adds calendar/reference failure modes and preserves broad internal reads.

**Fix:** extract the existing per-day scoring body and accept exact civil-day windows directly. Keep formulas unchanged.

---

# Additional repo-wide defects discovered

These are real findings but should be separated by risk.

## Follow-up schema issue — RR duplicates can be dropped across chunk boundaries

RR `seq` is rebuilt from zero for each insert call. Two physically distinct identical beats with the same `(ts, rrMs)` split across two chunks can both map to `seq = 0`; the later row conflicts and is dropped.

**Root fix:** persist a stable protocol sequence where available, or allocate the next sequence against existing rows inside the transaction. This changes a hot schema path and requires fixture/parity testing, so do it in a dedicated follow-up after Phase 3–4 unless the failure is already reproduced on current hardware.

## Follow-up schema issue — repeated same-kind events in one second can collide

The Event key `(deviceId, ts, kind)` cannot represent two same-kind payloads in the same second.

**Root fix:** add a stable event sequence/content hash to the key after validating protocol behavior.

## Registry bug — `setActive` can leave no active device for an invalid ID

It demotes every active row, then updates the requested row without proving it exists.

**Root fix:** verify target existence or use a guarded single transaction that throws when the target update count is not one.

## Raw outbox hardening

Generic raw-batch enqueue uses `ON CONFLICT DO NOTHING`; callers outside the historical atomic commit can silently reuse a batch ID with different payload.

**Root fix:** validate existing metadata and decompressed payload on conflict or expose only the validated scoped API.

## Corrupt raw frame unpacking is permissive

`unpackFrames` returns a partial frame list when a length is truncated. Durable replay should fail closed, not replay a partial prefix.

**Root fix:** throwing decoder for durable replay; a separate lossy diagnostic decoder may remain if useful.

---

# What Phase 1 and Phase 2 got right

Retain these implementations/concepts:

- SQLite-backed Today snapshot instead of a UserDefaults shadow history.
- Explicit metric states and per-metric day attribution.
- Prior-day Strain suppression.
- Source/database restore fencing.
- Scalar-only Sleep score support.
- Strain V2 provenance repair.
- Five-minute durable Strain snapshot throttle.
- Merge-time provenance.
- Atomic historical rows + cursor + receipt before strap acknowledgement.
- Device lineage and cursor epoch scoping.
- Receipt generation and database identity.
- Exact source-scope validation.
- Current `IntelligenceAnalysisCoordinator` as the one analysis owner.
- Existing recovery read-back verification and publication barrier concepts.

The combined Phase 3–4 work should replace incorrect orchestration while preserving these proven pieces and all scoring formulas.

## P1-17 — Receipt, analysis, and snapshot generations must not be numerically compared

The three generations are allocated by different durable tables/processes. A valid analysis generation can
be numerically lower than a receipt generation, and a valid snapshot generation can be lower than an analysis
generation. Comparing them creates false failures after long receipt histories or database restores. The
included core tracks `analyzedThroughReceiptGeneration`, `analysisGeneration`, and `snapshotGeneration`
separately and validates equality/order only inside the appropriate domain.


## P1-18 — Trends can combine several WAL generations

Trends independently reads Sleep performance, stress, and Apple daily rows. A scorer can commit between those reads, so one screen snapshot can describe several database states.

**Fix:** build the canonical Trends inputs from one `DatabasePool.read` transaction and publish one Repository generation.

## P1-19 — Durable work identity compares JSON bytes

The proposed work store originally queried `workKindJSON = ?`. Codable bytes are payload, not a stable SQL identity.

**Fix:** persist and query a deterministic `workKindKey`; decode and verify the JSON payload separately.

## P1-20 — Long-running work and destination writes can lose leases

Analysis, verification, HealthKit, and Watch calls may outlive an initial lease. Another lifecycle signal can then recover the same work concurrently.

**Fix:** renew the same lease while the owner is suspended. Analysis work releases its lease after the exact projection and outbox rows commit. Destination retries use their own leases.

## P1-21 — Source replacement needs receipt-scope retirement

Quarantining current work alone leaves old receipt generations behind the new runtime’s singular admission context.

**Fix:** advance the old scope’s consumer watermark and quarantine nonterminal work in one transaction before activating the new lineage.

## P1-22 — Raw decompression trusts an attacker-controlled length prefix

The current archive format stores an uncompressed size before the zlib payload. An unchecked size can cause an excessive allocation before the frame decoder validates content.

**Fix:** compare the prefix with the exact packed length derived from stored `frameCount` and `byteSize`, enforce a hard cap, then decode frames strictly.
