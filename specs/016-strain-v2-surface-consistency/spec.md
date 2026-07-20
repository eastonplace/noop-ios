# Feature 016 — Strain V2 Surface Consistency and Freshness

## Goal

Make every NOOP-owned surface present one canonical, freshness-aware Strain V2 value while preserving imported WHOOP and legacy provenance. Remove fake pre-score zeroes and make workout completion durable before UI success.

## User scenarios

### US1 — One daily Strain everywhere (P1)

While Today remains open, Strain advances as new physiological data arrives. Today, Strain detail, Trends, Coupled View, widgets, Live Activity, Watch, reports, and metric exploration show the same canonical NOOP V2 value for the same day within their documented refresh windows.

**Acceptance:** computed V2 wins for NOOP headlines; fresh live V2 may supersede an older persisted V2; stale live data cannot; imported or legacy-only data never masquerades as V2.

### US2 — Honest live workout scoring (P1)

Before the V2 evidence gate, a live workout says Building with reading/coverage progress. After the gate it shows the canonical 0–21 score. A genuine post-gate zero remains distinguishable from Building.

**Acceptance:** no unscorable state renders as numeric zero; accumulator output matches the authoritative scorer, including equal-second samples around the gate.

### US3 — Durable workout finish (P1)

Finishing a workout shows a saving state, prevents double submission, and succeeds only after the exact row has been persisted and republished. Summary, list, detail, and relaunch all show the same row.

**Acceptance:** failures retain retryable durable state; success returns the read-back row; edits/relabels preserve V2 provenance.

### US4 — Explicit source provenance (P2)

Imported WHOOP and legacy Strain remain available only as explicitly sourced comparisons or migration states, never blended into NOOP V2 headlines or aggregates.

**Acceptance:** every copy/merge path preserves the version belonging to the winning value; NOOP workout aggregates include only version-2 NOOP rows.

## Functional requirements

- Stored Strain remains `0...100`; every user-facing value uses the canonical `0...21` display conversion.
- `StrainScorerV2.version == 2` remains the sole canonical NOOP version; scoring math changes are out of scope unless parity proves a defect.
- One resolved read model records value, version, origin, source, day, as-of time, and raw-data frontier.
- Live daily data can win only for the same day and only when its raw frontier is at least as fresh as persisted V2.
- Daily and workout copy/edit/relabel helpers preserve unspecified fields and never silently reset provenance.
- Imported WHOOP rows and production databases are never rewritten by this feature.
- Live daily updates are incremental or frontier-based; no full-day query runs on every heart-rate event.
- Workout finish stops samples, persists and reads back the final row, refreshes the repository, then clears durable state and reports success.
- All production Strain occurrences are classified as producer, canonical resolver, imported comparison, legacy migration, user-facing surface, fixture, or violation.
- Existing calendar-aligned Trends, dashboard/chrome, performance, and migration repairs remain intact.

## Edge cases

- Imported and computed V2 rows coexist for one logical day.
- Legacy/unversioned is the only available daily or workout value.
- Live and persisted frontiers share a timestamp or arrive out of order.
- Multiple HR readings share one second near the reliability gate.
- Day rollover, physiological-cycle change, backfill completion, backgrounding, and relaunch invalidate or rebuild live state safely.
- Workout persistence fails after scoring but before read-back.

## Success criteria

- A fixture day renders exactly one displayed Strain across every production presentation model.
- Home updates while mounted and remains exactly equal to detail for a five-minute physical-phone observation.
- No tested copy, merge, edit, import, backup, or relabel path downgrades version 2 or relabels imported data as V2.
- Workout finish yields one row that is byte-equivalent for returned, persisted, list, and detail representations.
- All package and focused app suites pass; signed in-place installation preserves the existing database container.

## Assumptions and gates

- iPhone is the primary visual QA target; Watch/widget/Live Activity require source/model parity plus device evidence where available.
- The child branch targets `codex/noop-v2-trends-performance`; neither it nor PR #4 is merged by Codex.
- The attached package reviewed parent SHA `65e58ada`; implementation starts from the current local PR #4 continuation so dashboard work is preserved.
- Physical QA requiring a 12-minute workout, Watch, or unlocked phone is a hard evidence gate and is never claimed from static tests.
