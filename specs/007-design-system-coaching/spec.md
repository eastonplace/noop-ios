# Spec 007 — The Real Design System + Coaching

> Seventh pass, and a correction of course. "Paper" was the executor's coinage
> (spec 001), never Easton's — and grading against it produced a build that
> reads DEAD next to Easton's actual design system. That system now exists as
> an explicit spec: the **LOOP Component Library board** (iOS Design System
> v1.0) plus the **5-screen coaching sheet**, both in `references/`. This pass
> (a) re-bases every token and shared component on the library VERBATIM, and
> (b) builds the coaching/check-in system the journal was always meant to be.
> The name "Paper" is retired; the system is just the NOOP design system.

## References (Easton must drop both boards in)
- `references/component-library.png` — LOOP Component Library, iOS Design
  System v1.0 (typography, spacing, radius, color, rows, controls, chips,
  menus, alerts, cards, nav, sheets, dialogs).
- `references/coaching-sheet.png` — 5 screens: Coaching Root, Evening
  Check-In, Coaching Behavior Settings, Quick Add Behaviors,
  Supplement/Medication Stack Detail.

## G-rulings

- **G1 — The component library is canonical, verbatim.** Token rebase, exact
  values from the board (board wins over every prior D/F sizing ruling):
  - Type: LargeTitle 34/40 bold · Title1 28/34 semibold · Title2 22/28
    semibold · Body 17/24 regular · Caption1 13/18 · Caption2 11/16 ·
    OVERLINE 11/14 semibold. (This reverses parts of D12: body 15→17,
    overline 9.5→11 semibold. Data-loudness F1/F2 outcomes are kept where
    they exceed the board.)
  - Spacing scale 4/8/12/16/20/24/32/40/48/64; margin 20; row 56; gap 18;
    button radius 22; button height 56; nav bar 76.
  - Radius scale 8/12/16/20/22/28/32.
  - Color: textPrimary #000000 · textSecondary #666666 · border/divider
    #ECEBE7 · background #F7F6F3 · surface #FFFFFF · success #16C784 · info
    #2D8CFF · warning #FFB020 · error #FF3B30 · stress #FF8A00. Divider 1px
    @8% black. Card shadow y2 blur8 @10% — REAL shadows, not the 4% ghost.
  - Components to the board's specs: settings rows (56pt, chevrons, value
    slots, destructive red row), **black toggles** (replaces green), buttons
    (black filled primary 56/r22, outlined secondary, icon buttons, black
    FAB), status chips (Connected/Queued/Not connected/Success/Blocked/Live
    styles verbatim), dropdowns compact+expanded, overflow menus, segmented
    picker, notification badges, status dots, tiny metric badges (+1.2),
    banners/toasts (warning/success/error with ✕), inline alert rows, sheet
    handle, routine picker rows, compact form fields, confirmation dialog,
    action sheet, nav-bar selected states.
- **G2 — Color domains.** The library's semantic colors (success/info/
  warning/error/stress) are global. BUT pillar/metric data keeps the WHOOP
  grammar and hexes (C13/C14/F3/F4 stand: banded Recovery, Strain blue
  #0093E7, Sleep slate, zone ramp, no-color-text). The board's #7C4DFF purple
  is NOT strain — it maps to **`journalAccent`: the coaching/journal domain
  accent**. Coaching surfaces carry the purple tint per the coaching sheet
  (check-in ring, primary coaching buttons, chips, icons); data surfaces
  never do. The board's "12.4 STRAIN purple" tile is understood as LOOP-app
  naming; in NOOP that ring family renders per WHOOP grammar.
- **G3 — Coaching system, built on the existing journal engine.** The
  5-screen sheet is the product spec; existing journal behaviors
  (alcohol/caffeine/late meal/… with Yes/No semantics feeding What Moves
  You) are the data foundation. Build:
  1. **Coaching Root** — today's check-in card (progress ring, "N of M
     logged", Continue Check-In primary), Shortcuts (Repeat yesterday,
     stacks with status dots, Edit), Quick Add chip grid (+ More), Recent
     Entries with honest empty state.
  2. **Check-In flow** — progress header with % ring, "Saved locally" note,
     collapsible groups (Sleep setup / Fuel / Training & activity /
     Recovery & stress / Supplements & medication) mixing toggles,
     steppers (−/n/+), and hour/quantity counters; Cancel/Save.
  3. **Behavior Settings** — active behavior-set card + Change Set, Add
     custom behavior, reorderable behavior list (drag handles) with ACTIVE
     and QUICK ADD toggle columns, footer explainer.
  4. **Quick Add** — search, tile grid (icon/name/category/Add), View all.
  5. **Stack detail** — Active chip, Preset·Daily meta, description, item
     checklist with doses, Last used, Notes, black Log Stack, Skip for now.
- **G4 — Data integrity constraints for G3.** Additive only: behavior sets,
  stacks, quick-add prefs, and quantity metadata are NEW storage; existing
  Yes/No journal semantics and the associations pipeline (What Moves You)
  must be provably unchanged (same inputs → same associations; integration
  test required). Quantity logging (counters/steppers) stores quantities as
  metadata while still deriving the boolean the engine consumes. No
  migration of existing journal rows.
- **G5 — Entry points ("hook the journal tab into coaching" — Easton).**
  NOOP's tab bar is UNCHANGED (Today/Trends/⊕/Sleep/More). Every existing
  journal entry point routes to Coaching Root: FAB "Log journal" quick
  action, Insights "Journal" chip, any journal cards, More row if present.
  The old single-card journal remains reachable as the Check-In flow's
  quick path, not deleted.
- **G6 — Gates.** 005-style: T130 audit gate first (journal-engine
  inventory: what exists vs what the sheet needs — additive schema list
  reviewed BEFORE building), token/component rebase as one batch with one
  full-app re-shoot gate ("deadness check" — the board's shadows/type/
  toggles visibly present), coaching screens in two-screen gates with
  full-page + interaction evidence, integration proof (log → persist →
  relaunch → associations intact), final side-by-side against BOTH boards.

## Tasks (T130–T139)

- [x] T130 — Gate: tag `pre-007`; drop both reference boards in; journal
  engine audit (existing behaviors/storage/associations mapped vs sheet
  needs; additive-schema proposal). STOP for review.
- [x] T131 — G1 token rebase (type/spacing/radius/color/shadow/divider).
- [x] T132 — G1 component rebase (toggles, buttons, chips, rows, banners,
  menus, dialogs, nav 76, badges) + absorb pending T126a items.
- [x] T133 — GATE: full-app re-shoot, deadness check vs the board.
- [ ] T134 — Coaching Root + G5 entry-point rewiring.
- [ ] T135 — Check-In flow (groups, steppers, counters, save/cancel).
- [ ] T136 — Behavior Settings + Quick Add grid. GATE (with T134/T135).
- [ ] T137 — Stacks (additive storage + detail screen + shortcuts wiring).
- [ ] T138 — G4 integration proofs + tests (associations unchanged; quantity
  metadata round-trips; relaunch persistence).
- [ ] T139 — GATE: final evidence — full-page set + side-by-side vs the
  coaching sheet AND spot-pairs vs the component library. External review.
