# Feature 015 — Today Dashboard Library Adoption

## Goal

Adopt NOOP Design Lab sections 34–38 on iPhone, backed only by production data and actions, while preserving the existing macOS UI and every fix already on `codex/noop-v2-trends-performance`.

## User-visible requirements

- Today uses the new three-pillar hero and a separately tappable workout summary/action.
- Health Monitor is the single customizable Today dashboard with 1–9 persisted tiles.
- The repetitive lower Your Cards block is removed; Show All opens the complete eligible catalog.
- Today at a glance opens a day-focused workouts page. Existing Workouts entry points remain the full management screen.
- A pinned global status chrome appears on iPhone content screens, with page headers immediately below it.
- Missing measurements, baselines, traces, and scores render as unavailable rather than inferred.

## Data and compatibility

- Reuse `today.dashboardCards`; no database schema change.
- Keep stable `DashboardCard` identifiers and normalize legacy/unknown selections deterministically.
- Use canonical `WorkoutRow` reads and Strain V2 values.
- Hydration is eligible only when its existing feature preference is enabled.
- Do not redesign macOS; retain source/build compatibility.
- Install over the existing phone bundle without uninstalling, resetting, or replacing its database.

## Delivery

- Branch: `codex/noop-v2-trends-performance`
- Pull request: #4
- Push implementation and QA evidence to that branch; do not merge.
