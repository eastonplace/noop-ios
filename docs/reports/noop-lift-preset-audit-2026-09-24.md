> Final verification: see [release verification](noop-release-verification-2026-09-24.md). Full app and package tests now pass; the startup stall is fixed. Findings below retain the original audit context.

# NOOP Lift preset audit, 2026-09-24

**Status: Partial.** Source parity is verified. The parent reports that the simulator build passed and that the full Xcode tests are now running. This audit did not run Xcode.

## Preset parity

The five routine templates in `../lift-reference-20260924/LiftApp/LiftStore.swift` match the `LiftRoutineBank` templates in `Packages/ReceiptLiftFeature/Sources/ReceiptLiftFeature/LiftStore.swift`. The compared bank blocks are identical.

| Preset | Planned exercises |
| --- | ---: |
| Upper A | 8 |
| Lower A | 7 |
| Pull + Posture | 9 |
| Push + Delts | 9 |
| Lower B | 7 |
| **Total** | **40** |

The bank also contains 37 starter exercises. The 40 plan rows reuse some exercises across routines.

## Database load and tests

`ReceiptLiftCoordinator` creates `ReceiptLiftDatabase` from load and save closures. `LiftStore.performLoad()` seeds the routine bank when the database adapter returns no envelope, then schedules the seed envelope through the database save path. The new tests exercise this coordinator and store path with an in-memory database adapter. They do not use `RoutinePreviewFixtures` or the sample preview.

`StrandiOSTests/ReceiptLift/ReceiptLiftDatabaseTests.swift` checks the exact preset names and exercise order, all 40 plans resolving to exercises, the saved database envelope, save failure and retry, source discard, invalidation during a suspended load, and completed barbell bench metadata. The bench assertion expects catalog target `pectorals` and secondary muscles `triceps` and `shoulders`.

The simulator build and test execution status above are parent-reported. The test run remains the gate for runtime confirmation.

## Gaps and potential bugs

- No preset name or plan row is missing from the current imported bank source. Runtime resolution of every plan is covered by the new test, pending its Xcode result.
- `LiftStore.makeStarterRoutine` uses `compactMap` for exercise-name resolution. A future missing or renamed exercise can silently remove a plan row. The new expected plan list will catch that for these five presets.
- In the file-backed legacy migration, `LiftPersistence.loadLocked()` filters the old `Push Day`, `Pull Day`, and `Leg Day` names, then stamps `starterBankVersion` as current. `applyStarterBankUpdatesIfNeeded()` will consequently skip adding the five current presets. This is a potential legacy file-migration gap. The database-backed fresh-load path tested here does not use that migration.

## Changed paths

- `StrandiOSTests/ReceiptLift/ReceiptLiftDatabaseTests.swift`
- `docs/reports/noop-lift-preset-audit-2026-09-24.md`
