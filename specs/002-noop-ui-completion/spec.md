# Spec 002 — NOOP UI Completion (fidelity, metrics, restoration, integration)

> **For agentic workers:** This is the WHAT for the second reskin pass. Read `plan.md`
> for the HOW, `tasks.md` for the ordered task list (T30–T55), `fidelity.md` for the
> per-screen QA evidence. **Spec 001 (`../001-concept-ui-reskin/spec.md`) remains the
> pixel bible** — its §2 design language, §4 component inventory, and §6 screen
> requirements still govern except where a C-ruling below supersedes them. Reference
> images: `../001-concept-ui-reskin/references/`.

**Goal:** Take the Paper reskin from "good first pass" to reference quality: fix
composition/proportion/header gaps (fidelity.md), migrate the primary metrics to
**Recovery / Strain / Sleep** with Strain on a **0–21** display scale, restore and
restyle every surface the first pass skipped, and verify every surface is wired to its
real data path. The current UI is a foundation to iterate on, not the visual target.

**Non-goals:** No new features (sleep-marks logging, advanced live controls etc. stay —
restyled, never removed). No storage-schema migration for scores (C2). No
Android/watch-face redesign beyond terminology/scale alignment (C12). No macOS polish.

**Acceptance bar:** "Directionally similar" is NOT acceptance for reference-backed
screens. A reviewer holding the reference next to the screenshot should recognize the
screen at first glance — hierarchy, proportions, rhythm, and visual character, not just
palette and card shapes. Where real data, Dynamic Type, or platform constraints force a
deviation, preserve the reference's intent and note the deviation in the task.

---

## 1. Canonical rulings (C-series; extend/supersede 001's R-series)

- **C1 — Metric names.** User-facing pillar names become **Recovery** (was Charge),
  **Strain** (was Effort), **Sleep** (was Rest). Stress keeps its name. Pillar colors
  follow the WHOOP color logic in **C13** (supersedes 001 R3's static
  green/purple/blue).
  The Sleep tab and the Sleep pillar intentionally converge — the tab shows the pillar's
  detail surface. Internal identifiers/DB columns (`strain`, `recoveryScore`, etc.) are
  NOT renamed; this is a user-facing-string + presentation migration through all four
  `Localizable.xcstrings` catalogs (app, StrandDesign, NOOPWatch, complications), all
  localized languages (EN/DE/IT — machine-translate DE/IT via existing `Tools/translate-*.py`
  pattern and mark for review), accessibility labels, widgets, notifications, and
  App Intents phrases. Battery/charging metaphors in Recovery copy are retired unless
  they read naturally as "recharge your body" recovery language.
