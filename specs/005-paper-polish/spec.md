# Spec 005 — Paper UI Density and Stress Polish

## Goal

Move the reference-core screens from faithful implementation to the tighter,
editorial Paper composition in the refined reference sheets. This is a visual
pass only: data, scoring, BLE, storage, navigation, and metric scales do not
change.

## Rulings

- **E1 — Honest stress timeline.** Keep the compact D13 module. Only hours
  backed by `DaytimeStress` may receive a band color. Missing intraday data uses
  the neutral track; the daily stress value may still render in the badge/state.
- **E2 — Density rhythm.** Top-level screen stacks use 16 pt spacing; semantic
  section gaps use 20 pt. Card interiors use 8–10 pt vertical rhythm while
  preserving 16 pt horizontal padding.
- **E3 — Paper surface.** Cards use a 14 pt continuous radius, a hairline border,
  and a restrained 2 pt / 2.5% black light-mode shadow. Dark mode separates by
  fill and hairline, never glow.
- **E4 — Header geometry.** One compact shared header row everywhere: centered
  wordmark, inline back affordance, trailing actions, 28 pt minimum row, and a
  4 pt header-to-content handoff.
- **E5 — Accessible density.** Presentation gaps may shrink; interactive hit
  areas may not. Dynamic Type XL must not clip or collapse hierarchy.
- **E6 — Color restraint.** Physiological status/data and primary actions retain
  color. Navigation, framing, labels, and card chrome remain ink/slate.
- **E7 — Core first.** Perfect Today, Trends, Sleep, pillar details, Workouts,
  pre-run, live-run, and post-run. Secondary screens inherit shared tokens and
  receive regression fixes only.

## Acceptance

1. An unscored stress day never renders a fabricated solid colored timeline.
2. Reference-core screens are visibly 10–15% tighter vertically without smaller
   tap targets or clipped XL text.
3. Headers, cards, list rows, and charts share one optical system in light/dark.
4. Run flow retains real route gating and C9's no-fake-Pause control state.
5. Every task has a green build and seeded iPhone 17 Pro Max screenshot proof.

