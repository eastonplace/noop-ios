# Spec 001 — Concept UI Reskin ("Paper" theme)

> **For agentic workers:** This is the WHAT. Read `plan.md` for the HOW and `tasks.md` for
> the ordered task list. Reference images live in `references/` (see its README for the
> manifest). Where an image conflicts with §3 Canonical Rulings, the ruling wins.

**Goal:** Restyle the NOOP iOS app to match the 2026-07 concept sheets — a light,
editorial, off-white "paper" aesthetic with white cards, thin hairlines, flat score rings
in per-pillar colors, black pill buttons, and a letter-spaced NOOP wordmark — replacing
the current dark "Titanium & Gold" look. Near pixel-for-pixel against the concepts,
corrected per the rulings below.

**Non-goals:** No data-model, scoring, BLE, import, or feature-logic changes. No new
features. No Android/watchOS redesign (watch keeps its dark theme). This is a visual
reskin of existing, working screens.

---

## 1. Scope

### In scope
- `Packages/StrandDesign` — all tokens and shared primitives (Palette, Typography,
  StrandCard, NoopButton, GlowRing/RecoveryRing/BevelGauge, Hypnogram, Sparkline, PipBar,
  DayNavBar, OverviewHRChart, ChartHover, SportIcon and any other visual primitive).
- `StrandiOS/App/RootTabView.swift` — tab bar, FAB, quick-action shell.
- `Strand/Screens/*.swift` — every screen, as rendered on iOS. Screens with a concept
  reference get pixel treatment (§6); screens without one inherit the design system (§7).
- `Strand/Liquid/*` — the V8 liquid Today is superseded (Ruling R7).

### Out of scope
- `NOOPWatch`, `NOOPWatchComplications`, `android/`, `StrandiOSWidgets` (widgets get a
  follow-up spec; don't let them break, don't restyle them).
- macOS: shared tokens/views mean macOS inherits the new look automatically. That's
  accepted. Do not do macOS-specific polish in this spec.
- Onboarding flow (`Strand/Onboarding`) — inherit tokens only, no layout work.

---

## 2. Design language

The concept aesthetic in one paragraph: a warm off-white canvas carrying pure-white
cards with 1 pt warm-gray borders and near-invisible shadows; near-black ink text with
warm-gray secondary text; one accent color per health pillar used *only* for data
(rings, chart lines, deltas, status) — never for chrome; black is the only action color
(buttons, FAB, active tab); generous whitespace; ALL-CAPS letter-spaced overlines label
every section; everything square-ish with 14–16 pt radii; zero glassmorphism, zero
gradients, zero glow.

### 2.1 Color tokens (light — the pixel target)

Neutrals:

| Token | Value | Role |
|---|---|---|
| `canvas` | `#F7F6F3` | Screen background |
| `card` | `#FFFFFF` | Card / sheet / tab-bar background |
| `cardBorder` | `#ECEAE5` | 1 pt card outline |
| `hairline` | `#F0EEEA` | Dividers inside cards |
| `inset` | `#F4F3F0` | Inset wells: segmented-control tracks, chart plot areas, ring tracks, empty-state tiles |
| `textPrimary` | `#141414` | Ink |
| `textSecondary` | `#6F6F6C` | Subtitles, captions, overlines |
| `textTertiary` | `#A3A29E` | Timestamps, footnotes, disabled |
| `ink` | `#0E0E0E` | Primary buttons, FAB, active tab icon, big numerals may use `textPrimary` |
| `onInk` | `#FFFFFF` | Text/icons on `ink` |

Pillar accents (each with a 10%-tint background token for chips/badges):

| Token | Value | Tint | Used for |
|---|---|---|---|
| `chargeAccent` | `#2FA45C` | `#E7F4EC` | Charge ring/line/deltas; also generic "success/connected/good" |
| `effortAccent` | `#7A5AF8` | `#F0EBFE` | Effort ring/line/deltas; Journal + Experimental badges |
| `restAccent` | `#5B6CF9` | `#EAEDFE` | Rest ring/line/deltas |
| `stressAccent` | `#E0A63A` | `#FBF3DF` | Stress ring/line/badge/timeline |
| `liveRed` | `#E5484D` | `#FDEBEC` | Live HR ring, live workout HR, Awake stage |

Semantic:

| Token | Value | Used for |
|---|---|---|
| `success` | `#2FA45C` | Green status dots, checkmarks, "Connected/Imported/Up to date" |
| `warning` | `#E07B39` on `#FBF1E6` | Warning note cards (alarms-are-local, beta notices) |
| `destructive` | `#D93025` | Finish button, Delete/Remove rows, Paused badge |
| `link` | `#3B82F6` | Text links ("View all workouts", "View Details"), Add reading button |

Data-viz fixed ramps (never re-derive from pillar tokens):

- HR zones: Z5 `#E5484D` · Z4 `#F59E0B` · Z3 `#2FA45C` · Z2 `#5B9BF6` · Z1 `#C7C6C2`
- Sleep stages: Awake `#E5484D` · REM `#A8CBF7` · Light `#5B9BF6` · Deep `#1E3A8A`
- Stress timeline segments: reuse `stressAccent` ramp — Restful `#2FA45C`, Low `#CDE7D6`,
  Medium `#E0A63A`, High `#E5484D`

### 2.2 Dark theme (derived, not in the concepts)

Every token above is defined via the existing `Color(light:dark:)` provider. Dark values
follow the same language on a near-black warm canvas: `canvas #131311`, `card #1C1C1A`,
`cardBorder #2A2A27`, `hairline #262624`, `inset #232321`, `textPrimary #F2F1EE`,
`textSecondary #A5A4A0`, `textTertiary #6E6D69`, `ink #F2F1EE` (buttons invert: light
buttons, dark label `#141414`), accents lightened one step (e.g. charge `#43C173`, effort
`#9B82FF`, rest `#7D8BFF`, stress `#EBBE5C`, red `#F26B6F`). Dark must be *checked*, not
pixel-matched — the light theme is the deliverable; dark just has to look intentional and
pass contrast.