- **C2 — Strain scale.** Strain displays on **0–21 with one decimal** everywhere
  (daily pillar, workout effort badges, run hero, charts, deltas, thresholds, widgets,
  watch, notifications). Evidence (plan §Metric findings): WHOOP-native strain (0–21,
  nonlinear) is stored ×(100/21) as 0–100 (`AppleDemoSeeder.STRAIN_SCALE`,
  `WhoopImporter`); `MetricCatalog` already maps 0–100↔0–21 (#268). Therefore: **no
  storage migration** — historical 0–100 values convert losslessly at the display
  boundary. Implement ONE converter (`StrainScale` in StrandDesign or MetricCatalog,
  single source of truth): `display = stored × 21 / 100`, formatted 1 decimal, clamped
  0–21. Status bands (scaled WHOOP convention): Light 0–9.9, Moderate 10.0–13.9,
  High 14.0–17.9, All Out 18.0–21.0. Rings/gauges take range 0…21; chart y-axes 0–21
  with gridlines at 7/14/21; deltas convert before display. Forbidden: dividing inside
  individual views, string-formatting hacks, or migrating stored rows.
- **C3 — Sleep representation rules.** "Sleep" must mean one thing per surface:
  Today trio + Trends tiles/chart = **Sleep score (0–100)**; Sleep tab hero = score +
  Duration/Efficiency/Resting-HR triplet; hypnogram/stages = durations; sleep need &
  debt appear ONLY in the Sleep detail (and Smart Alarm) where the existing
  calculations (`SleepView`/`SmartAlarmView`/`CoupledView` sleep-need code) already
  live; notifications/widgets show score, duration as secondary. Never mix a percent
  and a duration in one numeral. No new sleep calculations.
- **C4 — Header contract.** ONE header row on every screen: back chevron (pushed
  screens only) inline LEFT, "N O O P" wordmark CENTER, screen icons RIGHT — never a
  floating chevron row stacked above the wordmark. Below it, the screen's
  overline-title/date row. Wordmark row sits tight to the safe area: ≤ 12 pt below the
  status bar (kill `ScreenScaffold.swift:43` `.padding(.top, 24)` → 8, and per-screen
  spacer stacks). Today's right-side cluster becomes reference's sync icon + green
  status dot only — the red-dot recording indicator, bell, and avatar ring move behind
  More/Settings (they are not in any reference).
- **C5 — Proportion contract.** Trio rings 64 pt Ø / 5 pt stroke / 30 pt numerals;
  hero rings 96 pt / 7 pt / 44 pt; live-run timer 64 pt; Health-Monitor grid = dense
  3×2 tiles inside ONE card (icon 16 pt + 13 pt label + 20 pt value + sparkline, no
  per-tile border cards); stress timeline strip 8 pt tall; chart lines 2 pt; icon
  circles 32–36 pt. These numbers repeat 001 §2.3/§2.4 — they were specified and not
  followed; treat them as hard acceptance values (±2 pt).
- **C6 — No "of 100"/"of 21" sublabels** inside rings; references show bare numerals.
  Scale context belongs to the detail screen's axis/labels.
- **C7 — No source pills in heroes.** "WHOOP" capsules leave hero cards; source
  attribution lives in Data Sources and detail footnotes (e.g. "Why this sleep?").
- **C8 — Restore, don't remove.** Every pre-reskin feature remains reachable. Legacy
  surfaces/components the first pass skipped (fidelity.md + plan §Inventory) get full
  Paper treatment — layout preserved, primitives swapped — not deletion, not
  legacy-island styling.
- **C9 — Live-workout controls.** Reference S25/S26 requires lock + **Pause/Resume** +
  Finish. If the session engine supports pause (verify in the run controller located in
  T31), implement the reference control row; if it genuinely cannot pause, keep
  End-workout but document the engine limitation in tasks.md and match the reference's
  control-row geometry.
- **C10 — One detail path per pillar.** The paper pillar details (currently in
  `CoupledView.swift`) become the ONLY pillar detail surfaces: repoint the legacy
  deep-link routes (`StrandiOSApp.swift:301` "effortdetail" → `MetricDetailView`,
  `:307` "chargebreakdown" → `ChargeBreakdownDemoHost`) and any `V5PillarHosts.swift` /
  NavRouter paths at them. No screen may present the old detail UI.
- **C11 — Evidence discipline.** Every visual task ends with a simulator screenshot
  into `specs/002-noop-ui-completion/qa/` named `T##-<screen>.png`, compared against
  the reference crop before the commit. QA images live ONLY in this spec folder — the
  stray repo-root `qa/` folder gets consolidated here and removed (T31).
- **C12 — Watch/widgets scope.** `NOOPWatch`, complications, and `StrandiOSWidgets`
  get terminology (C1) + strain scale (C2) + color logic (C13) + accessibility-label
  alignment ONLY — no visual redesign this spec.
- **C13 — WHOOP color logic (source: official WHOOP Brand & Design Guidelines PDF,
  developer.whoop.com; recovery bands per support.whoop.com).** Applies EVERYWHERE a
  pillar value appears: rings, numerals, chart lines/points, badges, calendar dots,
  status words, widgets, watch, notifications.
  - **Recovery is valuated (banded):** the score's color depends on its value —
    High 67–100 green, Medium 34–66 yellow, Low 0–33 red (`≥67 / ≥34 / else`).
    WHOOP hexes are the dark-mode values; light mode uses same-hue,
    luminance-adapted values for the paper canvas:
    `recoveryHigh` light `#12A833` / dark `#16EC06`; `recoveryMed` light `#C29200` /
    dark `#FFDE00`; `recoveryLow` light `#E00028` / dark `#FF0026`.
    **Recovery data WITHOUT a valuation** (trend lines, sparklines, non-scored
    recovery context) uses `recoveryData` light `#3E87C7` / dark `#67AEE6`
    (WHOOP "Recovery Blue") — e.g. the Trends recovery line is `recoveryData` with
    per-day point dots colored by that day's band; the detail over-time chart likewise.
  - **Strain is constant blue** at every value: `strainAccent` light `#0084CE` /
    dark `#0093E7`. No banded strain colors — bands (C2) change the status WORD, never
    the color. Replaces every purple strain/effort surface.
  - **Sleep is constant slate-blue:** `sleepAccent` light `#5E86A3` / dark `#7BA1BB`
    for sleep score + sleep-related data (hours, ring). Sleep-stage ramp (Awake/REM/
    Light/Deep, 001 §2.1) is unchanged. Optional `sleepNeedTeal` light `#00A66E` /
    dark `#00F19F` (WHOOP teal) ONLY for the sleep-need value in the Sleep detail;
    nowhere else — NOOP's CTAs stay ink black (the paper design language wins over
    WHOOP's teal-CTA convention).
  - **Unchanged:** Stress amber (WHOOP has no stress color), HR-zone ramp, semantic
    success/warning/destructive tokens. The Journal/Experimental purple badges keep
    purple via their own token — decouple them from the old `effortAccent` before it
    flips blue.
  - **Precedence:** C13 beats the concept sheets' static ring colors (sheets still
    govern layout/proportion). A 41 Recovery renders YELLOW even though sheet 3-2
    painted it green; small text stays `textPrimary`/`textSecondary` — accent color is
    for graphics, numerals, and badges, matching the existing pattern.

