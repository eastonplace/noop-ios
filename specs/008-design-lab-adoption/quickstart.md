# Quickstart 008 — Verification Journey

## Preconditions

- Build `NOOPiOS` for simulator; seed with the existing spec-004 fixture mechanism
  (nights with full stages, a naps-only night, a no-timeline night, ≥ 14 ledger
  nights, a stress day with scored hours + a sustained-high run, a calibrating
  profile, live/stale/offline HR fixtures).
- Primary device: `NOOP-Paper-iPhone16Pro-QA` (00522DAA-FDB8-4DC9-866C-71C7862C354D),
  light mode, default type. Secondary: iPhone 17 Pro Max (602CD04D-…).
- Keep the lab app screenshots from `noop-design-lab` QA open as composition
  references; they are references, not pixel masters (tokens differ by design).

## Atom Gallery (Phase 1 gate)

1. Open each new/upgraded component `#Preview` in Xcode; verify light/dark and Reduce
   Motion variants; export gallery screenshots.

## Sleep Journey

1. Sleep tab → full-night fixture. Capture hero, stages card, breakdown rows.
2. Tap REM row → hypnogram dims others; row tints. Tap again → clears. Capture both.
3. Scroll: window strip, stages-vs-typical, tiles, debt ledger (capture stagger
   mid-reveal and settled).
4. Switch fixtures: naps night, no-timeline night, zero-ledger profile → honest empty
   states, no fabricated bars.
5. Delete a sleep session → undo toast presents; tap Undo before dwell ends → session
   restored; repeat and let it expire → deletion stands.
6. Repeat 1–3 in dark mode, XL type, Reduce Motion.

## Stress Journey

1. Stress screen on the scored-day fixture: line draws on once, band guides, peak
   annotation matches the fixture's true peak hour, hour ruler, legend.
2. Time-in-band rails show the fixture's Calm/Moderate/High hours; zero-hours fixture
   shows empty rails.
3. Today tab → stress card strip + calibrating fixture shows the placeholder.
4. Sustained-high fixture → nudge card appears; Start a Breathe session opens the
   trainer.
5. Marker tiles: RHR +delta tints warning, HRV +delta tints positive.
6. Dark + Reduce Motion pass (no draw-on under RM).

## Trends and Navigation

1. Trends tab: chart + one summary row per series; values match tapped chart points;
   switch ranges → rows update with the chart.
2. Day navigator: navigate back/forward; date animates numerically; forward chevron
   disabled at today.

## States and Micros

1. Backup: run a backup, force a failure → operation card retains Retry; success →
   toast.
2. Live: waiting → live (pulse) → stale → offline pill states from the HR fixture.
3. Devices/wizard: ProgressDots step through; search fields clear correctly.

## Pass/Fail

Every step above maps to a numbered screenshot under
`outputs/2026-07-14/design-lab-adoption/qa/<phase>/`. A journey passes only when its
failure-state steps (empty/calibrating/offline/failed-save) are captured, not just the
happy path. Both app targets must build and all suites pass before the final contact
sheet is assembled.
