# WHOOP connection, background, and battery audit

Audit date: 2026-10-22. Base: `main` at `6f49d855d6f747103f4dc2a60949cb933445c3c0`. Working branch: `fix/noop-end-to-end-audit-20261022`.

## Implemented findings

### BLE-1 — System power-on could undo an explicit connection stop

**Confirmed; fixed in working tree. Affects both WHOOP 4.0 and WHOOP 5.0/MG.**

The actual path was `centralManagerDidUpdateState(.poweredOn)` → `handleBluetoothPoweredOn` → `connectFromSystem` → `connectCore`. `disconnect()` and `forgetDevice()` set `intentionalDisconnect = true`, but `connectCore` unconditionally cleared it. Therefore a later radio power-on could reconnect a user-disconnected or removed strap, and could restart WHOOP after `SourceCoordinator` stopped it for another source. The restored-peripheral branches independently bypassed the stop too: they directly called the reconnect/discovery closures.

Changes:

- Only explicit `connect(model:)` clears the stop request; the shared `connectCore` no longer does.
- `connectFromSystem` includes connection intent in its existing pause check.
- Both restored power-on branches check the same intent before reconnecting or rediscovering.
- Explicit Disconnect/Forget cancels an already-armed reconnect timer immediately.

Initial launch remains enabled because the initial stop flag is false. Explicit Connect re-enables recovery. Existing secure-recovery and background-cap pauses remain separate and unchanged.

Relevant source: `Strand/BLE/BLEManager.swift`, `connect`, `systemReconnectPauseReason`, `connectCore`, `disconnect`, and `handleBluetoothPoweredOn`; pure decision in `Packages/WhoopProtocol/Sources/WhoopProtocol/LinkPolicy/ConnectionIntentPolicy.swift`.

### BLE-2 — Late connect/failure callbacks could replace a newer selected strap

**Confirmed; fixed in working tree. Affects both families, especially source switching and asynchronous teardown.**

The manager already checked peripheral ownership in `didDisconnect` and peripheral-level delegates, but `didConnect` and `didFailToConnect` did not. A delayed `didConnect(A)` after `preparePeripheral(B)` could reset B's characteristics and secure state, publish A's identity, and start discovery under the selected source. A delayed `didFailToConnect(A)` could change pairing guidance or enter the retry path for the wrong target. In the background, that retry can call `preparePeripheral` again, clearing current characteristics.

Changes:

- Connection success is admitted only when the callback UUID equals the requested peripheral, still matches any preferred pin, and connection intent is active.
- An unwanted success cancels only the callback's peripheral; it never cancels the newer `self.peripheral` target.
- Failure handling checks the same ownership before logs, pairing guidance, or backoff changes, and accepts only a currently disconnected requested target. A failure arriving after the same peripheral is already connected or connecting is stale.
- Normal first connection with no preferred pin still works: `preparePeripheral` establishes the requested target before every normal `central.connect` call.

Relevant source: `Strand/BLE/BLEManager.swift`, `centralManager(_:didConnect:)`, `centralManager(_:didFailToConnect:error:)`, `preparePeripheral`, normal attach/target/scan paths, and `ConnectionIntentPolicy.swift`.

### BLE-3 — Removing an inactive device stopped active WHOOP recovery

**Confirmed; fixed in working tree. Affects both families; does not require two currently connected straps.**

`DevicesView.confirmRemove` called `ble.forgetDevice` for every row. `forgetDevice` set global disconnect intent, cancelled scan fallback, and reset recovery state even when the UUID did not match the current strap. Removing an inactive row could therefore leave the active strap connected until its next involuntary drop, then silently prevent recovery. An inactive row without a peripheral ID was worse: nil meant release the current strap.

Changes:

