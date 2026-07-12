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

## Batch 3 — onboarding steps 5–8

Build: `NOOPiOS`, Debug iPhone Simulator, iPhone 17 Pro Max, `--demo-seed` — PASS.

- [Step 5](qa/t110-onboarding-steps/step-5.png): replaced the blurred strap halo with a flat raised Paper disc and hairline.
- [Step 6](qa/t110-onboarding-steps/step-6.png): scan controls, state pill, strap selector, help disclosure, and black primary action remain fully visible and wired.
- [Step 7](qa/t110-onboarding-steps/step-7.png): removed the celebration bloom; the real Recovery ring and positive status colour carry the state without decorative glow.
- [Step 8](qa/t110-onboarding-steps/step-8.png): profile controls remain ink-first on a single Paper card with secondary explanatory copy.

## Batch 4 — onboarding steps 9–12

Build: `NOOPiOS`, Debug iPhone Simulator, iPhone 17 Pro Max, `--demo-seed` — PASS.

- [Step 9](qa/t110-onboarding-steps/step-9.png): import actions retain their original file-picker wiring inside flat Paper rows.
- [Step 10](qa/t110-onboarding-steps/step-10.png): notification explanation and wrist-alert status remain ink-first with restrained semantic colour.
- [Step 11](qa/t110-onboarding-steps/step-11.png): appearance selection remains interactive and immediately updates the app theme.
- [Step 12](qa/t110-onboarding-steps/step-12.png): removed the final decorative bloom; the thread glyph, ink headline, secondary copy, and black Enter action now finish the flow cleanly.

All 12 onboarding steps now have current iPhone 17 Pro Max evidence in `qa/t110-onboarding-steps/`.

## Batch 5 — device utilities

Build: `NOOPiOS`, Debug iPhone Simulator, iPhone 17 Pro Max, `--demo-seed` — PASS.

- [Add Device](qa/t110-device-add/page-1.png): full catalog remains reachable with honest Beta/Experimental states and flat Paper rows.
- [Xiaomi](qa/t110-device-xiaomi/page-1.png): designed empty/import state uses one compact Paper card with no fake device data.
- [Apple Watch setup](qa/t110-device-watch-setup/page-1.png): primary Continue/Done actions now use canonical black Paper treatment; close, back, and Health permission wiring is unchanged.
- [Apple Watch about](qa/t110-device-watch-about/page-1.png): capability and calibration states remain semantic, readable, and fully Paper-aligned.

## Batch 6 — utilities and support

Build: `NOOPiOS`, Debug iPhone Simulator, iPhone 17 Pro Max, `--demo-seed` — PASS.

- [Storage](qa/t110-storage/page-1.png): footprint, cleanup state, and explanatory content use flat Paper cards; cleanup behavior is unchanged.
- [Support](qa/t110-support/page-1.png): donation selector, copy action, QR, contact actions, and privacy note are fully visible after the entrance-animation window. The QR retains its required black-on-white scanner surface.
- [What's New](qa/t110-whats-new/page-1.png): expectations and release history migrated from legacy tinted vessels to `PaperCard`; Got It now uses the black primary treatment.
- [How NOOP Works](qa/t110-how-noop-works/page-1.png): primer and scoring-method sections migrated to `PaperCard`; Got It now uses the black primary treatment.
- Added debug-only direct routes for What's New and How NOOP Works so their screenshot evidence is deterministic without changing production reachability.
