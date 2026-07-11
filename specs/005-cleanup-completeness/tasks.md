# Tasks 005 — Cleanup & Completeness (T100–T112)

> Rules: `~/Code/noop-completion`, commit `clean(T###): …` per task, push to
> `private-noop-report`, evidence per spec E5 (FULL-PAGE captures —
> `qa/<screen>/page-N.png`), STOP at gates marked GATE. iPhone 17 Pro Max sim,
> `--demo-seed`. Never build from the iCloud path.

## Phase A — Audit (produce the table before touching UI)

- [x] **T100 — Gate + audit scaffolding**: tag `pre-cleanup`; create
  `audit.md` with one row per screen/sheet/tool (enumerate from
  `Strand/Screens/*.swift` + StrandiOSApp routes + More list + FAB sheet +
  settings rows). Columns: full-page evidence links · Paper-conformant? ·
  duplication? · tap-through result · reachable from? · action needed.
- [ ] **T101 — Full-page capture sweep**: seeded sim, capture EVERY screen
  full-scroll (E5 protocol; use the demo-screen routes + in-app navigation for
  sheets/editors). Fill the evidence column. GATE — this is the "where are we
  actually" artifact Easton asked for; deliver the table before proceeding.
- [ ] **T102 — Tap-through audit**: walk every screen tapping every control
  once; log works/dead/misroutes. Include: ScoringGuide close (known dead via
  CoupledView:932), every onClose/onAccept callback site (grep list in spec
  §B2), toggles persist after relaunch, links route correctly. GATE.
- [ ] **T102b — Interaction-parity diff (E6)**: per reskinned screen, diff
  pre-reskin NavigationLink/tap destinations vs current (script the grep over
  `git show pre-paper-reskin:<file>`); list every lost tap-through in the audit
  table. Known-lost: Today Live-HR card → FullDayChartView. GATE (list reviewed
  before restoration work).
- [ ] **T103 — Reachability matrix**: `git show pre-paper-reskin` More
  list/routes vs current; list lost entry points + code-orphans. GATE (any
  proposed retirement goes to Easton via the gate — never silently dropped).

## Phase B — Dedupe & relocation (per Easton rulings E1–E3)

- [ ] **T104 — Workouts history Paper pass (E1)**: keep history below the tab;
  restyle `sessionsSection` fully (paper search/chips/rows, kill any remaining
  liquid module); features intact (add, filters, search, per-row nav). Full-page
  proof. GATE.
- [ ] **T105 — Live→Test Centre move (E2)**: relocate Signal Trust + record/
  inspect tools into Test Centre as Paper sections; exercise record + inspect
  flows before AND after (screen recordings or step logs); Live keeps reference
  content. GATE.
- [ ] **T106 — Trends legacy builders**: find callers of the pip
  `weekInReview`/`NoopCard` blocks; delete if orphaned (all platforms) else
  Paper-restyle the macOS path. No double week-review anywhere.
- [ ] **T107 — MetricDetailView full alignment** + Explore catalog screen pass.

## Phase C — Dead controls + coverage

- [ ] **T107b — Deep Timeline restore (E6 exemplar)**: Today Live-HR card
  taps through to `FullDayChartView(.hr)` (port the pre-reskin wiring);
  FullDayChartView gets the Paper chrome pass (tokens/header/cards ONLY — the
  zoom/pan/timelineSeries machinery is untouched); every other lost interaction
  from T102b restored the same way: copy original wiring + destination, Paper
  the chrome. Full-page + interaction proof (zoom/pan exercised in-sim). GATE.
- [ ] **T108 — Dead-control fixes**: everything T102 logged. Known: ScoringGuide
  onClose (dismiss-on-push fix) + its stale 0–100/Effort copy + `.charge`
  section ids. Re-tap-through to verify. GATE.
- [ ] **T109 — Coverage refresh wave 1** (worst offenders from T101, spec §C
  list): each screen brought fully onto Paper, full-page proof per screen.
  Batch gates every 3–4 screens.
- [ ] **T110 — Coverage refresh wave 2**: remainder of §C incl. onboarding +
  editor sheets. Same protocol.

## Phase D — Hygiene + handoff

- [ ] **T111 — Tests + dead code + strings**: fix WeeklyDigest "Charge"
  assertion + T81 proportion test to current rulings; delete proven-orphan
  legacy code (call-site proof in commit message); xcstrings stale-term/dead-key
  sweep (all languages). Suite green.
- [ ] **T112 — Evidence + PR update**: regenerate full-page contact set,
  fidelity.md "complete & clean" column, update the audit table to final state,
  push, summarize for Easton's next alignment.
