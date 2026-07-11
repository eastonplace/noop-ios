# Spec 005 — Cleanup & Completeness (deep-pass audit + global alignment)

> Fifth pass. Priority per Easton (2026-07-11): **before pushing visuals further,
> clean house** — kill new-next-to-old duplication, bring EVERY screen onto the
> Paper system, verify every pre-reskin tool still exists and is reachable, and
> prove no dead/false buttons shipped. Tasks: `tasks.md` (T100–T112). All prior
> rulings stand (R/C/D series). Execute in `~/Code/noop-completion`.

## Audit findings (2026-07-11, code-level deep pass)

### A. New-UI + legacy-UI stacked on one screen (the duplication class)
1. **Workouts** — paper modules (score card, recent list, zones/splits) with the
   full legacy history browser below (`SectionHeader("Workout history")` +
   `sessionsSection`: Add workout, range chips, sport/source filters, search,
   session table). RULING E1 (Easton): **history stays on the Workouts tab** but
   gets the complete Paper pass — every control restyled (paper chips, paper
   search field, paper rows), zero features removed. Any remaining pre-Paper
   module inside it (e.g. a liquid "Typical Effort" gauge if still rendered)
   is replaced by the already-built paper equivalents.
2. **Live console** — legacy "Signal Trust" rail + "Session — record or inspect
   the current stream" tools below the reference modules. RULING E2 (Easton):
   **move both into Test Centre** as Paper-styled sections; behavior must be
   provably unbroken (record/inspect flows exercised in-sim before+after; the
   Live screen keeps its reference content + Start-workout path).
3. **Today "Your cards"** — stress card kind duplicates the stress module.
   RULING E3 (Easton): **leave as-is** (user-togglable). No work.
4. **Trends** — legacy pip-bar `weekInReview`/`NoopCard` builders coexist with
   the rendered paper body. Determine callers: if unreferenced on all platforms,
   DELETE; if macOS still renders them, restyle to Paper there. No screen may
   render two week-review modules.
5. **MetricDetailView (trend explorer)** — half-papered secondary surface
   (T56/T64 partial). Full Paper alignment pass.

### B. Dead / false affordances (confirmed + suspected)
1. **CONFIRMED**: `CoupledView.swift:932` pushes
   `ScoringGuideView(initialSection: .charge, onClose: {})` — the guide's Close
   button no-ops on this path (nav-back works, the button lies). Fix pattern:
   dismiss via environment when pushed, or hide the Close affordance on push.
   Also note the stale `.charge` section id + audit ScoringGuideView copy for
   leftover 0–100/Effort teaching content.
2. **Sweep required**: every production callback invoked with an empty closure
   (`onClose: {}`, `onAccept: {}`, `onStart: { _ in }` etc. outside #Preview
   and DEBUG demo routes); every `Button`/`NavigationLink`/chip whose action is
   a no-op or whose destination is gone.
3. **Runtime tap-through audit** (the only honest test): on the seeded sim,
   every visible control on every screen gets tapped once; result logged in the
   audit table (works / dead / crashes / misroutes). This is how "false buttons"
   are actually found — grep can't see a button wired to a stale handler.

### C. Global Paper coverage (RULING E4 — Easton: "every screen aligns")
Verify-and-refresh list (Codex's T47/T95 claimed coverage — VERIFY visually
with full-page evidence, refresh what fails): StorageView, TrendsReportSheet,
FusedRecordView, ScoringGuideView, UpdatesInboxView, WhatsNewView,
XiaomiBandView, IntervalTimerView, AppleWatchSetupView/AboutView, Biofeedback
prefs/controller, HydrationView, CompareView, CoachView, HealthView,
IntelligenceView, InsightsHubView, MetricExplorerView catalog ("Explore"),
JournalLogCard/CaffeineLogCard/StressCheckInCard/SkinTempCards/AutoWorkoutCard/
HealthAlertBanner/MindSection/FullDayChartView, DashboardCardsEditorSheet,
KeyMetricsEditorSheet, ManualWorkoutSheet, AddDeviceWizard inner steps,
**onboarding flow** (now in scope), UpdatesInbox, Support sub-screens.

### D. Reachability & completeness
Build the tool matrix: every screen/tool/sheet reachable on the `pre-paper-reskin`
tag must be reachable now (More list, hub rows, settings rows, deep links,
FAB sheet, context menus). Diff the two More/route inventories; restore any
lost entry point. Nothing may exist in code but be unreachable in UX (orphans
get an entry point or an explicit Easton decision to retire).

### E. Hygiene
1. Fix the two known red tests (WeeklyDigest still asserts "Charge"; the T81
   proportion test expects pre-D12 tokens) — update expectations to current
   rulings, don't delete coverage.
2. Delete provably-dead legacy code left by the migration (orphaned pip
   week-review if unreferenced, `ChargeBreakdownFormat`/V5 leftovers if
   orphaned, any Liquid remnants) — `grep` + call-site proof per deletion.
3. xcstrings sweep across ALL languages for stale pillar terms and dead keys.

### F. Lost interactions (RULING E6 — Easton, 2026-07-11, verified in code)
The reskin dropped tap-through destinations while rebuilding cards. Confirmed
case: pre-reskin Today's HR section navigated to **`FullDayChartView`** (the
"Deep Timeline", #575 — full-day zoom/pan chart, metric picker, resolution-
adaptive reads). It still exists and works (Explore → tap-through at
`MetricExplorerView.swift:211`), but the paper `paperLiveHeartRateCard` has NO
tap action — the interaction was lost, not the screen. Ruling:
1. Restore the Today Live-HR card tap → `FullDayChartView` (opening on `.hr`),
   and give that screen the Paper pass (it's on the §C list) WITHOUT touching
   its zoom/pan/read machinery — chrome and tokens only.
2. **Interaction-parity audit** (generalizes the class): for every reskinned
   screen, diff its pre-reskin source (`git show pre-paper-reskin:…`) for
   NavigationLink/Button/onTap destinations vs current; every lost destination
   is restored by COPYING the original wiring and destination from the
   pre-reskin code (the original app is the reference implementation — port,
   don't reinvent) and refreshing its UI to Paper. Log each in the audit table
   (column: "interactions lost/restored").

## Evidence protocol (new, mandatory — RULING E5)
Top-of-fold screenshots hid every stacked-duplication bug. From 005 on, screen
evidence = **full-page capture**: scroll in viewport-height steps and shoot
each step (2–4 images per screen), filed `qa/<screen>/page-N.png`. The audit
table links the full set per screen.

## Acceptance
1. Audit table complete: every screen row has full-page evidence, tap-through
   result, Paper-conformance verdict, and dedupe status.
2. Zero screens render legacy visual system anywhere in their full scroll.
3. Zero dead controls (every logged control works or was explicitly retired
   with Easton's sign-off).
4. Reachability matrix: 100% of pre-reskin tools reachable (or explicitly
   retired by Easton — none assumed).
5. Test suite green including the two currently-red tests.
6. Live console diagnostics live in Test Centre and are exercised working.
7. Full-page contact set regenerated; fidelity.md gains "complete & clean"
   column.
