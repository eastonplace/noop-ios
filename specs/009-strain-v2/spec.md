# Canonical Strain V2

## Objective

Make the timestamp-aware continuous-HRR Strain V2 score canonical for every NOOP-owned daily and workout record while preserving imported scores exactly.

## Requirements

- Home, history, Trends, Watch, reports, and workout surfaces consume one canonical score.
- Daily and workout V2 rows carry `strainVersion = 2`; imported rows retain nil provenance.
- Home and historical analysis share the same physiological-day inputs and never compare V2 against V1 by taking a maximum.
- Historical NOOP-owned rows are recomputed from raw evidence in cancellable, resumable 30-day chunks.
- Rows without sufficient evidence remain unchanged; shadow candidates are removed only after canonical persistence succeeds.
- The migration pauses during active workouts, backfill, cancellation, or background transition and is idempotent after completion.

## Acceptance

- Identical day context produces identical live and persisted V2.
- Imported daily/workout records remain byte-identical.
- A repeated completed migration performs zero mutations.
- All user-visible surfaces resolve to the same fixture score.
