# T138 — G4 integration oracles

All six T130-approved oracles run in `CoachingIntegrationTests` against the
real journal/store/ranker contracts.

| # | Oracle | Result |
|---|---|---|
| 1 | Imported/native collision merge before vs after coaching metadata | PASS — identical; native still wins the collision |
| 2 | Boolean Check-In write → recreate Repository → read canonical/day/answer | PASS |
| 3 | Positive quantity → recreate Repository → numeric + `answeredYes` | PASS — one `journal.numericValue` truth |
| 4 | Two checked stack items → journal occurrences + stack provenance | PASS — 2 occurrences, exactly 1 use row |
| 5 | EffectRanker fixture before vs after coaching metadata | PASS — full `RankedEffect` arrays equal, pinning effects, lags, means, samples, confidence, and order |
| 6 | Clear native collision while imported source remains | PASS — imported row remains readable and merged |

## Implementation seam

`Repository.logCoachingStack` centralizes the approved stack semantics. It
fans checked items through the existing `saveJournalAnswer` /
`saveJournalNumeric` APIs and writes one `coachingStackUse` provenance row.
The detail screen calls this same tested path. Skips write provenance only.

## Regression verification

- Focused `CoachingIntegrationTests`: all 6 passed on iPhone 17 Pro Max.
- Complete supported `NOOPiOSTests` target: passed.
- `WhoopStore`: 232 passed, 0 failures.
- `StrandAnalytics`: 954 passed, 0 failures.
- No scoring, association, merge, day-key, or canonical-string implementation
  changed.
