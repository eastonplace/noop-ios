# Implementation plan: four approved features

## Ownership

| Workstream | Files | Owner |
| --- | --- | --- |
| Daily target | New analytics engine/tests, repository adapter/tests, Today section/detail | Root |
| Lift progression | ReceiptLiftFeature sources and corresponding native tests | Lift specialist |
| Voice journal | Parser/tests, journal composer/voice controller, journal adapter/transaction/tests | Journal specialist |
| Workout labels | Pure classifier/tests, source-pinned adapter/tests, AutoWorkoutCard | Workout specialist |
| Integration | Specification, shared configuration, verification record, final review and PR | Root |

## Sequence

1. Inspect current contracts and record source/date/storage ownership before changes.
2. Add failing domain tests, implement each feature, and connect the existing entry point.
3. Test data boundaries, cancellation, stale reviews, failed writes, and persistence compatibility.
4. Review combined changes, fix confirmed defects, and run repository audits and available Swift tests.
5. Publish one draft PR, run the native CI checks, record results and remaining limits, and leave the PR unmerged.

## Acceptance checks

- Current Recovery, sleep, and prior canonical Strain produce a bounded daily target. Missing evidence gives a clear reason. Preview changes no stored metric.
- Lift review uses valid completed history, preserves saved routines, and cannot replace an active workout or a changed coordinator.
- Journal text and dictation share the same explicit review. Conflicts reject all proposed writes atomically.
- Detection labels cite actual motion or confirmed history. Save failure remains visible, and exact source/interval ownership survives each await.
- No changes enter Claude's training-mix implementation or other PR branches.

The user already approved this implementation and GitHub publication. This plan records that work; it does not require another approval step.
