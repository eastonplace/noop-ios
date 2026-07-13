# Spec 006 — Loud Data (prominence, punch, and the no-color-text rule)

> Sixth pass, scoped by direct interview with Easton (2026-07-13). Diagnosis from
> the T112 side-by-side stack: the reference grammar is QUIET CHROME, LOUD DATA —
> D12 correctly quieted chrome but wrongly quieted data with it, light-mode
> colors were over-desaturated in the C13/C14 paper adaptations, and charts read
> lifeless. This pass executes as ONE batch with ONE gate. Prior rulings stand
> except where F-rulings below supersede.

## F-rulings

- **F1 — Reference-exact data loudness.** Data-primary type roles size to the
  reference sheets' proportions (≈2× current tile presence). Token-level:
  - `statValue` (Trends tiles, triplets) 20 → **32 pt bold**, tabular ink.
  - `metricValue` (stat grids) 24 → **28 pt bold**.
  - Health-Monitor tile values +4 pt; glance-row stats +2 pt.
  - Live-HR numeral → **34 pt**.
  - Chrome roles (overlines, captions, axis labels, badges) are UNCHANGED.
- **F2 — Rings grow with their numerals.** Trio 64→**72 pt** Ø (numerals 26→30
  semibold), hero rings 96→**104 pt** (numerals 44→48). Stroke +0.5 pt each to
  hold optical weight. Card layouts absorb the growth; no clipping at XL type.
- **F3 — True WHOOP hexes in BOTH modes for graphics.** The light-mode
  desaturated adaptations are retired. Rings, arcs, bars, ribbons, chart lines,
  underfills, chips, and badge fills use the exact WHOOP palette (C13/C14 dark
  values) on the paper canvas too. Single source: collapse each
  `Color(light:dark:)` pillar/zone graphic token to its WHOOP hex.
- **F4 — Color never carries text. Anywhere.** Values, deltas, and status words
  render in INK (or textSecondary per role); the color meaning moves into an
  adjacent graphic: band chip, ▲▼ glyph tint, dot, or fill. This supersedes
  every colored-numeral/colored-status-word pattern in the app (Trends tile
  values, deltas, factor status words, zone percentages, effect sizes, etc.).
  Sweep target: zero `foregroundStyle(<accent>)` on Text carrying data values
  in light mode. (Overlines/captions in textSecondary/tertiary are chrome, not
  color-as-text.)
- **F5 — Charts alive.** All trend/detail lines full-opacity **2.5 pt** (the
  55%-receded-line device is retired; series differentiate by hue + banded
  dots); hero-chart underfills 6% → **12–15%** gradient wash; chart heights
  180 → **230 pt**; day point-dots (4 pt) on Trends and pillar over-time charts
  ONLY (reference placement — not on sparklines). Demo seeder gains realistic
  biometric variance (jitter, spikes, recovery dips) so evidence charts wiggle
  like real data — sim-only as always.
- **F6 — Small items, one commit each, zero iteration:** Trends tiles flip to
  reference (metric name colored — as a colored NAME it is chrome-labeling, F4
  exempts pillar names used as labels; value big black ink); Week-in-Review rows
  get colored circular ✓/status badges (checklist per ref); Insight card always
  renders (next-distinct insight instead of hiding); viewport fill verified on
  Pro Max (no dead bottom third at default type) as a consequence of F1/F5, not
  via spacers.
- **F7 — One gate.** Everything lands as one batch. Acceptance artifact: the
  regenerated 8-pair side-by-side stack (Today, Trends, Sleep, Live, Workouts,
  Recovery detail, Strain detail, Insights) on a HEALTHY populated day (add
  `--demo-scenario healthy` as default; illness fixture becomes opt-in), light
  mode, plus a dark-mode strip. External review judges; merge/phone sequencing
  decided at the gate.

## Tasks (T120–T126, one batch, gate at end)

- [x] T120 — F1 type tokens + F2 ring scale (Typography/NoopMetrics/ScoreRing).
- [x] T121 — F3 palette collapse to true hexes for graphic tokens (both modes);
  contrast re-check for any graphic ON tinted fills.
- [ ] T122 — F4 no-color-text sweep app-wide (values→ink, meaning→chip/glyph/
  dot); includes deltas, factor words, zone %, effect sizes.
- [ ] T123 — F5 chart pass (weight, opacity, underfill, heights, ref-placed
  dots) + seeder variance.
- [ ] T124 — F6 small items (tile flip, ✓ badges, insight-always).
- [ ] T125 — healthy-day default scenario + full re-shoot: 8 light pairs +
  dark strip, regenerate side-by-side stack.
- [ ] T126 — GATE: external review of the stack. No PR until approved.