- `forgetDevice` now requires explicit `isActiveDevice` context; the only production call passes the existing `wasActive` value from the Devices screen.
- Active-row removal, removal of the actual physical link, and removal of the pinned pending target still release that connection.
- Unrelated inactive rows, including nil-peripheral rows, preserve the active connection, its reconnect timer, and its collection intent.
- If an unrelated removed UUID is retained solely as a restored peripheral, only that restored reference and its own pending connection are released.
- Registry archiving remains in the existing `model.archiveDevice` flow.

The single related `DevicesView` line is the only UI edit in this audit.

### BLE-4 — WHOOP 5/MG reboot diagnostics read the packet type as the result

**Confirmed; fixed in working tree. WHOOP 5.0/MG diagnostic-only defect.**

`FrameRouter.handle` handled reboot responses for both families but called `commandResultByte(in:)`, which uses the WHOOP 4 result offset (byte 8). A WHOOP 5/MG frame has its packet type at byte 8 and response result at byte 12; the log consequently read 0x24/0x26 as the result and reported rejection regardless of the actual byte.

The 5/MG path now reads `ParsedFrame.responseResult`, supplied by the existing family decoder. The response byte's meaning is command-specific, so the log preserves the actual byte without inventing a physical-reboot verdict. WHOOP 4 retains its existing layout and diagnostic wording. Three real-router tests cover the 4.0 layout, both 5/MG packet types (36/38), and an unknown result byte. No command, radio behavior, or sampling changes.

### BLE-5 — Explicit Broadcast HR OFF was blocked, including after reconnect

**Confirmed; adapted from existing draft PR68 at the parent's request. WHOOP 5.0/MG only.**

The Settings toggle persists false before calling `setBroadcastHr(false)`, but the WHOOP 5 command allowlist previously admitted SET_DEVICE_CONFIG only while the saved preference was true. This rejected the disable write. Secure-ready replay also only sent true, so choosing OFF while disconnected did not remove a previously enabled strap-side broadcast setting on reconnect.

This draft intentionally incorporates only PR68's Broadcast HR correction (`a5e9c5c8ed050b5a476d5b6f15daa39cebb9b433`), with its original tests. The exact OFF payload for `whoop_live_hr_in_adv_ind_pkt` is now allowed after the preference becomes false; ON still requires opt-in. Unrelated keys, altered padding, wrong prefixes, truncated payloads, and unsupported values do not gain this exception. Existing secure-session admission remains required. Post-secure-ready replay honors a real persisted Boolean true or false; registered defaults, an absent key, and non-Boolean stored values do not become device writes. The log now says "requested" rather than claiming the queued write completed.

The behavior change was communicated before editing: an explicit user OFF disables the additional broadcast feature, including after reconnect. This does not change standard HR/R-R collection, raw capture, history, continuous HRV preferences, command encoding, or sampling. An untouched preference does not request a strap write. WHOOP 4 is unaffected.

## Files changed by this audit

| File | Purpose |
|---|---|
| `Strand/BLE/BLEManager.swift` | Preserve explicit stop intent, fence connection callbacks, scope Forget to its target, admit/replay explicit Broadcast HR choices |
| `Strand/BLE/FrameRouter.swift` | Read the 5/MG reboot response result from its family decoder |
| `Strand/Screens/DevicesView.swift` | Pass the removed row's actual active status |
| `Packages/WhoopProtocol/Sources/WhoopProtocol/LinkPolicy/ConnectionIntentPolicy.swift` | Portable connection and removal admission decisions |
| `Packages/WhoopProtocol/Tests/WhoopProtocolTests/ConnectionIntentPolicyTests.swift` | 13 portable regressions |
| `StrandiOSTests/BLEConnectionIntentTests.swift` | 9 real-manager integration regressions for Apple CI |
| `StrandiOSTests/RebootResponseLogTests.swift` | 3 real-router logging regressions for Apple CI |
| `Packages/WhoopProtocol/Sources/WhoopProtocol/Whoop5Config.swift` | PR68's exact Broadcast HR payload admission helper |
| `Packages/WhoopProtocol/Tests/WhoopProtocolTests/Whoop5ConfigTests.swift` | PR68's 4 additional payload-admission regressions |
| `Strand/BLE/PuffinExperiment.swift` | PR68's strict persisted-Boolean choice lookup |
| `StrandiOSTests/PuffinBroadcastPreferenceTests.swift` | PR68's 4 native preference regression tests |

