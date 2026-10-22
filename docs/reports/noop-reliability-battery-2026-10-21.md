# WHOOP reliability and battery control fixes

## Scope

This change implements the first reliability and battery batch from
`NOOP-iOS-Review-2026-10-21.zip`, reviewed against main
`6f49d855d6f747103f4dc2a60949cb933445c3c0`.

| Finding | Result |
| --- | --- |
| BLE-01 | Admit only the exact HR Broadcast OFF payload after the preference becomes false. ON still requires opt-in. Replay an explicitly persisted Boolean after secure session proof. |
| APP-01 | Consume the emitted `@Published` HR value and clear smoothing once both HR and RR clear. |
| D1 / D2 | Resume WHOOP after a durable transition or rollback and restore the default source's write identity. Preserve cold restoration without reconnect churn. |
| D3 | Capture source, family, intake generation, and clock before buffering. Keep decoded and raw writes under that identity. Retry only uncommitted owned batches. |
| BLE-04 | Carry discarded bytes and frames in their original order through the admitted history queue. A surviving START cannot erase missing evidence before a trim ACK. |
| HK-01 | Declare background delivery in both XcodeGen and the checked-in HealthKit entitlements. |
| PRIV-01 | Use bundled-asset providers for block and inline Coach Markdown images. |

The framing change preserves the legacy frame-only output and per-characteristic
fragment windows. During an admitted offload, loss on a proprietary WHOOP channel
conservatively invalidates the pass. Standard HR and battery characteristics do
not use this route. Loss outside an admitted pass does not contaminate a later
pass. Current connection/session tokens and secure admissions reject stale
frames and stale loss markers. The existing failure and retry policy remains.

Collector retains existing caps and failure backoff. Pre-clock bytes from an old
source stay unassigned and bounded; a new strap's clock cannot correlate them.
Already acknowledged historical chunks retain their original receipt, source,
cursor, and save-before-ACK protection. No database migration or historical
reassignment is included.

## Baseline proof

The unchanged production baseline compiled with Xcode 27.1 (27A9275).

1. HR/source regressions: 8 test cases, 7 failing cases and 8 failed assertions.
   Initial cold activation passed; the other cases reproduced the reported HR,
   restart, rollback, and default-identity defects.
2. Collector/history regressions: 8 test cases, all failing, with 14 failed
   assertions. These reproduced mixed ownership, retry ownership, raw/decoded
   owner divergence, wrong clocks, and START clearing an existing loss marker.
3. Twelve existing source-audit commands and 19 extracted-production-SQL tests
   passed. The system Python lacks pytest; an isolated `uv run --with pytest`
   run executed 131 capture tests successfully, excluding the existing real-DB
   integration case.

## Candidate verification

- WHOOP protocol: 520 tests passed, including nine new Broadcast and ordered-loss
  cases. Legacy framing output, fragment isolation, and existing diagnostics
  remain covered.
- Affected native app suites: 51 tests passed on an isolated iOS Simulator.
  These cover historical receipts (28), Collector ownership and partial retries
  (10), incoming heart rate (4), source transitions and rollback (4), explicit
  persisted Boolean preferences (4), and physical clock ownership policy (1).
  Numeric preferences such as 0, 1, and 1.0 cannot become a device-write choice.
- Independent source re-review found no blocking issues, including physical
  clock fencing, strict Boolean replay, COMPLETE after loss, and retries after
  an earlier owner has already committed.
- WHOOP persistence: 635 tests passed. The default Swift build engine could not
  sign generated bundles with iCloud Finder metadata. The same package passed
  using the native SwiftPM engine with its scratch directory outside iCloud.
- Final source audits and extracted-SQL checks passed. Isolated capture and QA
  pytest: 161 passed, one real-database integration case excluded.
- All eight hosted Swift package checks and hosted source audits passed for
  the initial draft head. Its native workflow was cancelled to prioritize the
  requested PR #66/#67 merge checks; it must run again on the integrated base.
- The full app compiles. The broad local native run ended with 493 passing
  entries and six failure entries: four existing background-grant cancellation
  cases, a killed test, and a test-host error. It did not finish the full suite.
  A sample placed cancelled tasks inside XCTest's Swift error observer; that
  does not establish a product root cause. The isolated cancellation suite
  passed 18 of 20 cases; the two cancelled-sleep cases still timed out. Both
  source and tests are byte-identical to main. A separate test host is being
  used to distinguish framework behavior from full-app startup effects.
  No full-suite pass is claimed.

## Remaining qualification

Native tests do not establish physical strap behavior or energy improvement.

1. Verify actual online/offline Broadcast OFF delivery and observable peripheral
   behavior on WHOOP 5 and MG. An absent preference must send no configuration.
2. Check source transitions, reconnects, and live/history continuity on WHOOP 4,
   WHOOP 5, and MG using preserved user data.
3. Verify signed HealthKit entitlements, provisioning, and background delivery
   on a real device. An unsigned Simulator does not prove this capability.
4. Intercept requests from the native Markdown renderer for block, inline, and
   reference images. Compilation and provider source checks do not prove the
   absence of every automatic network request.
5. Measure battery under controlled conditions before claiming savings.

Broad non-WHOOP removal, timestamped HR receipt events, realtime lease redesign,
sleep episode arbitration, analysis-cache revisions, temperature rescoring,
and performance work remain separate review items. This PR does not claim to
resolve the complete 29-entry register.

Merge and physical phone installation require Easton's separate review.
