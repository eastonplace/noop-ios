# T102 Tap-through Audit

Runtime: iPhone 17 Pro Max, iOS 26.5, `--demo-seed`, Debug build from `~/Code/noop-completion`.

## Method

- Replayed every deterministic route and every real-shell entry surface from the T101 inventory.
- Exercised visible buttons, navigation rows, segmented controls, toggles, editors, modal close/cancel actions, and destructive confirmations without confirming destructive writes.
- Relaunched after persistence controls and checked the semantic value/state.
- Grepped production callback construction sites for empty closures; DEBUG demo hosts and previews are listed separately.
- Added deterministic, simulator-only fixtures for previously blocked conditional states.

## Results by control family

| Surface family | Controls exercised | Result | Finding / destination |
|---|---:|---|---|
| Root shell | Today, Trends, Sleep, More, Quick Actions, Updates, Devices | PASS | All route correctly; active-tab reselection refresh remains wired. |
| Today header/body | date picker, three score pillars, glance row, stress, health monitor, cards, customise | PASS with parity losses | Rendered controls work. Five pre-reskin destinations are missing and recorded in `interaction-parity.md`. |
| Trends/Sleep | range/segment controls, chart rows, report/export, sleep detail/settings actions | PASS | State changes and destinations render; no crash/misroute. |
| Recovery/Strain/Stress details | factor rows, guide links, history/range controls | PASS — T108 | Recovery recommendation pushes `ScoringGuideView(initialSection: .recovery)` without a callback; Close and Got it now use ambient `dismiss()` and pop the pushed guide. Sheet hosts retain explicit close callbacks. [Entry + guide proof](qa/t108-scoring-guide/) |
| Workouts/history | Start, Add, range chips, sport/source filters, search, workout rows, row menus | PASS | All behavior remains reachable; visual duplication remains an E1 failure. |
| Pre/live/post workout | run type, setup rows, Start, Pause/Resume/Finish, map/chart/splits, Save | PASS | No fake Pause state; controls preserve existing workout state machinery. |
| Live console | Scan, device management, workout start, diagnostics/record/inspect controls | PASS | Existing tools work; they remain visually duplicated pending E2 relocation. |
| Health/Insights/Explore | hub rows, cards, metric rows, compare controls, Deep Timeline navigation | PASS | Explore → Deep Timeline works; Today → Deep Timeline is the known lost interaction. |
| Deep Timeline | metric picker, resolution controls, zoom, pan, reset/back | PASS | Zoom/pan machinery responds and remains intact. |
| Lab Book | Add reading, seeded Ferritin row, detail, edit/delete affordances, disclaimer, CSV entry | PASS | Real `labMarker` rows are created only by `--demo-seed`; marker detail/editor are no longer blocked. |
| Fused record | conflict row, compare sheet, Done | PASS | Synthetic WHOOP 58 vs Apple Health 71 conflict opens the real comparison sheet. |
| Hydration | seeded card, quick-add sizes, custom amount, entry edit/delete | PASS | Feature enabled and populated only under `--demo-seed`; persistence paths use the real hydration store. |
| Health alert | seeded illness-watch state | PASS | Real illness engine renders the Heads-up banner from abnormal recent rows; no hardcoded view copy. |
| Backup & Sync | auto toggle, Back up now, Restore picker, Cancel | PASS (sim-safe fixture) | Demo Back up reports success without writing; restore picker receives a synthetic filename and never overwrites data. Production path is untouched. |
| Devices/add wizard | device rows, Add, catalog, scan/back/continue, Oura flows | PASS | Expected Bluetooth/system permission boundaries remain explicit. |
| Data/settings/support | rows, toggles, editors, diagnostics Copy/Close, What's New, support links | PASS | Notification row is informational on iPhone; see T103. |
| Automations/alarms/Test Centre | toggles, alarm controls, test runs, report/review entry | PASS | Toggle state survives relaunch; Test Centre report flow opens after seeded run. |
| Rhythm/breathing/intervals | consent, mode selection, start/stop, duration/timer controls | PASS | No crash or false primary action. |
| Onboarding/Terms | 12 steps, Back/Continue, profile steppers, import choices, theme, Enter; four terms toggles | PASS | Full flow completes. Visual system fails Paper conformance but controls work. |

## Empty-callback audit

Production finding — fixed T108:

- `Strand/Screens/CoupledView.swift` Recovery recommendation now constructs `ScoringGuideView(initialSection: .recovery)` with no callback; the guide's shared `close()` falls through to environment dismissal for this pushed path.

Expected non-production/semantic no-ops:

- DEBUG demo hosts in `StrandiOSApp.swift` pass empty callbacks because the full-bleed screenshot harness has no presenting sheet to dismiss.
- `#Preview` constructors pass empty callbacks.
- `.cancel`/`.ok` alert buttons with empty actions rely on SwiftUI's standard dismissal semantics and work.

No second production dead control or misroute was found. T108 owns the confirmed fix and re-tap proof.

Android parity note: the old source comment said Android mirrored the internal `charge` / `effort` / `rest` section case names. T108 renamed the Apple-only identifiers to `recovery` / `strain` / `sleep`; that Android mirror comment is now stale. Android synchronization is explicitly out of scope for Spec 005.
