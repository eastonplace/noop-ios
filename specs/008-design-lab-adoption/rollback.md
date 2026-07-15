# Rollback 008 — Design Lab Adoption

## Principles

- Every phase is one revertible slice (commit or PR) in the migration order.
- Promotions are **additive** (new package files) and upgrades are **API-preserving**,
  so the package layer can outlive any screen rollback: reverting a screen adoption
  never requires reverting StrandDesign.
- Ad-hoc implementations are deleted only in the commit that replaces them, so a
  single revert restores the exact previous presentation.
- No data migrations exist in this spec; rollback is purely code-level. Nothing to
  down-migrate, no stored-state compatibility risk.

## Abort Criteria (stop the phase, roll it back)

1. Engine-output drift: the T031 fixture-diff test shows any changed
   SleepModel/DaytimeStress/StressTotals/TrendPoint value.
2. Palette drift: `Palette.swift`/strain-token fingerprint changes attributable to
   this spec.
3. Realtime performance regression: visible frame drops on the live HR surfaces after
   pulse/reveal adoption (profile before/after on the primary device).
4. macOS target fails to compile from a package change.
5. Accessibility regression: any touched control loses its VoiceOver label/trait or
   44 pt target.

## Per-Phase Rollback

| Phase | Checkpoint | Rollback action | Residue after rollback |
|---|---|---|---|
| 0 Audit | `4e16269` | Revert evidence/spec ledger only | No product code changed |
| 1 Atoms | `4e10983` | Revert package commit; delete new files | None — nothing consumed them yet |
| 2 States/toast | `6f7f762` | Revert per-screen commit | Package atoms remain, unused — harmless, keep |
| 3 Sleep | `45bbad4` | Revert Sleep adoption commit; `highlightedStage` reverts with it | Hypnogram returns to pre-008 styling; selection remains |
| 4 Stress | `39fd552` | Revert Stress/Today adoption commit | Stress totals return to LiquidTube fills |
| 5 Trends/nav | `0902276` | Revert Trends/DayNav commit | Chart remains; summary rows disappear |
| 6 Convergence | `785cc75` | Revert the convergence commit | Screens regain their prior ad-hoc copies |
| 7 QA | final phase commit | Revert evidence/ledger only | Remove the lab coverage note if phases 3–6 are rolled back |

## Partial-Ship Positions (acceptable stopping points)

- After Phase 2: atoms + toast/states shipped, screens otherwise untouched — coherent.
- After Phase 4: the user-visible micro-detail goal (sleep+stress) shipped — coherent.
- Stopping between 3 and 4 is acceptable but must be recorded in TASKS.md as an open
  slice; stopping mid-phase is not an acceptable ship state.

## Procedure

1. Identify the failing abort criterion and capture evidence (test output, profile,
   screenshot) into `outputs/2026-07-14/design-lab-adoption/qa/rollback/`.
2. `git revert` the phase's commits in reverse order (or close the PR slice).
3. Re-run the phase's verification gate from plan.md to confirm restoration
   (before-screenshots from T001 are the comparison baseline).
4. Record the rollback, cause, and disposition (fix-forward plan or descope) in
   tasks.md Execution Evidence and TASKS.md.
5. If the package layer itself was reverted (Phase 1), re-run the full T003 baseline
   before any retry.
