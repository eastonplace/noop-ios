# Plan 002 — NOOP UI Completion: Technical Approach

> Read `spec.md` (WHAT + C-rulings) and `fidelity.md` (per-screen evidence) first.
> Ordered tasks: `tasks.md` (T30–T55). 001's plan.md remains valid background (token
> architecture, verification workflow, simulator seeding).

**Goal:** Close the fidelity gap, migrate metrics to Recovery/Strain(0–21)/Sleep,
restore skipped surfaces, and prove data integration — with the same token-first,
shared-component-first blast-radius discipline as 001.

**Architecture recap + what pass 1 left behind:** Pass 1 (commits `b01acd7d…e783c5c4`
on `reskin/paper-ui`) rewrote `StrandPalette`/`StrandFont`, added
`Packages/StrandDesign/Sources/StrandDesign/PaperComponents.swift`, rebuilt chrome in
`StrandiOS/App/RootTabView.swift`, and restyled ~40 screen files. It did NOT: enforce
the 001 §2.4 component dimensions (rings/tiles/bars oversized), unify the header (three
different header stacks exist), touch 27 screen-support files (list below), remove
Liquid, or dedupe legacy pillar routes. T28/T29 (device matrix, evidence handoff) were
never run. One uncommitted AC-3 `textTertiary` contrast fix sits in the working tree.

**Tech stack:** unchanged from 001 (SwiftUI, XcodeGen `project.yml`, scheme `NOOPiOS`,
iOS 16 floor, four xcstrings catalogs, `AppleDemoSeeder` behind a launch argument for
simulator data).

## Global constraints

