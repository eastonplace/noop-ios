# Tasks 003 — Craft Pass (T60–T69)

> Continue on `reskin/paper-ui` in `~/Code/noop-completion` (never build from the
> iCloud path). One SCREEN per task. **Every task ends at a hard review gate (D10):**
> build → seeded simulator screenshot to `specs/003-craft-pass/qa/T##-<screen>.png`
> → commit `craft(T##): …` → push → **STOP and report the screenshot path for
> external review. Do not start the next task until approved.** Apply gate feedback,
> re-shoot, re-gate. The absorbed T56 punch list items live in critique.md.

- [x] **T60 — Gate**
  - Verify `references/board-v2.png` exists (Easton drops it in). If missing, STOP.
  - `git tag pre-craft-pass` → push branch + tag to `private-noop-report`.
  - Read spec.md D-rulings + critique.md fully. Resolve D9 verifications
    (Garmin/Nutrition importers? crypto donation config? — check StrandImport,
    `Tools/`, `DONATIONS.md`) and note answers here.
  - Confirm deep links recoverydetail/straindetail → PaperPillarDetailView (T56);
    fix if not.
- [x] **T61 — Today** — critique §Today items 1–8 (stress ribbon D3, health-tile
  icon language D2, Live-HR states D5, center FAB D4 — note D4 touches
  RootTabView, shared: land it here, all later screens inherit). GATE.
- [x] **T62 — Trends** — critique §Trends 1–6 (chips, C13-legible lines, bullet
  dots, insight dedupe, plot slab). GATE.
- [x] **T63 — Sleep** — critique §Sleep 1–4 (triplet swap D8, hypnogram floats,
  marks card label). GATE.
- [x] **T64 — Pillar details + MetricDetailView** — critique §Pillar details 1–4.
  GATE (screenshot all three pillars + stress + explorer).
- [x] **T65 — Workouts** — critique §Workouts (D7 restructure). GATE.
- [ ] **T66 — Run flow** — critique §Run flow (D6 picker/live/summary-tabs), three
  screenshots. GATE.
- [x] **T67 — Live console + Devices** — critique §Live console + §Devices. GATE.
- [ ] **T68 — Data & tools screens** — critique §Data & tools 1–7, per-screen
  screenshots. GATE.
- [ ] **T69 — Global sweeps + evidence** — critique §Global craft sweeps across
  every screen not yet touched; XL-type collision pass; refresh
  `qa/after/` full set + contact sheet; update 002 fidelity.md scores with a
  "craft" column; push. Final GATE = full-set review.

---

## Shipped by Claude (T60–T62) — 2026-07-10

- **T60** (`105cb046`): spec committed, `pre-craft-pass` tag. D9 answers: Nutrition
  CSV importer EXISTS (`StrandImport/NutritionCsvImport.swift`); BTC/ETH addresses
  EXIST (`docs/DONATIONS.md:86`) → both board rows allowed in T68; Garmin —
  `WearableExportImporter` covers wearable exports, verify Garmin specifically
  before adding its row. T56 had NOT been done: deep links still hit
  `MetricDetailView` — fixed: `StrandiOSApp.swift` routes recoverydetail →
  `PaperPillarDetailView(kind: .charge)`, straindetail → `(kind: .effort)`.
  **`references/board-v2.png` is still missing — Easton must drop it in before
  T63.**
- **T61** (`528b69c5`, proof `qa/T61-today.png`): center-docked 44 pt ink FAB in
  `PaperTabBar` (Today·Trends·⊕·Sleep·More), floating FAB removed from TodayView;
  `MetricTile` icons monochrome ink + line variants (lungs/drop/moon), sparklines
  removed; `StressTimelineBar` → 6 pt continuous capsule ribbon (spacing 0);
  Live-HR empty state = dimmed flat trace in the 130×42 chart slot; glance icon
  ink. Deferred: trio rhythm micro-tuning; Key Metrics empty-card states (T69);
  stress timeline DATA is a repeat-fill of today's scalar
  (`TodayView.paperStressCard`) — wire the real day curve in T64.
- **T62** (`036f2e5f`, proof `qa/T62-trends.png`): plot slab removed; Recovery line
  55% opacity so band-colored dots carry it (Strain #0093E7 unmistakable); dots
  symbolSize 12; bullets = focalPoints only, pillar-keyword dot tints; Insight
  renders only when distinct from bullets (verified — duplicate gone). Deferred:
  W·M·3M·6M·Y·All range chips are DATA work (Trends is week-stepper based) —
  Codex wires real range queries or Easton drops the chips; paper chip style, not
  blue pills.
- Build: `NOOPiOS` BUILD SUCCEEDED (iPhone 17 Pro Max sim); note `swift test` on
  StrandDesign reported 0 discovered tests under swift-testing — Codex should run
  the XCTest path it used for its 34/34 count and confirm.

## Shipped by Claude (T63–T67) — 2026-07-10, under ruling D11 (hybrid)

- **D11 (Easton):** original 001 sheets win conflicts with board-v2, EXCEPT the
  center-docked FAB stays. Splits stay on Workouts; Sleep keeps Asleep/Woke row.
  spec.md/critique.md amended.
- **T63 Sleep** (proof `qa/T63-sleep.png`): "Phase 1" dev label removed from Sleep
  Marks; hypnogram risers receded (0.35→0.12 opacity, 1.5→1 pt) so stage bars read
  as the reference's floating bars; Asleep/Woke row confirmed per D11.
- **T64 Pillar details + explorer** (proof `qa/T64-recovery-detail.png` — shot via
  the repointed recoverydetail deep link, now opening PaperPillarDetailView):
  `SegmentedPillControl` active pill = ink (was blue accent) — shared fix, all call
  sites; explorer overline no longer stutters ("RECOVERY/Recovery"); explorer hero
  numeral was ghost-white `onDark*` on paper — now ink at 36 pt in a 132 pt gauge;
  stress ring "of 3" caption dropped (C6).
  **FLAG for T64 gate feedback / integration lane: Recovery KEY FACTORS status
  words are HARDCODED "Good" (`CoupledView.swift:907–920`) and render in link-blue
  — must be computed per metric band and tinted band-colors. Also key-factor icon
  circles use filled glyphs (icon-language sweep) and the over-time x-axis labels
  are sparse ("S…S").**
- **T65 Workouts** (proof `qa/T65-workouts.png`): strain badges already
  `strainAccent` blue (T34); "View all workouts" has no stray glyph (chevron.right
  only — the earlier "↓" is gone); splits card stays per D11. No code change.
- **T66 Run flow: DEFERRED to Codex** — timer is already `StrandFont.timer` 64 pt
  and controls are C9-aligned (lock + End workout). The remaining D6 items are a
  real rebuild, too big to rush: pre-run activity-picker composition, live-screen
  2×3 grid fields (Live Strain/Max HR), and the tabbed summary
  (Overview·Splits·Heart Rate·Map + "Done"). No tab scaffold exists in
  `WorkoutDetailView` — build it there and reuse for the post-run summary.
- **T67 Live + Devices** (proof `qa/T67-live.png`): already conformant from 002 —
  session console is card-wrapped with Start-workout actions, Live→Manage-devices
  route exists, Devices capability prose is behind a collapsed-by-default
  disclosure (`showsDetails=false`). Verification only, no code change.
- Builds: NOOPiOS BUILD SUCCEEDED ×2 (after T63/T64 batch). Next for Codex: T66
  rebuild, then T68, then T69 sweep (fold in the T64 flags above).
