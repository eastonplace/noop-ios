# Tasks 002 — NOOP UI Completion

> Execute in order on `reskin/paper-ui`. Task IDs continue 001's sequence (T30–T55).
> Every task ends with the verification loop (plan.md §Verification): build → seeded
> simulator → screenshot to `specs/002-noop-ui-completion/qa/T##-<screen>.png` →
> side-by-side vs reference → commit `reskin(T##): …` → push to `private-noop-report`.
> "Spec §" = `spec.md`; "001 §" = `../001-concept-ui-reskin/spec.md`; fidelity rows =
> `fidelity.md`. **T30 is a hard gate — no file modifications until every box is
> checked.** Tasks marked ∥ may run in parallel within their phase once the phase's
> first task lands.
>
> **Throughput (added after T33 — plan §Throughput addendum):** work from a
> persistent local clone (`~/Code/noop-completion`), never build from the iCloud
> path; batch the screenshot sweep per ∥ group (build still green per task);
> T34+T35 may execute as one combined sweep with DE/IT translation run once.

## Phase 0 — Gate + evidence

- [x] **T30 — Safety gate (plan §Safety has full commands)**
  - Read required skills (`~/.codex/skills/`: swiftui-expert-skill + latest-apis,
    swift-concurrency, swift-testing-expert).
  - Review + commit the dirty `Palette.swift` textTertiary fix
    (`reskin(T30): commit AC-3 tertiary contrast fix`).
  - `git tag pre-ui-completion` → push branch + tag to `private-noop-report`.
  - Tarball snapshot to `~/Backups/noop-pre-completion-<date>.tgz`, verify >10 MB.
  - Note tag/tarball/remote URL under this task.
  - **Completed 2026-07-10:** `pre-ui-completion` tags commit `8643a5a9` on
    `reskin/paper-ui`; branch and tag pushed only to
    `https://github.com/eastonplace-ai/noop.git` (`private-noop-report`). Snapshot:
    `~/Backups/noop-pre-completion-20260710.tgz` (418 MB; required spec and palette
    paths verified in the archive). `StrandDesign` package: 30 tests passed.

- [x] **T31 — Evidence consolidation + unknowns**
  - `git mv` repo-root `qa/*` into `specs/002-noop-ui-completion/qa/baseline/`
    (C11); remove the root folder.
  - Seed the simulator (`AppleDemoSeeder` launch arg) and capture CURRENT screenshots
    of every 001 §5 screen missing recent evidence: S24 pre-run, S25 live, S26 paused
    (if reachable), S27 with full data (zones + route), S6 devices, S12 insights, plus
    Dynamic-Type-XL Today. File as `baseline/S##-*.png`.
  - Resolve unknowns, append answers here: (a) C9 — does the workout session engine
    support pause/resume? (inspect the run controller found via T01 notes /
    `LiveWorkoutView`); (b) C10 — full list of legacy pillar routes (grep NavRouter +
    `StrandiOSApp` string routes + `V5PillarHosts` consumers); (c) location of every
    score-band comparison for T32 (sweep: `grep -rnE "score [<>=]|[<>]= ?[0-9]{2}"
    Strand Packages --include='*.swift'` triaged to strain only).
  - Verify: baseline set complete; three unknowns answered in writing.
  - **Evidence completed 2026-07-10:** repo-root `qa/` was moved to
    `qa/baseline/`. Fresh seeded captures: `S01-today-dynamic-type-xl.png`,
    `S06-devices.png`, `S12-insights.png`, `S24-pre-run.png`,
    `S25-live-run.png`, and `S27-post-run-full-data.png`. S27 uses a
    simulator-only seeded fixture with stored strain 67 plus imported zone percentages and
    a locally captured GPS route, proving both cards render together. S26 is not reachable
    because the engine has no paused state (C9 finding below). The full `NOOPiOS` simulator
    build passed from a `/tmp` source mirror after Xcode's file coordinator blocked the
    iCloud project path; no source was changed in the mirror.
  - **Reference comparison:** S6 remains materially too dense; S12 has the duplicate
    subtitle called out in fidelity.md; S24 keeps the right content but is much taller and
    uses a sport-list composition absent from the reference; S25 lacks Pause/Resume and is
    vertically oversized; S27 proves zones + route but remains in the old purple/0–100
    presentation; XL Today does not clip, but preserves the oversized ring/card rhythm and
    extra header icons. These are routed to T40/T43–T46 as specified.
  - **C9 answer — no pause support:** `LiveWorkoutView.swift:155-156` explicitly states
    the engine has no pause/resume state. `AppModel.swift:529` starts a workout and
    `AppModel.swift:624` ends it; there is no intermediate session phase or recorder pause
    API. T44 therefore follows C9's limitation branch: retain a real End action and match
    the reference control-row geometry; no cosmetic Paused state may be fabricated.
  - **C10 route inventory:** the canonical current path is
    `TodayView.swift:1480-1481` → `PaperPillarDetailView`. Legacy primary-pillar routes are
    `StrandiOSApp.swift:301-307` (`effortdetail` → strain `MetricDetailView`, `restdetail`
    → sleep-performance `MetricDetailView`, `chargebreakdown` →
    `ChargeBreakdownDemoHost`) plus the generic trend links in
    `TrendsView.swift:694-704` and `:815` that still open `MetricDetailView`. The similarly
    named v5 route layer is separately live: `NavRouter.swift:22-30`,
    `RootTabView.swift:124-125/:161-164`, and `RootView.swift:312-315/:416-435` consume
    `V5PillarHosts.swift:21` (`FusedRecordHost`) and `:51` (`RhythmHost`); these are real
    non-score features and must be preserved while T49 removes only duplicate score detail
    destinations.
  - **T32 threshold inventory:** `TodayView.swift:1224-1229` applies shared 35/70 status
    cuts to all trio values (including stored strain); `WorkoutsView.swift:760-766` applies
    stored-strain 34/67 cuts; `CoupledView.swift:312-319` applies display-strain cuts at
    6/10/14; and `CoupledView.swift:1259` hardcodes the Strain hero status. All migrate to
    `StrainScale.band`. `StrandDesign/Palette.swift:354-355` is the old value-varying strain
    ramp and migrates to constant C13 blue. Excluded as non-band behavior:
    `TodayView.swift:2884-2886` is the honest near-zero explanation gate and
    `IntelligenceEngine.swift:949` is an analytics cohort filter; neither is presentation
    status logic and neither changes in this visual-only pass.