- All of 001's Global Constraints stand (visual-first, iOS 16 floor, xcstrings for new
  strings, surgical diffs, R1–R10) except where C-rulings supersede (C1 supersedes the
  Charge/Effort/Rest naming embedded in R3/001-§6 copy; C2 supersedes R2's "keep 0–100
  effort display").
- **No storage/schema migration** for scores (C2). No calculation changes (FR-6).
- **Required reading before T32** (`~/.codex/skills/`): `swiftui-expert-skill/SKILL.md`
  + `references/latest-apis.md`, `swift-concurrency/SKILL.md`,
  `swift-testing-expert/SKILL.md`; Xcode build skills on demand (001 plan lists them).
  iOS 26 Liquid Glass guidance remains explicitly unwanted.
- No modifications before the T30 safety gate passes.

## Safety & rollback (T30 — hard gate)

Same net as 001, updated anchors:
1. Review + commit the dirty `Palette.swift` `textTertiary` AC-3 fix (it's correct per
   001 AC-3; commit as `reskin(T30): commit AC-3 tertiary contrast fix`).
2. Tag `pre-ui-completion` on `reskin/paper-ui` HEAD; push branch + tag to
   `private-noop-report` (never `origin`, never force-push).
3. Continue working ON `reskin/paper-ui` (001's work is unmerged; 002 completes the
   same deliverable — one PR at the end covers both).
4. Fresh tarball snapshot outside iCloud:
   `tar czf ~/Backups/noop-pre-completion-$(date +%Y%m%d).tgz --exclude='Noop/build' -C "$HOME/Library/Mobile Documents/com~apple~CloudDocs/Vibe Coding Projects/projects" Noop`
   — verify >10 MB.
5. Rollback recipes: `git reset --hard pre-ui-completion` (branch), tag
   `pre-paper-reskin` still exists for full-pass rollback, tarballs for untracked
   damage, per-task commits for surgical reverts.

## Metric findings (evidence, so Codex doesn't rediscover)

- **Storage scale:** WHOOP-native strain (0–21, nonlinear) is rescaled at import:
  `AppleDemoSeeder.swift:22` (`STRAIN_SCALE = 100.0/21.0`), `WhoopImporter.swift`, and
  `Packages/StrandImport/Sources/StrandImport/WhoopExportImporter.swift` store 0–100.
  `Strand/Data/MetricCatalog.swift:31–65` already maps displayed 0–100 onto the WHOOP
  0–21 axis (#268) — build `StrainScale` next to (or from) this existing mapping; it is
  the only sanctioned conversion point.
- **Terminology counts** (UI code, `Strand/Screens`+`Liquid`+`StrandiOS`): "Charge…"
  ×55, "Effort…" ×36, "Rest…" ×99, "Sleep…" ×43, plus 12 hits across
  NOOPWatch/StrandiOSWidgets, plus four xcstrings catalogs × languages (EN/DE/IT).
  "Rest" needs case-by-case audit (verb vs pillar); "Sleep" collisions resolve via C3.
- **Pillar detail hosts:** new Paper details live in `Strand/Screens/CoupledView.swift`
  (T13/T14 commits, +342 lines); legacy paths still alive: `V5PillarHosts.swift`
  (untouched), `StrandiOSApp.swift:301` `"effortdetail"` → `MetricDetailView`, `:307`
  `"chargebreakdown"` → `ChargeBreakdownDemoHost`. C10 dedupes.
- **Demo data:** opt-in via `AppleDemoSeeder.requested` (checked at
  `Strand/App/AppModel.swift:344`) — launch-argument gated, no production mock leak
  found. Keep it that way; use it for QA screenshots.
- **Sleep need:** existing calculations referenced from `SleepView.swift`,
  `SmartAlarmView.swift`, `CoupledView.swift` — C3 places them; do not add new ones.

## WHOOP color findings (evidence for C13)

Source: official "WHOOP — Brand & Design Guidelines" PDF (developer.whoop.com) +
support.whoop.com recovery article. Verbatim system: Recovery banded — High
`#16EC06` 100–67%, Medium `#FFDE00` 66–34%, Low `#FF0026` 33–0%; "Recovery Blue"
`#67AEE6` for recovery-related data *without a valuation*; Strain `#0093E7` constant
("use the Strain color for Activities and other Strain related topics"); Sleep
`#7BA1BB` ("Sleep related data, for example Hours of Sleep"); Teal `#00F19F` for
positives/Sleep Need. Those hexes are tuned for WHOOP's near-black app — C13 keeps
them as the DARK values and defines luminance-adapted light values for the paper
canvas.

Token migration: `chargeAccent` → `recoveryHigh/Med/Low` + `recoveryData` (band
helper `RecoveryBands.color(for:)` lives beside `StrainScale`); `effortAccent` →
`strainAccent` blue — but FIRST decouple the Journal/Experimental badge purple into
its own `journalAccent` token (they currently share the effort purple);
`restAccent` → `sleepAccent`. Keep the old token names as deprecated aliases only if
non-iOS targets reference them. Note: NOOP computes its own scores from its own data;
adopting the familiar color grammar is a UX choice, and WHOOP-logo attribution rules
(separate section of that PDF) are already satisfied by the existing Data Sources
branding.

## Header-gap findings (Phase-3 ask)

Three coexisting header patterns cause the inconsistent top treatment:
1. `ScreenScaffold.swift:43` adds `.padding(.top, 24)` inside the scroll content (safe
   area already respected) — every scaffold screen starts ~24 pt lower than reference.
2. Today/Trends build custom in-content header stacks (wordmark row + overline row)
   with their own spacing — combined with (1) the wordmark floats ~60–70 pt below the
   island (see `qa/T09-today.png`, `T10-trends.png`).
3. Pushed/sheet screens (Live `T15`, Workouts `T16`) float a chevron circle button in
   its own row ABOVE the centered wordmark — a stack no reference shows (~130 pt spent
   before content).
Fix centrally (C4): one `PaperHeaderBar(back:trailing:)` in StrandDesign rendering
chevron-inline-left + wordmark-center + icons-right in ONE row, applied via
`ScreenScaffold` (title/subtitle rows below it); scaffold top padding 24→8. Screens
stop composing their own wordmark rows. Verify the fix on notch AND non-notch
simulators, scrolled and at rest, and that content doesn't just slide up leaving the
composition unbalanced (re-shoot each screen after).

## Inventory (screens/components pass 1 never touched)

`git diff --name-only main...reskin/paper-ui -- Strand/Screens` inverse, triaged:

- **Today subviews still legacy-styled:** `DashboardCards.swift`,
  `VitalSignsSummary.swift`, `KeyMetricsEditorSheet.swift`,
  `DashboardCardsEditorSheet.swift` (Today renders, but its edit/expanded surfaces are
  pre-Paper).
- **Reachable screens skipped:** `StorageView.swift`, `TrendsReportView.swift`,
  `FusedRecordView.swift`, `ScoringGuideView.swift` (also carries 0–100 Effort copy →
  C1/C2 content update), `UpdatesInboxView.swift`, `XiaomiBandView.swift`,
  `IntervalTimerView.swift`, `AppleWatchSetupView.swift`, `AppleWatchAboutView.swift`,
  `BiofeedbackPrefs.swift` (+`BiofeedbackController.swift` UI).
- **Card components skipped:** `CaffeineLogCard`, `JournalLogCard`, `StressCheckInCard`,
  `SkinTempCardsView`, `AutoWorkoutCard`, `DonationNudgeCard`, `HealthAlertBanner`,
  `MindSection`, `FullDayChartView`, `CoachMarkdownTheme` (coach prose styling).
- **Legacy engine still present:** `Strand/Liquid/` (LiquidCore/Sky/TodayView,
  LiveSessionView) — `LiveView.swift`, `HydrationView.swift`, `CoupledView.swift`
  still reference liquid symbols; `V5PillarHosts.swift` orphaned-or-duplicate (C10).
- **Repo hygiene:** stray committed repo-root `qa/` folder (T11–T21 screenshots) to
  consolidate into `specs/002-noop-ui-completion/qa/` (C11); `ChargeBreakdownFormat.swift`
  naming survives internally (fine per C1) but its demo host route must die (C10).

## Integration map (critical surfaces; verify + fill gaps in T50)

| Surface | Frontend entry | State layer | Service/repo | Source of truth | Refresh/persistence |
|---|---|---|---|---|---|
| Recovery (trio + detail + trends) | `TodayView` trio → `CoupledView` detail | `Repository` published snapshots | `Repository`/store handle | daily recovery metric rows (imported + computed) | repo refresh on launch/import; verify trio==detail==trends same-day value |
| Strain (trio, Workouts, run hero) | `TodayView`, `WorkoutsView`, run flow | same | same + `MetricCatalog` mapping | stored 0–100 strain (WHOOP import ×100/21) | display via StrainScale only (C2) |
| Sleep (tab hero, stages, need) | `SleepView` | same | same | sleep sessions/stages tables | C3 placement; verify night-boundary + nap handling unchanged |
| Live HR / Live console | `LiveView` | live BLE stream state | `Strand/BLE` stack | strap stream | "Waiting" states verified good; verify reconnect + zone column with strap sim (Test Centre "Simulate workout") |
| Run flow | `LiveWorkoutView`/session views | session engine | workout recorder | workout rows + HR samples | C9 pause capability check lives here |
| Health Monitor | Today grid → `HealthView` | same | repo vitals queries | vitals tables | verify each tile's metric id → detail deep link |
| Devices/Data Sources/Backup | respective views | device/import managers | `WhoopStore`/`StrandImport`/BLE registry | device registry, import ledger | exercise pair/import/backup once in sim; failure paths must surface |
| Widgets/Watch | `WidgetPublish.swift`, `NOOPWatch/*`, `WatchScoreSnapshot` | snapshot publishing | shared app-group data | same repo snapshots | C1/C2 alignment; verify after rename that publishers compile + values match phone |

Evidence rule: for each row, T50 records file:line of each hop in tasks.md notes —
"matching protocol exists" is not verification; values must be watched to flow.

## Phases

| Phase | Tasks | Delivers |
|---|---|---|
| 0 Gate + evidence | T30–T31 | Safety gate; consolidated qa/; full current-state screenshot set incl. missing S24/S26/S27-with-data shots; C9/C10 unknowns resolved and noted |
| 1 Metrics | T32–T37 | StrainScale + bands; Recovery/Strain/Sleep rename through app+xcstrings+watch+widgets; pillar details on new scales; tests |
| 2 Chrome | T38–T39 | PaperHeaderBar (C4), scaffold spacing, density constants (C5) |
| 3 Composition | T40–T46 | Today/Trends/Sleep/Workouts/run-flow/Live+Devices rebuilt to reference proportions; nit pass on Close screens |
| 4 Restoration | T47–T49 | Inventory list restyled; Liquid removed; routes deduped |
| 5 Integration | T50–T53 | Integration map verified with evidence; state coverage; widget/watch/notification alignment; integration tests |
| 6 QA + handoff | T54–T55 | Device/theme/type matrix; contact sheet; AC pass; PR |

Order rationale: metrics FIRST (renames + scale touch the same lines composition tasks
will edit — do the rename once, then reshape); chrome before composition (every screen
re-shoots against the fixed header); restoration after composition (restyled components
reuse the corrected primitives); integration after surfaces settle.

## Verification workflow

001 plan's per-task loop stands (build → seeded simulator → screenshot → side-by-side →
commit → push). Additions: screenshots land in `specs/002-noop-ui-completion/qa/`
(C11); metric tasks add a value-trace check (pick one seeded day, assert the same
number on every surface, per FR-8/AC-4); route tasks exercise deep links via
`xcrun simctl openurl booted <scheme-url>` when a URL scheme exists, else via UI
navigation.

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| "Rest"/"Charge" are common English words → over-rename breaks copy | Case-by-case audit task (T33/T35 include a grep-review step, not sed) |
| DE/IT translations go stale after rename | Machine-translate via existing `Tools/translate-*.py`; mark strings needs-review; EN is authoritative |
| Threshold/status logic keyed to 0–100 bands breaks (state words, colors, notifications) | T32 inventories every band comparison (`grep -rn "score >\|>= 6\|>= 70"` style sweep) before the flip |
| Header fix collapses per-screen compositions unevenly | C4 task re-shoots every reference screen; fidelity says "don't just slide content up" |
| CoupledView is now a 342-line multi-screen host with liquid refs | T49 may split pillar details into their own file(s) — mechanical move, no logic change |
| Session engine may not support pause (C9) | T31 resolves the unknown first; task branches on the answer |
| Widget/watch compile breaks from shared-string renames | Smoke-build all schemes in T34/T52, not just at the end |
| WHOOP neon hexes fail contrast on paper canvas | C13 ships adapted light values; AC-3 re-check per surface; graphics-only rule for accent color |
| Banded recovery contradicts the concept sheets' static green | Intentional — C13 precedence clause; note in PR so reviewers don't "fix" it back |
| Badge purple accidentally flips blue with `effortAccent` | Decouple `journalAccent` BEFORE recoloring strain (T32 order) |
| iCloud path + long builds | unchanged from 001; keep DerivedData default (outside iCloud) |

## Decision log

| # | Decision | Why |
|---|---|---|
| D7 | Continue on `reskin/paper-ui`, one PR for reskin+completion | 001 unmerged; splitting branches doubles review with no rollback benefit (tags give the boundary) |
| D8 | Display-boundary strain conversion, no storage migration | Stored values are lossless ×100/21 linear transforms of native 0–21 (see Metric findings); converting back at display is exact and reversible |
| D9 | Internal identifiers keep charge/effort/rest names | Renaming DB columns/types buys nothing user-visible and risks import/analytics regressions |
| D10 | Sleep pillar and Sleep tab converge (C3) | Rest→Sleep rename makes the old Rest detail the natural Sleep tab content; two "Sleep" surfaces would contradict C3's one-meaning rule |
| D11 | fidelity.md is a living doc — re-scored in T55 | Keeps acceptance measurable instead of vibes |
| D12 | Adopt WHOOP color logic (C13) with WHOOP hexes as dark values + adapted light values | Easton asked for WHOOP parity "everywhere"; official brand PDF gives exact values; verbatim neon fails on paper canvas, so hue-preserving light variants keep the logic identical while passing AC-3 |
| D13 | Teal CTAs rejected; teal only for sleep-need value | Paper design language (ink CTAs) is the approved look; wholesale teal would fork the reference aesthetic |

## Throughput addendum (2026-07-10, added after T33)

Pace through T33 plus Codex's own T31/T32 notes identify the time sinks. These
adjustments are authorized and supersede the per-task loop where stated:

1. **Work from a persistent local clone — never build from the iCloud path.**
   Xcode's file coordinator blocked the iCloud project path (T31 note) and every
   build has been paying a full /tmp mirror. Instead: `git clone` once to
   `~/Code/noop-completion`, check out `reskin/paper-ui`, and run ALL subsequent
   edits/builds/simulators/screenshots there, pushing each commit to
   `private-noop-report` exactly as before. The iCloud working copy is left
   untouched during execution; after T55 sync it with
   `git fetch private-noop-report && git merge --ff-only private-noop-report/reskin/paper-ui`.
   Incremental builds in the persistent clone replace the full mirror+rebuild.
2. **Batch verification for ∥ tasks.** Build must stay green per task, but the
   seeded-simulator screenshot sweep may be batched per ∥ group (one sim boot, one
   navigation pass shooting every screen in the batch), commits still one per task.
   Exception: value-correctness traces (T34 strain 0–21, T36 recovery equality) keep
   their own shots — they are evidence, not style checks.
3. **Combine same-file passes.** T34+T35 hit the same xcstrings catalogs and many of
   the same screens: execute as ONE sweep (two commits or one `reskin(T34+T35)`),
   and run DE/IT machine translation ONCE at the end of Phase 1, not per task.
4. **Subagents: mostly no.** Parallel agents on one Xcode project collide on
   xcstrings/project.yml/DerivedData/simulator and pay merge tax with no build-time
   win on one machine. Sanctioned exception: Phase 3's disjoint-file tasks
   (T41 `TrendsView` / T42 `SleepView`+`Hypnogram` / T43 `WorkoutsView`+post-run /
   T45 `LiveView`+`DevicesView`) may run as parallel worktrees IF the harness
   supports it — with the rule that NO StrandDesign package file may be edited
   inside the parallel batch (shared-primitive changes land in T38–T40 first,
   sequentially), and one merged verification sweep runs before T46. When in doubt,
   stay sequential — correctness over throughput.
