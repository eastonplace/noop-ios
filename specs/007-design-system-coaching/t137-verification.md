# T137 — Coaching stacks

## Shipped

- Added the approved additive `coachingStack`, `coachingStackItem`, and
  `coachingStackUse` tables. No quantity/provenance duplicate was introduced.
- Added a persisted Daily preset and wired Coaching Root's Stacks shortcut to
  its detail surface.
- Stack detail matches sheet panel 5: Active state, Preset · Daily metadata,
  description, dose-aware checklist, Last used, Notes, primary Log Stack, and
  Skip for now.
- Logging checked items calls the existing journal APIs with immutable
  canonicals. Positive doses call `saveJournalNumeric`; ordinary occurrences
  call `saveJournalAnswer`; the stack-use row is provenance only.
- The two T136 carry-alongs are closed: Coaching Root's ring displays percent,
  and Quick Add renders compact catalog names while retaining canonical storage
  keys and canonical-aware search.

## Evidence

- [Stack detail — light](qa/t137/stack-detail-light.png)
- [Stack detail — dark](qa/t137/stack-detail-dark.png)
- [Coaching Root percent + Stacks shortcut](qa/t137/coaching-root-carry-light.png)
- [Quick Add short catalog names](qa/t137/quick-add-short-names-light.png)

## Verification

- `NOOPiOS` iPhone 17 Pro Max simulator build: succeeded.
- `CoachingStoreTests`: 3 passed, including table/config/item/use round trips
  and proof that reseeding does not overwrite user Active/Notes state.
- Light/dark screenshots were visually checked for library hierarchy,
  journalAccent containment, readable ink values, clipping, and overflow.
