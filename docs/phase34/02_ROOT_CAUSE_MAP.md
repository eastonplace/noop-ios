# Root-Cause Map

## A. Why Today, Sleep, and Trends disagree

```text
Persisted WHOOP imported Sleep score ─┐
Persisted NOOP Sleep V2 score ────────┼─> Today private precedence
Persisted legacy Rest composite ──────┘

Imported performance + local DailyMetric composite ─> SleepView model

Generic metricSeries + in-memory DailyMetric fallback ─> Trends
```

Three readers independently decide what “Sleep score” means. The mismatch is expected behavior under the current architecture, not a one-off UI bug.

### Root replacement

```text
Persisted score candidates
        ↓
CanonicalSleepScoreResolver
        ↓
CanonicalHealthReadModel (one Repository revision)
        ├─ Today
        ├─ Sleep
        ├─ Trends
        ├─ Widget
        ├─ Live Activity
        ├─ Watch
        └─ Export
```

---

## B. Why current-day processing remains slow

```text
BLE chunk commit
    ↓
Receipt planner
    ↓
global min/max day expansion
    ↓
relative contiguous analysis runs
    ↓
analysis
    ↓
4,000-day Repository refresh
    ↓
UI
```

The system added exact receipt infrastructure but still funnels it back into two broad legacy interfaces:

1. `analyzeRecent(maxDays:startOffset:)`
2. `Repository.refresh(days:)`

### Root replacement

```text
Receipt timestamp buckets + explicit days
    ↓
exact CivilDay set
    ↓
exact per-day analysis
    ↓
read-back verification
    ↓
verified Today snapshot transaction
    ↓
exact changed-day Repository merge
```

---

## C. Why receipt work can be skipped

```text
Decoded rows already existed
    ↓
insertedRows.total == 0
    ↓
planner says “no analysis”
    ↓
receipt acknowledged
    ↓
missing/stale score remains
```

Insert counts answer “did this SQL insert mutate rows?” They do not answer “does this committed evidence require scoring?”

### Correct obligation

```text
requires analysis =
    decoded physiological evidence
    OR explicit affected days
    OR exact timestamp-heal days
    OR durable full-history repair
```

---

## D. Why a crash-safe receipt is not yet a crash-safe pipeline

Current durable state ends at “staged payload/checkpoint.” It does not model:

```text
pending
analyzing
verifying
snapshot committed
repository published
downstream pending
complete
retryable
quarantined
```

Without these states, every failure becomes generic “deferred,” and operators cannot tell where the pipeline stopped.

### Root replacement

A leased durable work row, transformed only by a tested reducer. The work item records receipt generations, exact days, attempts, next retry, analysis generation, snapshot generation, pending downstream destinations, and terminal error.

---

## E. Why external surfaces drift

```text
Today ← persisted/Repository snapshot
Widget/Live Activity ← independently rebuilt repo.days projection
Apple Health ← lifecycle-driven import/export path
Watch ← another publication trigger
```

Even correct individual readers can race across generations.

### Root replacement

```text
VerifiedHealthProjection generation N
        ↓ durable outbox
        ├─ widget N
        ├─ live activity N
        ├─ HealthKit write-only N
        └─ watch N
```

---

## F. Why startup and page navigation scale poorly

The Repository’s in-memory cache still doubles as:

- Today’s recent projection,
- the full history extent,
- Trends’ source,
- historical navigation availability,
- Sleep’s full session store.

This forces broad reads to preserve old UI assumptions.

### Root replacement

```text
Today snapshot:       1 keyed row
Recent dashboard:     90–120 days
History extent:       MIN/MAX/COUNT aggregates
Historical day:       exact on-demand query + LRU
Sleep navigation:     paginated wake-day groups
Trends:                bounded range query or streamed full-history report
```

## G. Why generation comparisons can reject valid work

Receipt generation, engine analysis generation, and snapshot generation are independent counters. Treating
`analysisGeneration >= receiptGeneration` or `snapshotGeneration >= analysisGeneration` as a correctness
check can reject a fully valid current-day update. Preserve all three IDs and compare receipt-to-receipt only;
verify the snapshot by explicit analysis identity and read-back evidence.

## H. Why a value can appear, then disappear after relaunch

```text
resolve new Today candidate
    ↓
publish to memory
    ↓
SQLite save/read-back fails or process stops
    ↓
next launch hydrates older committed snapshot
```

### Root replacement

```text
resolve candidate
    ↓
save to SQLite
    ↓
read back and verify
    ↓
publish committed value
```

A derivative snapshot failure keeps the prior committed value visible and schedules a retry.

---

## I. Why source transitions can strand old work

A runtime that asks only for the new active scope cannot drain receipts from the replaced lineage. Repeatedly
returning “scope is not current” leaves permanent pending state.

### Root replacement

Before the transition, one transaction advances the old consumer watermark through its final receipt and
quarantines nonterminal work. Receipts remain for diagnostics. The runtime then discovers only valid scopes.

---

## J. Why durable JSON and wall-clock fields cannot be identity

JSON dictionary/enum byte order and wall-clock timestamps are serialization details. Using them as replay or
coalescing identity causes false conflicts.

### Root replacement

- `workKindKey` is deterministic SQL identity; `workKindJSON` is payload.
- Verified projections compare decoded value graphs.
- Receipt fingerprint V2 contains immutable received bytes and source scope only.
- Receipt, analysis, Repository, and snapshot generations remain separate domains.
