# Implementation Plan

## Feature / thing update map

| Update | Why | Affected surfaces | User-visible result | Verification |
|---|---|---|---|---|
| Canonical resolved Strain | Merged daily fields cannot encode origin/freshness | Repository, Today/detail, Trends, Coupled, reports, widgets, Live Activity, Watch | One V2 value per day; imported remains labeled | Resolver matrix and cross-surface fixtures |
| Provenance-safe copying | Memberwise rebuilds drop `strainVersion` | DailyMetric and WorkoutRow merge/edit/relabel/import paths | V2 stays V2; imported stays imported | Copy/merge regression tests |
| Live-day coordinator | Today's private snapshot can remain stale | AppModel/Repository, Today/detail, external publishers | Home advances without navigation | Frontier freshness and mounted-phone QA |
| Live workout state | Nil is currently coerced to zero | AppModel persistence and LiveWorkout UI | Building before score gate | Gate/parity/rehydration tests |
| Durable finish | Fire-and-forget save races UI | AppModel, LiveWorkout, Workouts list/detail | Saving state; identical persisted summary | Failure/success/read-back tests |
| Surface migration | Direct reads mix versions/origins | All matrix rows | Canonical V2 everywhere | Static audit plus model parity |

## Execution

1. Add failing provenance, resolver, freshness, live-building, and finish-equivalence tests; inventory every production occurrence in `surface-matrix.csv`.
2. Add preservation-first copy APIs and refactor lossy daily/workout paths.
3. Add `ResolvedStrain`, pure `StrainResolver`, repository canonical daily/workout APIs, and explicit imported comparison access.
4. Add an incremental physiological-day accumulator/coordinator outside Today and reconcile on frontier/cycle/backfill changes.
5. Replace live workout numeric default with Building/scored state and make finish an awaited durable transaction.
6. Route every user-facing/internal publication surface through the canonical resolver; retire ambiguous production Effort presentation aliases.
7. Run package/app/regression suites, source audit, signed build, in-place phone install, database check, and physical equality QA.
8. Commit/push the child branch, open a child PR against PR #4's branch, run no-mistakes, and leave both PRs unmerged.

## Architecture decisions

- Resolved provenance/freshness is a domain contract, not a view concern.
- Raw frontier timestamps outrank wall-clock timestamps for live-vs-persisted selection.
- Imported comparisons remain separately queryable; merged `DailyMetric.strain` is not a canonical headline source.
- Live-day and live-workout integration share the authoritative V2 kernels to prevent formula drift.
- Workout success is defined by persisted read-back, not by completion of in-memory scoring.

## Risks and gates

- Source audit is broad; migration must be staged behind tests to avoid silently changing imported presentation semantics.
- Foreground update cadence must not reintroduce HR-driven whole-screen invalidation or full-history reads.
- External surfaces throttle publication, so equality is measured against the same resolved source within their refresh windows.
- Phone data preservation, physical Home/detail equality, Building state, and post-finish equality are hard release gates.
