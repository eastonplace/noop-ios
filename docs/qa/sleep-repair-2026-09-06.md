# Sleep repair review

Baseline: `aed9ba67166e14acc5a045379711cc684e0f9509`.
Branch: `fix/sleep-state-and-layout`.
Checkout: `/private/tmp/noop-sleep-fix-20260906`.

## Changes

- Missing-current-day recovery remains visible above older sleep history. Copy says no sleep is recorded yet and asks the user to act only after finishing sleep. Earlier nights remain browsable.
- Removed the manual sleep-mark card from the main screen. Historical marks and recovery editing remain intact.
- Replaced the inline full alarm editor with a compact entry and preserved shared BehaviorStore/runtime ownership. The alarm destination uses native controls and existing Paper components. Unavailable modes remain disabled. Removed duplicate navigation chrome.
- Replaced seven large metric tiles with compact selected-night rows and expandable details. Imported WHOOP need is labeled when used.
- Read exact-day canonical need and repayment together. The ledger excludes the repayment adjustment from its nightly target to avoid recounting existing debt. Missing targets remain unknown; the ledger counts the most recent 14 usable nights, not 14 calendar days. Its footer reports the average target.
- Refresh need reads on repository/canonical revision and check cancellation before publishing. The breakdown refreshes on same-day changes instead of date changes alone.
- Limit duration trend points to the current 30 calendar days. Average, minimum, maximum, and count use those same points; one recorded point is allowed.
- Added an explicit `--demo-sleep-need` fixture inside the existing Debug + simulator-only demo gate. On a seeded demo database it adds synthetic need components for visual QA. It cannot run on a physical phone or Release build.

## Verified

- Simulator build passed.
- 11 SleepDebtTests passed.
- 19 targeted iOS tests passed: SleepPresentationPolicyTests, SleepPresentationRepositoryTests, SleepRecoveryAppTests, AlarmPresentationTests.
- Source contract, UI unification, and accessibility/localization audits passed.
- iPhone 17 Pro simulator: missing-current-day card with older history, compact alarm entry, focused editor without duplicate back controls, expanded night metrics, missing-target ledger, populated ledger, and 30-day hours chart inspected.
- Populated synthetic example: 8h20 nightly need, 6h49 asleep, 82% hours vs need, and a separate target excluding 30 minutes of repayment.
- NOOP enforces dark appearance in AppearanceMode. A system light toggle does not change the product theme.

## Remaining gates

- No push, PR, merge, or physical-device installation was performed.
- Real overnight detection, real sync, strap actuation, and phone notification delivery remain unverified.
- Large accessibility text exposed pre-existing wrapping in the global device header and tab bar; the alarm controls remained readable. This change does not repair the global shell.
- Nights without persisted canonical target/repayment components cannot contribute to the new canonical ledger. They show an explicit unavailable state rather than the old historical-mean estimate.
- A current-day recorded session suppresses the missing-day card, including naps; per-main-sleep classification remains a possible refinement.
