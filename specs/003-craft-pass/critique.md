# 003 Critique — board v2 vs current build (external review, 2026-07-10)

> Module-by-module deltas from a direct visual comparison of `references/board-v2.png`
> against the 002 final screenshots (`../002-noop-ui-completion/qa/after/`). Each item
> is a required change unless marked (verify). Hues per D1: C13 WHOOP hexes — where
> the board shows purple Strain / bright-blue Sleep, render C13 blue/slate instead.

## Today (board: Main Screens #1 · build: S01)

| # | Module | Board shows | Build shows | Required change |
|---|---|---|---|---|
| 1 | Header | NOOP center, date + gear right, tight | ✓ tight; sync+dot right | Keep; right side = date + gear per board (sync status merges into gear/More; verify which icon set Easton prefers at gate) |
| 2 | Trio | Thin rings, quiet 11 pt state words, balanced gaps | Rings close; state words heavy; card tall | Match board's vertical rhythm: ring 64 pt, 6 pt gap ring→name, 2 pt name→state; state in `micro` `textSecondary` |
| 3 | At-a-glance | Single quiet row | ✓ but blue filled runner icon | Ink line-glyph (D2 icon language) |
| 4 | Live HR | Hero numeral + fine green trace + 120/40 micro labels + "1 min ago" | Bare dash + "Waiting for live signal" | D5: design both states; populated 28 pt numeral, 2 pt trace; empty = dimmed flat trace, same geometry |
| 5 | Stress | 6 pt continuous mixed-color ribbon, micro axis | Fat red segmented bricks with gaps, oversized axis text | **D3 rebuild** — this is the worst module in the build |
| 6 | Health Monitor | 3×2 plain tiles: mono icon + label + value·unit, NO sparklines | Multicolor filled icons, one stray sparkline, loose grid | D2: monochrome line icons, drop sparklines, tighten to board density; keep "All metrics in range" + chevron |
| 7 | FAB/tab bar | Center-docked + in bar | Floating bottom-right, collides with "14-day trend/Edit" | **D4** center dock; collision class dies |
| 8 | Key Metrics section (restored feature, not on board) | — | Half-empty cards below the fold | Keep feature (C8) but cards must render designed states (D5); Edit/trend links move above the fold of that section |

## Trends (board #2 · build: S02)

1. Add the range chip row (W · M · 3M · 6M · Y · All) under the header per board —
   paper chip style (ink active, `card`+border inactive), NOT the blue pill style
   seen in MetricDetailView.
2. Tiles ✓ (colored numbers, neutral labels). Keep.
3. Chart: Recovery line vs Strain line are two near-identical blues at 2 pt (C13
   compliant, illegible). Fix within C13: Strain solid `#0093E7`; Recovery line in
   `recoveryData #67AEE6` **with band-colored point dots** (its existing treatment)
   plus 40% reduced saturation on the line so the dots carry it; Sleep slate. Legend
   dots match line treatments. Point dots ≤ 4 pt.
4. Week-in-review bullets: board shows colored status dots per line (green/amber);
   build renders all-blue. Restore per-pillar/status dot colors.
5. Insight card must never repeat a week-in-review bullet verbatim — if the engine
   returns the same string, drop the insight card or pick the next insight.
6. Kill the gray plot slab: hairline gridlines on `card`, no filled plot rect.

## Sleep (board #3 · build: S03)

1. Hero ✓ (ring, headline, prose). Keep.
2. (SUPERSEDED by D11 — Asleep/Woke row stays as built.)
3. Hypnogram: bars ✓; remove the gray vertical connector lines (board bars float
   free); bar height ~10 pt, stage rows evenly spaced.
4. Sleep-marks card stays; "Phase 1" link label is developer-speak — retitle to
   "Beta" chip or drop the trailing label.

## Pillar details (board row 2 · build: trio-tap `PaperPillarDetailView`)

