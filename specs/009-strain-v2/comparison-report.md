# Strain V2 Shadow Comparison

Status: implementation baseline. Population results remain a rollout gate and are populated from `strain_v2_shadow` after at least 14 paired WHOOP cycles exist.

## Deterministic anchors

| Scenario | Expected V2 display strain | Acceptance |
|---|---:|---:|
| 8 hours valid worn sleep, no cardiovascular load | 4.00 | approximately 4.0 |
| 6,000 steps | 4.42 | 4–7 |
| 12,000 steps | 6.05 | 4–7 |
| 60 minutes at 70% HRR plus sleep seed | 13.70 | 13–14.5 |
| 60 minutes at at least 90% HRR plus sleep seed | 18.40 | 18–19 |
| 6 hours at at least 90% HRR | 21.00 (asymptotic) | at least 20.9 |

These are equation-derived expectations and are enforced by `StrainScorerV2Tests`; they are not a substitute for a successful test run.

## Population rollout gates

- Distribution: compare V1, V2 shadow, and imported WHOOP day-strain percentiles (P10/P25/P50/P75/P90).
- Coverage: count cycles with fewer than 20 HR samples, under 10 minutes integrated coverage, gaps over 90 seconds, missing main sleep, and missing movement inputs.
- Paired WHOOP: once at least 14 paired cycles exist, median absolute display-strain difference must be at most 2.5.
- Monotonicity: more effective load must never lower V2 strain; movement floors must never lower cardiovascular strain.
- Outliers: inspect the ten largest V1-to-V2 and WHOOP-to-V2 absolute differences with sleep ownership, HR coverage, steps, and active energy visible.
- Imported-data safety: WHOOP-owned daily and workout rows must remain unversioned and byte-identical.

## Promotion rule

Do not call `cutoverStrainV2` until the deterministic test suite passes and the applicable population gates above pass. Promotion is atomic per supplied batch, only accepts NOOP-computed source IDs ending in `-noop`, removes only successfully promoted shadows, and is safe to resume with the same rows.