### 2.3 Typography

Family: **SF Pro (system)** — replaces Helvetica Neue via the single `family` constant in
`Packages/StrandDesign/Sources/StrandDesign/Typography.swift` (Ruling R9). All numeric
roles keep `.monospacedDigit()`. Roles and sizes (weight / tracking):

| Role | Spec | Where |
|---|---|---|
| `wordmark` | 13 pt semibold, tracking +4 pt, ALL-CAPS | "N O O P" centered in every header |
| `screenOverline` | 12 pt semibold, tracking +1.5, ALL-CAPS, `textSecondary` | Screen titles like "LIVE BODY CONSOLE", "WORKOUTS" |
| `sectionOverline` | 11 pt semibold, tracking +1.2, ALL-CAPS, `textSecondary` | Card/section labels: "SLEEP STAGES", "KEY FACTORS", "PAIRED DEVICES" |
| `ringScoreSmall` | 30 pt bold, tabular | Numbers inside the Today trio rings |
| `ringScoreLarge` | 44 pt bold, tabular | Detail-screen hero rings (Charge 41, Rest 92…) |
| `timer` | 64 pt bold, tabular, tracking −1 | Live-run elapsed time |
| `metricValue` | 24 pt bold, tabular | Stat-grid values (4.21, 8:02, 152) |
| `statValue` | 20 pt semibold, tabular | Baseline/Yesterday/7D-Avg triplets |
| `cardTitle` | 16 pt semibold | Card headlines ("Good Rest", "NOOP Strap") |
| `body` | 15 pt regular | Prose, row titles |
| `caption` | 13 pt regular, `textSecondary` | Subtitles, explanations |
| `micro` | 11 pt regular, `textTertiary` | Timestamps, axis labels, footnotes |

Dynamic Type: prose/label roles scale (`relativeTo:` as today); fixed-geometry numerals
(rings, timer) stay fixed — same policy the codebase already documents in
`Typography.swift`.

### 2.4 Shape, spacing, elevation

- Card: radius **16**, padding **16**, `card` fill, 1 pt `cardBorder` stroke, shadow
  `black 4%, y 1, blur 3` (near-invisible — borders do the separation work).
- Screen gutters: 16 pt horizontal; 12 pt between stacked cards; 24 pt between sections.
- Primary button: height **52**, radius **14**, `ink` fill, `onInk` 16 pt semibold label,
  optional leading SF Symbol. Full-width inside gutters.
- Destructive button: same geometry, `card` fill, 1 pt `destructive` border, `destructive`
  label (see Finish / Remove imported data).
- Secondary "outline chip" button (e.g. "Choose export"): height 32, radius 16, 1 pt
  `link` border, `link` 13 pt medium label.
- FAB: **56** pt circle, `ink` fill, white SF Symbol `plus` 22 pt, bottom-right, 16 pt
  above the tab bar. Opens the Quick Actions sheet.
- Rings: flat stroke, rounded caps, track = `inset`. Trio rings: 64 pt Ø, 5 pt stroke.
  Hero rings: 96 pt Ø, 7 pt stroke. Live-HR ring: 96 pt Ø, 7 pt stroke, `liveRed`.
  No glow, no bevel, no gradient — retire the `GlowRing`/`BevelGauge` look.
- Status badge: capsule, tint background, 11 pt semibold colored label, optional 6 pt dot
  (e.g. ● Connected green, ● Live green, ● Paused red, Beta gray, Experimental purple).
- Toggles: system `Toggle`, tint `success`.
- List row: 52–56 pt min height, leading 36 pt icon circle (`inset` fill, `textPrimary`
  SF Symbol 16 pt) or 40 pt device thumbnail (radius 10), title `body`, subtitle
  `caption`, trailing value `caption` + chevron `textTertiary`. Hairline separators inset
  to text edge.
- Note cards (recurring pattern): lock/info/warning icon + caption text on a tinted
  background — privacy notes use `inset` bg + `textSecondary`; warnings use `warning`
  colors; radius 12.

### 2.5 Motion

Keep the existing calm-easing system (`Motion.swift`, cubic-bezier(0.22,1,0.36,1),
~240 ms tab crossfade). Rings animate sweep-in on appear (~600 ms, same easing). No new
motion work beyond re-verifying nothing references removed glow/liquid effects.

### 2.6 App chrome (every screen)

- **Header**: centered `wordmark` "N O O P". Left slot: context — root tabs show a small
  dropdown ("TODAY ▾") or nothing; pushed screens show back chevron. Right slot: screen
  icons (sync + green status dot on Today; calendar/share/⋯ per screen). Below the
  wordmark row, screens with a date context show `screenOverline` title left + date
  ("Wed, May 14 ▾") — see each screen spec.
- **Tab bar**: flat `card` background, top `hairline`, system safe-area height. 4 items:
  Today (`square.grid.2x2`), Trends (`chart.bar`), Sleep (`moon`), More (`ellipsis`).
  Active = `ink` icon + 11 pt label; inactive = `textTertiary`. **This replaces the
  current floating glass islands + gold FAB bar.** The black FAB floats bottom-right
  (Today tab only, as in sheet 1/3).

---

## 3. Canonical rulings (concept errors → decisions)

The concepts are AI renders with internal contradictions. These rulings are final; cite
them in code comments where a deliberate deviation from an image occurs.

- **R1 — Tab bar.** Tabs are **Today · Trends · Sleep · More** (matches sheets 1/3/4/5
  and the existing app). Sheet 2's "Home / Workouts / Coaching / More" bar is a concept
  error — there is no Coaching tab. Workouts stays reachable via More + Today quick
  actions, unchanged.
