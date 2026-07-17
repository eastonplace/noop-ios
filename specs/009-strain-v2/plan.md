# NOOP Strain V2 Implementation Plan

## Update map

| Surface | Change | User-visible result | Verification |
|---|---|---|---|
| StrandAnalytics | Add continuous timestamp-aware V2 scorer | Ordinary movement registers; extreme effort saturates honestly | Unit anchors and cadence tests |
| Daily analytics | Feed sleep, steps, energy, and cycle HR into physiological-day mode | Day Strain reflects the physiological day | Integration and ownership tests |
| Workouts/live | Use activity mode | Workout Strain shares the new cardio curve without background credit | Workout/live tests |
| WhoopStore | Add nullable scorer provenance and shadow storage | Imported WHOOP values remain untouched | Migration/readback tests |
| Documentation | Correct the movement-floor and algorithm explanation | Scoring guide matches shipped behavior | Source review |

## Execution

1. Add failing V2 unit tests for anchors, cadence equivalence, gaps, bounds, and missing inputs.
2. Implement the pure V2 scorer and movement-floor helpers.
3. Thread V2 inputs through daily, workout, manual-rescore, and live paths.
4. Add nullable version provenance, V2 shadow metrics, and idempotent cutover support.
5. Update documentation and comparison reporting.
6. Run package tests, app tests, iPhone build, and populated visual QA.

## Gates

- Preserve the existing localization-catalog change.
- Do not rewrite imported WHOOP rows.
- Do not add muscular-load claims or scoring.
- Shadow comparison must exist before canonical historical cutover is enabled.

