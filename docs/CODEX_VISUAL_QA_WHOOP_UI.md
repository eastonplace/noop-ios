# Codex handoff: NOOP WHOOP-aligned UI visual QA

Use this document as the complete execution prompt.

## Mission

Visually and technically qualify branch `design/whoop-unified-ui-20260821` at its exact remote head.

The branch changes NOOP's shared visual system to one dark graphite theme. It keeps existing components, product copy, data semantics, alarm behavior, BLE behavior, and local-first storage.

Do not merge the PR. Do not redesign components. Do not rename NOOP concepts. Do not copy WHOOP logos, screenshots, artwork, or wordmarks.

## 1. Establish the evidence head

Work in a clean worktree.

```bash
git fetch origin --prune
git switch --detach origin/design/whoop-unified-ui-20260821
export QA_HEAD="$(git rev-parse HEAD)"
printf 'QA_HEAD=%s\n' "$QA_HEAD"
git status --short --branch
```

Record:

- `QA_HEAD`.
- Xcode version.
- Swift version.
- macOS version.
- Simulator runtime.
- Simulator device and UDID.

Every screenshot, test log, trace, and finding must name `QA_HEAD`. Stop if the branch moves. Restart from the new exact head.

## 2. Read before changing source

Read these files fully:

1. `docs/WHOOP_UI_AUDIT.md`
2. `docs/WHOOP_UI_FILE_MATRIX.md`
3. `Packages/StrandDesign/Sources/StrandDesign/Appearance.swift`
4. `Packages/StrandDesign/Sources/StrandDesign/Palette.swift`
5. `Packages/StrandDesign/Sources/StrandDesign/Typography.swift`
6. `Packages/StrandDesign/Sources/StrandDesign/StrandCard.swift`
7. `Strand/Screens/ScreenScaffold.swift`
8. `StrandiOS/App/RootTabView.swift`
9. `Strand/Screens/TodayView.swift`
10. `Strand/Screens/SleepView.swift`
11. `Strand/Screens/SettingsView.swift`

Use the official WHOOP developer design guide only as a visual reference. Keep NOOP identity and labels.

## 3. Build gates

Run the repository audits first.

```bash
set -o pipefail
mkdir -p qa-artifacts/whoop-ui/audits
for audit in Tools/qa/*_audit.py; do
  name="$(basename "$audit" .py)"
  python3 "$audit" 2>&1 | tee "qa-artifacts/whoop-ui/audits/$name.txt"
done
```

Generate the project.

```bash
xcodegen generate 2>&1 | tee qa-artifacts/whoop-ui/xcodegen.txt
```

Build the app and extensions.

```bash
xcodebuild \
  -scheme NOOPiOS \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build 2>&1 | tee qa-artifacts/whoop-ui/build.txt
```

Run iPhone tests on an available simulator.

```bash
xcodebuild \
  -scheme NOOPiOS \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=<UDID>' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  test 2>&1 | tee qa-artifacts/whoop-ui/tests.txt
```

Run the design package separately.

```bash
swift test --package-path Packages/StrandDesign \
  2>&1 | tee qa-artifacts/whoop-ui/strand-design-tests.txt
```

Required result: all commands pass at `QA_HEAD`.

## 4. Device matrix

Use these simulator widths:

| Device class | Purpose |
|---|---|
| Small iPhone, such as iPhone SE | Wrapping, compact height, minimum hit targets. |
| Current standard iPhone | Primary acceptance device. |
| Current Pro Max | Wide cards, max line length, chart expansion. |

Run the standard device in portrait for the complete app. Use the small and large devices for every root tab, Sleep, Settings, Live Workout, Coach, and long forms.

## 5. System appearance matrix

For the standard simulator, test all conditions below.

### System Light

Set iOS to Light. Launch NOOP cold.

Expected:

- NOOP remains dark.
- Launch screen transition does not flash white.
- Navigation stacks remain dark.
- Sheets remain dark.
- Date pickers, menus, and keyboards use a compatible dark presentation.
- Status bar content remains readable.

### System Dark

Repeat the same route set.

Expected:

- Visual output matches the Light-system run.
- No token changes occur.

### Accessibility settings

Run the important routes with:

- Largest Accessibility Dynamic Type.
- Bold Text.
- Increase Contrast.
- Reduce Transparency.
- Reduce Motion.
- Button Shapes.
- Differentiate Without Color.

Record clipping, truncation, overlap, hidden actions, or color-only meaning.

## 6. Global design checks

