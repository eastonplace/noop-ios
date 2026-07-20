# iOS Performance Stabilization Plan

## Phases

1. Capture privacy-safe Release baselines and add signposts.
2. Remove redundant backfill/foreground/diagnostic/HealthKit work.
3. Split HR/R-R routing and add a parity-checked activity accumulator with throttled persistence.
4. Add sorted V2 fast path, analysis read bundle, idempotent upserts, batch sleep/workout reconciliation, and mutation-gated refresh.
5. Publish Today history/day snapshots atomically and extract value-fed leaf views.
6. Compare before/after Instruments evidence and run all data-integrity gates.

Each phase remains independently revertible. Corrected canonical V2 is the score-parity baseline.