1. Layout per board: hero ring + headline/prose, BASELINE · YESTERDAY · 7D AVG
   triplet, OVER-TIME chart (with dotted 7D avg + legend), CONTRIBUTORS list with
   status words. The T13-era build had this skeleton — polish type sizes to spec
   §craft-acceptance and verify contributors' status-word colors (green Good, amber
   Moderate, red High).
2. Strain detail: 0–21 axis with 7/14/21 gridlines ✓ (from T34); ring + chart in
   `strainAccent` blue (D1).
3. **MetricDetailView (trend explorer)**: still reachable as secondary surface —
   restyle its chrome now (was T56): duplicate "STRAIN/Strain" title collapses to
   one; blue W/M pill selector → paper chips; ghost oversized ring → standard
   96 pt hero ring with legible numeral.
4. Confirm deep links recoverydetail/straindetail land on PaperPillarDetailView
   (T56 item — verify done, else do).

## Workouts (board #5 · build: S05)

1. (D11) Keep the original-sheet structure as built: Workout Score card + recent
   rows + HR ZONES **and SPLITS** half-cards. Fix only: strain badges to blue
   tint per D1 (currently purple), and craft-acceptance type/spacing.
2. Remove the stray "↓" glyph next to View all workouts (from 002 list, verify).

## Run flow (board "RUN FLOW (ALIGNED)" · build: S24–S27)

1. Pre-run → activity picker per D6 (icon rows, GPS footnote, black Start
   Workout); setup rows behind gear (C8).
2. Live: timer hero + 2×3 grid (Heart Rate · Zone · Live Strain · Max HR · Avg HR ·
   Calories) + lock + red End Workout ✓ (engine-aligned). Map moves off the live
   screen per board — route renders in summary/detail Map tab.
3. Summary → segmented tabs Overview · Splits · Heart Rate · Map + Workout Strain
   hero + metric rows + zone bars + black **Done** (replaces Save Workout label;
   keep the save behavior).

## Live console (board #4 · build: S04)

1. Device card gains "Manage Devices" chip-link; status line "Connected ·
   Streaming · Battery x% · Signal" per board.
2. HR ring with HRV/RHR column ✓; physiology card ✓.
3. Add bottom black Start Workout CTA per board.
4. Advanced/record sections: keep (C8) inside proper PaperCards, after the board
   content.

## Devices (board #6 · build: S06)

Compress to board density: 40 pt thumb/name/status-dot+battery %/chevron rows,
black Add Device, one privacy note. Capability prose moves into each device's
detail screen. C1-consistent copy (no Effort references).

## Data & tools screens (board rows 3–4)

1. Data Sources: existing rows restyled ✓; add Garmin/Nutrition CSV only if
   importers exist (D9, verify in StrandImport/Tools). "Manage Imports" chip
   replaces bare destructive row placement (destructive action moves inside).
2. Backup & Sync ✓ close — match board's Backup Folder row + outline Restore.
3. Settings: add "Strain Scale — 0.0–21.0" info row (D9); profile card with real
   avatar/initials + member-since ✓ (verify done in 002).
4. Support: contact row (hello@ address from repo config), Support NOOP + QR ✓;
   crypto chips only if configured (D9, check DONATIONS.md).
5. Lab Book: polish populated marker rows (name, value+unit, date, trailing mini
   trend) per board using seeded markers.
6. Rhythm: populated Poincaré (2 pt dots, `inset` plot), SD1/SD2/nRMSSD stat row,
   "Regularity: Steady" line per board.
7. Test tools screen (board's "Alarms" panel is actually diagnostics — render
   quirk): keep 002's Alarms + Test Centre structure; no change beyond craft
   acceptance.

## Global craft sweeps (any screen)

- Icon audit: replace every multicolor filled SF Symbol outside status dots with
  ink line variants (`.symbolRenderingMode(.monochrome)`, weight-matched).
- Baseline audit: value+unit pairs align to one baseline per card.
- Copy audit: no duplicated strings on-screen; no dev-speak labels ("Phase 1").
- Collision audit at XL type on every reworked screen.
