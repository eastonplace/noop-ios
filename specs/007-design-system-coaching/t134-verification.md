# T134 — Coaching Root and journal entry points

## Shipped

- Coaching Root renders today's progress, Continue Check-In, Repeat Yesterday,
  honest stack state, Quick Add, recent entries, and the local-data note.
- Journal purple is isolated to coaching controls, rings, icons, and fills.
- Quick Add writes through `Repository.saveJournalAnswer` with the item's
  immutable canonical key.
- Repeat Yesterday reads the existing native boolean/numeric rows and replays
  them through `saveJournalAnswer` / `saveJournalNumeric`.
- FAB `Log journal`, Insights `Journal`, and the `--demo-screen journal` harness
  now route to Coaching Root. The classic journal remains reachable inside the
  root and is not removed.
- Today's stress value now uses the shared `TinyMetricBadge` component with a
  light semantic fill and ink value.

## Evidence

- [Coaching Root, light](qa/t134/coaching-root-light.png)
- Simulator: iPhone 17 Pro Max with `--demo-seed --demo-screen journal`.
- `NOOPiOS` simulator build: succeeded.
- No schema, storage, association, scoring, or tab-bar changes.
