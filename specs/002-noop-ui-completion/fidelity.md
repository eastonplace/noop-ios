# 002 — Reference Fidelity Audit (evidence baseline: 2026-07-09/10 QA screenshots)

> Evidence sources: `specs/001-concept-ui-reskin/qa/*.png|jpg` (per-task, T02–T27) and the
> repo-root `qa/T11–T21*.jpg` folder (Codex's later per-task shots — consolidate both into
> `specs/002-noop-ui-completion/qa/` during T31). References: `specs/001-concept-ui-reskin/references/`.
> Fidelity scale: Low · Partial · Directionally aligned · Close · High.
> NOTE (2026-07-10): spec C13 (WHOOP color logic) was adopted AFTER this audit — where
> rows below mention pillar colors (purple strain, static green recovery), the C13
> targets now apply: Recovery banded green/yellow/red by value, Strain constant blue,
> Sleep slate-blue. Layout/proportion judgments are unaffected.

## Screen-by-screen comparison

| Screen | Ref | Current fidelity | Reference intent vs current | Major differences | Shared or screen-specific | Required direction |
|---|---|---|---|---|---|---|
| Today (S1) | 1-1, 3-1 | **Directionally aligned** | Ref: dense glanceable dashboard, small thin trio rings, compact 3×2 vitals grid. Current: oversized rings (~90 pt, heavy stroke, 44 pt+ numerals), vitals tiles rendered as big nested cards ~3× reference size and cut off, chunky ~24 pt stress blocks vs ~8 pt strip | Trio proportions; health-monitor density; stress bar height; header icon cluster (red-dot/bell/avatar not in ref); big top gap | Both — ScoreRing + MetricTile sizes are shared; Today's grid/columns are screen-specific | Rebuild trio + vitals grid to §2.4/001-§6-S1 dimensions; fix header |
| Trends (S2) | 1-2 | **Directionally aligned** | Ref: numbers carry pillar color, labels neutral; compact chart w/ day+date axis. Current: labels colored + numbers black (inverted); 3–4 pt chart lines; axis "S M M T T W" | Color-role inversion on tiles; line weight; axis labeling; top gap | Both | Swap tile color roles; 2 pt lines; day+date axis labels |
| Sleep (S3) | 1-3 | **Directionally aligned** | Ref: hero ring + marks card + clean floating-bar hypnogram + asleep/woke row. Current: hero ✓, but "TAP TO LOG / Sleep marks" legacy section pattern, WHOOP pill + "of 100" clutter in hero, hypnogram is blocky steps on gray tracks | Sleep-marks card doesn't match ref; hypnogram rendering; pills/sublabels | Both — Hypnogram is shared; marks section is screen-specific | Restyle marks into a PaperCard; rebuild Hypnogram bars; strip pills/"of 100" (C6/C7) |
| Live (S4) | 1-4 | **Close** | Layout matches: device card, black scan button, HR ring + zone column, physiology card | Legacy "ADVANCED CONTROLS / RECORD…" sections use old header pattern; stacked chevron-above-wordmark header | Screen-specific + header shared | Card-wrap advanced sections; single-row header |
| Workouts (S5) | 1-5 | **Close** | Score card, recent list w/ effort badges, zones+splits split row all present | Stray "↓" icon; effort badges show 0–100 values (37.3 "of 100" world); stacked header; splits sparse | Screen-specific | Strain 0–21 badges (C2); header; polish |
| Devices (S6) | 4-1 | **Directionally aligned** | Ref: minimal rows (name, badge, battery %, signal). Current: correct skeleton but 3× text density (capability lists, footnotes), mixed "Strain/Effort" copy in one card | Density; terminology inconsistency | Screen-specific | Compress rows to ref density; move prose to a detail/disclosure; C1 naming |
| Add Device (S7) | 4-2 | **Close** (T19 shot) | Matches option-list pattern | — minor spacing | — | Nit pass only |
| Data Sources (S8) | 4-3 | **Close** (T20 shot, earlier T04/T06 iterations converged) | Matches | — | — | Nit pass |
| Backup & Sync (S9) | 4-4 | **Close** (T21 shot) | Matches | — | — | Nit pass |
| Settings (S10) | 4-5 | **Close** | Profile card generic ("Your profile / Age 30") vs ref name+member-since; grouping ✓ segmented ✓ | Profile presentation; missing "First day of week" row placement TBC | Screen-specific | Align profile card; verify all rows survived |
| Support (S11) | 4-6 | **Close** (T22 shot) | Matches | — | — | Nit pass |
| Insights (S12) | 5-1 | **High** | Chips, associations, With/Without, insight card, how-it-works all match | Duplicate tagline rendered twice (overline row + title block) | Screen-specific | Remove duplicate caption |
| Lab Book (S13) | 5-2 | **Close** (T24 shot) | Matches incl. empty states | — | — | Nit pass |
| Rhythm consent/Rhythm (S14/15) | 5-3/4 | **Close** (T25 shots) | Matches | — | — | Nit pass |
| Automations (S16) | 5-5 | **Close** (T26 shot) | Matches | — | — | Nit pass |
| Alarms (S17) | 5-6 | **Close** (T26 shot) | Matches | — | — | Nit pass |
| Test Centre (S18) | 5-7 | **Close** (T26 shot) | Matches | — | — | Nit pass |
| Quick Actions (S19) | 5-7 overlay | **Close** | Rows/icons/copy match | Workout icon tint purple vs ink (spec said ink) | Shared sheet | One-line tint fix |
| Charge→Recovery detail (S20) | 3-2 | **Close** | Hero/triplet/chart/factors/recommendation all match | "of 100" sublabel; sparse "S…S" axis | Shared (new detail skeleton in CoupledView) | C6; axis labels; C1 rename |
| Effort→Strain detail (S21) | 3-3 | **Close** (T13 shots) | Skeleton matches | 0–100 world throughout → must become 0–21 (C2) | Shared skeleton | C2 rescale ring/axis/thresholds |
| Rest→Sleep detail (S22) | 3-4 | **Close** (T14 shot) | Skeleton matches | C1 rename; hypnogram shared fix applies | Shared | C1, hypnogram |
| Stress detail (S23) | 3-5 | **Close** (T14 shot) | Skeleton matches, 0–3 scale ✓ | — | — | Nit pass |
| Pre-run (S24) | 2-1 | **Partial** (T17 shot) | Ref: type selector, route card, last workout, setup rows, black start | Not fully inspected in this audit — verify against ref; setup rows may be thinner than ref | Screen-specific | T31 re-shoot + gap list |
| Live run (S25) | 2-2 | **Partial** | Ref: timer + 3×2 grid + map + HR chart + lock/Pause/Finish. Current: grid/map/HR ✓ w/ honest empty states, but **no Pause button** (only red "End workout"), timer under-sized, header wordmark left-aligned | Missing pause/resume; control row layout; timer scale | Screen-specific | C9 pause control; 64 pt timer; centered wordmark |
| Paused run (S26) | 2-3 | **Unverified** | No screenshot exists (no pause state exists!) | Splits card + Resume/Finish unverified | Screen-specific | Depends on C9 |
| Post-run (S27) | 2-4 | **Close** | Hero/stats/save all match; honest no-HR note | "of 100" (C2/C6); zones+route cards absent when no data — verify with data | Screen-specific | C2 strain hero; verify zones/route with seeded data |