---

## 2. Requirements

### 2.1 Reference fidelity (see fidelity.md for the per-screen gap list)
- FR-1: Every fidelity.md row rated below "Close" reaches "Close" or better; every
  "Close" row has its listed nits fixed. Verification is side-by-side screenshot
  review per C11, on iPhone 16 Pro plus one small device (SE/13 mini class).
- FR-2: The cross-cutting defects (fidelity.md §Cross-cutting: header stack, ring
  proportions, source pills, density, chart weight) are fixed in shared components,
  then every consuming screen is re-shot — fixing the token/component without
  re-verifying the screens is not done.
- FR-3: Screens keep their information architecture from 001 §6; composition changes
  bring them TO the reference, never to a new invention.

### 2.2 Metric migration
- FR-4: C1 rename completes across: all Swift UI strings, all four xcstrings catalogs
  (all languages), accessibility labels/hints, widget/watch/complication strings,
  notification copy, App Intents phrases, `ScoringGuideView`/`HowNoopWorksView`
  explainer copy, and the Devices capability copy (which currently mixes
  Strain/Effort). Search terms: "Charge", "Effort", "Rest" as user-visible words —
  audited case-by-case ("Rest" the verb vs pillar; "charge" the battery vs pillar).
- FR-5: C2 strain scale completes across: Today trio, Trends tiles + chart axis,
  Strain detail (ring, baseline/yesterday/7D triplet, over-time chart 0–21 axis,
  contributor rows), Workouts score card + recent-workout badges, run flow hero +
  "compared to usual" delta, widgets/watch/complications, notifications, and any
  threshold logic that keys off score bands. All read through the single converter.
- FR-6: Recovery keeps 0–100%; its detail/summary copy is validated to describe
  recovery/readiness (not battery charging) and the value provably comes from the same
  repository field the old Charge surfaces read (no calculation change).
- FR-7: C3 sleep representation table is implemented; every "Sleep" numeral in the app
  is traceable to one of the C3 rules.
- FR-8: Historical data renders correctly: a 2025 workout with stored strain 67
  displays 14.1 everywhere it appears; trends across the rename boundary are
  continuous (no unit jump in charts).