### Canvas

- Base canvas is near-black graphite.
- No screen uses a bright canvas.
- No day/night or time-of-day scene changes the root background.
- Pushed routes and sheets use the same visual family.

### Typography

- Body copy uses one native sans-serif family.
- Headings use a consistent bold hierarchy.
- Overlines use uppercase and tracking only for short labels.
- Numbers use bold tabular digits.
- Live values do not change horizontal width as digits update.
- Dynamic Type scales prose without breaking fixed gauges.

### Color

- Generic primary actions use teal `#00F19F`.
- Recovery low uses red `#FF0026`.
- Recovery medium uses yellow `#FFDE00`.
- Recovery high uses green `#16EC06`.
- Strain uses blue `#0093E7`.
- Sleep uses blue-gray `#7BA1BB`.
- Sleep Need uses teal `#00F19F`.
- Recovery data uses `#67AEE6`.
- No score color is reused as generic card chrome.

Test Recovery at values 33, 34, 66, and 67.

### Cards

- Cards use the same graphite gradient, radius, border, and shadow.
- Domain tint is a quiet wash, not a full card fill.
- Long lists do not look like separate mini-apps.
- Nested cards remain visually distinct.
- Flat content sections keep clear separators.

### Controls

- Primary button is teal with dark text.
- Secondary button uses a neutral raised surface.
- Destructive action uses red and retains a confirmation gate.
- Disabled state remains readable.
- Every control has at least a 44-point hit target.
- Toggle, picker, text field, date picker, menu, and sheet controls fit the dark system.

### Motion

- Card press feedback is subtle.
- Chart style does not reset navigation or scroll state.
- Switching tabs does not restart unrelated visible tasks.
- Reduce Motion removes scale-heavy effects.

## 7. Route-by-route screenshot contract

Capture each route in a stable, named state. Use this filename pattern:

`<QA_HEAD>-<device>-<route>-<state>-<accessibility>.png`

### Root: Today

Capture:

- Normal current day.
- No Recovery yet.
- No Sleep yet.
- Disconnected strap.
- Historical day.
- Edited dashboard cards.
- Stress calibrating.
- Skin temperature unavailable.
- Long unit values.

Check:

- One coherent first load.
- Score trio color meaning.
- Health monitor tile consistency.
- No day-cycle background.
- No independent card flashes after the hero stabilizes.

### Root: Trends

Capture:

- Weekly review.
- Selected range.
- Empty range.
- One data point.
- Dense range.
- Scrub state.

Check axes, labels, tooltips, selected state, and contrast.

### Root: Workouts

Capture:

- Empty list.
- Mixed workout list.
- Long workout name.
- Workout detail.
- Manual workout sheet.
- Live workout.
- Paused live workout.

Check timer width, HR zones, destructive end flow, and long-session updates.

### Root: Settings

Capture:

- Root catalog.
- Search.
- Appearance and Units.
- WHOOP device settings.
- Sync and Battery.
- Sleep Alarm.
- Diagnostics.
- Data Sources and Storage.
- Backup and Restore.
- About and educational sheets.

Special inspection:

- Find every active appearance control.
- Find every active day-cycle toggle.
- Confirm whether native and legacy settings paths are both reachable.
- Record exact source path and navigation steps for duplicate controls.
- Remove stale controls only after proving the active route.

### Secondary routes

Capture one normal state and one edge state for:

- Health.
- Stress.
- Coach.
- Compare.
- Insights.
- Metric Explorer.
- Full Day HR.
- Devices.
- Test Centre.
- Apple Health.
- Automations.
- Journal.
- Hydration.
- Breathing.
- Interval Timer.
- Storage.
- Weekly Digest.
- Fitness Age.
- Smart Alarm.
- Add Device wizard.

Use `docs/WHOOP_UI_FILE_MATRIX.md` as the complete route checklist.

## 8. Sleep qualification

Sleep is the highest-priority screen.

### Data fixtures or states

Create or select evidence for:

1. No sleep data.
2. Normal staged main sleep.
3. Valid sleep with no stage packets.
4. Stage-less processing stub.
5. Split main sleep.
6. Main sleep plus nap.
7. Nap only.
8. Invalid session.
9. Historical night.
10. Current night while aggregate data is still loading.
11. One ledger night.
12. Fourteen ledger nights.
13. Debt balance below zero.
14. Debt balance crossing zero.
15. Sleep Need unavailable.
16. Sleep Need available after a delayed leaf load.

### Visual checks

