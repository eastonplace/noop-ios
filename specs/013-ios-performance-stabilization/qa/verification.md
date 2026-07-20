# Verification Ledger

| Date | SHA | Device/runtime | Configuration | Command or flow | Expected | Observed | Duration/counts | Result | Artifact |
|---|---|---|---|---|---|---|---|---|---|
| 2026-07-18 | 7b42bff8 | macOS host | baseline | `xcodebuild -version`; `swift --version` | Record tools | Xcode 26.6 (17F113); Swift 6.3.3 | repo 194 MB | PASS | terminal output |
| 2026-07-18 | 7b42bff8 | CoreDevice | baseline probe | `xcrun devicectl list devices` | Record connected iPhone | CoreDeviceService initialization timed out | no device evidence | BLOCKED | terminal output |
| 2026-07-18 | 7b42bff8 | SwiftPM/iCloud | focused RED | `swift test --package-path Packages/StrandAnalytics --scratch-path /private/tmp/noop-strandanalytics-build --filter AnalyticsEngineTests/testAnalyzeDayPersistsCanonicalV2PhysiologicalDayStrain` | Legacy scorer fails V2 anchor | SwiftPM produced no output for 60s while reading iCloud checkout; interrupted | 60s | BLOCKED | terminal output |
| 2026-07-18 | working tree | macOS local mirror | focused V2 | `swift test --filter StrainScorerV2Tests` | Live/history and accumulator parity | 4 tests, 0 failures | 0.014s | PASS | terminal output |
| 2026-07-18 | working tree | macOS local mirror | full analytics | `swift test` | No analytics regressions | 1,104 tests, 0 failures | 41.5s | PASS | terminal output |
| 2026-07-18 | working tree | macOS local mirror | R-R schema repair | `swift test --filter AnalyticsEngineTests.testSelfHealRecipeHealsEditedNightOnceRawArrives` | v30 conflict key accepts raw R-R | 1 test, 0 failures | 0.65s | PASS | terminal output |
| 2026-07-18 | working tree | iPhone 17 Pro simulator | performance console | relaunch DEBUG build and filter `com.eastonplace.noop:Performance` | Privacy-safe intervals emit | foreground 26.27ms; Today 941.13ms cold / 250.71ms follow-up; launch sequence 7,133.83ms including intentional 6s delay; unchanged analysis 1.98ms | 5 intervals | PASS | Console output |
| 2026-07-18 | working tree | iPhone 17 Pro simulator | visual QA | DEBUG seeded Today and Trends captures | Layout parity and fixed calendar alignment | Today card clean; Trends Monday-first 5×7 grid aligned; gray unavailable/future slot visible | 2 screenshots | PASS | `/private/tmp/noop-today-integrated.png`, `/private/tmp/noop-trends-integrated.png` |
| 2026-07-18 | working tree | arm64 iPhone simulator | Debug app build | `xcodebuild ... -sdk iphonesimulator -arch arm64 ... build` | Integrated app compiles | `BUILD SUCCEEDED` | incremental | PASS | `/private/tmp/noop-arm64-dd` |
| 2026-07-18 | working tree | Easton's iPhone | signed Release | `xcodebuild ... -configuration Release -destination id=00008150... build` | Signed device build succeeds | `BUILD SUCCEEDED` | Release | PASS | `/private/tmp/noop-device-final-dd/Build/Products/Release-iphoneos/NOOP.app` |
| 2026-07-18 | working tree | Easton's iPhone | in-place install/launch | `devicectl device install app`; `device process launch` | Preserve data and launch | Installed and launched; database UUID remained `67D59099-275F-45F8-8ACD-71C36AA86ABB` | sequence 4292 | PASS | CoreDevice output |

## Known gates

- GitHub Actions may be unavailable because of account billing/spending limits; local and physical-device evidence remains mandatory.
- Never uninstall/reset the phone app or seed/replace its production database.
- The simulator `xctrace` Time Profiler recorder exceeded its 8-second limit and produced an unusable 52 KB document (`Document Missing Template Error`). The same privacy-safe OSLog intervals were captured successfully and are the retained timing evidence.
