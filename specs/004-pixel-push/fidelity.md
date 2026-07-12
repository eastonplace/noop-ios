# 004 — Pixel Push Fidelity Audit

> Re-scored 2026-07-11 against `specs/001-concept-ui-reskin/references/`, after
> applying canonical rulings C1–C14 and D1–D17. Fidelity scale: Low · Partial ·
> Directionally aligned · Close · High. Evidence is the iPhone 17 Pro Max seeded
> simulator set in `qa/final/` (25 light, 25 dark, plus four XL-type proofs). The
> reference-ordered light overview is `qa/pixel-contact-sheet.jpg`; the comparison
> baseline supplied to the generator is `specs/003-craft-pass/qa/`.

| Screen | Reference | Light | Dark | Type scale | Fidelity | T88 judgment | Complete & clean |
|---|---|---:|---:|---|---|---|---|
| Today | 1-1, 3-1 | ✓ | ✓ | XL ✓ | **Close** | Compact trio, live HR, stress ribbon, 3×2 vitals, and thin Paper hierarchy align; D17 colors retained. | ✓ |
| Trends | 1-2 | ✓ | ✓ | Shared tokens | **Close** | Three compact score tiles, fine multi-series chart, and week review align. | ✓ |
| Sleep | 1-3, 3-4 | ✓ | ✓ | XL ✓ | **Close** | Slate hero, marks, hypnogram, and asleep/awake summary preserve C3. | ✓ |
| Recovery detail | 3-2 | ✓ | ✓ | XL ✓ | **Close** | Banded ring, triplet, fine chart, and real D16 factor statuses align. | ✓ |
| Strain detail | 3-3 | ✓ | ✓ | XL ✓ | **Close** | 0–21 blue system, contributors, D16 statuses, and D14 zone ranges align. | ✓ |
| Stress detail | 3-5 | ✓ | ✓ | Shared tokens | **Close** | Compact hero, 0–3 summaries, and fine stress plot align. | ✓ |
| Workouts | 1-6 | ✓ | ✓ | Shared tokens | **Close** | Black start action, recent sessions, 0–21 badges, and real bpm zone rows align. | ✓ |
| Workout / post-run detail | 2-4 | ✓ | ✓ | Shared tokens | **Close** | Strain hero, stats, tabs, bpm zones, and black save action align. | ✓ |
| Pre-run | 2-1 | ✓ | ✓ | Shared tokens | **Close** | D15 type cards, real route gate, last workout, honest setup rows, and Start Run align. | ✓ |
| Live run | 2-2 | ✓ | ✓ | Shared tokens | **Close** | D15 grid → real map → soft HR trace sequence aligns; C9 controls remain lock/recording/finish. | ✓ |
| Live body console | 1-4 | ✓ | ✓ | Shared tokens | **Close** | Device, scan action, HR ring, and physiology stack retain Paper density. | ✓ |
| Devices | 4-1 | ✓ | ✓ | Shared tokens | **Close** | Compact honest device cards and black add action align. | ✓ |
| Add device | 4-2 | ✓ | ✓ | Shared tokens | **Close** | Reference-ordered device options and state badges align. | ✓ |
| Data sources | 4-3 | ✓ | ✓ | Shared tokens | **Close** | Source cards, state chips, import actions, and disclosure hierarchy align. | ✓ |
| Backup & sync | 4-4 | ✓ | ✓ | Shared tokens | **Close** | Destination, backup, restore, and health sections align. | ✓ |
| Settings | 4-5 | ✓ | ✓ | Shared tokens | **Close** | Profile, segmented preferences, privacy, and support grouping align. | ✓ |
| Support | 4-6 | ✓ | ✓ | Shared tokens | **Close** | QR action and compact support list align. | ✓ |
| Insights | 5-1 | ✓ | ✓ | Shared tokens | **High** | Associations, With/Without comparison, journal prompts, and insight card closely match. | ✓ |
| Insights hub | 5-1 | ✓ | ✓ | Shared tokens | **Close** | Compact recommendation and association stack follows the same system. | ✓ |
| Lab Book | 5-2 | ✓ | ✓ | Shared tokens | **Close** | Marker empty state and import/recent sections align. | ✓ |
| Rhythm consent | 5-3 | ✓ | ✓ | Shared tokens | **Close** | Permission hierarchy and restrained disabled action align. | ✓ |
| Rhythm | 5-4 | ✓ | ✓ | Shared tokens | **Close** | Experimental empty state, insights, and privacy note align. | ✓ |
| Automations | 5-5 | ✓ | ✓ | Shared tokens | **Close** | Status banner and compact grouped toggles align. | ✓ |
| Alarms | 5-6 | ✓ | ✓ | Shared tokens | **Close** | Smart-wake, reminder, and test action stack align. | ✓ |
| Test Centre | 5-7 | ✓ | ✓ | Shared tokens | **Close** | Compact diagnostics and reports list align. | ✓ |

## Ruling-controlled reference states

- **Paused run (2-3): not scored.** C9 forbids a fake Pause state, so T88 does
  not manufacture one for visual parity. The live-run proof demonstrates the
  honest control state.
- **Quick Actions overlay (5-7): retained, not independently routed.** The
  existing overlay and navigation behavior were not changed by this visual-only
  pass; T88 does not add a production route solely for screenshot convenience.

## Result

Every deterministic reference surface is **Close** or **High** in both light and
dark. Today, Sleep, Recovery detail, and Strain detail also pass at XL without
clipping or hierarchy collapse. Remaining differences are deliberate rulings,
real seeded content, and brand-level polish—not missing surfaces or metric logic.
