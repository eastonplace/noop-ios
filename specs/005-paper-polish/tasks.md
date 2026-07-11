# Tasks 005 — Paper UI Density and Stress Polish

- [x] **T89 — Safety gate and durable plan.** Verify clean branch/remotes, tag
  `pre-paper-polish`, push the tag to `private-noop-report`, create and hash the
  tarball snapshot, and write Spec 005 artifacts.
- [x] **T90 — Shared Paper density.** Apply E2–E4 in `NoopMetrics`, Paper card
  surface, `PaperHeaderBar`, and `ScreenScaffold`. Build; shoot Today, Settings,
  and Recovery detail light/dark. GATE.
  Proof: `qa/T90-{light,dark}-{today,settings,recoverydetail}.png`; `NOOPiOS`
  simulator build passed. Tap/control heights remain unchanged.
- [x] **T91 — Honest stress module.** Apply E1: remove daily-score replication,
  retain neutral missing-hour track, extract a pure slot mapper, and unit-test
  empty/partial/mixed/full cases. Build; shoot Today light/dark. GATE.
  Proof: `qa/T91-{light,dark}-today.png`; neutral timeline with daily value
  retained. `StressTimelineSlotsTests` 4/4 and `NOOPiOS` build passed.
- [ ] **T92 — Today core polish.** Tighten trio/Live HR/stress/Health Monitor and
  section handoffs without changing data or navigation. Build; shoot Today
  light/dark and compare to sheet 1-1. GATE.
- [ ] **T93 — Trends, Sleep, and pillar details.** Normalize chart gaps, factor
  rows, and card rhythm on the core analytics surfaces. Build; batch-shoot
  Trends, Sleep, Recovery detail, Strain detail, Stress detail light/dark. GATE.
- [ ] **T94 — Workouts and run flow.** Refine map crops, metric alignment, zones,
  and control/content spacing across Workouts, pre-run, live-run, and post-run.
  Preserve route gating and C9. Build; batch-shoot all four light/dark. GATE.
- [ ] **T95 — Secondary regression sweep.** Review remaining deterministic
  screens after shared-token propagation; fix only visible density regressions.
  Build; batch-shoot the secondary set light/dark. GATE.
- [ ] **T96 — Final evidence.** XL pass on Today/Sleep/Recovery/Strain, full
  light/dark re-shoot, contact sheet, fidelity re-score, clean-tree audit, push.