- **R2 — Scales.** Daily pillar scores are 0–100 (Charge/Effort/Rest); Stress is 0–3.
  Sheet 2's per-run "Effort 7.3" / "Run Effort 11.4" are on the retired 0–21 strain
  scale — a concept error. Per-workout effort displays whatever
  `MetricCatalog`/existing workout scoring already produces, restyled visually only.
  **No scale, score, or data semantic changes anywhere in this spec.**
- **R3 — Pillar colors.** Charge = green, Effort = **purple**, Rest = **blue**,
  Stress = amber, everywhere. Sheet 1 renders Effort in blue and Rest in green in a few
  places — error; sheet 3 (detail screens) is canonical.
- **R4 — Sample data.** Every value, date, name, device list, and chart shape in the
  concepts is illustrative. Bind real `Repository` data. The profile is the real user
  profile, not "Alex Easton".
- **R5 — Duplicate screens.** Devices, Data Sources, Settings, Automations each appear
  on two sheets. The **more detailed variant wins** (sheet 4 for Devices/Data
  Sources/Settings/Backup, sheet 5 for Automations/Insights). Sheet-1 thumbnails of the
  same screens are treated as mid-scroll crops of the canonical variant.
- **R6 — Light first.** Concepts are light-only. Light is the pixel target; dark is
  derived per §2.2. The Settings "Appearance Light/System/Dark" control keeps working.
- **R7 — Liquid Today retired.** The concept Today replaces both the classic `TodayView`
  and the V8 `LiquidTodayView`. Implement the concept in `TodayView`, remove the
  `noop.liquidTodayEnabled` toggle path from `RootTabView`/Settings, and leave
  `Strand/Liquid/` compiling but unreferenced (deletion is a follow-up, not this spec —
  except `LiveSessionView` if it's the live-workout screen, which gets restyled where it
  lives).
- **R8 — Unshown screens.** Screens with no concept reference (Coach, Compare, Health,
  Hydration, Caffeine, Journal, Breathing, Intelligence, Metric Explorer, Weekly Digest,
  onboarding, etc.) keep their exact information architecture and get tokens/primitives
  only (§7). No layout redesign for them in this spec.
- **R9 — Typeface.** SF Pro (system) replaces Helvetica Neue app-wide — the concepts
  render the native iOS grotesque, and it's a one-constant change. *(Flagged for Easton:
  if he wants to keep Helvetica Neue, skip task T03-b; everything else stands.)*
