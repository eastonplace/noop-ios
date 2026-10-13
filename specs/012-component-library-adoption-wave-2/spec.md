# Specification 012 — Wave 2 Ship Plan: Lab Kits 42–47, Widget Sizing, Sleep Performance V2

## Read this first (execution posture)

- **Repo:** this local clone (`origin = eastonplace-ai/noop`). Branch off current
  `main` (which already includes Strain V2, flat surfaces, calendar-aligned history,
  and Design Lab kits 40–41: Devices page + Widgets & Live).
- **Parallelize aggressively.** Fan work out to subagents wherever tasks touch
  disjoint files. The two workstreams below are independent until the sleep-surface
  integration point; inside each workstream, tasks marked `[P]` can run
  concurrently. Do not serialize work that doesn't share files.
- **Ship fast, gate light.** The only hard gates are: package tests + all-target
  builds per merged unit, one Settings tool-inventory diff, and ONE consolidated
  visual QA + device install at the end. No per-phase screenshot ceremonies.
  Sleep V2's authority flip keeps its own release gates (it ships in shadow mode
  first, so it never blocks the UI work from landing).

## Scope — three deliverables

**A. Design Lab kits 42–47 adopted into production**, wired to real data, no tool
regressions:

| # | Kit | Lab source file | Production adoption surface |
|---|---|---|---|
| 42 | Metric Detail Kit | `MetricDetailComponents.swift` | `Strand/Screens/MetricExplorerView.swift` (detail) |
| 43 | Settings Kit | `SettingsKitComponents.swift` | `Strand/Screens/SettingsView.swift` + settings sub-screens |
| 44 | Journal & Check-ins | `JournalCheckinsComponents.swift` | `Strand/Screens/JournalLogCard.swift`, `InsightsView.swift` impact cards |
| 45 | Compare View | `CompareComponents.swift` | `Strand/Screens/CompareView.swift` |
| 46 | Sheets & Alerts | `SheetsAlertsComponents.swift` | Shared presentation grammar (app-wide) |
| 47 | Sleep Alarm | `SleepAlarmComponents.swift` | `Strand/Screens/SmartAlarmView.swift`, Sleep page module |

Lab checkout: `projects/noop-design-lab` (fixture host; links this repo's
`Packages/StrandDesign`).

**B. Widget sizing fix (kit 41 follow-up).** The adopted recovery widget renders
its content undersized with a dead band of empty container. Fix in
`Packages/StrandDesign/Sources/StrandDesign/WidgetLiveComponents.swift`
(host: `StrandiOSWidgets/NOOPWidget.swift`).

**C. Sleep Performance V2** per PR #6
(`agent/sleep-performance-v2-foundation`) and its bundled plan
`docs/superpowers/plans/2026-07-20-sleep-performance-v2.md`. Land PR #6 first
(pure additive foundation), then execute that plan's ordered work units. That
document is the authority for the model contract, hard invariants, and release
gates — this spec only schedules it and binds its UI phase to Kit 47.

## User-visible contract

- The six surfaces and the widget look exactly like the approved lab specimens:
  spacing, type, tints, motion, haptics. The lab is the visual source of truth.
- Every displayed value is real. Fixture numbers, frozen clocks, and seeded answers
  never ship. No real source → honest empty state, never invented data.
- Every production tool reachable today stays reachable: settings rows and
  sub-screens, metric drill-ins, exports, journal edit mode, per-day alarm
  overrides, annotations, destructive actions. No slot in the lab design → the tool
  is added in the lab's dialect, not cut.
- Destructive actions gain ConfirmGate / hold-to-confirm DestructiveGate. Toast
  Undo only where the operation is actually reversible.
- Sleep surfaces end up on ONE canonical sleep model: Kit 47's alarm module and
  need breakdown display Sleep V2's dynamic need — not a second parallel
  eight-hour estimate. The iOS honesty stance stays: no promised loud phone wake
  alarm; the module arms the strap silent alarm + wind-down nudge and says so.
- `Sleep goal` and `In the green` are backed by real, inspectable evaluators rather
  than fixture modes. Sleep goal compares current banked sleep with canonical V2
  need; In the green uses the existing conservative Recovery forecast lower bound.
  The strap is always pre-armed at the wake-window endpoint as a fail-safe, and an
  encrypted live BLE connection may move it earlier when the condition is met.
  Copy states that iOS background evaluation is best-effort while the endpoint
  strap alarm is the dependable fallback on confirmed hardware.

## Boundaries

- One implementation per component: promote to `Packages/StrandDesign`; the Design
  Lab consumes the promoted component. No forks.
- Business logic stays in repositories/engines. Components receive immutable
  display models + action closures; they never query storage or fabricate values.
- No schema/scoring changes outside the Sleep V2 plan's own provisions. No route
  removals. Imported WHOOP data untouched.
- macOS/watch/widget targets keep compiling and don't inherit unintended redesigns.
- Working tree may contain unrelated changes — don't revert, format, or absorb them.

## Acceptance

- Adopted surfaces render from the same `StrandDesign` components in both app and
  lab; widget fills its container in every family.
- Settings tool-inventory diff: zero lost controls. Other surfaces: implementation
  tasks carry their own preserve-list, checked in review, not as separate gates.
- Sleep V2: foundation + shadow scoring landed; authority flip only when its own
  release gates pass (may trail this spec's ship date — shadow mode ships).
- Package tests + xcodegen + all app/widget targets build.
- One consolidated visual QA pass (light/dark, Dynamic Type, Reduce Motion on
  iPhone) and an in-place device install at the end.
