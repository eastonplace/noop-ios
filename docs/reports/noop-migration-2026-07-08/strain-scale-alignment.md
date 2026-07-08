# Noop Strain Scale Alignment Note

Date: 2026-07-08
Status: alignment note only; no Noop source changes made in this publish step.

## Decision Direction

Yes: change user-facing `Effort` language to `Strain` where the metric is intended to represent WHOOP-like cardiovascular load.

Recommended display model:

- Label: `Strain`
- Scale: WHOOP-style `0.0` to `21.0`
- Formatting: one decimal place for headline values, for example `14.7`
- Copy: avoid implying official WHOOP scoring unless the underlying formula is truly parity-tested.
- Implementation posture: rename the UI and domain concept surgically first, then wire exact scoring math behind that label only where validated.

## Why

`Effort` is generic. For a WHOOP replacement app, `Strain` is the mental model Easton will expect on workouts, route details, daily cards, and recovery/training context. It also fits the Noop data model already noted in the migration report, where `noop_daily_metrics` and `noop_workouts` should carry strain as a first-class metric.

## Guardrail

Do not fake WHOOP parity. If the current formula is an approximation, display it as Noop strain on the WHOOP-style range, and keep a future parity/audit path for exact scoring differences.

## Likely Surfaces

- Workouts list and workout detail metric chips.
- Route detail chips currently described as effort/pace/elevation.
- Daily metric summaries.
- Supabase schema fields such as `strain`, `strain_score`, or equivalent typed columns.
- Any generated route concept board language can be updated from `Effort` to `Strain` in the next design pass.
