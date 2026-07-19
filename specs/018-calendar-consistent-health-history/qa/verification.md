# Calendar-Consistent Health History Verification

## Source provenance

- Branch: `codex/strain-v2-surface-consistency`
- Starting commit: `33502829d9a82163a353da2efe4d802aef510077`
- Installed implementation commit: `2736a83d379cc289c739a8b04e1ea90c5e5c8b04`
- Checkout: `projects/Noop-calendar-fix` (source ledger) and `/private/tmp/Noop-calendar-fix` (hydrated build lane)
- Bundle: `com.eastonplace.noop`, version `9.0.1 (204)`
- Signed artifact: `/private/tmp/noop-calendar-release/Build/Products/Release-iphoneos/NOOP.app`

## Verification log

| Date | Gate | Result | Evidence |
|---|---|---|---|
| 2026-07-19 | Source provenance | PASS | Fresh filtered clone of remote PR #5 branch at starting commit above. |
| 2026-07-19 | iCloud safety gate | PASS | `.git` became `compressed,dataless`; implementation/testing moved to a fresh `/private/tmp` clone at the same commit. Canonical `main` and `Noop-reconcile` were untouched. |
| 2026-07-19 | Calendar contract | PASS | 11/11 focused tests: Sunday slot, gaps, missing today, exact yesterday, DST/month boundaries, fixed domain, real-date position, weekday means. |
| 2026-07-19 | StrandDesign | PASS | 66/66 tests. |
| 2026-07-19 | StrandAnalytics | PASS | 1,110/1,110 tests; one pre-existing expected failure remains expected. |
| 2026-07-19 | Generic iPhone integration | PASS | Clean Debug `generic/platform=iOS` build with signing disabled. |
| 2026-07-19 | Week header regression | PASS | July 19, 2026 is pinned to Monday July 13 through Sunday July 19. |
| 2026-07-19 | Signed Release | PASS | Clean Release from `2736a83`; TeamIdentifier `QDJ575GGH4`, bundle `com.eastonplace.noop`, version `9.0.1 (204)`. |
| 2026-07-19 | In-place install and launch | PASS | Installed over the existing bundle on connected iPhone 17 Pro and launched successfully. No uninstall, reset, migration, or demo seed. |
| 2026-07-19 | Remote provenance | PASS | Implementation commit pushed to the existing unmerged PR #5 branch. |
| 2026-07-19 | Sunday Strain visual QA | PASS | Installed phone shows `Sun, Jul 19`; Monday-Saturday are empty and the 6.2 reading is attached only to the second `S`. Evidence: `outputs/2026-07-19/qa/noop-calendar-history/assets/strain-sunday-jul-19.jpeg`. |
| 2026-07-19 | Trends header/chart visual QA | PASS | Installed phone shows `Jul 13 — Jul 19`; M chart spans `Jun 20` through `Today`. Evidence: `outputs/2026-07-19/qa/noop-calendar-history/assets/trends-jul-13-19.jpeg`. |
| 2026-07-19 | Trends weekday-range visual QA | PASS | W/M/3M/6M visibly switch to Last 7/30/90/180 calendar days; chart starts update to Jul 13/Jun 20/Apr 21/Jan 21. Evidence includes `outputs/2026-07-19/qa/noop-calendar-history/assets/trends-weekday-last-30.jpeg`. |

## Remaining gates

- Missing-today Recovery could not be reproduced with the phone's current real data; deterministic missing-today/middle-gap tests pass. No data was changed or seeded to manufacture that state.