- FR-8b: C13 color logic is implemented on every pillar surface: Recovery
  ring/numeral/badge banded by value (67/34 boundaries), recovery trend lines in
  `recoveryData` blue with band-colored points, all strain surfaces `strainAccent`
  blue (zero purple strain remains), all sleep-score surfaces `sleepAccent`, widgets/
  watch/complications included; light-mode variants pass AC-3 contrast for their role
  (graphics ≥3:1, any colored text ≥4.5:1).

### 2.3 Restoration & integration
- FR-9: The untouched-by-001 components (plan §Inventory list) are restyled to Paper
  and their hosting flows verified reachable: DashboardCards + editor sheets,
  VitalSignsSummary, KeyMetricsEditorSheet, StorageView, TrendsReportView,
  FusedRecordView, ScoringGuideView, UpdatesInboxView, XiaomiBandView,
  IntervalTimerView, Biofeedback prefs/controller UI, and the card components
  (Caffeine/Journal/StressCheckIn/SkinTemp/AutoWorkout/DonationNudge/HealthAlertBanner/
  MindSection/FullDayChartView).
- FR-10: Zero remaining renders of liquid/scenic/glass styling: `Strand/Liquid/*` is
  deleted or fully unreferenced, `LiveView`/`HydrationView`/`CoupledView` liquid
  imports removed, `grep -rn "Liquid\|scenic\|glow" Strand StrandiOS` shows no
  rendered-on-iOS hit.
- FR-11: C10 route dedupe done; deep links, NavRouter destinations, and hub rows all
  land on Paper surfaces with required environment objects (no crash on any route —
  exercise each `StrandiOSApp` string route once in the simulator).
- FR-12: For the six pillar/vital surfaces (Recovery, Strain, Sleep, Stress, Health
  Monitor, Live HR): document and verify the chain frontend → state → repository →
  source table, per plan §Integration map; trio value == detail hero value == trends
  last-point for the same day (single source of truth).
- FR-13: Every reference-backed screen has correct loading/empty/error/permission
  states in the Paper style (the honest empty states that already exist — "Waiting for
  live signal", "Waiting for GPS route" — are the pattern; extend to screens lacking
  them; missing-HealthKit-permission and import-failure paths surface visibly, never
  silently succeed).
- FR-14: Widgets, watch app, complications, Live Activity, and notifications compile,
  run, and show C1/C2-consistent values with the phone app.

### 2.4 Design-system completion
- FR-15: No hardcoded hex/pt values in screens for things a token covers; new
  constants added to StrandDesign (`PaperComponents.swift` / `StrandDesign.swift`)
  when a value repeats. Intentional per-screen composition differences stay.
- FR-16: Dynamic Type XL, Reduce Motion, VoiceOver labels on the primary six screens;
  AC-3 contrast (001 §8) re-verified after any token change — the uncommitted
  `textTertiary` AC-3 fix in the working tree is reviewed and committed first (T30).
- FR-17: Dark mode re-verified on all reference screens after every shared-component
  change (001 §2.2 values stand).

## 3. Acceptance criteria (global)

1. Build green: `NOOPiOS` scheme + `StrandDesign` tests + `StrandTests` + smoke-build
   `NOOPiOSWidgets`/`NOOPWatch`.
2. fidelity.md re-scored ≥ Close on every row, with after-screenshots linked.
3. Grep gates: zero user-facing "Charge/Effort" pillar strings (localized included);
   zero "of 100" ring sublabels; zero rendered Liquid/scenic references; zero
   `× 21`-style ad-hoc conversions outside the single StrainScale; zero strain
   surfaces still reading the purple token.
4. Strain spot check: stored 67 → displayed 14.1 on Today, detail, Workouts badge,
   widget, watch (screenshot each). Color spot check: seeded days at Recovery 25 /
   50 / 80 render red / yellow / green on trio, detail hero, and trends points
   (screenshot each).
5. Route sweep: every deep-link/NavRouter destination opens without crash and shows
   Paper UI.
6. Device matrix: 16 Pro + SE-class + Pro Max, light + dark, Dynamic Type XL on the
   six primary screens — screenshots in `qa/`.
7. Final before/after contact sheet (`Tools/make_contact_sheet.py`) + PR
   `reskin/paper-ui → main` (or continuation branch per plan §Safety) with fidelity.md
   linked and C-rulings listed.
