# Plan

1. Import the immutable `COMMON_BASE..UPSTREAM_STABLE` backend allowlist with three-way context.
2. Resolve overlaps using package Sections 5–8: private structure wins; upstream correctness behavior is integrated semantically.
3. Add private migration numbering and exact R-R/HRV/R22/PPG/power/sync/identity contracts.
4. Run package suites, migration fixtures, scope gates, and a signed Release iPhone build/install without resetting or seeding phone data.
5. Commit in buildable layers, push `codex/reconcile-nuke-9.0.1`, and open the package-defined draft PR.

## Adaptations to the attached package

- Do not guard against the now-stale observed upstream `main`; verify only the immutable stable and selected commit SHAs.
- Run from this clean isolated worktree, not the canonical checkout that preserves a local localization delta.
- Merge new migration tests into private coverage rather than deleting newer tests wholesale.
- Keep QA iPhone-only: Swift package tests plus generic/signed physical-iPhone build and available real-device checks; no iPad/watch/macOS-app/simulator claims.
- Treat `specs/009-strain-v2` as the newer product source of truth. Preserve its 0–100 storage boundary
  while forcing every display path to the canonical 0–21 scale; place provenance after reconciliation
  migrations as `v29-strain-v2`, never at the colliding original v25 number.