## Phase 1 — Metric migration (spec §2.2)

- [x] **T32 — StrainScale converter + bands + C13 color tokens**
  - Files: `Strand/Data/MetricCatalog.swift` (extend the existing #268 0–100↔0–21
    mapping into the single public `StrainScale` API: `displayValue(fromStored:)`,
    `storedValue(fromDisplay:)`, `formatted(_:)` 1-decimal, `band(_:)` → Light/
    Moderate/High/All Out per spec C2), + unit tests in `StrandTests`.
  - Migrate every band/threshold found in T31(c) to read via `StrainScale.band`.
  - `Packages/StrandDesign/Sources/StrandDesign/Palette.swift`: add C13 tokens
    (`recoveryHigh/Med/Low`, `recoveryData`, `strainAccent`, `sleepAccent`,
    `journalAccent`, optional `sleepNeedTeal`) with the exact light/dark pairs from
    spec C13, plus `RecoveryBands.color(for:)` (≥67 high, ≥34 med, else low). ORDER
    MATTERS: repoint Journal/Experimental badges to `journalAccent` BEFORE any strain
    surface recolors (plan §Risks).
  - Verify: tests green incl. 67→14.1, 100→21.0, 0→0.0 cases + band-boundary color
    cases (33/34/66/67); StrandDesign tests pass. Commit.
  - **Completed 2026-07-10:** the public `StrainScale` is now the sole 0–100 ↔ 0–21
    converter used by `UnitFormatter` and `MetricCatalog`; all T31 presentation-band
    comparisons route through `StrainScale.band`. Exact C13 tokens and
    `RecoveryBands` landed in `StrandDesign`, with Journal/Experimental affordances
    first decoupled onto `journalAccent`. `StrandDesign`: 34/34 tests passed, including
    67→14.1, endpoint/clamping, round-trip, Strain band, and Recovery 33/34/66/67
    color boundaries. The corresponding `StrandTests` cases compile with the app;
    execution remains blocked by the pre-existing project setup (`NOOPiOS` has no Test
    action; the `StrandTests` host is macOS-only while current iOS screens contain
    unavailable navigation-bar modifiers). Full `NOOPiOS` build + seeded simulator
    launch passed. `qa/T32-journal-accent.png` was compared with reference sheet 5:
    Journal remains independently purple as required; the known Insights density gap
    is unchanged and remains assigned to T50.

- [x] **T33 — Rename Charge → Recovery** ∥
  - Scope: user-facing strings only (FR-4): Swift literals in `Strand/Screens`,
    `Strand/Liquid` (until deleted), `StrandiOS`, `Packages/StrandDesign` labels;
    all four `Localizable.xcstrings` (EN edit; DE/IT via `Tools/translate-*.py`,
    flag needs-review); accessibility labels; `ScoringGuideView`/`HowNoopWorksView`
    explainer copy (retire battery metaphors per C1); widget/watch strings.
  - Case-by-case grep review — NOT sed (plan §Risks). Internal identifiers stay (D9).
  - Apply C13 to every Recovery surface touched: ring/numeral/status colored via
    `RecoveryBands.color(for:)`; non-valuated recovery lines/sparklines →
    `recoveryData`.
  - Verify: `grep -rn '"Charge' …` shows zero user-visible pillar hits; app builds;
    Today shows "Recovery"; seeded 25/50/80 days render red/yellow/green. Screenshot.
    Commit.
  - **Completed 2026-07-10:** all rendered phone, widget, watch, complication,
    accessibility, explainer, Coach, and changelog copy now says Recovery; stable
    `.charge` symbols, the `chargebreakdown` route, the Insights outcome name, and
    `MetricCatalog` category IDs remain unchanged. The only catalog keys still using
    lowercase `charge` describe real battery charging. The main, Watch, and
    Complications catalogs were migrated structurally; StrandDesign had no Charge
    entries. Carried non-English values are flagged `needs_review`; the required DE/IT
    scripts refreshed their covered units (2,999 DE / 2,989 IT) and reported their
    pre-existing incomplete dictionary coverage rather than silently inventing copy.
    Recovery score graphics now use `RecoveryBands`, non-valuated recovery data uses
    `recoveryData`, and Trends/Year Heat Strip use band-colored points/cells.
    `StrandDesign` passed 34/34 tests; `NOOPiOS` and `NOOPiOSWidgets` simulator builds
    passed. Simulator-only fixtures set the latest seeded row to 25, 50, and 80—no
    stored schema or source data changed—and produced `qa/T33-recovery-25.png`,
    `qa/T33-recovery-50.png`, and `qa/T33-recovery-80.png`. Side-by-side against
    reference sheet 1 and C13 confirms red/yellow/green bands and the full Recovery
    label; the remaining header/card proportion gaps stay assigned to T38.