No commits or pushes were performed by this agent. The parent manages the shared Git index and draft PR.

## Sampling and collection impact

The parent was informed of the behavior changes before editing. These changes preserve the active strap's collection and prevent connections that no longer match explicit user/source intent. They do not change sensor sample rates, R-R conversions, raw-frame retention, historical decode/ACK policy, offload deadlines, or capture preferences.

Specific unchanged behavior inspected:

- WHOOP 4.0: the Live screen's R10/R11 raw burst, continuous-capture HR toggle, standard 0x2A37 HR/R-R source, 30-second keepalive, proprietary battery polling, and marginal-radio fallback.
- WHOOP 5.0/MG: CLIENT_HELLO → fresh protected notification confirmations → owned GET_HELLO proof; the serial confirmed-write lane; standard HR/R-R intake; post-bond standard battery polling; secure-recovery delays and terminal standard-HR fallback.
- History: 15-minute normal periodic floor, existing 45-minute low-battery floor, existing empty-offload backoff, bounded interrupted-session resume ladder, and background handoff to an OS-managed pending connect.

No battery saving percentage is claimed. The expected benefit is fewer unintended connections/recovery attempts, uninterrupted recovery for the correctly active strap, and honoring the user's request to disable optional HR advertising. On-device energy measurement is still required.

## Existing PR coverage and intentional narrow adaptation

Inspected the local `origin/pr68` diff (`a5e9c5c8ed050b5a476d5b6f15daa39cebb9b433`) against base main. It already covers Broadcast HR OFF admission and replay of an explicit saved preference, ordered reassembly-loss propagation into historical admission, clock/source ownership and Collector ownership, AppModel consuming the emitted `@Published` heart-rate value and resetting smoothing, and the HealthKit entitlement. PR68 does not remove equal-value suppression in `parseStandardHR` or create a sample-arrival channel. These are separate from the parent's subsequent live-session freshness fix. At the parent's explicit request, only PR68's Broadcast HR admission/preference corrections and related tests have now been adapted into this draft so its confirmed drain fix stands alone. The four config/preference/test files are byte-identical to PR68; BLEManager receives only the three broadcast regions. Source identity, clock ownership, ordered history, AppModel smoothing, and entitlement changes remain deferred to PR68.

PR67 (`ff0ec0f72a611adf6b83aabe9f0754879c76e4f3`) is tracked by the parent for alarm readback. This audit made no alarm changes.

## Verification evidence

Official Swift 6.4.1 Linux toolchain supplied and signature-verified by the parent was used. The restricted compiler sandbox could not support the toolchain's IPC/runtime requirements; approved local escalated execution was needed. This is not an iOS runtime or Xcode build.

