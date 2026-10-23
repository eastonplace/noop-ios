# NOOP deep review, 2026-10-23

Base: `a7ade2598d439d33cd20816d69ccc991b29322fc` (`main`).

## Confirmed findings and fixes

| Area | Trigger and consequence | Root fix | Regression evidence |
| --- | --- | --- | --- |
| HealthKit query lifetime | Background expiry cancels a task while a read has not called back. The continuation and import fence remain held. | A shared one-shot query owner stops the query, resumes cancellation once, and ignores late callbacks. Successful one-shot queries are also stopped. | `HealthKitQueryCancellationTests`; import-fence regression in `HealthKitSyncCoordinatorTests`. |
| HealthKit deletion and paging | Cancellation during durable identity journaling can still start deletion; a cancelled page can continue downstream. | Check cancellation before each identity batch, before deletion, and after each page read. Keep the identity journal. | Deletion-before-cancel and cancelled-anchor-page regressions. |
| Readiness baseline dates | A long wear gap pulls months-old rows into a nominal 30-day physiology baseline. | Use civil-day distance, including day 30 and excluding day 31, before calculating the existing signals. | `ReadinessEngineTests` long-gap and boundary cases. |
| Readiness malformed numbers | Infinite HRV reaches integer formatting and traps. Non-finite baseline observations contaminate statistics. | Filter non-finite values, require enough valid observations and format finite values without a trapping integer conversion. | `AnalyticsNumericSafetyTests`, including the pre-fix process crash. |
| App import boundary | Shortcut text accepts Infinity/NaN, and extreme finite WHOOP HR traps during rounding; invalid WHOOP Strain can overflow its scale conversion. | Drop non-finite optional Shortcut cells, use exact rounded HR conversion, and validate WHOOP’s 0–21 scale before mapping. Preserve valid sibling fields and report importer revision 2. | Real CSV-to-database and Shortcut persistence regressions, plus valid-value preservation. |
| Training-load overflow | A priming window of accepted finite values can overflow while being summed. | Use a scaled mean only when the original sum overflows. Normal inputs retain the original arithmetic. | Finite-extreme priming regression. |
| Sleep processing | Every missing HR epoch scans all known epochs again to locate its neighbors. | Advance one neighbor cursor through the sorted epoch indexes; preserve interpolation and convolution arithmetic. | Bit-for-bit parity against the prior algorithm across sparse, dense and edge-gap histories. |
| CSV timestamps | Concurrent imports mutate one shared formatter and use another import's timezone; an oversized numeric offset can overflow. | Serialize formatter configuration/use and use the existing UTC fallback for malformed or out-of-range timezone components before arithmetic. | `WhoopTimeSafetyTests`; pre-fix wrong timestamps and overflow crash reproduced. |
| GPS import distance | Valid antipodal coordinates round the haversine intermediate slightly above 1, producing NaN. | Clamp that intermediate to its mathematical [0, 1] domain before square roots. | 899 valid coordinate pairs; 35 failed before the fix. |
| HR coverage | Implausible PPG fallback values satisfy the coverage gate even though decoded HR would reject them. | Apply the same rounded BPM range predicate to PPG fallback rows, retaining measured-first precedence. | `WhoopStore` read regression with invalid-only, mixed-source and fractional-boundary cases. |
| WHOOP realtime frames | A CRC-valid packet declares more RR entries than its payload contains. The decoder reads checksum bytes as beats. | Bound WHOOP 4 and 5/MG RR reads to the payload before CRC32. | `RealtimeRRPayloadBoundsTests`. |
| FTMS packets | A truncated multibyte field leaves bytes available to a later HR field. | Exhaust the reader after an incomplete field. Retain earlier fully decoded values. | `FTMSTruncatedFieldTests` across four fitness-machine types. |
| Oura notification framing | A fragmented response or secure response followed by a partial event loses bytes or misaligns decoding. | Reassemble the shared control/event stream once, route complete frames in order, and hold durable cursors while records remain partial or are being mapped. | Full documented opcode-table and fragmented/mixed-stream fixtures. |
| Coach Brief scale | A valid brief with Strain above 21 is rejected although NOOP uses 0–100. | Validate the canonical 0–100 range. | Payload tests at 21.1, 50, 100 and invalid boundaries. |
| Widget privacy recovery | A damaged active epoch plus a surviving brief can reuse the old epoch and redisplay old prose. Cleanup also leaves that prose behind. | Include brief payload/fence epochs in recovery and clear both at the privacy boundary. | Four `WidgetPrivacyRecoveryTests`, including overflow and payload-only recovery. |
| GPS route shortcut | Background route export inherits `alwaysAllowed` authentication despite returning precise coordinates and timestamps. | Require local device authentication. | Actual App Intents SDK/source probe and `AppIntentRegistrationTests`. |
| Lift personal records | Summary redraws repeatedly sort/scan completed history. Receipt's appearance-only cache can become stale after history changes. | Cache the ledger in `LiftStore` and invalidate whenever completed sessions change; both views share it. | Memoization, live-edit, completion and persisted-load regression. |
| Lift receipt labels | Each receipt row represents one set, but the second row says “2 SETS” beside a one-set volume. | Label the per-exercise ordinal as “SET 2” or “SET 2 OF 3”; retain unchanged per-row and total volumes. | Multi-row receipt model regression and rendered receipt inspection. |
| Workout summary refresh | Details dismissal starts an independent reload task outside the screen's task lifetime. | Route dismissal reloads through the existing `.task(id:)` identity and retain cancellation checks before publication. | Static lifecycle review and native/UI qualification. |

