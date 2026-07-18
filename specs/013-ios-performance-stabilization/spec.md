# iOS Performance Stabilization

## Objective

Eliminate avoidable repeated work, actor/database round trips, live-workout O(n) processing, no-op writes, and SwiftUI invalidation fan-out without changing corrected V2 score semantics, imported data, source precedence, Paper UI, HealthKit correctness, edited sleep, or tombstones.

## Acceptance

- One effective repository publication after normal backfill.
- Foreground HealthKit uses seven days and skips unchanged successful write plans for six hours.
- Direct HR and R-R events are processed once; live workout work stays constant-time.
- Bundled reads equal legacy reads and unchanged analysis produces zero mutations/refreshes.
- Today publishes atomic snapshots with fewer update groups/body executions and visual parity.
- Physical-device Release traces demonstrate reduced launch/foreground/backfill/scroll/workout cost.
