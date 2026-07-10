# Tasks 004 — Pixel Push (T80–T88)

> Same rules as 003: `~/Code/noop-completion`, one task per gate, screenshot to
> `specs/004-pixel-push/qa/`, commit `pixel(T##): …`, push to
> `private-noop-report`, STOP for review between screens unless the task is a
> pure token change verified by the batch re-shoot.

- [x] **T80 — Gate**: tag `pre-pixel-push`; read spec 004 D12–D16; verify the
  demo seeder banks intraday HR samples (`AppleDemoSeeder`) so the stress ribbon
  and Live-HR module render populated states in screenshots — if it doesn't,
  extend the seeder (sim-only path) to write a plausible day of HR/R-R.
- [ ] **T81 — D12 type/density step-down (tokens + shared components only)**:
  Typography.swift (overline roles, add `axisLabel`), NoopMetrics (row heights,
  icon circles, ring stroke, badge height, intra-card spacing), ScoreRing
  (stroke 4, tinted track, 26 pt trio numerals), SectionHeader, factor/list row
  components. Build + re-shoot Today/Trends/Sleep/Recovery-detail as the batch
  proof. GATE.
- [x] **T82 — D13 stress module v2** (TodayView `paperStressCard` +
  StressTimelineBar height 4): exact layout per D13. Re-shoot Today populated
  (needs T80 seeder). GATE — Easton judges this one personally.
- [ ] **T83 — Live-HR module to ref layout**: big numeral left + "x min ago",
  full-width fine trace with right-edge 120/40 axisLabels, gradient underfill
  ≤ 8%; empty state same geometry (003 D5 pattern). Re-shoot Today. GATE.
- [ ] **T84 — D14 zone bpm-range labels**: surface the zones engine's bpm
  boundaries; ZoneBars label variant "Z5 (161+ bpm)"; verify strain detail +
  workout detail + post-run + Workouts. GATE.
- [ ] **T85 — D16 real status bands**: locate baselines in
  StressModel/AnalyticsEngine; implement band helpers beside StrainScale
  (`FactorBands`); restore status words on Recovery key factors + Strain
  contributors with citations; value-only fallback stays. Unit tests for the
  band boundaries. GATE.
- [ ] **T86 — D15 pre-run rebuild** per sheet 2-1 (run-type segmented cards,
  last-workout card, run-setup rows, Start button; route card only if route
  data exists). GATE.
- [ ] **T87 — D15 live-run**: map card returns between grid and HR chart; HR
  chart gradient underfill; verify controls unchanged (C9). GATE (simulate
  workout via Test Centre for the populated shot).
- [ ] **T88 — Evidence**: full re-shoot of all reference screens light+dark,
  XL-type pass on Today/Sleep/detail, regenerate
  `qa/pixel-contact-sheet.jpg` (before = 003 qa), re-score fidelity.md with
  type-scale column, push, and hand Easton the sheet for the next alignment.

## Shipped by Claude — 2026-07-10 (round 5)

- **T80:** tagged `pre-pixel-push`. Seeder gap found and fixed: `AppleDemoSeeder`
  banked NO intraday streams, so ribbons/Live-HR could never show populated
  states in screenshots. It now seeds one HR sample/10 s (06:00→now, daily arc +
  noise + morning/evening spikes) and R-R at 0.5 Hz via
  `store.insert(Streams(hr:rr:))` — sim-only (behind `--demo-seed`).
- **T81 (partial):** sectionOverline 11→9.5 pt medium tracking 1.4; trio numerals
  30→26 semibold; ring strokes 5→4 / 7→6; ring tracks = accent @10% (tinted, not
  gray). Remaining T81 items: axisLabel role adoption on remaining charts, row
  heights 48→40, icon circles 30→24, badges 18 pt globally, intra-card spacing —
  finish then batch re-shoot.
- **T82 DONE (proof `qa/T82-today.png`):** stress module v2 per D13 — dot +
  overline + 18 pt badge row, 13 pt quiet state word, 4 pt continuous ribbon
  drawing REAL DaytimeStress hourly bands (visible green→amber→red day in the
  proof), 9 pt axis. Third time's the charm — Easton judges.
- Queued: T83 Live-HR full-width layout, T84 zone bpm labels, T85 real status
  bands, T86/T87 run-flow per D15, T88 evidence + new contact sheet.
