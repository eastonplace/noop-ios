# T136 — Coaching configuration + combined gate

## Shipped

- Behavior Settings now exposes the active behavior set, Add custom behavior,
  reorder controls, and independent Active / Quick Add preferences.
- Quick Add now provides search, the configured tile grid, per-item Add state,
  and View all.
- The approved T130 set/membership split is implemented as additive SQLite
  storage. Membership stores only presentation and preference state:
  `coachingGroup`, `sortIndex`, `isActive`, and `isQuickAdd` keyed by the
  immutable canonical journal question.
- No coaching quantity table or second quantity truth was added. Check-In
  quantities continue through `Repository.saveJournalNumeric`; boolean Quick
  Add writes continue through `Repository.saveJournalAnswer`.
- The T133 carry-along is closed: Today's stress value uses the component
  library's light, quiet `TinyMetricBadge` treatment instead of a dark pill.

## Full-page evidence

### T134 — Coaching Root

- [Light](qa/t134/coaching-root-light.png)
- [Dark](qa/t136/coaching-root-dark.png)

### T135 — Check-In

- [Light](qa/t135/check-in-light.png)
- [Dark](qa/t136/check-in-dark.png)
- [Interacted state](qa/t135/check-in-interaction.png)
- [Post-save/relaunch root](qa/t135/check-in-persisted-root.png)

### T136 — Behavior Settings

- Light: [page 1](qa/t136/behaviorsettings/page-1-light.png) ·
  [page 2](qa/t136/behaviorsettings/page-2-light.png)
- Dark: [page 1](qa/t136/behaviorsettings/page-1-dark.png) ·
  [page 2](qa/t136/behaviorsettings/page-2-dark.png)

### T136 — Quick Add

- [Light](qa/t136/quickadd/page-1-light.png)
- [Dark](qa/t136/quickadd/page-1-dark.png)
- [Preference persistence proof](qa/t136/quickadd/preferences-persisted-light.png)

## Interaction proof

- On iPhone 17 Pro Max, Quick Add's `Did you feel stressed?` Add control was
  exercised and changed to Added through the existing journal occurrence API.
- In Behavior Settings, Alcohol's Quick Add preference was disabled. After
  terminating and relaunching the app, the Alcohol tile remained absent from
  Quick Add, proving the new membership preference persisted independently of
  journal history.
- T135 quantity + boolean writes were saved, followed by terminate/relaunch;
  Coaching Root reloaded the native occurrences and `N of M` progress.
- Reorder controls expose Move Up / Move Down with disabled end states; Active
  controls Check-In membership and Quick Add controls only shortcut visibility.

## Verification

- `WhoopStore`: 231 tests passed, 0 failures, including behavior-membership
  order/flag round trips and the default-seed-does-not-reset-preferences case.
- `NOOPiOS` iPhone 17 Pro Max simulator build: succeeded.
- Light and dark captures were visually checked for Paper component-library
  hierarchy, journalAccent use, readable values, clipping, and overflow.

## Gate

T134, T135, and T136 are ready for the combined external review. T137 has not
started.
