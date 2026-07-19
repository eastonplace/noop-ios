# Verification Ledger

## Automated verification

- `swift test` — StrandAnalytics: 1,110 passed, 0 failed.
- `swift test` — StrandDesign: 61 passed, 0 failed.
- XcodeBuildMCP iOS Simulator compile: passed after all component 39–41 changes.
- `xcodebuild build-for-testing` for `NOOPiOSTests`: passed, including the new widget snapshot and Live Activity compatibility tests.
- XcodeBuildMCP macOS compile: passed after all component 39–41 changes.
- `git diff --check`: passed.
- Corrective generic iPhone Simulator Debug build after the component-fidelity and viewport changes: passed.
- Signed iPhone Release build for `com.eastonplace.noop` with team `QDJ575GGH4`: passed.
- Source audits passed: no production fixture data, sync percentage, invented Fitness Age driver impact, `bonded`-as-full-bond, battery-health wording, or unsupported R22 claim was added.

## Visual verification

- Compared the real production Fitness Age destination directly with Design Lab component 39. The production screen now uses the same hero/age rail, centered pace rail, signed driver-impact grammar, and six-month history composition while retaining the real ±5-year engine disclaimer and only the two actual causal drivers.
- Compared the real production Devices route directly with Design Lab component 40. The production screen now uses the same identity/bond chip, three-value vitals strip, status verdict card, twin sync/power cards, 2×2 custom action controls, and privacy footer.
- `ScreenScaffold` now assigns the content column the measured viewport width, clips it at that boundary, uses a vertical-only scroll view, and disables horizontal bounce. The simulator captures show both production routes contained to the visible width with no cut-off edge.
- Evidence: `fitness-age-component-39-reference.png`, `fitness-age-component-39-production.png`, `devices-component-40-reference.png`, and `devices-component-40-production.png` in this directory.

## Environment limitations

- Focused `StrandTests` execution is blocked by unrelated pre-existing `SleepOnsetDecodeTests` references to removed `SleepView` APIs. The new device resolver tests are discovered and compile as part of the test target until that older file fails.
- The requested automated no-mistakes gate could not start because the `no-mistakes` executable is not installed or callable in this environment (`command not found`). Manual equivalents completed: committed-diff review, `git diff --check`, source-policy audits, package suites, simulator reference/production comparison, generic iPhone build, and signed Release build.

## Physical iPhone QA

The signed Release artifact is ready at `/private/tmp/noop-017-release/Build/Products/Release-iphoneos/NOOP.app`. The first in-place install attempt did not mutate the phone: CoreDevice listed Easton's iPhone as `unavailable`, so installation and launch remain pending reconnection/unlock. The retry must remain an in-place update of `com.eastonplace.noop`; no uninstall, reset, database replacement, or demo seed is permitted.
