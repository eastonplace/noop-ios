# Plan 005 — Paper UI Density and Stress Polish

## Safety and rollback

- Work only in `~/Code/noop-completion` on `reskin/paper-ui`.
- Push only to `private-noop-report`.
- Baseline tag: `pre-paper-polish` at `7f8369c9`.
- Snapshot: `/private/tmp/noop-pre-paper-polish-2026-07-11.tar.gz`.
- One `polish(T##)` commit and push per gate; screenshots live in `qa/`.

## Implementation

1. Lock the shared density, card, and header tokens in StrandDesign and
   `ScreenScaffold`; preserve interaction heights.
2. Correct Today stress-slot rendering and cover empty/partial/mixed states with
   pure unit tests.
3. Tune core screen composition using the shared system, avoiding per-screen
   constants unless the reference demands unique structure.
4. Re-shoot light/dark after each visual gate and compare against the refined
   sheets and Spec 004 contact sheet.
5. Run XL proof on Today, Sleep, Recovery detail, and Strain detail; regenerate
   the final contact sheet and re-score fidelity.

## Verification

- `NOOPiOS` simulator build after every task.
- Focused StrandDesign/iOS unit tests for changed rendering helpers.
- Seeded screenshots on iPhone 17 Pro Max with `--demo-seed`.
- Light/dark per visual task; XL for the final accessibility gate.
- No storage migration and no changes to scoring, BLE, or navigation behavior.

