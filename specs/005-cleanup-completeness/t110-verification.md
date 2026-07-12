# T110 — Coverage refresh wave 2

## Batch 1 — onboarding and Today editors

Build: `NOOPiOS`, Debug iPhone Simulator, iPhone 17 Pro Max, `--demo-seed` — PASS.

- [Onboarding welcome](qa/t110-onboarding/page-1.png): the flow now has a deterministic debug route, an ivory Paper canvas, quiet progress thread, and black primary action without the legacy blue glow. The route is debug-only; production onboarding state and completion wiring are unchanged.
- [Dashboard cards editor](qa/t110-dashboard-editor/page-1.png): replaced iOS 26 glass toolbar bubbles with a flat Paper header while preserving Reset, Done, toggles, drag ordering, and live persistence.
- [Key metrics editor](qa/t110-key-metrics-editor/page-1.png): removed the fixed inset sheet canvas, made the surface full-width and scroll-safe on iPhone, retained metric-color data dots, and moved the completion action to the canonical black Paper treatment. Toggle and reorder wiring is unchanged.

This is the first T110 batch. The T110 task remains open until the remaining §C surfaces and all onboarding steps have equivalent full-page/interaction evidence.
