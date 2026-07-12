# T110 — Coverage refresh wave 2

## Batch 1 — onboarding and Today editors

Build: `NOOPiOS`, Debug iPhone Simulator, iPhone 17 Pro Max, `--demo-seed` — PASS.

- [Onboarding welcome](qa/t110-onboarding/page-1.png): the flow now has a deterministic debug route, an ivory Paper canvas, quiet progress thread, and black primary action without the legacy blue glow. The route is debug-only; production onboarding state and completion wiring are unchanged.
- [Dashboard cards editor](qa/t110-dashboard-editor/page-1.png): replaced iOS 26 glass toolbar bubbles with a flat Paper header while preserving Reset, Done, toggles, drag ordering, and live persistence.
- [Key metrics editor](qa/t110-key-metrics-editor/page-1.png): removed the fixed inset sheet canvas, made the surface full-width and scroll-safe on iPhone, retained metric-color data dots, and moved the completion action to the canonical black Paper treatment. Toggle and reorder wiring is unchanged.

This is the first T110 batch. The T110 task remains open until the remaining §C surfaces and all onboarding steps have equivalent full-page/interaction evidence.

## Batch 2 — onboarding steps 1–4

Build: `NOOPiOS`, Debug iPhone Simulator, iPhone 17 Pro Max, `--demo-seed` — PASS.

- [Step 1](qa/t110-onboarding-steps/step-1.png): the custom Welcome headline now uses `textPrimary` ink; its explanatory subtitle remains secondary.
- [Step 2](qa/t110-onboarding-steps/step-2.png), [Step 3](qa/t110-onboarding-steps/step-3.png), and [Step 4](qa/t110-onboarding-steps/step-4.png): shared `StepShell` titles render in ink, subtitles remain secondary, cards stay flat Paper, and primary actions remain black.
- Added debug-only `onboarding-1`…`onboarding-12` routes so every step can be captured deterministically without changing production onboarding state, completion, or navigation wiring.
