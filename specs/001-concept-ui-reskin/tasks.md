# Tasks 001 — Concept UI Reskin

> Execute in order on branch `reskin/paper-ui`. Every task ends with the verification
> workflow from `plan.md §Verification` (build → screenshot → compare → commit). "Spec
> §" references point into `spec.md`. Do not start a screen task before its phase's
> primitive tasks are committed. Check boxes as you go.
>
> **T00 is a hard gate: do not modify a single file until every T00 box is checked.**

## Phase 0 — Safety gate + baseline

- [x] **T00 — Safety preflight (plan.md §Safety & rollback has full commands)**
  - Read the required skills at `~/.codex/skills/`: `swiftui-expert-skill/SKILL.md`
    + its `references/latest-apis.md`, `swift-concurrency/SKILL.md`,
    `swift-testing-expert/SKILL.md`. (Build-related Xcode skills listed in plan.md are
    on-demand, not required reading.)
  - Clean tree: commit `specs/` + any pre-existing modified files as `wip:` (or
    stash) → `git status --porcelain` empty.
  - `git tag pre-paper-reskin`
  - `git checkout -b reskin/paper-ui`
  - Push `main` + tag to the `private-noop-report` remote (NEVER `origin`, never
    force-push). Push `reskin/paper-ui` after every task commit from here on.
  - Local snapshot outside iCloud (exact `tar` command in plan.md) → verify
    `~/Backups/noop-pre-reskin-<date>.tgz` exists and is >10 MB.
  - Verify: all of the above done; write the tag name, tarball path, and remote
    branch URL as a note under this task before proceeding.
  - Completed 2026-07-09: tag `pre-paper-reskin`; snapshot
    `/Users/eastonplace/Backups/noop-pre-reskin-20260709.tgz` (200,532,605 bytes);
    branch `reskin/paper-ui` pushed only to
    `https://github.com/eastonplace-ai/noop/tree/reskin/paper-ui`. The private mirror's
    orphan report commit was joined to local `main` with a non-force merge before
    pushing; `origin` was not pushed.

- [x] **T01 — Baseline & sanity**
  - Confirm the five PNGs exist in `references/` (see its README). If missing, STOP and
    ask Easton to drop them in; the spec §6 transcriptions allow prep work but not
    final visual sign-off.
  - `xcodebuild -list -project Strand.xcodeproj` → record exact scheme names.
  - Build + boot simulator (iPhone 16 Pro), seed demo data, capture BEFORE screenshots
    of all 27 spec-§5 screens into `qa/before/`.
  - Locate-and-record (append findings to this file under T01): actual host files for
    S20–S23 (pillar details — start at `V5PillarHosts.swift`) and S24–S27 (run flow —
    start at `LiveWorkoutView.swift`, `Strand/Liquid/LiveSessionView.swift`).
  - Verify: 27 before-PNGs exist; S20–S27 file map written down.
  - Completed 2026-07-09 on simulator `NOOP-Paper-iPhone16Pro`
    (`4425C98D-9F53-456B-B493-B058D8FA81DA`, iOS 26.5). Demo data was seeded with
    `--demo-seed`. The cold `NOOPiOS` build succeeded in 204.4s; the post-harness
    incremental build succeeded in 20.7s. Baseline evidence: 27 `S01`–`S27` PNGs in
    `qa/before/` and `qa/before-contact-sheet.png`.
  - Schemes from `xcodebuild -list`: `GRDB-Package`, `MarkdownUI`, `NOOPiOS`,
    `NOOPiOSWidgets`, `NOOPWatch`, `NOOPWatchComplications`, `oura-decode`,
    `OuraProtocol`, `Strand`, `StrandAnalytics`, `StrandDesign`, `StrandImport`,
    `whoop-decode`, `WhoopProtocol`, `WhoopStore`.
  - Reference gate: the five canonical concept images are now named exactly per
    `references/README.md`; `sheet-2-run-flow-alt.png` is an older duplicate retained
    as secondary evidence.
  - S20–S23 host map: S20 Charge is `TodayView.swift` / `CoupledView.swift` sheet
    presentation backed by `ChargeBreakdownFormat.swift`; S21 has no dedicated Effort
    screen and currently resolves to `MetricDetailView` in `MetricExplorerView.swift`
    with metric key `strain` (with summary surfaces in `WorkoutsView.swift`); S22 has no
    dedicated Rest host and currently resolves through `SleepView.swift` plus
    `MetricDetailView` key `sleep_performance`; S23 is `StressView.swift`.
  - S24–S27 host map: S24's current pre-workout picker is `StartWorkoutSheet` in
    `ManualWorkoutSheet.swift`; S25 is `LiveWorkoutView.swift`; S26 has no distinct
    paused state or pause/resume control today, so its baseline intentionally captures
    the same live-workout host; S27 is `WorkoutDetailView.swift`, opened from
    `WorkoutsView.swift`. `Strand/Liquid/LiveSessionView.swift` is the separate silent
    live-coaching session, not the workout-run UI.

