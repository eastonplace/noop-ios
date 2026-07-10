# Tasks 003 — Craft Pass (T60–T69)

> Continue on `reskin/paper-ui` in `~/Code/noop-completion` (never build from the
> iCloud path). One SCREEN per task. **Every task ends at a hard review gate (D10):**
> build → seeded simulator screenshot to `specs/003-craft-pass/qa/T##-<screen>.png`
> → commit `craft(T##): …` → push → **STOP and report the screenshot path for
> external review. Do not start the next task until approved.** Apply gate feedback,
> re-shoot, re-gate. The absorbed T56 punch list items live in critique.md.

- [ ] **T60 — Gate**
  - Verify `references/board-v2.png` exists (Easton drops it in). If missing, STOP.
  - `git tag pre-craft-pass` → push branch + tag to `private-noop-report`.
  - Read spec.md D-rulings + critique.md fully. Resolve D9 verifications
    (Garmin/Nutrition importers? crypto donation config? — check StrandImport,
    `Tools/`, `DONATIONS.md`) and note answers here.
  - Confirm deep links recoverydetail/straindetail → PaperPillarDetailView (T56);
    fix if not.
- [ ] **T61 — Today** — critique §Today items 1–8 (stress ribbon D3, health-tile
  icon language D2, Live-HR states D5, center FAB D4 — note D4 touches
  RootTabView, shared: land it here, all later screens inherit). GATE.
- [ ] **T62 — Trends** — critique §Trends 1–6 (chips, C13-legible lines, bullet
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
