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
- Component 41 correction: `swift test` in StrandDesign passed 61/61; the focused `PaperIntegrationContractTests` simulator run passed 8/8; the embedded widget-extension Debug build passed; and the clean signed Release rebuild passed after removing only task-owned DerivedData that had filled `/tmp` on the first attempt.
- Source audits passed: no production fixture data, sync percentage, invented Fitness Age driver impact, `bonded`-as-full-bond, battery-health wording, or unsupported R22 claim was added.

## Visual verification

- Compared the real production Fitness Age destination directly with Design Lab component 39. The production screen now uses the same hero/age rail, centered pace rail, signed driver-impact grammar, and six-month history composition while retaining the real ±5-year engine disclaimer and only the two actual causal drivers.
- Compared the real production Devices route directly with Design Lab component 40. The production screen now uses the same identity/bond chip, three-value vitals strip, status verdict card, twin sync/power cards, 2×2 custom action controls, and privacy footer.
- `ScreenScaffold` now assigns the content column the measured viewport width, clips it at that boundary, uses a vertical-only scroll view, and disables horizontal bounce. The simulator captures show both production routes contained to the visible width with no cut-off edge.
- Evidence: `fitness-age-component-39-reference.png`, `fitness-age-component-39-production.png`, `devices-component-40-reference.png`, and `devices-component-40-production.png` in this directory.
- Component 41 was compared at true widget/accessory dimensions using the exact shared production views used by WidgetKit and ActivityKit. Small, medium, large, Recovery circular, Strain circular, rectangular, inline, workout Lock Screen, compact Island, and expanded Island all retained the Design Lab hierarchy, typography, palette, arcs, stress strip, traces, and zone split without clipping or horizontal overflow.
- ActivityKit was exercised through the real extension, not only an app mock. iOS rendered the compact Island with HR leading and canonical Strain trailing, plus the Lock Screen workout presentation with sport, elapsed time, live HR, HR trace, Strain, calories, and the first-run system consent sheet.
- Component 41 evidence is in `qa/component41-simulator/`: `component41home.png`, `component41large.png`, `component41lock.png`, `component41live.png`, `activitykit-home-dynamic-island.png`, and `activitykit-lock-screen.png`.

## Environment limitations

- Focused `StrandTests` execution is blocked by unrelated pre-existing `SleepOnsetDecodeTests` references to removed `SleepView` APIs. The new device resolver tests are discovered and compile as part of the test target until that older file fails.
- The requested automated no-mistakes gate could not start because the `no-mistakes` executable is not installed or callable in this environment (`command not found`). Manual equivalents completed: committed-diff review, `git diff --check`, source-policy audits, package suites, simulator reference/production comparison, generic iPhone build, and signed Release build.

## Physical iPhone QA

The signed Release artifact is ready at `/private/tmp/noop-017-release/Build/Products/Release-iphoneos/NOOP.app`. The first in-place install attempt did not mutate the phone: CoreDevice listed Easton's iPhone as `unavailable`, so installation and launch remain pending reconnection/unlock. The retry must remain an in-place update of `com.eastonplace.noop`; no uninstall, reset, database replacement, or demo seed is permitted.