- **R10 — Copy.** Use concept copy verbatim where legible ("Live Body Console", "What
  Moves You", "Private by design. You're in control.") unless it contradicts existing
  domain terminology; keep existing strings where concepts show obvious placeholder text.
  All new strings go through `Localizable.xcstrings` like existing ones.

---

## 4. Component inventory (build once, reuse everywhere)

All in `Packages/StrandDesign` unless noted. Names are the contract `tasks.md` uses.

| Component | Replaces / restyles | Spec |
|---|---|---|
| `ScoreRing(value:range:accent:size:)` | GlowRing/RecoveryRing/BevelGauge call sites | §2.4 rings; center numeral + optional caption under |
| `PaperCard` | `StrandCard` restyle | §2.4 card |
| `PrimaryButton` / `DestructiveButton` / `ChipButton` | `NoopButton` variants | §2.4 buttons |
| `StatusBadge(text:style:)` | ad-hoc badges | §2.4 badge; styles: connected, live, paused, beta, experimental, imported, upToDate, ready, notConnected |
| `SectionHeader(text:trailing:)` | ad-hoc caps labels | `sectionOverline` + optional trailing link/Edit |
| `StatTriplet` | — | 3 columns label-over-value (Baseline/Yesterday/7D Avg; Duration/Efficiency/RHR) with hairline column separators |
| `MetricTile(icon:label:value:unit:spark:)` | DashboardCards tiles | Health-monitor grid tile, 2- or 3-across, optional sparkline in accent color |
| `DeviceRow` | DevicesView rows | 40 pt thumb, name, status badge, battery % + green battery icon, signal, chevron |
| `SettingsRow` | SettingsView rows | §2.4 list row, trailing value/segment/toggle |
| `NoteCard(style: .privacy/.warning/.info)` | ad-hoc footers | §2.4 note card |
| `InsightCard` | — | sparkle/leaf/moon SF Symbol + `body` prose, `card` bg |
| `ZoneBars` | existing zone display | 5 rows Z5→Z1: label, colored bar (track `inset`), % right, time right |
| `SplitsTable` | — | columns MI · PACE · (bar) · HR, hairline rows |
| `StressTimelineBar` | Today stress strip | horizontal segmented bar, §2.1 stress ramp, axis 12AM/6AM/12PM/6PM/12AM in `micro` |
| `HeaderBar` | ScreenScaffold header | §2.6 |
| `PaperTabBar` + FAB | RootTabView custom bar | §2.6 |
| `QuickActionsSheet` | existing quick-action sheet | sheet 5 overlay: title "Quick Actions" + ✕, rows: Live HR ("Start live heart rate", red heart icon) · Start workout ("Track a workout") · Log journal ("How are you feeling?", purple icon) · Breathe ("Guided breathing", teal icon) |
| `Hypnogram` restyle | existing | §2.1 stage colors on `inset` track, stage legend rows with colored dots |
| Chart style | OverviewHRChart, Sparkline, trends charts | 2 pt accent lines, no area fill or ≤6% tint fill, `inset` plot bg or none, `micro` axis labels in `textTertiary`, dotted `textTertiary` baseline for 7D-avg overlays |

---

## 5. Screen index (concept → code)

| # | Screen | Concept | Source file |
|---|---|---|---|
| S1 | Today | sheet 1-1, 3-1 | `Strand/Screens/TodayView.swift` |
| S2 | Trends | sheet 1-2 | `Strand/Screens/TrendsView.swift` |
| S3 | Sleep | sheet 1-3 | `Strand/Screens/SleepView.swift` |
| S4 | Live | sheet 1-4 | `Strand/Screens/LiveView.swift` |
| S5 | Workouts | sheet 1-5 | `Strand/Screens/WorkoutsView.swift` |
| S6 | Devices | sheet 4-1 (canon), 1-6 | `Strand/Screens/DevicesView.swift` |
| S7 | Add Device | sheet 4-2 | `Strand/Screens/AddDeviceWizard.swift` |
| S8 | Data Sources | sheet 4-3 (canon), 1-7 | `Strand/Screens/DataSourcesView.swift` |
| S9 | Backup & Sync | sheet 4-4 | `Strand/Screens/BackupSyncView.swift` (+ `StorageView.swift` if split) |
| S10 | Settings | sheet 4-5 (canon), 1-10 | `Strand/Screens/SettingsView.swift` |
| S11 | Support | sheet 4-6 | `Strand/Screens/SupportView.swift` |
| S12 | Insights | sheet 5-1 (canon), 1-8 | `Strand/Screens/InsightsView.swift` / `InsightsHubView.swift` |
| S13 | Lab Book | sheet 5-2 | `Strand/Screens/LabBookView.swift` (+ `MarkerEditorView.swift`) |
| S14 | Rhythm Consent | sheet 5-3 | `Strand/Screens/RhythmView.swift` (consent gate) |
| S15 | Rhythm | sheet 5-4 | `Strand/Screens/RhythmView.swift` |
| S16 | Automations | sheet 5-5 (canon), 1-9 | `Strand/Screens/AutomationsView.swift` |
| S17 | Alarms | sheet 5-6 | `Strand/Screens/SmartAlarmView.swift` |
| S18 | Test Centre | sheet 5-7 | `Strand/Screens/TestCentreView.swift` |
| S19 | Quick Actions | sheet 5-7 overlay | `StrandiOS/App/RootTabView.swift` quick-action sheet |
| S20 | Charge detail | sheet 3-2 | `Strand/Screens/V5PillarHosts.swift` + `ChargeBreakdownFormat.swift` (locate actual host) |
| S21 | Effort detail | sheet 3-3 | same family as S20 |
| S22 | Rest detail | sheet 3-4 | same family as S20 / `SleepView` share |
| S23 | Stress detail | sheet 3-5 | `Strand/Screens/StressView.swift` |
| S24 | Pre-run | sheet 2-1 | `Strand/Screens/LiveWorkoutView.swift` (+ `Strand/Liquid/LiveSessionView.swift` — locate actual run UI) |
| S25 | Live run | sheet 2-2 | same as S24 |
| S26 | Paused run | sheet 2-3 | same as S24 |
| S27 | Post-run summary | sheet 2-4 | same as S24 + `WorkoutDetailView.swift` |

The implementer must confirm S20–S26 file mapping before starting those tasks
(`grep -rn "Charge" Strand/Screens/V5PillarHosts.swift`, `xcodebuild` + simulator walk).

---

## 6. Screen-by-screen requirements

Everything below is transcribed from the concept images. Layout order is top→bottom.
"AC" = acceptance criteria. Copy in quotes is literal (Ruling R10). Values are sample
(Ruling R4).

### S1 — Today (sheet 1-1 canonical; sheet 3-1 confirms variants)

Header: "TODAY ▾" left (day picker), wordmark center, sync icon + green dot right;
date "Wed, May 14" right-aligned under the icon row.

1. **Pillar trio** — three `ScoreRing`s in a row (Charge/Effort/Rest), 64 pt, numbers
   inside, pillar name under ring, state word under that in `micro` ("Good", "Moderate",
   "Calibrating"…). Colors per R3. Sheet 3-1 adds an optional "Today at a glance" row
   under the trio: icon + "3 workouts · 8,352 steps · 1,876 cal" + chevron — include it
   (data from existing Today models).
2. **Live Heart Rate card** — red heart icon + "LIVE HEART RATE" overline; big
   `metricValue` "62 BPM"; `micro` "52 min ago" (or "Latest"); trailing mini HR line
   chart (green, 2 pt) with 120/40 gridline labels.
3. **Today's Stress card** — "TODAY'S STRESS" overline, state word ("Low"), trailing
   `StatusBadge` with the numeric value ("1.8", stress tint); `StressTimelineBar`
   beneath with 12AM–12AM axis.
4. **Health Monitor card** — "HEALTH MONITOR" overline + "All metrics in range"
   caption (+ chevron in sheet 3-1 — include, routes to `HealthView`). 3×2
   `MetricTile` grid: HRV 65 ms · RHR 52 bpm · Resp. rate 14.2 rpm · SpO₂ 98% ·
   Skin temp +0.1 °F · Sleep perf. 85%, each with small accent sparkline
   (sheet 3-1 shows sparklines — include).
5. **FAB** bottom-right → `QuickActionsSheet` (S19).

AC: trio uses real scores/states; every card is a `PaperCard`; FAB present only here;
matches sheet 1-1 within spacing rhythm; light canvas `#F7F6F3` visible between cards.

### S2 — Trends (sheet 1-2)

Header: "THIS WEEK" overline + "May 8 — May 14" caption left; wordmark center;
calendar + share icons right.

1. **Score tiles row** — three `PaperCard` tiles: pillar name `caption`, value in pillar
   color `statValue`, delta `micro` ("+6 vs last week"). Effort delta shows sign.
2. **"SCORES OVER TIME"** card — legend dots (● Charge ● Effort ● Rest in pillar
   colors), multi-line chart 0–100 y-axis, Thu→Wed x-axis, 2 pt lines with point dots.
3. **"WEEK IN REVIEW"** card — bullet rows: 8 pt pillar-colored dot + `body` sentence
   ("Rest improved 4 points this week.", Effort sentence, Stress sentence). Bind to the
   existing week-review/digest copy generator if present; else existing trends summary.
4. **Insight card** — ✦ sparkle icon + "INSIGHT" overline + prose ("Better sleep on Sun
   and Mon was linked to higher Rest scores.") from the existing insights engine.

AC: pillar colors per R3 (concept's blue Effort tile = corrected to purple); chart
axes/gridlines in `micro`/`hairline`.

### S3 — Sleep (sheet 1-3)

Header: back chevron, "SLEEP" `screenOverline` center-left or under wordmark, date
"Wed, May 14 ▾", share + ⋯ right.

1. **Hero** — `ScoreRing` 96 pt (Rest score, `restAccent`) left; right column: "Good
   Rest" `cardTitle` + caption "This was a solid night of recovery."
2. **`StatTriplet`** — Duration 7:45 · Efficiency 85% · Resting HR 52 bpm.
3. **"SLEEP MARKS"** card — rows: big number "2" + "Disturbances"; "Light ✓";
   "On time ✓" (green checks). Bind to existing sleep-marks model; if the app lacks
   this concept, show existing sleep quality marks unchanged in the new card style.
4. **"SLEEP STAGES"** card — legend rows (● Awake red / ● REM light-blue / ● Light
   blue / ● Deep navy) + restyled `Hypnogram`, x-axis 11:15 PM → 7:00 AM `micro`.
5. **"ASLEEP / WOKE"** card — three columns: "Asleep 11:15 PM" · center "7h 45m — In
   bed 8h 05m" · "Woke 7:00 AM".

AC: hypnogram stage colors exactly §2.1; ring is flat (no glow).

### S4 — Live (sheet 1-4)

Header: wordmark, "LIVE BODY CONSOLE" `screenOverline`.

1. **Device card** — strap product image 56 pt left; "NOOP Strap" `cardTitle`,
   `StatusBadge` ● Connected; caption "Battery 78% · Worn · 1 min ago".
2. **`PrimaryButton`** "Scan & Connect".
3. **"HEART RATE"** card — 96 pt `liveRed` ring, "62 BPM" + ● Live badge inside/below;
   right column rows: "ZONE 1 — < 120 bpm", "HRV 65 ms" + green dot, "RHR 52 bpm".
4. **"PHYSIOLOGY STATUS"** card — green check circle + "All systems normal" `body` +
   "Last updated 1 min ago" `micro`.

AC: red used only for live HR; scan button black not gold.

### S5 — Workouts (sheet 1-5)

Header: wordmark, "WORKOUTS" `screenOverline`.

1. **`PrimaryButton`** "▶ Start Workout" (SF Symbol `play.fill`).
2. **"WORKOUT SCORE"** card — big value "38.4" `metricValue` + state word "Moderate";
   trailing sparkline (blue); `micro` delta "-3.2 vs last week". (Existing workout-score
   metric, whatever its scale — R2.)
3. **"RECENT WORKOUTS"** card — rows: effort badge (small rounded square, pillar/blue
   tint, bold number), name + date `body`/`caption`, distance + duration trailing.
   3 rows + "View all workouts" `link`.
4. **Bottom split row** — two half-width cards: "HR ZONES — Time in zones" mini
   `ZoneBars` (5 bars, % labels) · "SPLITS — Pace / mi" mini `SplitsTable`
   (1 8:21 / 2 8:09 / 3 8:04 / 4 8:04 / Best 7:58).

AC: zone colors exactly §2.1 ramp; start button is the only black element.

### S6 — Devices (sheet 4-1 canonical; sheet 1-6 shows longer list)

Header: back chevron, wordmark, "+" right. Title block: "Devices" `cardTitle` +
"Manage your straps and devices." caption.

1. **"PAIRED DEVICES"** section — `DeviceRow` cards, one per device, each expandable to
   a second line: battery pill (green battery icon + %) and "Signal Strong" caption.
   Status badges: Paired / Active Link (green) / Not connected (gray) with "Last seen
   May 13, 9:21 PM" caption.
2. **`PrimaryButton`** "+ Add a device" → S7.
3. **`NoteCard(.privacy)`** — "All data is stored locally on this device. Private by
   design. You're in control."

AC: real paired-device list; thumbnails use existing device imagery; battery %
green when >20 else amber.

### S7 — Add Device (sheet 4-2)

Title block: "Add a device" + "Connect a device to start collecting data."
List of `DeviceRow`-style options with chevrons: WHOOP 5.0 / MG (wrist strap), WHOOP 4.0
(wrist strap), Heart-rate strap (Bluetooth HR monitor), Gym equipment (Treadmills, bikes
& more, `Beta` badge), Oura ring (Sleep & readiness, `Beta`), Amazfit / Zepp (Watches &
bands), Xiaomi Mi Band (Activity & sleep tracker). Footer `NoteCard(.info)`: "Some
integrations are in beta. Features may change."

AC: options bind to the existing `AddDeviceWizard` catalog — do not invent or drop
integrations; Beta badges only where the catalog says beta.

### S8 — Data Sources (sheet 4-3 canonical)

Title block: "Data Sources" + "Import or connect your data."

1. **"IMPORT FROM FILE OR APP"** — rows with brand icon tiles (existing assets):
   WHOOP Export ("Import workouts, sleep, strain and recovery from WHOOP.",
   `Imported`/`Up to date` badge, "Last import: May 12, 2025" caption), Apple Health
   ("Import health, workouts, sleep and more.", badge + last-import), Xiaomi Smart Band
   Export ("Import activity, sleep and heart rate data.", `ChipButton` "Choose export").
2. **"MANAGE IMPORTED DATA"** — `DestructiveButton` row "Remove imported data".
3. **`NoteCard(.privacy)`** — "All imports stay on this device. Your data is never
   uploaded. You decide what to import."

AC: reflects real import sources/states from `StrandImport`/`WhoopStore`.

### S9 — Backup & Sync (sheet 4-4)

Title block: "Backup & Sync" + "Keep your local data safe."

1. **"BACKUP LOCATION"** — folder icon row "NOOP Backup — iCloud Drive › NOOP" +
   "48.2 GB available" caption + chevron.
2. **"AUTO BACKUP"** — toggle row "Daily auto-backup — Automatically back up your data
   every day"; row "Backup time — 2:00 AM ›".
3. **`PrimaryButton`** "Back Up Now"; beneath it green check + "Last backup: May 14,
   2025 at 2:01 AM" caption.
4. **"RESTORE"** — row "Restore from backup — Replace current data with a previous
   backup ›".
5. **`NoteCard(.privacy)`** — "Backups are saved to your local folder in iCloud Drive.
   You're in control."

### S10 — Settings (sheet 4-5 canonical; sheet 1-10 confirms grouping)

Title block: "Settings" + "Customize NOOP to your preferences."

1. **Profile card** — avatar (photo or initials circle), real name, "Member since …"
   caption, chevron.
2. **"PREFERENCES"** — Units (US | Metric segmented), Appearance (Light | System | Dark
   segmented), First day of week (Monday ›), Notifications (On ›), plus existing
   preference rows not shown in the concept (keep them, same row style; sheet 1-10 also
   shows Data & Storage here).
3. **"PRIVACY & LOCAL DATA"** — Local Data (On ›), Data Management ›, Export Your
   Data ›, Delete All Data (red, destructive row).
4. **"SUPPORT"** — "Support & Donation — Help keep NOOP independent." ›

AC: every existing settings row survives (nothing silently dropped); segmented controls
use `inset` track + `card` selected thumb; Delete row is the only red text on screen.

### S11 — Support (sheet 4-6)

Title block: "Support" + "We're here to help."

1. **"SUPPORT THE BUILD"** card — "NOOP is independent. Your support keeps it going."
   caption, `PrimaryButton` "Support NOOP", QR code image (existing donation QR from
   `Tools`/assets), "Thank you! ♥" `micro`.
2. **"HELP & CONTACT"** — rows: Help Center ›, Report an Issue ›, Request a Feature ›.
3. **"PRIVACY FIRST"** `NoteCard(.privacy)` — "NOOP works offline. Your data stays on
   your device. We respect your privacy."

### S12 — Insights (sheet 5-1 canonical; sheet 1-8 is a crop)

Header: wordmark, ✦ icon right. Title: "Insights" `screenOverline` + "What Moves You"
`cardTitle` + "Personal data associations ranked by effect size" caption + `Journal`
badge (purple tint) + `Local only` badge (gray tint).

1. **Filter chips** — All · Recovery · Sleep · Stress · Strain (capsules; active = `ink`
   fill white text, inactive = `card` + border).
2. **"TOP ASSOCIATIONS"** card — rows: icon circle + association title `body`
   ("Lower evening stress") + outcome caption ("Better Rest score") + effect size
   trailing in green `statValue` ("+0.62"); expanded rows show "With 2.4 → Without 1.8"
   (green → red values, arrow). 4 rows + "View all associations" `link` row.
3. **Insight card** — ✦ + prose ("On nights you fall asleep earlier, your Rest score
   improves by 18%.") + `micro` "Based on your data · Local only".
4. **"How this works"** footer caption — "We analyze your data to find what's associated
   with better outcomes for you. Results are personal and may change over time."

AC: binds to existing associations engine (`InsightsView`/`InsightsHubView`); effect
sizes real; chips filter the list.

### S13 — Lab Book (sheet 5-2)

Header: wordmark; title "Lab Book" + "Private health notebook" caption; `ChipButton`
"+ Add reading" (blue) right.

1. **"MARKERS" section** (trailing "Edit" link) — empty state card: flask line-icon,
   "No markers yet" `cardTitle`, "Track what matters to you. Add a marker to get
   started." caption, `ChipButton` "Add marker". Populated state: existing marker rows
   in `SettingsRow` style.
2. **Import readings row** — upload icon + "Import readings — Bring in data from a
   file" + "WHOOP export, CSV, or Apple Health" caption + chevron.
3. **"RECENT READINGS"** — empty state: "None yet — Your logged readings will appear
   here."
4. **`NoteCard(.warning → info tone)`** "Important" — "NOOP is for personal tracking and
   insights only. It is not medical advice or a diagnostic tool."

### S14 — Rhythm Consent (sheet 5-3)

Full-screen gate before Rhythm is enabled (existing consent state in `RhythmView`).

Title: "Before you turn on Rhythm" `cardTitle` + "Experimental wellness visualization"
caption. Four icon cards (icon circle + title `body` semibold + caption):
1. "This is experimental" — "Rhythm visualizes patterns in your heart rate dynamics.
   It's an early exploration, not a medical tool."
2. "For wellness awareness only" — "Use Rhythm to learn about your patterns over time.
   Always consult a professional for health concerns."
3. "Local and private" — "All processing happens on your device. Your data stays with
   you."
4. "You're in control" — "You can turn Rhythm off anytime from settings. Nothing is
   collected or shared."
Toggle row: "I understand Rhythm is experimental and for personal awareness only."
`PrimaryButton` "Turn on Rhythm" — disabled (40% opacity) until the toggle is on.

### S15 — Rhythm (sheet 5-4)

Header: back chevron, wordmark; "Rhythm" title + `Experimental` badge (purple).

1. **Empty state** — dashed-border circle with scatter-dot motif, "No rhythm data yet"
   `cardTitle`, "Wear your strap and go about your day. We'll start capturing when your
   heart rate has more variation." caption. (Populated state: existing Poincaré plot
   restyled — 2 pt dots in `effortAccent` on `inset` bg.)
2. **"HOW RHYTHM IS MEASURED"** card — three icon rows: "R-R interval variation —
   Timing between heartbeats"; "Poincaré plot — Visualizes short-term variability";
   "Trend over time — Shows how your rhythm adapts".
3. **`NoteCard(.privacy)`** "On-device only" — "All analysis is done on this device.
   Your data is private and never leaves your device."

### S16 — Automations (sheet 5-5 canonical; sheet 1-9 is a crop)

Header: wordmark; "Automations" title.

1. **Status banner** (when strap disconnected) — red dot + "Strap not connected —
   Automations will run when connected." on `card`.
2. Rows (toggle or chevron, existing settings bound): Wrist alerts ("Get gentle alerts
   on your wrist", toggle) · Double-tap action ("Choose what a double-tap does",
   "Play/pause ›").
3. **"HOW & PRESENCE"** — Wear detection (toggle) · Away mode ("Reduce alerts when
   you're away", toggle) · Sleep mode ("Reduce alerts at night", "10:30 PM ›").
4. **"BEHAVIOR REMINDERS"** — Inactivity reminder ("Move a little if you've been
   still", toggle) · Stress check-in ("Gentle nudge during high stress", toggle).
5. **"ADVANCED"** — Automation presets ("Configure preset packs") ›.
6. Sheet 1-9 additionally shows the Alarms + Test Centre entry rows here (Strap Wake
   Alarm 7:00 AM toggle, Run test, Simulate workout) and the orange warning "Alarms and
   alerts are local to this device. They do not affect any other devices." — keep these
   if the current `AutomationsView` already hosts them; otherwise they live in S17/S18.

### S17 — Alarms (sheet 5-6)

Header: wordmark; "Alarms" title.

1. **"Strap wake alarm"** card — Smart Wake toggle; rows "Wake window — 7:00 AM –
   7:30 AM"; "Target time — 7:15 AM"; caption "Your strap will vibrate gently to wake
   you during your lightest sleep."
2. **"Evening wind-down reminder"** card — toggle; "Start time — 9:30 PM ›";
   "Reminder — Wind down ›"; caption "Help build a consistent bedtime."
3. **"Backup notification"** card — toggle; "If alarm missed — Notify on phone ›";
   caption "We'll notify your phone if your strap alarm isn't acknowledged."
4. **`NoteCard(.warning)`** — "Alarms use your strap's vibration. Keep it charged and
   within range."
5. **`PrimaryButton`** "Test alarm".

### S18 — Test Centre (sheet 5-7)

Header: wordmark; "Test Centre" title + "Diagnostics & tools" caption.

1. **"DIAGNOSTICS"** (trailing "Run All" link) — rows with per-row `ChipButton` "Run":
   Strap connection ("Check link quality") · Sensor check ("HR signal quality") ·
   Firmware check ("Strap up to date") · Battery status ("Power & health").
2. **"DATA TESTS"** — R-R capture test ("30s sample") · Vibration test ("Test haptic
   feedback") · LED test ("Test strap lights"), each with "Run".
3. **"REPORTS"** — Diagnostics report ("View latest results") ›.

### S19 — Quick Actions sheet (sheet 5-7 overlay)

Presented from the FAB. `card` sheet, radius 16 top corners, grabber, "Quick Actions"
`cardTitle` + ✕. Rows (icon circle + title + caption): Live HR ("Start live heart
rate", red heart) · Start workout ("Track a workout", ink figure.run) · Log journal
("How are you feeling?", purple book) · Breathe ("Guided breathing", teal wind). Each
routes to the existing destination (LiveView, workout start, journal, BreathingView).

### S20 — Charge detail (sheet 3-2)

Header: back chevron, "CHARGE" `screenOverline`, date "Wed, May 14 ▾", share + ⋯.

1. **Hero** — 96 pt green `ScoreRing` "41" + ⓘ; right column "Building Charge"
   `cardTitle` + "Your body is still recovering." caption.
2. **`StatTriplet`** — Baseline 75 · Yesterday 38 · 7D Avg. 48.
3. **"CHARGE OVER TIME"** card — green 2 pt line + dotted 7D-avg overlay, 0–100 y,
   12AM–12AM x, legend "— Charge · ⋯ 7D Avg.".
4. **"KEY FACTORS"** card — rows: icon + metric name + value + status word right in
   green ("Good"): HRV 65 ms · RHR 52 bpm · Rest 92% · Resp. Rate 14.2 rpm · Skin Temp
   +0.1 °F.
5. **"CHARGE RECOMMENDATION"** card — leaf icon + "Keep prioritizing recovery. Great
   sleep and low stress will build Charge." + chevron.

### S21 — Effort detail (sheet 3-3)

Same skeleton as S20, purple. Hero "33 — Moderate Effort — You trained hard today.
Productive, but don't overdo it." `StatTriplet` Baseline 25 · Yesterday 31 · 7D Avg 29.
"EFFORT OVER TIME" purple chart. **"EFFORT CONTRIBUTORS"** rows with status words in
red/amber ("High"/"Moderate"): Average HR 144 bpm High · Calories 520 kcal High ·
Max HR 171 bpm High · Duration 42 min Moderate. **"HEART RATE ZONES"** `ZoneBars` with
% + time columns + "View Details" link.

### S22 — Rest detail (sheet 3-4)

Same skeleton, blue. Hero "92 — Good Rest — You had a strong recovery." `StatTriplet`
Duration 7:45 · Efficiency 85% · Resting HR 52 bpm. **"SLEEP STAGES"** restyled
hypnogram with legend. Second `StatTriplet`: Time in bed 8:05 · Sleep efficiency 85% ·
Latency 18 min. **"SLEEP INSIGHT"** card — moon icon + "Great sleep quality. Keep up
your consistent bedtime routine."

### S23 — Stress detail (sheet 3-5)

Same skeleton, amber; ring shows "1.8" (0–3 scale, R2). Hero "Low Stress — You've been
relaxed most of the day." `StatTriplet` Baseline 2.5 · Yesterday 2.2 · 7D Avg 2.4.
**"STRESS OVER TIME"** amber chart, y-axis 0–3.0. **"STRESS BREAKDOWN"** rows with
duration + green-tinted % badges: Restful 16h 20m 76% · Low 5h 10m 19% · Medium 1h 00m
4% · High 0h 10m 1%. **"RESET RECOMMENDATION"** leaf card — "You're handling stress
well. A short walk can help you reset further."

### S24 — Pre-run (sheet 2-1)

Header: wordmark + gear icon right. Title "Run" `cardTitle` + "Outdoor workout" caption;
badges right: `GPS Ready` (green tint) and `Route saving — Local only` (outline).

1. **"RUN TYPE"** segmented cards — Outdoor Run (selected: `ink` border) · Treadmill ·
   Trail Run, each with small icon. Bind to existing workout types.
2. **"RECENT ROUTE"** card — map thumbnail 64 pt + "Riverside Loop" `body` + "5.03 mi ·
   142 ft gain" caption + "Last used May 12, 2025" `micro` + chevron. (If no route
   feature exists, show the existing recent-workout equivalent; do not build route
   storage — R8 spirit: visuals only.)
3. **"LAST WORKOUT"** card — small effort ring + name/date/stats row.
4. **"RUN SETUP"** card (trailing "Edit") — `SettingsRow`s: Goal (General fitness ›) ·
   Audio cues (Every 1 mi ›) · Auto lap (1 mile ›) · Heart-rate alert (Off ›). Bind to
   existing workout settings; omit rows that have no backing setting.
5. **`PrimaryButton`** "▶ Start Run".
Tab bar per R1 (concept's Home/Workouts/Coaching bar is an error).

### S25 — Live run (sheet 2-2)

Header: "NOOP ▾" (workout-type switcher if it exists, else wordmark) + ● Live badge.

1. **Timer block** — `timer` "32:47" + "Elapsed Time" `micro` centered.
2. **Stats grid** — 3×2 `MetricTile`s (no cards, hairline-separated grid): DISTANCE
   4.21 mi · PACE 8:02 /mi · HEART RATE 152 bpm (value in red) · CALORIES 412 kcal ·
   CADENCE 168 spm · ELEVATION 236 ft.
3. **Map card** — route polyline (blue 3 pt) + current-position dot + "Riverside Path ›"
   pill overlay bottom-left.
4. **"HEART RATE (LAST 3 HOURS)"** card — green line chart + current "152 bpm" label,
   time x-axis, 100–180 y.
5. **Control row** — lock icon button (44 pt circle, `card` + border) · `PrimaryButton`
   "⏸ Pause" (flex) · `DestructiveButton` "■ Finish".

### S26 — Paused run (sheet 2-3)

Same as S25 with: ● Paused badge (red) replacing Live; timer subtitle "Paused";
**"SPLITS"** card replacing the HR chart — `SplitsTable` MI · PACE · bar · HR rows
(green bars lengthening per pace) + "View All" link; controls become "▶ Resume" +
"■ Finish".

### S27 — Post-run summary (sheet 2-4)

Header: back chevron, wordmark, share icon.

1. **"RUN EFFORT"** hero — purple ring with the app's real per-workout effort value
   (R2), "Good Work" `cardTitle` + "This run maintained moderate effort." caption;
   `micro` row "Compared to your usual" + `+1.2` green tint badge.
2. **Stats grid card** — 3×2: Distance 5.03 mi · Time 42:18 · Avg pace 8:24 /mi ·
   Avg HR 144 bpm · Max HR 171 bpm · Calories 520 kcal; full-width row below:
   Elevation gain 142 ft.
3. **"HEART RATE ZONES"** card — `ZoneBars` with % + time + "View Details" link.
4. **"ROUTE"** card — pin icon + "Riverside Loop" + "5.03 mi · 142 ft gain" + map thumb.
5. **`PrimaryButton`** "✓ Save Workout".

---

## 7. Screens without concept references (Ruling R8)

`CoachView`, `CompareView`, `HealthView`, `HydrationView`, `MetricExplorerView`,
`WeeklyDigestView`, `WhatsNewView`, `UpdatesInboxView`, `ScoringGuideView`,
`HowNoopWorksView`, `IntelligenceView`, `JournalLogCard`, `BreathingView`,
`IntervalTimerView`, sheets and editors (`ManualWorkoutSheet`,
`DashboardCardsEditorSheet`, `KeyMetricsEditorSheet`), onboarding, and the More tab
list itself: swap to the new tokens/primitives (they mostly inherit automatically via
`StrandDesign`), verify no dark-theme assumptions (white-on-dark text hardcodes,
gold/titanium references, glow effects), and fix what breaks. Layout unchanged.

---

## 8. Global acceptance criteria

1. **Build**: `xcodegen generate` then `xcodebuild -project Strand.xcodeproj -scheme
   NOOPiOS -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build` succeeds;
   `StrandTests` and `StrandDesign` package tests pass.
2. **No gold**: `gold`, `titanium`, glow, and liquid tokens/effects appear on zero
   rendered iOS screens (tokens may remain defined until follow-up cleanup, but no
   call site renders them).
3. **Contrast**: all text ≥ 4.5:1 against its background in both themes (`textTertiary`
   on `canvas` is the tightest — verify).
4. **Dynamic Type**: Today, Sleep, Settings, and Live run render without truncation or
   overlap at XL text size.
5. **Devices**: iPhone SE (small) and Pro Max (large) render without layout breakage on
   S1–S27.
6. **Dark**: every S-screen renders legibly in dark mode with §2.2 values.
7. **Visual match**: side-by-side against `references/` sheets, a reviewer finds no
   unexplained deviation (rulings R1–R10 are the only allowed deviations).
8. **No data regressions**: no scoring, storage, import, BLE, or navigation behavior
   changes; every existing screen remains reachable.
