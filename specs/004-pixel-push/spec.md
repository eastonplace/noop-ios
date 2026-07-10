# Spec 004 — Pixel Push (typography step-down + module rebuilds)

> Fourth pass. 001 = system, 002 = structure/metrics, 003 = craft round 1.
> Diagnosis for this pass (from side-by-side of 003 proofs vs the five reference
> sheets): the build reads "nothing like" the references not because modules are
> missing but because **every type role and density metric sits one notch larger
> and heavier than the reference**. The refs are small-type / hairline / airy;
> the build is medium-type / semibold / chunky. Fix the scale globally, then
> rebuild the three modules whose composition is still wrong (Stress, Live HR,
> pre-run). Rulings D1–D11 + C13/C14 stand. Tasks: `tasks.md` (T80–T88).

## D-rulings (new)

- **D12 — Global type/density step-down.** Exact new values (old → new):
  - `sectionOverline` 11 → **9.5 pt**, tracking +1.2 → +1.4, weight semibold →
    **medium**, color `textSecondary` → `textTertiary`.
  - `screenOverline` 12 → **10.5 pt**, weight → medium.
  - Chart/axis `micro` where used as axis labels: 11 → **9 pt** (add `axisLabel`
    role; do NOT shrink body-copy micro).
  - Card state words (stress "Low", trio "Good/Moderate"): cardTitle/body →
    **caption (13 pt)** for stress, **micro (11 pt)** for trio state words.
  - Ring numerals: trio 30 → **26 pt semibold**; ring stroke 5 → **4 pt**; ring
    tracks = accent at **10% opacity** (not gray inset — refs show tinted tracks).
  - List/factor rows: minHeight 48 → **40 pt**; icon circles 30 → **24 pt** with
    13 pt glyphs; row values captionNumber stays.
  - Badges (stress value, status): height 22 → **18 pt**, 11 → 10 pt label.
  - Card padding 16 stays; intra-card spacing 12 → **10**.
  Apply at the token/component level (Typography.swift, NoopMetrics,
  PaperComponents) — never per-screen literals. Every reference screen re-shot
  after.
- **D13 — Stress module rebuild v2 (third attempt — match sheet 1-1 exactly).**
  Layout top→bottom: ONE header row [8 pt amber status dot + "TODAY'S STRESS"
  sectionOverline + Spacer + value badge (18 pt capsule, stress tint bg, 10 pt
  semibold amber text)]; state word ("Low") 13 pt regular `textSecondary` on its
  own line; 4 pt continuous ribbon (mixed band colors, rounded, bare track for
  unscored hours); axis row 12AM·6AM·12PM·6PM·12AM in 9 pt `textTertiary`.
  Nothing else. No cardTitle-sized state word, no 6 pt bar, no 11 pt axis.
- **D14 — Zone rows show bpm ranges** (sheet 2-4: "Z5 (161+ bpm)"), colors per
  C14. Compute ranges from the user's max HR (the zones engine already buckets
  by these thresholds — surface its boundaries); fall back to %-of-max labels
  when max HR is unknown. Label format: "Z5 (161+ bpm)" 10 pt medium
  `textSecondary`, % zone-tinted, duration right, bar beneath.
- **D15 — Run flow per original sheet 2 (D11 confirms original wins).**
  Pre-run rebuild: title "Run / Outdoor workout"-style header from the chosen
  sport + GPS Ready / Route-saving badges (only if GPS available), RUN TYPE
  segmented cards (map to the existing sport types), LAST WORKOUT card (ring +
  name/date/stats — data exists), RUN SETUP rows (existing settings only),
  black Start button. Recent-route card ONLY if stored routes exist (no new
  storage). Live run: the **map returns** (sheet 2-2; board-v2's maplessness is
  overridden by D11) between the stats grid and HR chart; HR chart gets the
  ref's soft gradient underfill (≤ 12% alpha fade); controls stay engine-honest
  (C9: lock + red-outline End workout — no fake Pause).
- **D16 — Status words return with REAL bands.** Key-factor/contributor rows
  regain colored status words computed from data (this replaces 003's
  hidden-until-computed state): HRV & RHR vs the user's own 7-day baseline
  (>+5% HRV = Good green / within ±5% = Steady textSecondary / worse = amber-red
  by deviation; RHR inverted), Sleep performance ≥85 Good / ≥70 Fair / else Low,
  Resp rate & skin temp within-normal windows = Good, strain contributors banded
  by zone thresholds (Avg HR ≥85% max = High red, etc.). Baselines already exist
  in the analytics layer (StressModel/AnalyticsEngine use them) — reuse, never
  invent constants without citing the engine source. Any metric with no baseline
  renders value-only (003 behavior) — never a made-up word.

## Acceptance

1. Side-by-side vs sheets 1-1/3-x: a reviewer cannot pick the build out by type
   weight — overlines, state words, axis labels, badges match the refs' optical
   size within a point.
2. Stress module passes Easton's eye (third strike — treat sheet 1-1's module as
   a literal mockup).
3. Zone rows read "Z5 (161+ bpm)" with C14 colors on strain detail, workout
   detail, post-run, Workouts.
4. Pre-run and live-run match sheet 2-1/2-2 composition (minus Pause per C9,
   minus route card when no route data).
5. Status words on detail rows are computed, cited (code comment → engine
   source), and band-colored; no hardcoded literals return.
6. Full evidence set re-shot; contact sheet regenerated; fidelity.md re-scored
   with a "type-scale" column.