## Cross-cutting visual defects (shared-component level)

1. **Top gap / header stack** — Today & Trends: wordmark floats far below the Dynamic
   Island; pushed screens (Live, Workouts) stack a floating chevron circle ABOVE the
   wordmark row, burning ~130 pt. Reference: ONE header row, chevron inline-left,
   wordmark center, icons right, tight to safe area. Causes to fix centrally:
   `ScreenScaffold.swift:43` `.padding(.top, 24)` + per-screen custom header stacks +
   Today's icon cluster row. (C4)
2. **Ring proportions** — trio rings render ~90 pt/heavy stroke vs spec 64 pt/5 pt; hero
   rings carry "of 100" sublabels the reference doesn't have. (C5/C6)
3. **Source pills** — "WHOOP" capsules inside hero cards aren't in any reference. (C7)
4. **Density** — MetricTile renders as a bordered mini-card ~3× reference size (Today
   vitals); Devices rows carry 3× reference text. (C5)
5. **Chart weight** — lines 3–4 pt vs 2 pt; axis labels sparse single letters. (001 §4)
6. **Terminology drift already visible** — Devices card mixes "Strain" and "Effort" in
   adjacent lines. (C1)

## Verified-good (do not regress)

Paper palette + dark scheme render coherently (T27 shots); tab bar + FAB + Quick Actions
match; More list clean; Insights/Lab Book/Rhythm/Automations/Alarms/Test Centre/Data
Sources/Backup/Support/Settings all Close-or-better; honest empty states throughout
(Live HR "Waiting", GPS "Waiting for GPS route", no-HR-samples note); real data binding
via repository with opt-in demo seeder (no mock leak found).
