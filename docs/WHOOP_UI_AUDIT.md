# NOOP WHOOP-aligned UI audit

Branch: `design/whoop-unified-ui-20260821`

Reference: [WHOOP developer design guidelines](https://developer.whoop.com/docs/developing/design-guidelines/)

## 1. Goal

This pass gives NOOP one visual language across the iPhone app. It changes the shared appearance, color, type, card, and interaction contracts. It does not change the app's health logic, score formulas, data ownership, BLE commands, storage schema, alarm behavior, or screen component responsibilities.

The app keeps NOOP names and product identity. WHOOP is the design reference only. No WHOOP logo, wordmark, product copy, or protected image asset is added.

## 2. Locked scope

### Included

- One fixed dark appearance.
- One chart color grammar.
- One native Apple type system.
- One dark graphite surface hierarchy.
- One action color.
- Existing metric colors remain tied to their metric meaning.
- Existing components retain their public interfaces.
- Existing screen composition remains intact unless a later visual-QA finding proves a layout defect.
- Source-level performance review for root invalidation, high-frequency observation, repeated async loading, and large first-frame work.
- Detailed Sleep screen and Sleep ledger review.

### Excluded

- Score or health-model changes.
- New features.
- Backend, database, protocol, and BLE changes.
- Alarm schedule changes.
- Renaming NOOP concepts to WHOOP concepts.
- New third-party font files.
- Copying WHOOP artwork or app screenshots.
- Merge or release approval.

## 3. Official design mapping

| Design role | NOOP token | Value or behavior |
|---|---|---|
| App background | `StrandPalette.canvas` | `#101518` |
| Elevated graphite | `StrandPalette.cardFillTop` | `#283339` |
| Card body | `StrandPalette.card` | `#182126` |
| Card edge | `StrandPalette.cardBorder` | `#2A383F` |
| Primary text | `StrandPalette.textPrimary` | `#FFFFFF` |
| Primary action | `StrandPalette.ink`, `link`, `accent` | `#00F19F` |
| Recovery low | `recoveryLow` | `#FF0026`, scores 0–33 |
| Recovery medium | `recoveryMed` | `#FFDE00`, scores 34–66 |
| Recovery high | `recoveryHigh` | `#16EC06`, scores 67–100 |
| Strain | `strainAccent` | `#0093E7` |
| Sleep | `sleepAccent` | `#7BA1BB` |
| Sleep Need | `sleepNeedTeal` | `#00F19F` |
| Recovery data | `recoveryData` | `#67AEE6` |
| Word type | `StrandFont` semantic roles | Native Apple system sans-serif |
| Numeric type | `display`, `number`, `rounded` | Bold, tabular system digits |

The official guide permits a platform-default sans-serif fallback. NOOP uses native system fonts instead of shipping or looking up third-party font files.

## 4. Direct implementation

### `Packages/StrandDesign/Sources/StrandDesign/Appearance.swift`

Changes:

- Every stored appearance value resolves to dark.
- The visible appearance list has one `Dark` option.
- Every stored chart-style value resolves to the default style.
- The visible chart-style list has one `Default` option.
- `chartStyle(_:)` no longer adds `.id(...)` to the complete app tree.
- The day-cycle preference remains readable for migration safety, but the scene is disabled.
- Bloom and elevation use one dark-surface implementation.

Performance result:

The old `.id("noop.chartStyle.\(raw)")` replaced the complete root identity. A preference update could rebuild navigation, restart tasks, reset scroll state, and reconstruct every visible chart. The fixed style now updates the palette without replacing the app tree.

### `Packages/StrandDesign/Sources/StrandDesign/Palette.swift`

Changes:

- Every former light/dark token resolves to the fixed dark value.
- Generic actions use teal.
- Card, inset, border, text, and background tokens use one graphite hierarchy.
- WHOOP score colors remain distinct.
- Recovery uses exact hard bands at 0–33, 34–66, and 67–100.
- Legacy `gold*` names remain source-compatible but resolve to the teal action ramp.
- The resolved-color cache no longer carries a light/dark key.

Reason for keeping public names:

Hundreds of existing UI call sites depend on these symbols. Replacing values behind stable semantic names updates the whole UI while avoiding a high-risk component rewrite.

### `Packages/StrandDesign/Sources/StrandDesign/Typography.swift`

Changes:

- Removed `Font.custom("SF Pro", ...)`.
- Uses native system fonts for reliable Apple rendering.
- Prose roles use Dynamic Type.
- Headings use bold or semibold roles.
- Body text uses medium weight.
- Numeric roles use bold tabular digits.
- Existing `StrandFont` public names remain stable.

Bug avoided:

`SF Pro` is the platform system face. Looking it up as a custom family can resolve differently by host, SDK, or target. Native system APIs give consistent rendering and accessibility scaling.

### `Packages/StrandDesign/Sources/StrandDesign/StrandCard.swift`

Changes:

- One graphite gradient surface.
- One card border.
- One resting shadow.
- Optional metric tint becomes a quiet corner wash.
- Existing component structure and public initializers remain intact.
- Flat iOS content presentation remains intact.

### `Packages/StrandDesign/Tests/StrandDesignTests/WhoopThemeContractTests.swift`

Coverage:

- Legacy appearance values resolve to dark.
- Legacy chart styles resolve to the single supported style.
- Compatibility colors resolve to their dark value.
- Recovery boundary colors are exact.
- Strain, Sleep, Sleep Need, and Recovery data colors remain distinct.

## 5. Whole-app coverage model

The visual change is centralized. Every screen that uses `StrandPalette`, `StrandFont`, `NoopCard`, `StrandCard`, `NoopButton`, or a shared StrandDesign chart inherits the same visual contract.

This approach keeps the existing component graph. It avoids replacing each card, chart, row, button, or score view with a new type. It also reduces the chance of altering health behavior while changing presentation.

The separate file matrix in `docs/WHOOP_UI_FILE_MATRIX.md` lists each user-interface source group and its coverage status.

## 6. UI consistency findings

### Finding U1: duplicate appearance controls

Location: `Strand/Screens/SettingsView.swift`

Observed source:

- A native appearance picker.
- A chart-style picker.
- A day-cycle toggle.
- A second custom appearance control.
- A second day-cycle toggle.
- Old copy that describes Light, Dark, and System choices.

Current behavior after this pass:

- Rendering stays dark for every stored selection.
- Chart rendering stays on the default style.
- Today does not use the day-cycle scene.
- The visible lists contain one supported appearance and one supported chart style.

Remaining source cleanup:

Remove both day-cycle toggles and the old light/system blurb after simulator inspection identifies the active settings path. Do not delete a settings block by text search alone. `SettingsView.swift` contains native and legacy routes, and one may still serve a platform or preview path.

Severity: medium visual debt, low runtime risk.

### Finding U2: 18-point spacing values break the local 4-point grid

Location: `Packages/StrandDesign/Sources/StrandDesign/Components.swift`

Observed values:

- `gap = 18`
- `rowSpacing = 18`
- The same file defines a 4-point spacing ramp.

Recommendation:

Use 16 or 20 after screenshot comparison. Do not change both without checking dense list screens, two-column grids, and large Dynamic Type. An unverified global spacing change can cause wrapping and height regressions across many screens.

Severity: low visual inconsistency, broad blast radius.

### Finding U3: old source comments still describe the Paper theme

Locations include shared design files and screen comments.

Runtime effect: none.

Recommendation:

Update comments only when touching the owning source. Avoid a comment-only mega-diff during this visual pass.

Severity: low maintenance debt.

## 7. Sleep screen audit

Location: `Strand/Screens/SleepView.swift`

### Current user-facing order

1. Night navigation.
2. Invalid-session notice.
3. Sleep hero.
4. Sleep mark card.
5. Alarm editor.
6. Sleep stages.
7. Sleep window.
8. Rhythm entry.
9. Nap section.
10. Metric grid.
11. Sleep debt ledger.
12. Sleep Need breakdown.
13. Stages versus typical.
14. Duration trend.

### Hierarchy finding

The screen places action and management modules before several core sleep results. This can make the screen feel like separate tools joined together. It also delays performance, efficiency, consistency, restorative sleep, and debt information.

Recommended visual order for simulator evaluation:

1. Night navigation and hero.
2. Stages and sleep window.
3. Key metric grid.
4. Sleep Need and debt.
5. Stages versus typical and duration trend.
6. Nap, rhythm, alarm, and mark controls.

This is a presentation-order proposal. It does not alter models, components, or health logic. Apply it only after the visual-QA run confirms no workflow depends on the current placement.

### Existing performance protections

The Sleep screen already includes several strong choices:

- It avoids observing high-frequency `LiveState` at the screen root.
- Small leaf views own live dependencies.
- It uses `LazyVStack`.
- It memoizes the main `SleepModel`.
- Navigated nights cache decoded content.
- Async detail modules are isolated.

### Remaining performance risk

The first frame can build the large `SleepModel` synchronously during `body` evaluation. Independent leaf tasks can then fill Sleep Need, heart-rate, motion, and other details at different times. The result can look like several modules loading independently.

Visual-QA checks must record:

- First contentful frame.
- Number of visible loading transitions.
- Whether layout height shifts after the hero appears.
- Main-thread stalls while entering Sleep.
- Duplicate repository refreshes.
- Repeated model builds during scrolling or live heart-rate updates.

## 8. Sleep ledger root-cause finding

The ledger is built from aggregated daily rows:

- `repo.days`
- `previousNightSleepHours`
- a nightly target or recommended need
- the latest wake-day key

The hero and navigated sleep session use session data:

- `night.allSessions`
- merged main-sleep blocks
- split-sleep and nap-aware session selection

These sources can become ready at different times. A valid current session can appear in the hero while the daily aggregate still lacks `previousNightSleepHours`. In that state, the ledger can look empty, stale, or incomplete.

### Safe correction contract

A later source patch must:

1. Keep one canonical wake-day key.
2. Prefer the scored daily aggregate when it exists.
3. Fill only a missing newest ledger entry from the already-selected displayed main sleep.
4. Never double-count split blocks or naps.
5. Never treat a stage-less sleep stub as measured asleep time.
6. Reconcile the fallback away when the daily aggregate arrives.
7. Keep the 14-night rolling balance stable across refresh.
8. Add tests for aggregate lag, split sleep, naps, missing stages, and day-boundary changes.

### Status

Root cause is traced. This branch does not change the ledger's health-data semantics. A blind UI fallback could produce an incorrect debt value, so the fix requires simulator data cases and focused tests.

## 9. Performance audit findings

### Fixed in this branch

- Removed full app-tree identity reset from chart-style application.
- Removed dynamic light/dark color resolution work from the palette.
- Removed custom system-font lookup.
- Kept high-frequency Sleep live state in leaf views.
- Preserved lazy Sleep layout and model caches.

### Needs measurement

- Synchronous Sleep model construction on entry.
- Independent Sleep leaf tasks and layout shifts.
- Today section snapshot timing.
- Settings destination construction.
- Long list card-shadow cost.
- Chart interpolation and drawing during scroll.
- Repeated task starts after tab changes.
- Large Dynamic Type layout.
- Reduce Motion and Reduce Transparency behavior.

## 10. Acceptance rules

The branch is ready for merge review only when all rules pass:

- The app launches in dark appearance with the device set to Light or Dark.
- No white launch, navigation, sheet, or tab transition flash appears.
- Generic primary actions use teal.
- Recovery, Strain, Sleep, and Sleep Need keep their assigned colors.
- Body, heading, overline, and numeric roles look consistent.
- Dynamic Type does not clip essential content.
- Every changed package test passes.
- The complete iPhone build and test workflow passes at the exact branch head.
- Sleep ledger cases receive simulator evidence.
- No health value, alarm time, BLE command, data row, or stored schema changes.
- The PR stays unmerged until visual QA is attached.