## Performance evidence

- Lift synthetic fixture: 1,000 completed workouts, 24,000 sets and 50 unchanged-history reads. Full history computations drop from 50 to 1. An optimized host run measured 866.99 ms versus 6.86 ms; a repeat under concurrent build load measured 909.92 ms versus 20.08 ms. Both compare identical ledgers and checksum 39,600. These are synthetic host timings, not device frame-rate or battery measurements.
- Sparse sleep interpolation: an optimized source-extracted benchmark with 50% missing samples, two warmups and the median of 25 runs measured 0.156 to 0.078 ms for 8 hours, and 0.973 to 0.234 ms for 24 hours. Outputs are bit-identical. These are sub-millisecond helper savings; app-wide latency and battery gains remain unmeasured. Neighbor search changes from repeated full scans to one forward traversal. The convolution and physiological thresholds are unchanged.

## Coverage and constraints

Six focused code reviews covered storage/import, protocols, analytics, HealthKit/background lifetime, UI/workouts and extensions. An additional reviewer examined the combined fixes. Existing WHOOP4 alarm request/readback ownership, historical durable ACK handling and online SQLite backup paths were inspected and retained. Secondary 4,000-day workout comparison reads were noted, but no speed claim or redesign is made without measurements.

This review uses current main. PR #77 remains separate unmerged feature work. Version stays in the held 2.0.0 batch; this branch uses build 249 and updates its cumulative notes. No phone installation, live health-data mutation, pairing change, release publication or merge is included.

A review cannot prove the absence of all bugs. Synthetic tests do not establish physical Bluetooth, HealthKit delivery, background expiry timing, real-world battery consumption or on-device responsiveness. Numeric-extreme cases are malformed-data hardening, not claims about typical physiology.

## Verification

Verified package suites on the final package changes:

| Suite | Result |
| --- | --- |
| WhoopProtocol | 550 passed |
| OuraProtocol | 83 passed |
| WhoopStore | 724 passed |
| StrandImport | 260 passed, 1 explicit real-export fixture skip |
| StrandAnalytics | 1,667 passed |
| NoopPhase34Core | 140 passed |
| WorkoutRouteExport | 11 passed |

All 20 source audit scripts and all nine native safety harnesses passed. The combined source received independent static review; the identified Oura opcode-table omission and importer diagnostic revision were corrected.

Native app/test build, simulator execution, visual checks and exact-head CI selection are recorded in the pull request. Hardware-dependent verification and overall device performance remain separate from these local regressions.