- [x] **T34 — Rename Effort → Strain + apply 0–21** ∥
  - MAY combine with T35 into one sweep (plan §Throughput #3) — same files, one
    build, one screenshot pass, translation once; keep the two value-trace shots.
  - Same string scope as T33 for "Effort"; ALSO flip every strain display to
    `StrainScale` (FR-5): Today trio ring (range 0…21), Trends tile + chart y-axis
    (0–21, gridlines 7/14/21), Strain detail in `CoupledView.swift` (ring, triplet,
    over-time axis, contributors), `WorkoutsView` score card + recent badges, run
    hero + delta in the run-flow views, `WidgetPublish.swift`/`WatchScoreSnapshot`/
    watch views, notification copy.
  - Recolor every strain surface to constant `strainAccent` blue (C13 — bands change
    the status word, never the color); remove "of 100" sublabels encountered (C6).
  - Smoke-build `NOOPiOSWidgets` + `NOOPWatch` (plan §Risks).
  - Verify: seeded day traces one stored value to identical 0–21 display on trio,
    detail, Workouts badge (FR-8/AC-4) — screenshot each. Commit.
  - **Completed 2026-07-10 (combined T34+T35 sweep):** all rendered Strain labels,
    settings, explainers, accessibility strings, widgets, Live Activity, watch and
    complication copy now use the canonical name. Every presentation boundary routes
    stored 0–100 values through `StrainScale`; rings and detail charts use 0–21 with
    7/14/21 gridlines, one decimal, and constant `strainAccent`. Simulator fixture
    stored value 67 rendered as 14.1 in `qa/T34-value-trace-today.png`,
    `qa/T34-value-trace-detail.png`, and `qa/T34-value-trace-workouts.png`, compared
    against reference sheets 1 and 3. `NOOPiOS` and `NOOPiOSWidgets` builds passed
    from `~/Code/noop-completion`. The required Watch build was attempted first via
    XcodeBuildMCP and then generic `xcodebuild`; both report the same host limitation:
    watchOS 26.5 is not installed, so no watchOS destination exists. Source/catalog
    migration is complete; DE/IT runs once after T37 per the throughput addendum.

- [x] **T35 — Rename Rest → Sleep + C3 representation rules** ∥
  - String scope as T33 for pillar-"Rest" (audit each hit — "rest" the verb stays).
  - Implement C3 table: trio/Trends = score; Sleep tab hero = score + triplet; need/
    debt only in Sleep detail + SmartAlarm; widgets/notifications score-primary.
  - Sleep tab and pillar converge (D10): trio Sleep tap lands on the Sleep tab
    surface (`SleepView`), not a separate Rest detail; reconcile with `CoupledView`
    rest detail (keep the reference S22 layout as the Sleep detail).
  - Recolor sleep-score surfaces to `sleepAccent` (C13); sleep-stage ramp unchanged;
    sleep-need value may use `sleepNeedTeal` in the Sleep detail only.
  - Verify: no user-visible pillar-"Rest"; every Sleep numeral maps to a C3 rule
    (list them in the commit message). Screenshot Sleep + Today. Commit.
  - **Completed 2026-07-10 (combined T34+T35 sweep):** pillar labels and score copy
    now say Sleep while ordinary uses such as Resting HR, Restful, interval REST, and
    “Rest up” remain intact. Today, Trends, widgets, notifications and watch surfaces
    present the 0–100 Sleep score; the Sleep tab hero presents that same score plus
    Duration / Efficiency / Resting HR; need and debt remain confined to Sleep detail
    and Smart Alarm. Tapping the Today Sleep pillar lands on `SleepView`, eliminating
    the duplicate Rest destination. Sleep-score surfaces use `sleepAccent`, stage
    colors are unchanged, and sleep-need teal remains detail-only. Evidence:
    `qa/T35-today.png` and `qa/T35-sleep.png`, compared with reference sheets 1 and 3.

- [x] **T36 — Recovery/Stress detail validation**
  - Confirm Recovery detail (CoupledView) reads the same repository field legacy
    Charge read (FR-6) — record file:line of the read in this file. Stress detail
    unchanged (0–3). Remove "of 100" on recovery hero (C6) + WHOOP hero pills (C7).
  - C13 on the detail: hero ring/numeral banded by value; "over time" chart line
    `recoveryData` with band-colored day points; key-factor status words keep
    semantic green/amber.
  - Verify: trio Recovery == detail hero == Trends last point (same seeded day),
    screenshot. Commit.
  - **Completed 2026-07-10:** `CoupledView.swift:717` reads Recovery directly from
    `repo.days[].recovery`, the same `DailyMetric.recovery` field used by Today and
    Trends; Stress remains on its unchanged 0–3 range at `CoupledView.swift:1257`.
    Hero source pills were removed per C7 while attribution remains in Data Sources
    and detail footnotes. Recovery hero value/color and over-time styling follow C13:
    value 50 is yellow, the line is `recoveryData`, day points are band-colored, and
    key-factor status words retain their semantic colors. The sweep also caught and
    fixed `WeeklyDigest`'s package-owned legacy display labels/prose so Trends now
    renders Recovery/Strain/Sleep without changing its metric cases or calculations.
    Seeded equality proof: 50 in `qa/T36-recovery-trio.png`, 50 in
    `qa/T36-recovery-detail.png`, and the final Recovery point at 50 in
    `qa/T36-recovery-trends.png`; `qa/T36-stress.png` proves the preserved 0–3
    surface. Compared with reference sheets 1 and 3; `NOOPiOS` build passed.

- [x] **T37 — Metric regression tests**
  - Add/extend tests: StrainScale round-trips; band boundaries; a rendering-level
    test (view-model/formatter level) asserting Workouts badge string for a stored
    fixture; xcstrings lint that no key still contains user-facing "Charge"/"Effort"
    pillar terms (script or test). Verify: suite green. Commit.
  - **Completed 2026-07-10:** `StrainScale` round-trips every half point from stored
    0–100 through display 0–21; existing 9.9/10/13.9/14/17.9/18/21 band boundaries
    remain pinned. `StrainScale.badgeText(fromStored:)` is the formatter-level row
    contract used by Workouts and tests: stored 67 → `14.1`, 0 → `0.0`, nil → `–`;
    the legacy `.hundred` preference can no longer alter the badge. Added
    `Tools/lint-paper-localizations.sh`; it passes across all four catalogs with no
    Charge/Effort pillar keys. Per the throughput addendum, `translate-de.py` and
    `translate-it.py` ran once at Phase 1 end (main catalog coverage after the run:
    DE 2,997 / IT 2,986 of 2,999; scripts reported their existing uncovered
    dictionary entries rather than generating copy). `StrandDesign`: 35/35 tests;
    full `NOOPiOS` simulator build passed.

## Phase 2 — Chrome (C4/C5)

- [x] **T38 — PaperHeaderBar + gap fix**
  - Files: `Packages/StrandDesign/Sources/StrandDesign/PaperComponents.swift` (add
    `PaperHeaderBar`), `Strand/Screens/ScreenScaffold.swift` (render it; top padding
    24→8), `StrandiOS/App/RootTabView.swift`, `Strand/Screens/TodayView.swift` +
    `TrendsView.swift` + `LiveView.swift` + `WorkoutsView.swift` (delete per-screen
    wordmark rows/floating chevron stacks; today's icon cluster → sync + status dot
    per C4).
  - Verify: wordmark ≤12 pt below status bar on notch + non-notch sims, at rest and
    scrolled; every reference screen re-shot; compositions still match references
    (don't just slide content up — plan §Header-gap). Commit.
  - Evidence: added the shared `PaperHeaderBar`, rendered it through a pinned
    `ScreenScaffold` safe-area header, reduced content top padding 24→8, removed
    the Today duplicate wordmark/avatar row, and replaced Live/Workouts floating
    chevrons with the inline header back action. `NOOPiOS` simulator build passed;
    `StrandDesign` 35/35 tests passed. Header QA covers notch rest/scrolled
    (`T38-today-notch.png`, `T38-today-scrolled-notch.png`,
    `T38-trends-notch.png`, `T38-trends-scrolled-notch.png`) and non-notch
    (`T38-today-nonnotch.png`), with the wordmark inside the first 12 pt below the
    safe-area boundary and no island overlap. The complete reference-screen sweep
    is `T38-{today-notch,trends-notch,sleep,live,workouts,more,devices,insights,data-sources,automations,settings}.png`.

- [x] **T39 — Density constants (C5)**
  - Files: `PaperComponents.swift`/`StrandDesign.swift` — enforce spec C5 dimensions
    in the shared primitives themselves (ScoreRing sizes, MetricTile compact grid
    variant, stress strip height 8 pt, chart line 2 pt default, StatTriplet).
  - Verify: StrandDesign tests; build; Today/Sleep screenshots show new proportions
    (full screen fidelity lands in Phase 3). Commit.
  - Evidence: `NoopMetrics` now owns the C5 ring, timer, health-tile, stress-strip,
    chart-line, and icon-circle dimensions; `ScoreRing`, `MetricTile`,
    `StressTimelineBar`, `TrendChart`, and `StatTriplet` consume the contract.
    `StrandDesign`: 36/36 tests including an explicit proportion-contract test;
    full `NOOPiOS` simulator build passed. `T39-today.png` and `T39-sleep.png`
    were compared with sheet 1: trio 64/5/30, hero 96/7/44, dense borderless
    health tiles, 8 pt stress strip, and 2 pt chart defaults are in place; the
    remaining screen-composition differences stay assigned to Phase 3.

## Phase 3 — Composition fidelity (fidelity.md rows below Close + nits)

- [x] **T40 — Today rebuild to reference (fidelity S1)**
  - Trio 64/5/30 pt; Health Monitor = ONE card w/ dense 3×2 tile grid + sparklines
    (restyle `VitalSignsSummary.swift`/`DashboardCards.swift` tiles it uses); stress
    strip 8 pt; Live-HR card layout per 001 §6-S1 incl. populated state (seed or
    strap-sim for the populated screenshot). FAB must not overlap grid content.
  - Verify vs sheet 1-1/3-1 side-by-side; SE-class device too. Commit.
  - Evidence: `T40-today-empty.png` and `T40-today-populated.png` were compared
    side-by-side with sheet 1-1/3-1. Today now uses the 64/5/30 trio, reference
    12 pt section rhythm, compact cards, green 2 pt populated HR trace with 120/40
    labels, 8 pt stress strip, and one borderless 3×2 Health Monitor grid. The
    green header status dot replaces the recording indicator; the 52 pt tile
    sparklines keep the Today-only FAB clear of grid content. `T40-today-narrow.png`
    proves the same composition on the narrowest installed supported phone
    (iPhone 17e, used as the SE-class surrogate) without truncation or content/FAB
    overlap. HR population was a simulator-only `hrSample` fixture (no app storage,
    scoring, or view math changed). Full `NOOPiOS` builds passed on both simulators;
    `StrandDesign`: 36/36 tests.
- [x] **T41 — Trends corrections (S2)** ∥ — tile color roles (numbers colored per
  C13: Recovery number banded, Strain blue, Sleep slate; labels neutral), chart lines
  per C13 (recovery line `recoveryData` + band-colored points, strain `strainAccent`,
  sleep `sleepAccent`), 2 pt lines, day+date x-axis labels, 0–21 strain series axis
  handling
  (dual-axis? No — separate normalized presentation is forbidden; plot strain on its
  own 0–21 right axis only if the reference's single 0–100 axis can't host it —
  decide, note here, keep visual match). Verify vs 1-2. Commit.
  - Evidence: `T41-trends.png` was compared with sheet 1-2. Tile labels are neutral
    while Recovery/Strain/Sleep numerals carry C13 color; all lines are 2 pt,
    Recovery points remain band-colored, and x-axis labels show weekday + date.
    Decision: the shared 0–100 left axis cannot honestly host raw 0–21 Strain, so
    the chart overlays a true 0–21 Strain plot with its own right axis—no normalized
    view value or storage conversion. Full `NOOPiOS` build passed.
- [x] **T42 — Sleep corrections (S3)** ∥ — sleep-marks section into a PaperCard
  (reference pattern; keep tap-to-log feature per C8, restyled + untruncated button
  labels), rebuild `Hypnogram` rendering (floating stage bars, 001 §2.1 colors, no
  gray track rows), strip WHOOP pill + "of 100" (C6/C7), add Asleep/Woke card per
  001 §6-S3. Verify vs 1-3. Commit.
  - Evidence: `T42-sleep.png` and `T42-sleep-window.png` were compared with sheet
    1-3. Sleep marks are one PaperCard with both full labels and unchanged logging
    actions; the hypnogram now floats the canonical stage bars without gray lane
    tracks; the hero is a bare 96/7/44 slate score ring with no source/scale pill;
    and the existing Asleep / duration / Woke card is visible and aligned beneath
    the stage chart. Full `NOOPiOS` build passed; `StrandDesign`: 36/36 tests.
- [x] **T43 — Workouts + post-run polish (S5/S27)** ∥ — stray "↓" icon, strain badges
  (0–21 from T34) visual per reference, splits/zones cards verified with seeded full
  data, post-run zones + route cards render with data (T31 baseline shot proves),
  elevation row. Verify vs 1-5/2-4. Commit.
  - Evidence: `T43-workouts.png`, `T43-post-run.png`, and
    `T43-post-run-route.png` were compared with sheet 1-5/2-4. Recent rows now use
    compact sport icons + canonical 0–21 blue Strain pills; the stray down arrow is
    a forward disclosure; zones/splits are populated; the post-run hero, 3×2 stats,
    zones, and seeded route all render. The elevation row is restored and honestly
    says `Not recorded` because the current persisted route model is 2D-only—no
    altitude was fabricated. Moving the FAB into the Today root also removes it from
    pushed Workouts/detail screens while preserving Quick Actions. Full `NOOPiOS`
    build passed; `StrandDesign`: 36/36 tests.
- [x] **T44 — Live-run controls + scale (S25/S26)** — implement C9 per T31 answer:
  lock + Pause/Resume + Finish row per reference (or documented engine limitation +
  reference geometry); timer to 64 pt; wordmark centered; paused state w/ splits
  table + Resume/Finish per 001 §6-S26. Verify vs 2-2/2-3 (screenshot paused state).
  Commit.
  - Evidence: `qa/T44-live-run.png` and `qa/T44-controls.png` were compared with
    sheet 2-2/2-3. The header now keeps the wordmark centered between sport and
    Live status, the elapsed timer remains the required 64 pt, and the control row
    matches the lock / center state / Finish geometry. The canonical Strain gauge
    shows the raw 0–21 value without an `of 21` caption. Per the C9 finding recorded
    in T31, the engine exposes only start/end and has no paused recorder state, so
    the center surface truthfully reads `Recording` and the real Finish action is
    retained; no cosmetic paused/splits state was fabricated. The Today-local FAB
    was also lifted above the tab bar after T43's scope correction. Full `NOOPiOS`
    simulator build passed; `StrandDesign`: 36/36 tests.
- [x] **T45 — Live console + Devices density (S4/S6)** ∥ — wrap advanced/record
  sections into Paper cards; Devices rows compressed to reference density (name,
  badge, battery, signal; capability prose behind the row's detail/disclosure),
  C1-consistent capability copy. Verify vs 1-4/4-1. Commit.
  - Evidence: `qa/T45-live-console.png`, `qa/T45-live-advanced.png`, and
    `qa/T45-devices.png` were compared with sheet 1-4/4-1. Live retains the compact
    device, heart-rate, physiology, and recording composition; Advanced Controls is
    now one Paper card and the strap log remains a contained Paper surface. Devices
    rows are compressed to name/model, state badge, honest battery-or-last-seen and
    signal state, with capability/caveat prose moved behind `Device details`; make
    active, rename, remove, and add-device controls remain reachable. Duplicate
    Recovery/Strain/Sleep copy was corrected to the canonical C1 terms. The seeded
    offline state shows `Signal —` instead of inventing RSSI or battery. Full
    `NOOPiOS` simulator build passed.
- [x] **T46 — Nit sweep on Close screens** ∥ — fidelity.md "Required direction" nits:
  Insights duplicate tagline, Quick-Actions workout icon tint, Settings profile card
  (real name + member-since per 001 §6-S10), pre-run row audit vs 2-1, "of 100"
  stragglers grep (AC-3 gate). Verify each with screenshot. Commit per screen-group.
  - Evidence: `qa/T46-insights.png`, `qa/T46-quick-actions.png`,
    `qa/T46-settings.png`, and `qa/T46-pre-run.png` were compared with sheets
    5-1/5-7/4-5/2-1. Insights now has one title treatment; the workout quick-action
    icon is ink; Settings uses the real local account identity plus the month of the
    oldest local history row (no profile schema/defaults migration); and pre-run
    retains Run type, GPS/local status, recent route, last workout, searchable sport
    list, and the pinned black Start action. All production and test Swift sources are
    now free of literal `of 100` / `of 21` captions; Vitality and Bevel-gauge renders
    use bare numerals. Final `NOOPiOS` simulator build passed; `StrandDesign`: 36/36
    tests.

## Phase 4 — Restoration (C8/C10, FR-9–11)

- [x] **T47 — Restyle skipped components/screens (plan §Inventory list)**
  - Paper treatment, layout preserved: DashboardCards editor sheets +
    KeyMetricsEditorSheet, StorageView, TrendsReportView, FusedRecordView,
    ScoringGuideView (+C1/C2 copy rewrite), UpdatesInboxView, XiaomiBandView,
    IntervalTimerView, AppleWatch setup/about, Biofeedback prefs, and the card
    components (Caffeine/Journal/StressCheckIn/SkinTemp/AutoWorkout/DonationNudge/
    HealthAlertBanner/MindSection/FullDayChartView, CoachMarkdownTheme prose colors).
  - Each surface: navigate to it in-sim (prove reachable), screenshot, commit per
    group.
  - **Completed 2026-07-10:** the skipped visual inventory now uses `PaperCard` and
    the Paper canvas while preserving each screen's layout and behavior. Restored
    Today's previously-hidden Key Metrics / Your Cards hosts plus the existing
    alert, auto-workout and donation cards, so the editor sheets and conditional
    cards remain reachable rather than silently disappearing. Scoring Guide copy
    uses Recovery / canonical 0–21 Strain / Sleep; Interval Timer keeps honest
    WORK/REST terminology. Trends Report now sizes responsively on iPhone instead
    of cropping its 460-pt macOS sheet, and Apple Watch About no longer duplicates
    the Sleep label. Added deterministic DEBUG-only `--demo-screen` routes for the
    restoration inventory; they do not change production navigation. Reachability
    proof: `qa/T47-{keymetricseditor,dashboardeditor,storage,trendsreport,fused,
    scoringguide,xiaomi,intervals,watchsetup,watchabout,updates,insights,health}.png`.
    The Insights and Health captures cover the hosted Journal/Mind/Caffeine and
    skin-temperature/card families; stress-check, auto-workout, donation and health
    alert remain honestly state-gated in their restored production hosts. Compared
    against sheets 1, 3, 5 and the brand guide. Final `NOOPiOS` simulator build
    passed; `StrandDesign`: 36/36 tests.
- [x] **T48 — Remove Liquid**
  - Delete `Strand/Liquid/` after repointing survivors: `LiveView`/`HydrationView`/
    `CoupledView` liquid references → Paper equivalents; if `LiveSessionView` still
    hosts run UI, move what's live into the run-flow files first. Remove liquid
    entries from `project.yml`; `xcodegen generate`.
  - Verify: FR-10 grep gate zero; all schemes build. Commit.
  - **Completed 2026-07-10:** deleted all five files under `Strand/Liquid/`
    (core physics, primitives, sky, obsolete Today and live-session hosts) and
    removed the directory. Replaced every remaining rendered vessel/tube/thread/
    press use with the flat `PaperGauge`, `PaperProgressBar`,
    `PaperSparkline` and `PaperPressStyle` implementations in
    `Strand/Screens/PaperDataPrimitives.swift`; the primitives use solid strokes,
    flat rails and no motion/tilt/glint engine. Onboarding's ambient bloom was also
    removed. The required identifier gate is zero for `LiquidVessel`,
    `LiquidTube`, `LiquidThread`, `LiquidPressStyle`, `LiquidTodayView`,
    `LiveSessionView` and `LiveSessionSummarySheet`; the only remaining
    liquid/scenic/glow words are comments and historical release-note prose, not
    rendered styling. Built the official XcodeGen CLI from source in `/tmp` and
    ran `xcodegen generate`. `NOOPiOS`, `NOOPiOSWidgets` and macOS `Strand`
    builds passed; `NOOPWatch` was attempted and remains environment-blocked
    because watchOS 26.5 is not installed (same documented host constraint as
    T34). `StrandDesign`: 36/36 tests. `qa/T48-live-paper-primitives.png`
    confirms the live console now renders the flat Paper gauge against the
    reference treatment.
- [x] **T49 — Route dedupe (C10)**
  - Repoint `StrandiOSApp.swift:301/:307` routes + any V5PillarHosts/NavRouter pillar
    destinations at the Paper details; delete `V5PillarHosts.swift` +
    `ChargeBreakdownDemoHost` if provably unreferenced after repoint (else leave
    compiling + unreferenced, note follow-up). Consider splitting CoupledView's
    pillar details into `PillarDetailViews.swift` (mechanical, plan §Risks).
  - Verify: exercise every string route in-sim without crash (FR-11 list them here
    with result). Commit.
  - **Completed 2026-07-10:** removed the legacy DEBUG routes
    `effortdetail`, `restdetail` and `chargebreakdown` plus the orphaned
    `ChargeBreakdownDemoHost`. Their canonical replacements are
    `recoverydetail → MetricDetailView(recovery)`,
    `straindetail → MetricDetailView(strain)`, and
    `sleepdetail → SleepView` (the C3 single Sleep destination). The route sweep
    also caught a real boundary bug: the Strain detail hero showed 14.1/21 while
    its graph still plotted stored 0–100 values. It now converts points through
    the single `StrainScale`, uses constant `strainAccent`, fixes the domain to
    0–21, and pins ticks at 0/7/14/21. `V5PillarHosts.swift` remains intentionally
    referenced by both shells: its two structs are repository/data adapters for
    the Paper `FusedRecordView` and `RhythmView`, not duplicate visual routes.
    Simulator process-alive smoke passed with zero failures for every current
    string route: today, trends, sleep, live, stress, workouts, health, insights,
    insightshub, explore, compare, settings, storage, trendsreport, fused,
    scoringguide, updates, xiaomi, intervals, watchsetup, watchabout,
    dashboardeditor, keymetricseditor, data, backup, support, labbook,
    automations, alarms, testcentre, rhythmconsent, rhythm, liveworkout,
    preworkout, recoverydetail, straindetail, sleepdetail, devices,
    devicescatalog, fitnessage, vitality, addwizard, ouraonboarding and ouradevice.
    Evidence: `qa/T49-{recoverydetail,straindetail,sleepdetail}.png`, compared
    with reference sheets 1 and 3. Final `NOOPiOS` build passed;
    `StrandDesign`: 36/36 tests.

## Phase 5 — Integration (FR-12–14)

- [x] **T50 — Integration map verification**
  - For each plan §Integration-map row: record file:line of every hop (entry → state
    → repo → table → refresh) HERE under this task; fix breaks found (wrong source,
    stale cache, missing environment object). Assert trio == detail == trends for
    Recovery/Strain/Sleep on one seeded day (FR-12).
  - **Completed 2026-07-10 — six critical traces:**
    - **Recovery:** Today entry/value is `TodayView.swift:1155–1165` →
      selected `repo.today/repo.days` row at `TodayView.swift:462–474` →
      canonical resolver at `Repository.swift:357–373` → merged repository
      publication at `Repository.swift:667–735` → `dailyMetric.recovery` read at
      `MetricsCache.swift:365–384` (write contract `:288–321`). Pull-to-refresh
      enters at `TodayView.swift:1378–1379`; `refreshSeq` reload is
      `:1429–1431`. Detail uses that same row at `CoupledView.swift:29–57`;
      Trends reads `day.recovery` at `TrendsView.swift:341–349`.
    - **Strain:** Today reads stored `day.strain` and applies only
      `StrainScale` at `TodayView.swift:1155–1168` → same
      `Repository.days/today` merge/refresh chain above →
      `dailyMetric.strain` at `MetricsCache.swift:295–321/:369–384`. Detail
      uses the same field + single converter at `CoupledView.swift:63–69`;
      Trends does the same at `TrendsView.swift:387–400`. No view-side score math.
    - **Sleep:** Today uses the selected daily row at
      `TodayView.swift:462–474/:1169–1170`; repository refresh loads imported
      `sleep_performance` at `Repository.swift:686–701` and falls back through
      the canonical daily composite at `:1780–1795`. Imported scalar source is
      `metricSeries` (`Database.swift:198–215`,
      `MetricSeriesStore.swift:31–59`); raw session source is `sleepSession`
      (`MetricsCache.swift:347–360`). Detail shares imported-first/composite
      fallback at `CoupledView.swift:72–78`; Trends reloads the same resolved key
      at `TrendsView.swift:263–269`.
    - **Stress:** `StressView.swift:30–34` owns the view state →
      refresh-driven load at `:80–89` → `Repository.series("stress")` →
      `metricSeries` table/read above; no stored point falls back to the model
      built from `repo.days` at `:125–132`. Intraday uses repository HR and the
      same store's R-R rows at `:92–122`. Scale remains 0–3.
    - **Health Monitor:** `HealthView.swift:14–37` enters through `Repository`
      and refreshes via the scaffold → `VitalsSection` passes
      `repo.vitalMetricRows` at `:1116–1134` → pure resolver/source precedence
      at `VitalSignsSummary.swift:96–145/:321–331` → repository source rows
      published at `Repository.swift:171–177/:707–735` → dailyMetric columns in
      `MetricsCache.swift:365–384`.
    - **Live HR:** `LiveView.swift:878–916` reads smoothed `AppModel.bpm` plus
      `LiveState` connection state → `AppModel.swift:490–520` consumes
      `LiveState.heartRate/rr` → `LiveState.swift:34–48/:430–442` →
      CoreBluetooth 2A37 notification dispatch at
      `BLEManager.swift:3331–3351`. This is intentionally stream-backed, not a
      database/cache path; disconnect clears the live buffers and the view returns
      to Waiting rather than showing stale data.
    Seeded-day equality remains exact: Recovery 50 on trio/detail/Trends
    (`qa/T36-recovery-{trio,detail,trends}.png`); stored Strain 67 → 14.1 on
    trio/detail/Workouts and the corrected detail route
    (`qa/T34-value-trace-{today,detail,workouts}.png`,
    `qa/T49-straindetail.png`); Sleep 86 on Today/Sleep and the canonical Sleep
    route (`qa/T35-{today,sleep}.png`, `qa/T49-sleepdetail.png`). No broken
    source, stale-cache trigger, or missing environment object was found.
- [x] **T51 — State coverage (FR-13)** ∥
  - Sweep reference screens for loading/empty/error/permission states; extend the
    existing honest-empty-state pattern where absent (import failure banner, HealthKit
    permission-denied surfaces, BLE-off state on Live/Devices). Screenshot each new
    state. Commit per group.
  - **Completed 2026-07-10:** the reference-screen sweep confirmed the established
    loading/empty patterns remain intact (calibrating pillar rings, Waiting Live HR,
    no-history Trends, pending device registry, source-specific empty states). Filled
    the three missing error/permission gaps without changing import, HealthKit or BLE
    behavior: Data Sources now raises a persistent Paper warning when the file picker
    itself fails instead of logging silently; Apple Health denial now says permission
    is off and offers the only actionable next step, Open Settings, rather than a
    request button that cannot prompt twice; and `LiveState` exposes the central
    manager's radio-unavailable reason so both Live and Devices render an honest
    Bluetooth-off/denied/unsupported Paper warning. DEBUG-only launch fixtures make
    the states deterministic and do not ship behavior changes. Evidence:
    `qa/T51-import-failure.png`, `qa/T51-healthkit-denied.png`,
    `qa/T51-live-bluetooth-off.png`, and
    `qa/T51-devices-bluetooth-off.png`, compared with reference sheets 4/6 and
    the shared Paper warning treatment. Final `NOOPiOS` simulator build passed.
- [x] **T52 — Widget/watch/notification alignment (C12, FR-14)** ∥
  - C1/C2/C13 through `StrandiOSWidgets`, `NOOPWatch`, `NOOPWatchComplications`,
    Live Activity (`LiveActivityController`), notification strings; values match
    phone for the seeded day. Build + run watch sim; screenshot widget gallery +
    watch glance. Commit.
  - **Completed 2026-07-10:** re-audited the phone publication boundary and every
    consumer. `WidgetSnapshot.publish` and `WatchSessionBridge` both use
    `Repository.widgetAnchor`; Recovery stays 0–100, Strain is converted exactly
    once through `StrainScale` before publication, and Sleep uses the same
    `sleep_performance` resolver as Today. Corrected the remaining presentation
    drift: widget Recovery now uses `RecoveryBands` instead of a duplicate
    threshold expression; widget, watch glance and complication Sleep now use the
    constant slate `sleepAccent` instead of Recovery bands; and watch/complication
    preview fixtures now carry canonical 14.1 Strain rather than invalid 41/61
    values. Live Activity already consumes the published 0–21 value and labels
    Recovery/Strain correctly. iOS local notifications contain no score numerals;
    the renamed catalogs lint clean across all four targets, while move/alarm copy
    remains behaviorally untouched. `NOOPiOS` and `NOOPiOSWidgets` builds passed;
    `StrandDesign`: 36/36 tests. Actual Simulator widget-gallery proof is
    `qa/T52-widget-gallery-small.png`. Both `NOOPWatch` and
    `NOOPWatchComplications` build/run + watch-glance screenshot were attempted
    and are host-blocked because Xcode has no watchOS 26.5 platform/runtime
    installed; no simulated watch screenshot was fabricated.
- [x] **T53 — Integration/regression tests**
  - Add tests covering: repository→snapshot publication for the three pillars;
    StrainScale usage at the widget-publish boundary; route-resolution smoke (every
    string route returns a view); xcstrings completeness for renamed keys. Suite
    green. Commit.
  - Evidence: `NOOPiOSTests/PaperIntegrationContractTests` covers canonical
    repository-to-widget publication (including the sole stored 0–100 → displayed
    0–21 StrainScale boundary), all 45 deterministic demo routes, and all four
    localization catalogs. `NOOPiOS` test action and simulator build passed;
    `StrandDesign` 36/36 and `Tools/lint-paper-localizations.sh` passed.

## Phase 6 — QA + handoff

- [ ] **T54 — Matrix QA (001 T28 superseded)**
  - Light+dark × {16 Pro, SE-class, Pro Max} on all reference screens; Dynamic Type
    XL on the six primary; Reduce Motion spot check; VoiceOver labels on Today/Sleep.
    AC-3 contrast re-check. Smoke-build macOS `Strand`. Fix fails, screenshot proof,
    commit.
- [ ] **T55 — Evidence + PR (001 T29 superseded)**
  - Full AFTER set into `qa/after/`; contact sheet via `Tools/make_contact_sheet.py`
    (before = T31 baseline); re-score every fidelity.md row inline (D11); walk spec
    §3 ACs 1–7 pass/fail; open PR `reskin/paper-ui → main` with contact sheet,
    C-rulings, fidelity re-scores, and follow-ups (deleted-Liquid confirmation,
    widget/watch visual redesign as next spec, macOS polish).
