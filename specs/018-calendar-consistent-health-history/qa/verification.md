# Calendar-Consistent Health History Verification

## Source provenance

- Branch: `codex/strain-v2-surface-consistency`
- Starting commit: `33502829d9a82163a353da2efe4d802aef510077`
- Current release candidate: `fc8c95056142139e8bebc6a2ac8b3e968cb69f46`
- Most recently installed implementation commit: `46886a9f7565651efe8f12f058b988be2cc9b0c4`
- Checkout: `projects/Noop-calendar-fix` (source ledger) and `/private/tmp/Noop-calendar-fix` (hydrated build lane)
- Bundle: `com.eastonplace.noop`, version `9.0.1 (204)`
- Signed artifact: `/private/tmp/noop-calendar-alignment-fc8c950-derived/Build/Products/Release-iphoneos/NOOP.app`

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
| 2026-07-20 | Canonical Strain alignment follow-up | PASS | `46886a9` unions canonical V2-only days into the shared dated presentation, reruns only source-backed V2 history, styles only the real current weekday/current heatmap date, and uses exact 7/30/90/180-day headings. No Strain V1 rollback or imported-score relabeling. |
| 2026-07-20 | Exact-day Trends inspection | PASS | `fc8c950` changes the range chart and five-week heatmap to press-and-drag over fixed calendar slots. A touched gap reports its real date and `No data` rather than snapping to a neighboring observation. Focused coverage is 15/15. |
| 2026-07-20 | Full regression | PASS | StrandDesign 70/70, StrandAnalytics 1,110/1,110, WhoopStore 276/276. |
| 2026-07-20 | Clean signed Release | PASS | Fresh DerivedData tied to `fc8c950`; bundle `com.eastonplace.noop`, version `9.0.1 (204)`, TeamIdentifier `QDJ575GGH4`. Build completed with 46 pre-existing warnings and no compile/sign errors. |
| 2026-07-20 | Final in-place install and launch | PASS | The signed `fc8c950` Release installed over `com.eastonplace.noop` and launched as PID `57339`. No uninstall, reset, migration, or demo seed occurred. |

## Remaining gates

- Missing-today Recovery could not be reproduced with the phone's current real data; deterministic missing-today/middle-gap tests pass. No data was changed or seeded to manufacture that state.
- Easton hands-on QA remains: confirm the chart and heatmap tooltips on both a scored day and a missing day, plus Strain/Trends date alignment on current phone data.
