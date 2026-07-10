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

- [ ] **T36 — Recovery/Stress detail validation**
  - Confirm Recovery detail (CoupledView) reads the same repository field legacy
    Charge read (FR-6) — record file:line of the read in this file. Stress detail
    unchanged (0–3). Remove "of 100" on recovery hero (C6) + WHOOP hero pills (C7).
  - C13 on the detail: hero ring/numeral banded by value; "over time" chart line
    `recoveryData` with band-colored day points; key-factor status words keep
    semantic green/amber.
  - Verify: trio Recovery == detail hero == Trends last point (same seeded day),
    screenshot. Commit.

- [ ] **T37 — Metric regression tests**
  - Add/extend tests: StrainScale round-trips; band boundaries; a rendering-level
    test (view-model/formatter level) asserting Workouts badge string for a stored
    fixture; xcstrings lint that no key still contains user-facing "Charge"/"Effort"
    pillar terms (script or test). Verify: suite green. Commit.

## Phase 2 — Chrome (C4/C5)

- [ ] **T38 — PaperHeaderBar + gap fix**
  - Files: `Packages/StrandDesign/Sources/StrandDesign/PaperComponents.swift` (add
    `PaperHeaderBar`), `Strand/Screens/ScreenScaffold.swift` (render it; top padding
    24→8), `StrandiOS/App/RootTabView.swift`, `Strand/Screens/TodayView.swift` +
    `TrendsView.swift` + `LiveView.swift` + `WorkoutsView.swift` (delete per-screen
    wordmark rows/floating chevron stacks; today's icon cluster → sync + status dot
    per C4).
  - Verify: wordmark ≤12 pt below status bar on notch + non-notch sims, at rest and
    scrolled; every reference screen re-shot; compositions still match references
    (don't just slide content up — plan §Header-gap). Commit.

- [ ] **T39 — Density constants (C5)**
  - Files: `PaperComponents.swift`/`StrandDesign.swift` — enforce spec C5 dimensions
    in the shared primitives themselves (ScoreRing sizes, MetricTile compact grid
    variant, stress strip height 8 pt, chart line 2 pt default, StatTriplet).
  - Verify: StrandDesign tests; build; Today/Sleep screenshots show new proportions
    (full screen fidelity lands in Phase 3). Commit.

## Phase 3 — Composition fidelity (fidelity.md rows below Close + nits)

- [ ] **T40 — Today rebuild to reference (fidelity S1)**
  - Trio 64/5/30 pt; Health Monitor = ONE card w/ dense 3×2 tile grid + sparklines
    (restyle `VitalSignsSummary.swift`/`DashboardCards.swift` tiles it uses); stress
    strip 8 pt; Live-HR card layout per 001 §6-S1 incl. populated state (seed or
    strap-sim for the populated screenshot). FAB must not overlap grid content.
  - Verify vs sheet 1-1/3-1 side-by-side; SE-class device too. Commit.
- [ ] **T41 — Trends corrections (S2)** ∥ — tile color roles (numbers colored per
  C13: Recovery number banded, Strain blue, Sleep slate; labels neutral), chart lines
  per C13 (recovery line `recoveryData` + band-colored points, strain `strainAccent`,
  sleep `sleepAccent`), 2 pt lines, day+date x-axis labels, 0–21 strain series axis
  handling
  (dual-axis? No — separate normalized presentation is forbidden; plot strain on its
  own 0–21 right axis only if the reference's single 0–100 axis can't host it —
  decide, note here, keep visual match). Verify vs 1-2. Commit.
- [ ] **T42 — Sleep corrections (S3)** ∥ — sleep-marks section into a PaperCard
  (reference pattern; keep tap-to-log feature per C8, restyled + untruncated button
  labels), rebuild `Hypnogram` rendering (floating stage bars, 001 §2.1 colors, no
  gray track rows), strip WHOOP pill + "of 100" (C6/C7), add Asleep/Woke card per
  001 §6-S3. Verify vs 1-3. Commit.
- [ ] **T43 — Workouts + post-run polish (S5/S27)** ∥ — stray "↓" icon, strain badges
  (0–21 from T34) visual per reference, splits/zones cards verified with seeded full
  data, post-run zones + route cards render with data (T31 baseline shot proves),
  elevation row. Verify vs 1-5/2-4. Commit.
- [ ] **T44 — Live-run controls + scale (S25/S26)** — implement C9 per T31 answer:
  lock + Pause/Resume + Finish row per reference (or documented engine limitation +
  reference geometry); timer to 64 pt; wordmark centered; paused state w/ splits
  table + Resume/Finish per 001 §6-S26. Verify vs 2-2/2-3 (screenshot paused state).
  Commit.
- [ ] **T45 — Live console + Devices density (S4/S6)** ∥ — wrap advanced/record
  sections into Paper cards; Devices rows compressed to reference density (name,
  badge, battery, signal; capability prose behind the row's detail/disclosure),
  C1-consistent capability copy. Verify vs 1-4/4-1. Commit.
- [ ] **T46 — Nit sweep on Close screens** ∥ — fidelity.md "Required direction" nits:
  Insights duplicate tagline, Quick-Actions workout icon tint, Settings profile card
  (real name + member-since per 001 §6-S10), pre-run row audit vs 2-1, "of 100"
  stragglers grep (AC-3 gate). Verify each with screenshot. Commit per screen-group.

## Phase 4 — Restoration (C8/C10, FR-9–11)

- [ ] **T47 — Restyle skipped components/screens (plan §Inventory list)**
  - Paper treatment, layout preserved: DashboardCards editor sheets +
    KeyMetricsEditorSheet, StorageView, TrendsReportView, FusedRecordView,
    ScoringGuideView (+C1/C2 copy rewrite), UpdatesInboxView, XiaomiBandView,
    IntervalTimerView, AppleWatch setup/about, Biofeedback prefs, and the card
    components (Caffeine/Journal/StressCheckIn/SkinTemp/AutoWorkout/DonationNudge/
    HealthAlertBanner/MindSection/FullDayChartView, CoachMarkdownTheme prose colors).
  - Each surface: navigate to it in-sim (prove reachable), screenshot, commit per
    group.
- [ ] **T48 — Remove Liquid**
  - Delete `Strand/Liquid/` after repointing survivors: `LiveView`/`HydrationView`/
    `CoupledView` liquid references → Paper equivalents; if `LiveSessionView` still
    hosts run UI, move what's live into the run-flow files first. Remove liquid
    entries from `project.yml`; `xcodegen generate`.
  - Verify: FR-10 grep gate zero; all schemes build. Commit.
- [ ] **T49 — Route dedupe (C10)**
  - Repoint `StrandiOSApp.swift:301/:307` routes + any V5PillarHosts/NavRouter pillar
    destinations at the Paper details; delete `V5PillarHosts.swift` +
    `ChargeBreakdownDemoHost` if provably unreferenced after repoint (else leave
    compiling + unreferenced, note follow-up). Consider splitting CoupledView's
    pillar details into `PillarDetailViews.swift` (mechanical, plan §Risks).
  - Verify: exercise every string route in-sim without crash (FR-11 list them here
    with result). Commit.

## Phase 5 — Integration (FR-12–14)

- [ ] **T50 — Integration map verification**
  - For each plan §Integration-map row: record file:line of every hop (entry → state
    → repo → table → refresh) HERE under this task; fix breaks found (wrong source,
    stale cache, missing environment object). Assert trio == detail == trends for
    Recovery/Strain/Sleep on one seeded day (FR-12).
- [ ] **T51 — State coverage (FR-13)** ∥
  - Sweep reference screens for loading/empty/error/permission states; extend the
    existing honest-empty-state pattern where absent (import failure banner, HealthKit
    permission-denied surfaces, BLE-off state on Live/Devices). Screenshot each new
    state. Commit per group.
- [ ] **T52 — Widget/watch/notification alignment (C12, FR-14)** ∥
  - C1/C2/C13 through `StrandiOSWidgets`, `NOOPWatch`, `NOOPWatchComplications`,
    Live Activity (`LiveActivityController`), notification strings; values match
    phone for the seeded day. Build + run watch sim; screenshot widget gallery +
    watch glance. Commit.
- [ ] **T53 — Integration/regression tests**
  - Add tests covering: repository→snapshot publication for the three pillars;
    StrainScale usage at the widget-publish boundary; route-resolution smoke (every
    string route returns a view); xcstrings completeness for renamed keys. Suite
    green. Commit.

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