- Hero reads first.
- Stages and sleep window form one result group.
- Key metrics do not appear too late.
- Sleep Need and debt read as one planning group.
- Alarm, mark, nap, and rhythm actions do not overpower results.
- Each loading state reserves stable height.
- No section jumps after data arrives.
- Stage labels remain readable at minimum band size.
- Split sleep and nap labels are clear.

### Ledger root-cause test

Reproduce this ordering:

1. Session data becomes available in `night.allSessions`.
2. The daily aggregate for the same wake day has no `previousNightSleepHours` yet.
3. Open Sleep before aggregate reconciliation.
4. Observe hero and ledger.
5. Trigger or wait for aggregate refresh.
6. Observe whether the ledger appears, duplicates, reorders, or changes balance.

Record:

- Session identifiers.
- Wake-day key.
- Aggregate day key.
- Displayed sleep duration.
- Ledger row count before and after refresh.
- Balance before and after refresh.
- Whether a nap or split block was counted.

A valid source fix must follow the correction contract in `docs/WHOOP_UI_AUDIT.md`. Do not fill the ledger with a visual-only guess.

### Sleep performance trace

Measure:

- Tap-to-first-content time.
- Main-thread work before hero display.
- Number of `SleepModel` builds.
- Repository refresh count.
- Number of independent loading transitions above the fold.
- Layout shifts.
- Scrolling frame rate.

Use Instruments Time Profiler and SwiftUI where available. Attach the trace or a summary with top stacks.

## 9. Performance checks across the app

### Cold launch

Record launch to first usable Today content.

Fail when:

- A white frame appears.
- Main-thread work blocks input for a visible interval.
- Unrelated tabs construct heavy models before use.

### Tab switching

Cycle Today, Trends, Workouts, Settings, then return to Today.

Verify:

- Scroll positions remain stable.
- Navigation state remains stable.
- No global task restart occurs because of chart style.
- No duplicate repository refresh starts.

### Long lists

Profile Settings, Devices, Journal, Test Centre, and Metric Explorer.

Verify:

- Card shadows do not cause visible scroll hitching.
- Off-screen rows stay lazy where supported.
- High-frequency publishers do not invalidate the entire list.

### Charts

Scrub and scroll charts while data updates.

Verify:

- Tooltips track correctly.
- Gradient/color cache does not grow without limit.
- No chart reanimates because a parent card hover or state change fires.

## 10. Fix rules

You may make a source change only when evidence names:

- Route.
- Device.
- State.
- Expected behavior.
- Actual behavior.
- Owning file.
- Root cause.

Keep fixes small. Prefer shared tokens for visual drift. Prefer leaf observation for live data. Preserve existing public component APIs unless a compile-safe migration is included.

Never change:

- Score formulas.
- Sleep classification.
- Recovery calibration.
- BLE commands.
- WHOOP 5/MG experimental gates.
- Stored data schema.
- Smart Alarm occurrence identity, DST behavior, or background completion rules.
- Local-first privacy guarantees.

## 11. Finding template

Use one block per finding:

```markdown
### UI-<number>: <title>

- QA head:
- Severity:
- Route:
- Device and iOS:
- Accessibility settings:
- Source owner:
- State or fixture:
- Expected:
- Actual:
- Root cause:
- Fix:
- Tests added:
- Screenshot before:
- Screenshot after:
- Trace or log:
- Residual risk:
```

Severity:

- P0: unsafe data or destructive behavior.
- P1: app unusable, wrong health meaning, alarm error, or repeatable crash.
- P2: major visual break, inaccessible control, severe performance problem.
- P3: local inconsistency or polish defect.

## 12. Final package

Create:

- `qa-artifacts/whoop-ui/REPORT.md`
- `qa-artifacts/whoop-ui/screenshots/`
- `qa-artifacts/whoop-ui/audits/`
- `qa-artifacts/whoop-ui/build.txt`
- `qa-artifacts/whoop-ui/tests.txt`
- `qa-artifacts/whoop-ui/strand-design-tests.txt`
- Instruments summaries or traces.

`REPORT.md` must include:

- Exact `QA_HEAD`.
- Pass/fail for every build gate.
- Device matrix completed.
- Accessibility matrix completed.
- Route matrix completed.
- Sleep fixture matrix completed.
- Performance measurements.
- Findings and fixes.
- Changed files.
- Remaining risks.
- Merge recommendation.

A compile-only report is a fail. A screenshot-only report is a fail. A report without the exact head SHA is a fail.