1. **Unmodified WhoopProtocol baseline:** 511 XCTest cases executed. 510 passed; one failed: `RawHistoryArchiveRotationTests.testEvictionsAreReportedWhenTheWriteFailsAfterRotating`, at line 108. Its fixture uses chmod 0555 to make a directory undeletable; running as root bypasses this restriction, producing `.written(count: 1, evicted: 5)` instead of `.failed(evicted: 5)`. Log: `/tmp/noop-whoop-protocol-baseline.log`.
2. **New policy tests:** 13/13 passed. Log: `/tmp/noop-whoop-intent-after.log`.
3. **Full WhoopProtocol suite after changes:** 524 cases executed; 523 passed with the exact same pre-existing root/chmod fixture failure. Log: `/tmp/noop-whoop-protocol-after.log`.
4. **Root-fixture explanation verified:** ran the same compiled failing test as unprivileged UID/GID 65534. It passed (1/1), without changing production code or weakening the fixture. Log: `/tmp/noop-whoop-chmod-unprivileged.log`.
5. **Full compiled WhoopProtocol XCTest suite as unprivileged user:** **524/524 passed**, zero failures. This includes the previously root-bypassed permissions fixture and all 13 new policy regressions. The package source and test binary were unchanged between the root and unprivileged executions. Log: `/tmp/noop-whoop-protocol-unprivileged.log`.
6. **Swift parser verification:** `swiftc -frontend -parse` succeeded for changed `BLEManager.swift`, `FrameRouter.swift`, `DevicesView.swift`, and both new Apple integration test files. Parsing does not establish Apple SDK type checking or runtime behavior.
7. **Diff and call sites:** `git diff --check` passed; `rg` verified all production/test `forgetDevice` call sites use the new argument.
8. **PR68 Broadcast HR adaptation:** all 10 `Whoop5ConfigTests` passed, including 4 added admission tests. The initial test-only attempt failed compilation because the production helper had not yet been adapted; this is not claimed as an assertion-level red reproduction. Logs: `/tmp/noop-broadcast-before.log`, `/tmp/noop-broadcast-after.log`.
9. **Full updated protocol binary after Broadcast HR changes:** **528/528 XCTest cases passed**, zero failures, as unprivileged UID/GID 65534. Log: `/tmp/noop-whoop-protocol-broadcast-unprivileged.log`.
10. **Exact production preference reader on Linux:** compiled the complete unchanged `PuffinExperiment.swift` with a small assertion runner and real Foundation/CoreFoundation. All 12 checks passed: absent/default-only ignored, both Boolean choices preserved, malformed strings/numbers/arrays ignored, saved false overrides a registered true. Harness and logs: `/workspace/scratch/a25c9a323562/review-work/broadcast-preference-harness/`. This verifies the persistence helper on Linux, not AppStorage or physical BLE writes. Swift parsing also passed for BLEManager, PuffinExperiment, and the added native preference tests.

Tests were written before the implementation. The first portable attempt failed compilation because the new production policy did not exist yet; this is not claimed as an assertion-level reproduction of the old manager bug. The nine real-manager, three real-router, and four native preference tests have not run as the Apple app target locally because Linux has no CoreBluetooth/UIKit/Xcode. Apple CI must run `NOOPiOSTests/BLEConnectionIntentTests`, `NOOPiOSTests/RebootResponseLogTests`, `NOOPiOSTests/PuffinBroadcastPreferenceTests`, and existing BLE/source-coordinator integration suites before merging.

Portable command used (with approved compiler execution):

```sh
LD_LIBRARY_PATH=/tmp/noop-swift-toolchain/compat/usr/lib/x86_64-linux-gnu \
CLANG_MODULE_CACHE_PATH=/tmp/noop-ble-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/noop-ble-swift-cache \
/tmp/noop-swift-toolchain/usr/bin/swift test \
  --build-system native --package-path Packages/WhoopProtocol \
  --scratch-path /tmp/noop-whoop-protocol-native \
  --cache-path /tmp/noop-swift-package-cache --configuration debug --jobs 4
```

## Source coverage

Directly traced these execution paths, in addition to running the complete portable package suite:

