# Widget stress completeness correction

## Confirmed defect and impact

**P1: a fixed 20,000-row prefix can exclude all waking-hour physiology from widget stress.** `WidgetSnapshot.verifiedStressInput` requested each source's entire civil day but capped both HR and RR at 20,000. `WhoopStore.hrSamples` orders ascending before `LIMIT`; the selected RR policy also orders ascending before its limit. At one HR row per second, a stream beginning at midnight reaches the cap at 05:33:19. `DaytimeStress` scores only 06:00–22:00, so an otherwise fully recorded day can produce no scored widget stress hours. Late RR is also omitted, changing HRV availability and potentially the stress result.

The read path is `WidgetSnapshot.verifiedDashboardStress` → `verifiedStressInput` → `WhoopStore.hrSamples` / `rrIntervals` → `DaytimeStress.analyze`. Stored physiology and collection are intact; the defect is loss of data from this consumer's input. The dense fixture reproduced it using the exact original helper and actual production SQL/read policy: HR/RR stopped at 20,000 and noon RMSSD was nil. The corrected helper returns HR 20,300 and RR 20,600, with noon RMSSD exactly 50 ms.

This finding arose while evaluating upstream stress commit [4d40dda7](https://github.com/ryanbr/noop/commit/4d40dda7f7bcabaf9c437c008d0b4bb9dbe2c12b), but it is a separate fork defect rather than a direct port of that commit. PR68's fetched head `a5e9c5c8ed050b5a476d5b6f15daa39cebb9b433` has no change to `WidgetPublish.swift` or `StressView.swift` relative to the audit base.

## Minimal fix and its proof

Changed `StrandiOS/Widgets/WidgetPublish.swift` only for production behavior:

1. Add `stressInputBounds(start:endExclusive:)`, which accepts only exact integral `Int` timestamps and uses overflow-reporting subtraction. Nonfinite, fractional, reversed, empty, and overflowing bounds fail closed with `CivilDayError.unrepresentableDate`.
2. Read HR with a limit equal to the actual number of seconds in the Gregorian civil-day window. This is a complete row bound: `hrSample` and `ppgHrSample` each have primary key `(deviceId, ts)`, while the production measured-first anti-join excludes a PPG row when measured HR exists for that second. The result therefore has at most one row per source per second. Calendar arithmetic supplies the window, so a 25-hour day retains all 90,000 possible seconds.
3. Read RR over exactly the same full-day window with `limit: Int.max`. RR's key `(deviceId, ts, rrMs, seq)` intentionally permits multiple distinct and equal beats at one timestamp; an HR-style count bound is invalid. There is no existing RR pagination/stream API in this fork. Narrowing windows to simulate pagination would change WHOOP 5's whole-window transport selection, and advancing by `last.ts + 1` could drop tied beats. The existing RR selection, order, provenance, and equal-beat handling remain unchanged.
4. Remove the unused arbitrary `limit` argument from this internal helper. Its only callers use the complete-day operation. Correct the nearby CPU-offload comment to describe dense full-day input rather than an obsolete fixed row maximum.

The verified source ordering, deduplication across sources, measured-first PPG fallback, whole-day WHOOP 5 transport choice, UTC-hour WHOOP 4 transport policy, stress formula, and sensor sampling rates are unchanged.

## Regression tests and executed evidence

Added three native cases to the existing `StrandiOSTests/PR29IOSSinkAndHealthKitTests.swift`:

| Test | Failure prevented |
| --- | --- |
| `testWidgetStressKeepsWakingHRAndRRBeyondDenseMidnightPrefix` | A 20,000-row overnight prefix hides a later covered midday hour and its 600 alternating RR beats. Checks complete counts and exact expected 50 ms RMSSD. |
| `testWidgetStressReadsAllSecondsOfTwentyFiveHourDay` | Fixed 24-hour/count assumptions omit the repeated DST hour. Checks all 90,000 HR rows, last-second equal RR beats and ordinals, and exclusion of rows outside the civil day. |
| `testWidgetStressRejectsInvalidOrOverflowingReadBounds` | Unsafe Double-to-Int conversions or overflowing duration arithmetic trap or misbound the query. Checks eight rejected invalid inputs and a valid 90,000-second window. |

**The native iOS XCTest cases were not run on Linux.** They remain required in Xcode/macOS CI. Both changed native files passed `swiftc -frontend -parse`; this is syntax evidence, not an app build result.

Executed an independent regression harness using:

- The exact before/after `verifiedStressInput` method, with the exact new bounds helper for the patched run.
- The exact production `WhoopStore.hrSamples` and `rrIntervals` methods and complete `RRReadPolicy` source, including the actual SQL and source-family classifier.
- Actual production `CivilDay`, `DaytimeStress`, `HRVAnalyzer`, `HRValidity`, `AnalyticsMemo`, and the local `WhoopProtocol` package.
- SQLite C with a small GRDB-compatible read facade. This substitutes database I/O plumbing only; it does not substitute the numerical kernels, SQL, source policy, or widget read implementation. Fixture schema mirrors the relevant keys/columns; full migrations and GRDB integration are not exercised.

| Harness check | Original method | Patched method |
| --- | --- | --- |
| Dense overnight prefix followed by waking data | **FAIL:** HR 20,000, RR 20,000, noon RMSSD nil | **PASS:** HR 20,300, RR 20,600, noon RMSSD 50 |
| Dense 25-hour day and equal late RR beats | **FAIL:** HR 20,000 | **PASS:** HR 90,000; both last-second RR beats and ordinals retained |
| Verified source order, duplicate source IDs, measured-first PPG | PASS | PASS |
| WHOOP 5 uses one transport for the full requested day | PASS | PASS |
| Invalid/nonfinite/reversed/overflow bounds | New helper | PASS: 8 of 8 rejected |

The original executable exited **1** with exactly the two expected completeness failures. The patched executable exited **0** with all five checks passing. The orchestration script exited **0** only after verifying those expected outcomes. The first sandboxed Swift build failed before any tests because the runtime could not inspect process state; automatically approved execution outside that process sandbox completed the red/green run. No build failure is being misreported as a regression failure.

Evidence and reproduction:

- `widget-stress-harness/before.log` and `after.log` contain commands, compile output, checks, and exit status.
- `widget-stress-harness/function-before.swift` preserves the original helper.
- `function-after.swift`, `production-store-extract.swift`, and `production-rr-policy.swift` record the exercised production code; the runner regenerates current extracts before running.
- Run `python3 review-work/widget-stress-harness/run-regressions.py` from this workspace. The runner generates a synthetic SQLite fixture and temporary Swift package; it does not access real health data.
- `git diff --check` passed for both modified native files.

## Deliberate tradeoff and limits

RR is **bounded by the selected civil day, not by an invented row count**. Peak memory can therefore grow with the amount of RR actually stored for that day and the number of verified sources. This corrects completeness without changing valid physiology. If pathological daily density requires a hard memory bound, the follow-up should add store-level streaming/paging that fixes WHOOP 5's source choice against the original full window, preserves complete same-timestamp order, and uses a stable database snapshot. Silently truncating or downsampling HRV input is not an equivalent fix.

This pass does not claim real-device battery improvements, widget refresh timing under iOS suspension, full migration/GRDB integration, or an Xcode app build. No database schema, collection cadence, scoring constants, or stored history was changed. No commits or pushes were performed.
