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
- [ ] **T63 — Sleep** — critique §Sleep 1–4 (triplet swap D8, hypnogram floats,
  marks card label). GATE.
- [ ] **T64 — Pillar details + MetricDetailView** — critique §Pillar details 1–4.
  GATE (screenshot all three pillars + stress + explorer).
- [ ] **T65 — Workouts** — critique §Workouts (D7 restructure). GATE.
- [ ] **T66 — Run flow** — critique §Run flow (D6 picker/live/summary-tabs), three
  screenshots. GATE.
- [ ] **T67 — Live console + Devices** — critique §Live console + §Devices. GATE.
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
