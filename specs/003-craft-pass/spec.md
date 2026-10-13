# Spec 003 — Craft Pass (board v2, screen-at-a-time, review-gated)

> **For agentic workers:** 001 defined the design system, 002 fixed structure and
> metrics. Both are DONE and their rulings stand except where a D-ruling below
> supersedes. This pass is about **visual character**: the current build is
> structurally right but reads "mid" next to the reference — icon language,
> module finesse, empty-state design, spacing rhythm. Read `critique.md`
> (module-by-module deltas — the actual punch list) and `tasks.md` (T60–T69,
> one screen per task, HARD external review gate after each).

**Goal:** Make each screen read as the reference board at first glance — craft, not
coverage. External reviewer (Easton/Claude) approves every screen before the next
starts. Codex does not self-certify fidelity in this pass.

**The reference:** `references/board-v2.png` — the consolidated 27-screen board
(2026-07-10). It **supersedes the five 001 sheets for layout and composition**. It is
natively Recovery/Strain(0–21)/Sleep, so 002's C1/C2/C3 need no reinterpretation.

## D-rulings (supersede board/previous where stated)

- **D1 — Board v2 is the composition target; C13 hues override board hues.**
  Easton's call 2026-07-10: keep WHOOP hexes (Strain constant `#0093E7` blue, Sleep
  slate `#7BA1BB`, Recovery banded green/yellow/red per C13). The board's purple
  Strain / bright-blue Sleep are render artifacts. Everything else on the board wins
  over the old sheets.
- **D2 — No sparklines in Health Monitor tiles** (board + Easton, replaces 001
  §6-S1's sparkline note). Tile = 16 pt **monochrome ink line-icon** + 13 pt label +
  20 pt value with 11 pt unit. One icon language everywhere: thin line glyphs in
  `textPrimary` — never multicolor filled SF Symbols.
- **D3 — Stress module rebuild** (flagged "terrible" by Easton — it is). Thin
  **continuous** ribbon, 6 pt tall, fully rounded ends, segments colored by stress
  band (001 ramp: restful `#2FA45C`, low `#CDE7D6`, medium `#E0A63A`, high
  `#E5484D`) with NO gaps between segments; `micro` axis labels
  12AM · 6AM · 12PM · 6PM · 12AM; header row = "TODAY'S STRESS" overline, state word
  in `cardTitle`, amber value badge right. Delete the segmented-brick rendering.
- **D4 — FAB docks center-tab** (board): Today · Trends · **[56 pt ink circle +]** ·
  Sleep · More. Opens Quick Actions as before. Removes the floating bottom-right FAB
  and its collision with content links.
- **D5 — Empty states are designed, not bare.** Same layout as the populated state,
  dimmed placeholder visuals, one caption line. The Live-HR "—  BPM / Waiting for
  live signal" card is the anti-pattern: populated = 28 pt numeral + 2 pt green
  trace with 40/120 micro gridline labels + "x min ago"; empty = identical
  composition with flat dimmed trace line + caption.
- **D6 — Run flow per board** (already engine-aligned — no pause exists):
  pre-run = activity picker list (Running / Walking / Cycling / Strength Training /
  HIIT / Other, icon rows) + "GPS will be used automatically when available"
  footnote + black Start Workout; existing setup rows (goal, audio cues, auto-lap,
  HR alert) stay reachable behind a gear icon on the picker (C8). Live = timer +
  2×3 grid (Heart Rate / Zone / Live Strain / Max HR / Avg HR / Calories) + lock +
  red-outline End Workout. Summary = Workout Strain hero + segmented
  Overview · Splits · Heart Rate · Map tabs + metric rows + zone bars + black Done.
- **D11 — Hybrid ruling (Easton, 2026-07-10):** where the ORIGINAL 001 sheets and
  board v2 conflict, the original sheets win — EXCEPT the center-docked FAB (D4)
  which stays. Concretely: Splits card returns to Workouts (D7 amended), Sleep
  keeps the Asleep/Woke bottom row (D8 amended), and the original sheets' density
  and detail are the pixel bar. Names, WHOOP colors, 0–21 Strain, and
  no-sparklines are unaffected.
- **D7 — Workouts simplifies** (board, AMENDED by D11 — splits card stays on
  Workouts): "TYPICAL STRAIN (7D)" card (value + state +
  sparkline + "Compared to your usual +x.x"), recent-workout rows with strain
  badges, HR ZONES (TIME) module. Splits leave the Workouts tab — they live in the
  workout-detail Splits tab (D6).
- **D8 — (AMENDED by D11)** Sleep keeps the Asleep/Woke bottom row from the
  original sheet. Sleep-marks card stays (C8), styled as-is from 002.
- **D9 — New board content ships only where the feature exists.** Settings gains a
  "Strain Scale — 0.0–21.0" info row (display-only). Data Sources' Garmin/Nutrition
  CSV rows, Support's BTC/ETH/LTC chips: add ONLY if the importer/donation config
  actually exists in the repo (check `Tools/`, `DONATIONS.md`, StrandImport) —
  otherwise skip; no new features in a craft pass. Lab Book and Rhythm get their
  populated-state layouts polished per board using the seeder.
- **D10 — Review gate.** Every screen task ends with: build → seeded screenshot →
  **STOP**. Post the screenshot path and wait for external approval before the next
  screen. Feedback gets applied and re-shot before moving on. Self-assessment
  ("looks close to me") does not open the gate.

- **C14 — WHOOP HR-zone grammar (Easton, 2026-07-10, reference: WHOOP zones
  screenshot in chat).** Everywhere HR zones render (ZoneBars, Workouts mini card,
  strain detail, workout detail, post-run): Z5 orange-red, Z4 orange, Z3 green,
  Z2 blue, Z1 pale slate. Tokens (light / dark): zoneZ5 `#E64A19`/`#FF6B2C`,
  zoneZ4 `#E08E00`/`#FFA424`, zoneZ3 `#27A85C`/`#33BE66`, zoneZ2
  `#4C9FE0`/`#64B5F6`, zoneZ1 `#9FB3BF`/`#B7C9D3` — dark values match WHOOP's
  app; light are paper-adapted (dark renders only in dark mode). Row format per
  the WHOOP shot: "ZONE 5 (90–100%)" label + zone-tinted share %, bold duration
  right, 8 pt fill bar beneath on the inset track.

## Craft acceptance (applies to every screen)

1. One icon language: thin ink line-glyphs, uniform optical weight; zero multicolor
   filled symbols outside status dots and pillar data.
2. Numerals share a baseline grid inside each card; units set in 11 pt `micro`
   beside, not under, the value.
3. No element collisions at any Dynamic Type size up to XL (the FAB-over-links bug
   class is dead).
4. No verbatim-duplicated copy on one screen (insight ≠ week-in-review bullet).
5. Charts: 2 pt lines, ≤ 4 pt points, hairline gridlines, `micro` axis labels,
   no heavy area fills (≤ 6% tint).
6. Every module has designed populated AND empty states (D5).
7. Side-by-side with board v2: same module order, same visual weight distribution,
   same whitespace rhythm — a stranger matches screenshot to board instantly.