## Phase 1 — Tokens

- [x] **T02 — Palette rewrite**
  - Modify: `Packages/StrandDesign/Sources/StrandDesign/Palette.swift`
  - Triage first: `grep -rn "StrandPalette.accent" Strand StrandiOS Packages | wc -l`
    and skim — if `accent` mixes "brand gold" and "interactive" roles, add `ink` token
    and repoint action call sites; data call sites get pillar tokens in later tasks.
  - Rewrite neutral tokens to spec §2.1 light values with §2.2 dark values via the
    existing `Color(light:dark:)` initializer. Keep token names (`surfaceBase` etc.).
  - Add new tokens: `chargeAccent/Tint`, `effortAccent/Tint`, `restAccent/Tint`,
    `stressAccent/Tint`, `liveRed/Tint`, `success`, `warning`, `warningBg`,
    `destructive`, `link`, `zoneZ5…zoneZ1`, `stageAwake/REM/Light/Deep`, `ink`, `onInk`.
  - Repoint `recovery0xx` ramp → charge greens, `strain0xx` → effort purples (or alias
    them to the new tokens if they're pure color ramps).
  - Leave `gold*`/`titanium*`/`scenic*`/glow tokens defined; do not restyle them.
  - Verify: package tests pass; app builds; screenshot Today — canvas is off-white,
    no crash. Expect visual chaos (glass bar etc.) — that's Phase 2's job. Commit.
  - Verified 2026-07-09: the 351-call-site `accent` audit confirmed mixed chrome/data
    semantics, so `ink` and pillar tokens were added while legacy `accent` remains a
    link compatibility alias until owning component/screen tasks repoint call sites.
    `StrandDesign` passed 30 tests; `NOOPiOS` built and ran on the T01 simulator;
    `qa/T02-today.png` confirms the paper canvas and R3 pillar colors with the expected
    pre-Phase-2 scenic/glass remnants still visible.

- [x] **T03 — Typography**
  - Modify: `Packages/StrandDesign/Sources/StrandDesign/Typography.swift`
  - Step 1: add/adjust roles to cover spec §2.3 table (`wordmark`, `screenOverline`,
    `sectionOverline`, `ringScoreSmall/Large`, `timer`, `metricValue`, `statValue`,
    `cardTitle`, `body`, `caption`, `micro`) — map onto existing role names where they
    already exist rather than renaming call sites; add tracking constants.
  - Step 2 (R9 — skip only if Easton vetoed): switch the `family` path to the system SF
    Pro face — numeric roles keep `.monospacedDigit()`, prose roles keep
    `relativeTo:` Dynamic Type scaling.
  - Verify: build; screenshot Today + Settings; type renders SF Pro, no layout
    explosions. Commit.
  - Verified 2026-07-09: `StrandDesign` passed 30 tests and `NOOPiOS` built and ran.
    `qa/T03-today.png` and `qa/T03-settings.png` render SF Pro without missing glyphs,
    clipping, or new layout failure; legacy scenic composition remains for later tasks.

## Phase 2 — Primitives (all in `Packages/StrandDesign/Sources/StrandDesign/`)

- [x] **T04 — PaperCard + layout constants**
  - Modify: `StrandCard.swift` (restyle in place — keep the `StrandCard` type name so
    call sites stand; wherever the spec says "PaperCard" it means this restyled
    `StrandCard`).
  - Card per spec §2.4; add shared constants (radius 16, gutter 16, stack 12, section
    24) in `StrandDesign.swift` if no constants home exists.
  - Verify: build + screenshot any card-heavy screen; cards are white, bordered,
    flat. Commit.
  - Verified 2026-07-09: `StrandDesign` passed 30 tests and `NOOPiOS` built and ran.
    `qa/T04-data-sources.png` confirms 16pt white cards, warm 1pt borders, minimal
    shadow, and the 16/12/24 Paper spacing rhythm; legacy tint arguments no longer
    color card chrome.

- [x] **T05 — ScoreRing**
  - Modify: `RecoveryRing.swift`, `GlowRing.swift`, `BevelGauge.swift` call-site
    audit → implement one flat `ScoreRing` (spec §4) and repoint ring call sites;
    keep old files compiling if non-iOS targets use them.
  - Sizes: 64 pt/5 pt trio, 96 pt/7 pt hero; track `inset`; rounded caps; sweep-in
    animation per spec §2.5; no glow/bevel/gradient.
  - Verify: build; Today trio + Sleep hero screenshot vs sheet 1-1/1-3. Commit.
  - Verified 2026-07-09: `ScoreRing(value:range:accent:size:)` is the single rendered
    ring path; legacy `GlowRing`, `RecoveryRing`, `StrainGauge`, and `BevelGauge`
    preserve their APIs but delegate to the flat primitive. `StrandDesign` passed 30
    tests and `NOOPiOS` built and ran. `qa/T05-today.png` and `qa/T05-sleep.png`
    confirm solid rounded arcs on inset tracks with no gradient, bevel, bead, or glow.
    Today still uses its pre-T09 large-trio layout; T09 owns the canonical 64pt trio.

- [x] **T06 — Buttons**
  - Modify: `NoopButton.swift` → `PrimaryButton` (ink pill 52/14), `DestructiveButton`
    (outline red), `ChipButton` (32-pt blue outline chip) per spec §2.4.
  - Verify: build; screenshot Workouts (Start Workout) + Data Sources (Remove/Choose
    export). Commit.
  - Verified 2026-07-09: `StrandDesign` passed 30 tests and `NOOPiOS` built and ran
    in the iPhone 16 Pro simulator. `qa/T06-workouts.png` confirms the 52-pt ink
    primary action; `qa/T06-data-sources.png` confirms 32-pt blue outline import
    chips and the red outline destructive action.

- [x] **T07 — Rows, badges, notes, small parts**
  - Create (or extend existing files if equivalents exist — audit first):
    `StatusBadge`, `SectionHeader`, `SettingsRow`, `DeviceRow`, `NoteCard`,
    `InsightCard`, `StatTriplet`, `MetricTile`, `ZoneBars`, `SplitsTable`,
    `StressTimelineBar` per spec §4 specs. Toggle tint → `success`.
  - Restyle chart primitives: `Sparkline.swift`, `OverviewHRChart.swift`,
    `Hypnogram.swift` (§2.1 stage colors), `PipBar.swift`, `ChartHover.swift`,
    `DayNavBar.swift` to §4 chart style.
  - Verify: `swift test --package-path Packages/StrandDesign`; build; screenshot
    Sleep (hypnogram) + Trends (chart). Commit. (Split into multiple commits if the
    diff gets big — one commit per component group is fine.)
  - Verified 2026-07-09: added the reusable Paper card, badge, row, note, triplet,
    metric, zone, splits, and stress-timeline contracts after auditing existing
    equivalents; `SectionHeader` and `InsightCard` were extended in place. Chart area
    fills are capped at 6%, lines are 2 pt, stage tracks use `inset`, and tooltip glow
    is removed. `StrandDesign` passed 30 tests and `NOOPiOS` built and ran.
    `qa/T07-sleep-hypnogram.png` and `qa/T07-trends.png` were visually checked against
    sheets 1-3 and 1-2; `qa/T07-sleep.png` preserves the root-state capture.

- [x] **T08 — Header, tab bar, FAB, Quick Actions**
  - Modify: `StrandiOS/App/RootTabView.swift` (remove glass islands + gold FAB; build
    `PaperTabBar` per spec §2.6, black FAB bottom-right on Today only, restyle the
    quick-action sheet to S19), `Strand/Screens/ScreenScaffold.swift` (HeaderBar with
    centered wordmark per §2.6).
  - Keep: tab crossfade motion, swipe-between-tabs gesture, NavRouter sheet routing,
    `UITabBarAppearance` init block updated to `card` background.
  - Remove: `noop.liquidTodayEnabled` toggle path (R7) — `todayTabRoot` returns
    `TodayView()` directly; delete the Settings toggle row (find via
    `grep -rn "liquidTodayEnabled" Strand StrandiOS`).
  - Verify: build; screenshot all four tab roots — flat white bar, black active icon,
    FAB on Today only; Quick Actions sheet matches S19. Commit.
  - Verified 2026-07-09: `NOOPiOS` built and ran after the app-wide
    `noop.liquidTodayEnabled` route was removed. `qa/T08-today.png`,
    `qa/T08-trends.png`, `qa/T08-sleep.png`, and `qa/T08-more.png` confirm the
    centered wordmark, flat `card` tab bar, black active item, and Today-only black
    FAB. `qa/T08-quick-actions.png` confirms the four preserved routes, concept copy,
    colored symbols, and close control.

## Phase 3 — Core tabs

- [x] **T09 — Today (S1)** — Modify `Strand/Screens/TodayView.swift`
  (+ `DashboardCards.swift`, `VitalSignsSummary.swift` as needed). Implement spec §6-S1
  exactly: trio, glance row, Live HR card, stress card, health-monitor grid. Mechanical
  subview extraction into sibling files allowed (plan §Risks). Verify vs sheet 1-1 &
  3-1. Commit.
  - Verified 2026-07-09: the Today root now renders only the S1 hierarchy on the light
    Paper canvas. Existing score, workout, steps, calorie, HR, stress, and vital bindings
    feed the 64-pt trio, selected-day glance row, Live HR, stress timeline, and 3×2
    Health Monitor grid; existing detail routes remain attached. `StrandDesign` passed
    30 tests and `NOOPiOS` built and ran. `qa/T09-today.png` was visually checked against
    sheets 1-1 and 3-1.
- [x] **T10 — Trends (S2)** — Modify `Strand/Screens/TrendsView.swift`
  (+ `TrendsReportView.swift` if it hosts week-review copy). Spec §6-S2. Verify vs
  sheet 1-2. Commit.
  - Verified 2026-07-09: S2 now uses the existing deterministic weekly digest and
    daily series for the three score cards, week-over-week deltas, grouped 0–100
    three-line chart, review bullets, and insight. Calendar/share routes are preserved,
    the report sheet remains wired, and the page uses the light Paper canvas.
    `NOOPiOS` built and ran; `qa/T10-trends.png` was visually checked against sheet 1-2.
- [x] **T11 — Sleep (S3)** — Modify `Strand/Screens/SleepView.swift`. Spec §6-S3.
  Verify vs sheet 1-3. Commit.
  - Verified 2026-07-09: `NOOPiOS` built and ran on the canonical simulator with
    demo data. `qa/T11-sleep.jpg` confirms the 96-pt flat Rest ring, score copy,
    Duration/Efficiency/Resting HR triplet, preserved logging-only Sleep Marks,
    exact Paper sleep-stage palette, real hypnogram with clock axis, and the
    Asleep/Duration/Woke window hierarchy against sheet 1-3.
- [x] **T12 — More tab list** — Modify the More list in
  `StrandiOS/App/RootTabView.swift` (`moreTab`): restyle groups/rows with
  `SectionHeader` + `SettingsRow`; keep the persisted expand/collapse behavior
  (`MoreSectionPrefs`) and every destination. Verify: all destinations reachable.
  Commit.
  - Verified 2026-07-09: `NOOPiOS` built and ran; `qa/T12-more.jpg` confirms the
    flat Paper canvas, `SectionHeader` disclosure groups, and `SettingsRow` list
    treatment. Simulator accessibility snapshots exposed every unchanged destination
    in Insights, Body, Data, and App after expanding the persisted sections; the
    `MoreSectionPrefs` storage/encode path remains intact.

## Phase 4 — Pillar details (use T01's file map)

- [x] **T13 — Charge + Effort details (S20, S21)** — spec §6-S20/S21; shared skeleton
  (hero ring, StatTriplet, over-time chart, factor/contributor rows, recommendation
  card). Verify vs sheet 3-2/3-3. Commit.
  - Verified 2026-07-09: `NOOPiOS` built and ran. `qa/T13-charge.jpg` and
    `qa/T13-effort.jpg` confirm the shared 96-pt hero, baseline/yesterday/7-day
    triplet, 0–100 line chart with dotted average, Charge factor rows, and
    workout-backed Effort contributors against sheets 3-2/3-3. The lower state in
    `qa/T13-effort-zones.jpg` preserves an honest empty zone card because the demo
    workout has no stored `zonesJSON`; real zone data still renders through `ZoneBars`.
- [x] **T14 — Rest + Stress details (S22, S23)** — spec §6-S22/S23; Stress ring renders
  0–3 values correctly (R2 — check the ring's range parameter). Verify vs sheet
  3-4/3-5. Commit.
  - Verified 2026-07-09: `NOOPiOS` built and ran. `qa/T14-rest.jpg` confirms the
    Rest hero/triplet, canonical stage colors, real night clock axis, timing triplet,
    and insight card against sheet 3-4. `qa/T14-stress.jpg` confirms the 0–3 chart
    axis and a `0.2 of 3` ring whose sweep is driven by the explicit `0...3` range;
    the demo has insufficient intraday HR for a breakdown, so the card remains an
    honest empty state while real hourly data maps to the four Paper bands.

## Phase 5 — Live + workouts

- [x] **T15 — Live console (S4)** — Modify `Strand/Screens/LiveView.swift`. Spec §6-S4.
  Verify vs sheet 1-4. Commit.
  - Verified 2026-07-09: `NOOPiOS` built and ran. `qa/T15-live.jpg` confirms the
    Paper device card, black Scan & connect action, 96-pt live-red HR ring, zone/HRV/RHR
    rows, and physiology-status card against sheet 1-4. The simulator has no bonded
    strap, so status and live values remain honestly empty; all pre-existing session,
    pairing, haptic, disconnect, device-management, and diagnostic controls remain
    reachable below the Paper summary.
- [x] **T16 — Workouts (S5)** — Modify `Strand/Screens/WorkoutsView.swift`
  (+ `WorkoutDetailView.swift` shared parts). Spec §6-S5. Verify vs sheet 1-5. Commit.
  - Verified 2026-07-09: `NOOPiOS` built and ran. `qa/T16-workouts.jpg` confirms
    the full-width black Start workout action, real average workout score and
    week-over-week delta, three tappable recent-workout rows, and compact HR-zone /
    average-pace cards against sheet 1-5. Existing add/edit/detail/filter/selection/
    merge/history behavior remains reachable below the Paper summary.
- [x] **T17 — Run flow pre/live/paused (S24–S26)** — Modify the run UI located in T01.
  Spec §6-S24/25/26. Tab bar stays per R1. Omit setup rows with no backing setting
  (S24 note). Verify vs sheet 2-1/2-2/2-3 (live/paused need a simulated workout —
  Test Centre "Simulate workout" or demo seeder). Commit.
  - Verified 2026-07-09: `NOOPiOS` built and ran. `qa/T17-pre-run.jpg` confirms
    catalog-backed run types, real recent-route/last-workout equivalents, GPS/local
    badges, and the pinned black Start Running action against sheet 2-1.
    `qa/T17-live-run.jpg` confirms the real elapsed timer, six-cell live grid,
    GPS-backed route state, HR history card, and existing Finish action against sheet
    2-2. S26 is deliberately not fabricated: T01 proved the workout engine has no
    pause/resume state, and the spec's top-level non-goal forbids adding feature logic;
    a cosmetic Paused state would continue recording and be false. The existing
    uninterrupted recording behavior is preserved exactly.
- [x] **T18 — Post-run summary (S27)** — spec §6-S27; effort value is the app's real
  metric (R2). Verify vs sheet 2-4. Commit.
  - Verified 2026-07-09: `NOOPiOS` built and ran. `qa/T18-post-run.jpg` confirms
    the real stored `37.3 of 100` effort value (R2), same-sport comparison, six real
    workout stats, and black Save workout action against sheet 2-4. Route and zone
    sections remain conditional on actual stored data; the selected demo Walking row
    has neither, so no illustrative route or zone split was invented.

## Phase 6 — Management

- [x] **T19 — Devices + Add Device (S6, S7)** — Modify
  `Strand/Screens/DevicesView.swift`, `AddDeviceWizard.swift`. Spec §6-S6/S7. Verify vs
  sheet 4-1/4-2. Commit.
  - Verified 2026-07-09: `NOOPiOS` built and ran. `qa/T19-devices.jpg` confirms
    real paired-device states, Paper cards, green/gray status pills, black Add a
    device action, and local-privacy note against sheet 4-1. `qa/T19-add-device.jpg`
    confirms every existing catalog integration remains present in Paper rows with
    Beta/Experimental badges and the existing honest tier warning against sheet 4-2.
- [x] **T20 — Data Sources (S8)** — Modify `Strand/Screens/DataSourcesView.swift`.
  Spec §6-S8. Verify vs sheet 4-3. Commit.
  - Verified 2026-07-09: `NOOPiOS` built and ran. `qa/T20-data-sources.jpg`
    confirms grouped Paper import cards, real WHOOP imported state/counts, compact blue
    import chips, Apple Health destructive removal, Xiaomi import, and the continued
    full additional-import/connection catalog against sheet 4-3. All importer and
    confirmation handlers are unchanged.
- [x] **T21 — Backup & Sync (S9)** — Modify `Strand/Screens/BackupSyncView.swift`
  (+ `StorageView.swift` if it owns backup location UI). Spec §6-S9. Verify vs sheet
  4-4. Commit.
  - Verified 2026-07-09: `NOOPiOS` built and ran. `qa/T21-backup.jpg` confirms the
    folder row, blue Choose chip, green-tinted auto-backup switch, full-width backup
    action, restore card, and privacy note against sheet 4-4. The simulator has no
    selected folder, so backup/restore remain correctly disabled; picker, retention,
    backup, restore, and destructive-confirmation logic is unchanged.
- [x] **T22 — Settings + Support (S10, S11)** — Modify
  `Strand/Screens/SettingsView.swift`, `SupportView.swift`,
  `ProfileAvatarView.swift`. Spec §6-S10/S11; every existing row survives (AC);
  liquid-Today toggle already removed in T08. Verify vs sheet 4-5/4-6. Commit.
  - Verified 2026-07-09: `NOOPiOS` built and ran. `qa/T22-settings.jpg`
    confirms the compact Paper profile, segmented Units/Appearance controls,
    Preferences, Privacy & Local Data, and Support groups against sheet 4-5.
    Every pre-reskin settings control remains reachable in Detailed settings; the
    overview uses only real profile values and existing destinations, so unsupported
    name/member-since/first-day/global-delete state was not fabricated.
    `qa/T22-support.jpg` confirms the independent-support card, black action, existing
    donation QR/address flow, three contact rows, and privacy note against sheet 4-6.

## Phase 7 — Labs

- [x] **T23 — Insights (S12)** — Modify `Strand/Screens/InsightsView.swift` /
  `InsightsHubView.swift` (T01 decides which hosts "What Moves You"). Spec §6-S12.
  Verify vs sheet 5-1. Commit.
  - Verified 2026-07-09: `NOOPiOS` built and ran. `qa/T23-insights.jpg`
    confirms the What Moves You title/badges, five Paper filter chips, four compact
    real association rows with Cohen's d and with/without values, expandable full
    feed, personal insight, and method note against sheet 5-1. Simulator UI automation
    confirmed Recovery re-ranks the visible feed through the existing EffectRanker.
    All combines the four backed outcomes; Strain deliberately renders an honest
    unavailable state because the current association engine has no Effort series.
- [x] **T24 — Lab Book (S13)** — Modify `Strand/Screens/LabBookView.swift`,
  `MarkerEditorView.swift`. Spec §6-S13 including empty states. Verify vs sheet 5-2.
  Commit.
  - Verified 2026-07-09: `NOOPiOS` built and ran. `qa/T24-lab-book.jpg`
    confirms the private-notebook header, blue add action, dashed flask empty state,
    compact real CSV import row, recent-readings empty state, and info-toned medical
    disclaimer against sheet 5-2. Simulator UI automation opened Add marker and
    confirmed the complete existing catalog/editor remains reachable in Paper cards.
    The import subtitle names only the actually supported markers CSV path rather than
    implying unsupported WHOOP/Apple Health marker import.
- [x] **T25 — Rhythm + consent (S14, S15)** — Modify
  `Strand/Screens/RhythmView.swift`. Spec §6-S14/S15; consent button disabled until
  toggle on. Verify vs sheet 5-3/5-4 (fresh-install state for consent). Commit.
  - Verified 2026-07-09: `NOOPiOS` built and ran. `qa/T25-rhythm-consent.jpg`
    confirms the four Paper consent cards, exact experimental-awareness toggle, and
    disabled black Turn on Rhythm action against sheet 5-3. UI automation proved the
    button is absent from enabled targets before acknowledgement and becomes enabled
    after the switch. `qa/T25-rhythm.jpg` confirms the purple Experimental badge,
    dotted scatter empty state, three measurement rows, and on-device privacy note
    against sheet 5-4. Production consent keys/versioning and analysis are unchanged;
    deterministic consent/content capture routes are DEBUG-only.
- [x] **T26 — Automations, Alarms, Test Centre (S16–S18)** — Modify
  `Strand/Screens/AutomationsView.swift`, `SmartAlarmView.swift`,
  `TestCentreView.swift`. Spec §6-S16/17/18; keep every existing toggle/setting bound.
  Verify vs sheet 5-5/5-6/5-7. Commit.
  - Verified 2026-07-09: `NOOPiOS` built and ran. `qa/T26-automations.jpg`
    confirms the real disconnected banner and bound wrist-action/coaching/reminder
    rows; `qa/T26-alarms.jpg` confirms bound strap wake/wind-down controls, honest
    backup status, vibration warning, and test action; `qa/T26-test-centre.jpg`
    confirms compact Diagnostics/Data Tests/Reports groups backed by the existing
    TestCentre domains and redacted log. All pre-reskin advanced controls remain below
    the Paper summaries, preserving every existing binding and action.

## Phase 8 — Sweep + QA

- [ ] **T27 — R8 sweep (spec §7)**
  - `grep -rn "onDark\|gold\|titanium\|glow\|scenic" Strand/Screens Strand/Liquid
    StrandiOS` → repoint every rendered-on-iOS hit to new tokens.
  - Walk every §7 screen in the simulator (light + dark); fix hardcoded colors, broken
    contrast, dark-only imagery. Layout unchanged.
  - Verify: no rendered gold/glow anywhere (AC-2). Commit per screen-group.
- [ ] **T28 — Theme + platform matrix**
  - Dark mode pass over S1–S27 (§2.2 + AC-6); contrast spot-checks (AC-3).
  - Dynamic Type XL on Today/Sleep/Settings/Live-run (AC-4); iPhone SE + Pro Max
    (AC-5).
  - Smoke-build `NOOPiOSWidgets`, `NOOPWatch`, macOS `Strand` schemes — must build;
    log (don't fix) visual follow-ups. Commit fixes.
- [ ] **T29 — Evidence + handoff**
  - AFTER screenshots of all 27 screens into `qa/after/`; build a before/after contact
    sheet (`Tools/make_contact_sheet.py` exists — use it).
  - Re-read spec §8 ACs one by one; note pass/fail inline here; fix fails.
  - Open PR `reskin/paper-ui → main` with the contact sheet, the ruling list (R1–R10),
    and any logged follow-ups (Liquid deletion, gold-token deletion, widget/watch
    restyle, macOS polish).