- `Strand/BLE/BLEManager.swift`: init and store readiness boundaries; explicit/system connect; disconnect/forget/model switch; preferred-peripheral adoption; scan fallback; family-aware sends; confirmed-write ownership and serial lane; secure failure/recovery; background reconnect handoff and CLIENT_HELLO hold; battery/read/notification scheduling; live capture reconciliation and keepalive; history admission and delegate routing; all central/peripheral callback gates; restoration; clock correlation boundaries; secure-ready publication.
- `Strand/BLE/FrameRouter.swift`: both families' live-frame dispatch, integrity gating, event-triggered sync, charging events, live gestures during history, alarm/reboot diagnostics.
- `Strand/BLE/StandardHeartRate.swift`, `LiveState+Battery.swift`, `WhoopModel.swift`, and `HistoricalSyncBackgroundScheduling.swift`.
- `Strand/BLE/SourceCoordinator.swift`: startup subscriptions, WHOOP/generic transitions, pinning and active-source ownership boundaries.
- `Strand/App/AppModel.swift`: BLE construction before async registry wiring and injected source-coordinator hooks; `StrandiOS/App/AppModel+SeededWhoopModel.swift`: physical-source metadata guard.
- `Strand/Screens/DevicesView.swift`: remove-row call chain.
- `Packages/NoopPhase34Core/Sources/NoopPhase34Core/Whoop5SecureSession.swift`: full session, recovery, discovery, fallback, protected-frame admission, and R22 ownership state models.
- `Packages/WhoopProtocol` policy files: `ReconnectPolicy`, `RealtimeArmPolicy`, `ContinuousHrvSchedule`, `BackfillPolicy`, `WhoopCommand`; framing validation and family-specific response decode sections in `Framing.swift` and `Interpreter.swift`.
- Existing reconnect/background handoff, bond-loop, secure-session, framing, and family-decoder tests informed the review. All package tests ran; this report does not imply every decoder source file received independent manual line-by-line review.

## Follow-up observations (not fixed in this patch)

### Suspected integration risk: cold restoration may precede registry pin hydration

`willRestoreState` takes `peripherals.first` and selects the persisted family before asynchronous `wireSourceCoordinator` loads the active registry row. On the first WHOOP activation, SourceCoordinator points the target without necessarily disconnecting a mismatched already-restored peripheral. This deserves a cold-restoration test with two registered straps and reversed restored ordering. The current evidence proves the missing selection guard, but a reproducible OS restoration payload and startup ordering are still needed to establish user-visible impact. A complete fix belongs at registry/bootstrap admission, not a guess at array ordering. The new late-callback guard does not claim to solve this startup case.

### Device-only observation: radio-off state and quiet links

The non-powered-on central callback sets availability/error fields and invalidates history, but `state.markDisconnected()` is in the disconnect delegate. Whether a radio-off event without that delegate leaves a stale connected UI needs Apple device validation; no speculative lifecycle refactor was made. Similarly, the 5/MG 600-second quiet-link watchdog and 30-second battery reads were inspected but left unchanged without energy/traffic evidence.

## Required device verification

Run separately on a WHOOP 4.0 and a WHOOP 5.0/MG, preserving existing continuous-HRV, live-view, and history settings:

1. Connect, wait for current-family handshake and HR/R-R, then explicit Disconnect. Toggle phone Bluetooth off/on and background/foreground the app. Confirm no reconnect/rediscovery until explicit Connect; then confirm normal automatic recovery and data collection resume.
2. Start connection to A, then select B before A finishes. Deliver/observe delayed success and failure for A. Verify B remains selected, its characteristics/secure proof are not reset, no A samples are attributed to B, and only A's unwanted success is cancelled.
3. While A is active, remove inactive B. Repeat with an inactive row lacking a peripheral ID. Verify HR/R-R continues and an out-of-range/re-entry cycle reconnects A normally. Remove A itself and confirm it is released and no reconnect timer survives.
4. Cold launch without prior disconnect, then OS background restoration of the selected strap. Verify both still connect without a user tap. Include two-strap restoration ordering as the separate unresolved startup scenario above.
5. During these journeys, compare type-47/type-0x2F history completion, trim ACKs, R-R density, and existing capture preferences with baseline. The patch must not reduce sampling or newly gate an authorized source.
6. Use Instruments Energy Log and a strap/battery trace over matched idle, live-screen, history-backlog, and background periods. Attribute any improvement to prevented unintended connections; do not extrapolate a percentage from code review.
7. WHOOP 5/MG only: explicitly enable Broadcast HR, then turn it off while connected. Verify the exact disable write reaches the owned secure command lane and advertising changes without disrupting the app's HR/R-R/history. Repeat OFF while disconnected and reconnect; it must replay false only after secure proof. A clean preference domain and registered UI defaults must send no broadcast config. Preserve equivalent ongoing collection in all cases.
