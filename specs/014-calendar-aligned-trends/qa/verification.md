# Calendar-Aligned Trends Verification

| Date | Runtime | Command or flow | Observed | Result |
|---|---|---|---|---|
| 2026-07-17 | macOS host, local `/tmp` mirror | `swift test --filter TrendCalendarTests` | Initial compile exposed the stale value-only `TrendMonthHeat` public initializer; contract updated before green run. | RED |
| 2026-07-17 | macOS host, local `/tmp` mirror | `swift test --filter TrendCalendarTests` | 6 tests passed: missing Tuesday, multiple gaps/month boundary, DST, future classification, best-date age, weekday averages. | PASS |
| 2026-07-17 | macOS host, local `/tmp` mirror | `swift test` | StrandDesign built; 61 tests passed with 0 failures. | PASS |
| 2026-07-17 | generic iOS | `xcodebuild ... CODE_SIGNING_ALLOWED=NO build` | Xcode reached package resolution, then stalled on the iCloud checkout and was interrupted. | BLOCKED |
| 2026-07-18 | iPhone 17 Pro simulator | Hydrated arm64 build + DEBUG `NOOP_DEMO_TAB=trends` screenshot route | App built and Trends loaded the fixed Monday-first 5×7 recovery calendar. Headers and cells align; unavailable/future cell is gray. | PASS |
| 2026-07-18 | Easton's iPhone | Signed Release build, in-place install, launch | Build/install/launch succeeded without replacing the app data container. | PASS |

## Remaining gates

- None for this release. Missing-date and future-date semantics are covered by the six calendar contract tests; the production grid was visually verified on the iPhone simulator.
