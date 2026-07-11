# T103 Reachability Matrix

Baseline: `pre-paper-reskin`  
Current: `reskin/paper-ui`

## Inventory comparison

| Inventory | Pre-reskin | Current | Lost |
|---|---:|---:|---:|
| iPhone More rows | 26 | 26 | 0 |
| Shared `RootView` destinations | 29 | 29 | 0 |
| Primary iPhone tabs | 4 | 4 | 0 |
| Quick Actions | 4 | 4 | 0 |
| Device/header utilities | Updates + Devices | Updates + Devices | 0 |

The exact sorted More-row and shared-root destination diffs are empty.

## Notification Settings review note

`NotificationSettingsView` is **not a lost iPhone entry point**:

- Before and after the reskin, iPhone Settings renders an informational `Notifications — System` row, not a `NavigationLink` to `NotificationSettingsView`.
- Before and after, `project.yml` excludes `NotificationSettingsView.swift` and its AppKit-backed store from `NOOPiOS`.
- Before and after, the screen is reachable on macOS through `RootView` destination `.notifications`.
- iPhone wrist-alert controls remain in Automations, matching the existing platform split.

Adding an iPhone row would point at code intentionally absent from the target and would create a new broken affordance. No restoration is appropriate.

## Conditional reachability resolved by T102 fixtures

| Surface | Seeded entry |
|---|---|
| Marker detail/editor | Lab Book seeded Ferritin row + Add reading |
| Conflict compare | Fused record seeded WHOOP/Apple conflict row |
| Hydration/detail/amount | Today seeded Hydration card |
| Health alert | Today/Health seeded illness-watch output |
| Backup restore picker | Backup & Sync synthetic demo snapshot |
| Test report review | Test Centre seeded test run |

## Orphan candidates

- No production screen reachable before the reskin became a code orphan.
- DEBUG demo hosts are test harnesses, not production entry points.
- Legacy rendering builders and dead migration remnants remain deletion candidates only where T106/T111 can prove zero call sites across all platforms.
- Proposed retirements: none.

