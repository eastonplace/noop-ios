This is the specialist evidence snapshot before delivery. The [combined report](README.md) is authoritative for release status. Scratch paths record the original execution environment.

# NOOP 2.0 Bluetooth, collection, and protocol audit

Date: 2026-10-23. Repository: `/workspace/scratch/fc582a8e42a6/noop-ios`.
Branch: `audit/noop-2-release-hardening-20261023`.
Exact reviewed base: `a7ade2598d439d33cd20816d69ccc991b29322fc`.

## Handoff status and boundaries

Six root-cause groups have narrowly scoped fixes in the shared working tree: radio/Forget retirement; expired background admission; redundant WHOOP5 fallback publication; queued physical identity adoption; suspended bootstrap/battery/replay ownership; and stale outbound HR. Radio loss and Forget are documented as separate user scenarios within the shared retirement group. The root report labels these F01, F02, F03, F13, F14, and F15. No protocol packet layout, physiological threshold, collection frequency, firmware command sequence, backend format, database schema, or Coach prompt/template/instruction was changed by this specialist.

The final unchanged WhoopProtocol package suite executed **546 tests, zero failures**, in 5.855 seconds. Source-derived Swift probes reproduced the defects and the corrected outcomes for cancellation, fallback publication, identity admission, bootstrap continuation, battery ownership, archive replay ownership, and HR replay. The lifecycle probe reproduced the base radio-state defect; the native common-retirement tests have been written and parsed, but were **not executed** in this Linux environment. No Xcode build, iOS simulator test, Instruments session, physical iPhone, WHOOP4, WHOOP5/MG, or alternate-provider hardware test was performed.

All production executable declarations/bodies under `Strand/BLE`, `Strand/Collect`, and `Packages/WhoopProtocol/Sources` were inspected. This includes the bundled protocol schema and the portable decoder CLI. The manifest below distinguishes this complete assigned-directory review from targeted reads in other domains. Executing a test suite does not imply manual review of every test file. No claim of exhaustive real-world firmware validation is made.

## Confirmed findings and implemented changes

### F01a — P1: Radio loss can leave a retired WHOOP connection published and its work alive

**Base evidence:** `Strand/BLE/BLEManager.swift:5133` handles a non-powered-on central by invalidating history admission and publishing a banner, while the complete cleanup lives under `didDisconnectPeripheral` at `5371`. The comment at `1899` incorrectly says the radio callback clears `state.connected`. It does not. Apple's [central state callback contract](https://developer.apple.com/documentation/corebluetooth/cbcentralmanagerdelegate/centralmanagerdidupdatestate(_:)) states that powered-on is required for central operations; lower states disconnect links, and states below powered-off invalidate retrieved peripheral objects. A radio transition must therefore retire state without depending on a later per-peripheral callback.

**Production path:** CoreBluetooth state update → existing radio-state branch → stale connected/security/live-HR/history/timer/characteristic state. A pending retry or later command can observe the retired connection; resetting/unauthorized states can also leave an invalid peripheral cached.

**Reproduction:** The source-extracted base radio handler was run with `state.connected = true` and powered-off/resetting states, without a `didDisconnectPeripheral` callback. It reported `FAIL production radio handler retained connected=true after poweredOff`, and the same failure for resetting.

**Change:** Current `BLEManager.swift:5192` factors normal disconnect teardown into `retireConnectionState(reason:)`. Current `:5322` calls it for central unavailability, cancels reconnect/scan fallback, and discards the peripheral only for states that invalidate it. Write, read, and delegate admission require a powered-on central. The teardown captures the old live-HR source and collector before retirement, invalidates historical ACK ownership, advances connection generation, clears transport proof and timers, and flushes the captured collector. It retains user disconnect intent, secure recovery pause/caps, the held-hello deadline, and requested realtime mode.

**Regression risk:** Moderate because ordinary disconnect cleanup is shared. The existing cleanup is retained, with two intentional ordering fixes: stop backfilling/fence the Backfiller before publishing final burst work, and flush captured collectors rather than looking up a later mutable collector. Native tests cover repeated callbacks, replacement-provider preservation, retry intent, and received HR/RR persistence. Physical radio loss/restoration during an acknowledged history transfer remains required.

### F01b — P1: Forget clears the peripheral before normal cleanup can accept its callback

**Base evidence:** `BLEManager.swift:1425–1483` cancels and clears the active peripheral. `didDisconnectPeripheral:5371` rejects callbacks that no longer match the active object. Thus Forget can bypass normal security/timer/history/collector cleanup entirely.

**Production path:** Devices Forget → active peripheral nil → delayed disconnect callback rejected → old link work and partially buffered samples are left behind. A new device selection can occur before those tasks finish.

**Change:** Current `forgetDevice:1471` invokes the same captured-owner retirement helper before clearing the peripheral. Pin clearing and explicit stop intent are preserved. Commands are not sent to a retired or unpowered link. `BLEConnectionRetirementTests` includes Forget without any callback, immediate A→B ownership change, and verification that buffered HR80/RR750 persist under A.

**Regression risk:** Moderate shared cleanup, covered by the same targeted native tests. No hardware command was sent during this audit.

### F02 — P2: An already-expired background operation can still request another history transfer

**Base evidence:** `StrandiOS/App/HistoricalSyncBackgroundTaskRegistrar.swift:60,87`. The main-actor Task can be cancelled before first execution, but the body still calls `requestSync`; the cancellation check occurs only later in the wait loop.

**Production path:** BGProcessingTask expiration → cancel operation and complete task → queued actor body begins → requests history despite the expired grant.

**Change:** The production `makeOperation` factory checks cancellation before executing the body, and the registrar checks again immediately before `requestSync`. Existing scheduling, completion gate, and expiration ownership remain unchanged.

**Executed reproduction:** Cancelled-before-entry operation: one request before, zero after. Noncancelled control: one request after. `HistoricalSyncCancellationTests` exercises that exact factory. This establishes an avoided obsolete operation, not a measured battery percentage.

**Regression risk:** Low. No normal sync cadence or running-transfer cancellation policy changes.

### F03 — P2: WHOOP5/MG standard-HR fallback republishes identical state and log text on every packet

**Base evidence:** The standard HR notification branch near base `BLEManager.swift:6975` assigns identical `standardHRMode` text and appends a log on every packet while the secure link is unverified or terminally paused. This happens after `parseStandardHR`, independently of its existing periodic diagnostic throttle. Pending log publication and durable tail persistence make those extra entries observable work.

**Change:** Current `updateWhoop5StandardHRFallback:7051` records fallback mode but only republishes/logs when the actual displayed mode changes. `parseStandardHR` remains first and processes every HR/RR sample. Both WHOOP4 behavior and WHOOP5 secure-mode transitions are preserved.

**Executed operation counts:** 3,600 identical fallback notifications produced 3,600 publications and 3,600 logs before; one of each after. A further 3,600 notifications after entering paused fallback produced cumulative 7,200/7,200 before and 2/2 after. The source-derived probe executes the production method body; native Combine tests cover actual `@Published` delivery.

**Regression risk:** Low. This is publication/log deduplication only; there is no reduction in packet processing, subscription frequency, or persisted samples.

### F13 — P1: A queued connection identity can be committed to a different logical source

**Base evidence:** `SourceCoordinator.swift:457–479` queues a raw UUID and resolves `registry.activeDeviceId` only when the fence admits it. `AppModel.swift:2015` holds that fence for source selection, while `SourceTransitionRecoveryCoordinator.swift:328–341` awaits historical/external quiescence before stopping the affected live source. The old strap can therefore finish connecting during this interval. `AppModel.swift:1575–1581,1931–1939` forwards the eventually chosen device plus UUID into a durable physical replacement.

**Production interleaving:** A→B selection owns the transition fence; A finishes connecting and queues its UUID while cleanup is suspended; selection commits unpinned B; queued UUID reconciliation reads B and adopts A's physical identity into B. A separate delay can also allow a pre-bond notification to borrow later `live.encryptedBond` proof.

**Executed reproduction:** The actual `SourceTransitionFence.swift` and extracted production intake/reconcile/adopt methods were compiled in a controlled registry harness. Base result: `A identity: nil`, `B identity: uuid-from-strap-a`. Corrected result: both remain nil for that retired observation; the native test then verifies a fresh B callback still adopts B.

**Change:** `SourceCoordinator.swift:463` captures the active owner, observation generation, and bond proof at callback intake. Selection, stop, and newer physical observations invalidate pending admissions. The check runs inside the fence before registry mutation. The generation protects leave-and-return to the same logical ID. Four native tests cover source switch, same-ID retirement/reactivation, newest observation, and pre-bond proof.

**Regression risk:** Moderate. Identity adoption triggers durable lineage transitions. Positive controls retain current-source first adoption and a genuinely bonded handoff. The registry schema, lineage semantics, and fence implementation are unchanged.

### F14 — P1: Store bootstrap continuations can publish retired handles or cross-source historical state

**Base evidence:** `BLEManager.swift:931,948` checks generation after open and registry lookup, but `:961` awaits `upsertDevice` and then installs collector/backfiller at `:965,971` without another check. Restore increments generation and drops handles at base `:4361` onward. Battery seed reads at `:1060` and publishes at `:1066` without owner validation. Archive replay at `:1036–1044` reads mutable `deviceId` for each asynchronous insert and stamps a global completion key after return. `RawHistoryArchive.swift:289–306` awaits insert once for each stored family.

**Production paths:** (1) Bootstrap upsert suspends; restore/new bootstrap replaces the store; old continuation installs old collectors. (2) Battery read for A suspends; source B clears/seeds its own history; A's rows are appended to B. (3) Archive replay yields; source changes; a later family writes under the new mutable device ID, or a replaced database receives a replay completion stamp for work done only on the old store.

**Change:** Current bootstrap starts at `:913`. Revalidate restore state, store object identity, and generation after upsert before installing collectors. Capture device/source epoch and HR source around battery reads. Archive inserts capture original device identity and require current store/generation/source ownership before each insert; completion revalidates before stamping success. The small `isStoreBootstrapCurrent:1108` predicate is shared by replay admission/completion. Injectable store/replay boundaries let native tests suspend real production continuations without radio hardware.

**Executed source-derived results:** Retired bootstrap installed collector: `true → false`. Battery history after A→B: `[22.0, 88.0] → [22.0]`. Replay write owners after source change: `["strap-b"] → []`. Source-switched replay stamped: `true → false`. Retired-store replay stamped: `true → false`.

**Native regression coverage:** Retired post-upsert continuation; battery A→B, store replacement, and A→B→A; current-owner battery positive control; replay batch rejection; stale replay completion. Nine new methods in `BLEStoreBootstrapOwnershipTests.swift`, including the two final registry-snapshot cases below.

**Final independent-review addition:** The detached active-registry read also admitted an A→B→A sequence when the logical ID and nil HR source matched again. The reviewer executed the unchanged production block and observed a stale B snapshot reparent the current A owner. Bootstrap now captures `historicalSourceEpoch` before the registry read and requires equality when applying the snapshot. A mismatch skips only stale registry adoption; collector initialization continues for the explicit current owner. Two added native tests cover the ABA case and unchanged stable adoption. The independent base probe exited 1 with current owner incorrectly `strap-b` after A→B→A (epoch 3); the final extracted block exited 0 preserving `strap-a`, with a stable-startup control still adopting `selected-strap`. Snapshots and logs are preserved in `ble-audit-evidence/independent-registry-aba-*`. The independent reviewer reported no remaining confirmed issue in this BLE patch.

**Regression risk:** Moderate. Raw archive storage remains legacy/unscoped: old files contain family/frame data but no logical device identity. This fix prevents an in-flight operation from changing owner or falsely completing after retirement. It cannot reconstruct the original physical source of an old archive. No archive format, migration, or across-launch ownership reinterpretation was introduced.

### F15 — P2: The HR broadcaster can replay a retired source's cached BPM

**Base evidence:** `HrBroadcaster.swift:126` ignores nil/invalid input; `:226,239` sends `lastBpm` when a central subscribes or becomes ready. `DataSourcesView.swift:90–102` binds this foreground broadcaster to `LiveState`. `LiveState+Biometrics.swift:89` clears HR on source retirement, but the broadcaster retains the old value.

**Production scenario:** Broadcast HR94; WHOOP/provider disconnects or source changes and live HR becomes nil; another central subscribes while the settings screen remains visible; cached HR94 is sent despite no current reading.

**Change:** Clear the replay cache for nil/invalid readings, continue sending nothing, and resume normal behavior on the next valid sample. The existing supported-value range and one-subscription binding remain unchanged.

**Executed source-derived result:** Input `[94, nil]` changes cached value `94 → nil`; sent readings remain `[94]` in both versions, so no synthetic zero or extra notification is introduced. The native regression uses actual LiveState retirement and verifies a subsequent HR112 becomes available.

**Regression risk:** Low. Current HR silence now also means no stale replay to a newly ready subscriber.

## Unchanged protections and disproven/limited leads

- WHOOP5 secure commands carry connection/attempt ownership; historical ACKs bind connection, store generation, session, physical peripheral, and durable source scope. Reassembly is per characteristic, caps frame length, validates headers, and preserves order through a cursor-based buffer. These protections were already present and are not counted as fixes.
- Backfiller captures source/clock/session context before detached decode, commits before ACK, and checks receipt/admission ownership before trimming. Collector retains intake ownership for buffered standard HR/RR and raw frames. The radio/Forget fix uses those existing ownership guarantees rather than changing data ordering.
- The source-derived probe and package tests do not establish firmware layouts beyond the fixture/capture evidence already in the repository. WHOOP4/v24 and WHOOP5/MG/v18, v20, v21, v26 decoding paths, raw IMU/optical boundaries, checksum handling, temperature family distinctions, and timestamp gates were traced without altering them.
- A generic multi-hop `Schema.resolveVersionChain` concern is dormant in the shipped schema: all bundled references are one hop (12→24, 7→5, 9→5). No shipped multi-hop defect was claimed.
- `captureRawAccel` has a possible end-window/buffer-tail timing issue, but repository search found no shipping caller. It is documented as dormant, not a production regression fixed in this PR.

## Remaining leads, explicitly not fixed or claimed verified

1. **WHOOP4 session range lifetime.** GET_DATA_RANGE is issued after bond, its reply assigns Backfiller session bounds, and `Backfiller.begin:414` clears them (the reset is near `:479–480`). `HistoricalStreams.swift:41–49` applies a session-relative window only when both bounds are valid, with a seven-day margin; the independent absolute timestamp gate remains active. The ordering can disable the extra session gate. Reusing old bounds indefinitely could reject genuine newer history after a long connection, and clock correction changes the coordinate question. No range-retention fix was made. A safe follow-up needs a first-admission fixture, late-reply ordering, refreshed/first-pass-only bounds, continued passes, and >7-day connection tests.
2. **Alternate provider radio loss.** StandardHRSource, HuamiHRSource, FTMSSource, and OuraLiveSource clear the live receipt session on central unavailability, but retain cached peripheral/partial state until a disconnect callback. Most concretely, `OuraLiveSource.swift:807–821` leaves its 15-second reengagement and 900-second history timers alive; `:462–472` writes with only peripheral/characteristic presence checks. In the documented no-disconnect-callback radio transition, stale work could persist. This was reported to root as an unfixed experimental-provider lifecycle lead; controlled native/hardware reproduction and generation-safe cleanup are required before claiming it resolved. No alternative provider, pairing consent, or Oura key-install flow was changed.
3. **Parser malformed-envelope hypotheses.** Some legacy field/RR readers bound by full frame length, potentially permitting checksum bytes to be read as payload in a deliberately shortened but valid-CRC frame. Production reassembly and historical integrity checks already reject malformed outer framing, and no authentic firmware/capture scenario was established for the remaining structural cases. No layout tightening was shipped, because it could drop supported historical data. A future fixture must show both the crafted failure and preservation of authentic minimal payloads.
4. **Delayed haptic/liveness callbacks.** Some WHOOP4 delayed pulses and store-dependent liveness decisions merit controlled source-switch tests. No confirmed unintended physical command was demonstrated, and no command scheduling behavior changed.
5. **Legacy archive attribution.** Capturing replay owner fixes within-run reassignment. The existing archive omits original source identity, so across-launch/multi-device attribution remains a format-design limitation. This audit did not claim to repair historical provenance that was never stored.

## Executed verification and reproduction commands

Toolchain: Swift 6.4.1 at `/tmp/noop-swift/usr/bin`. This Linux container runs uid0 and initially retained DAC override, which bypassed an existing read-only-directory fixture. The exact failing test was `RawHistoryArchiveRotationTests` at line 108. No assertion or production code was changed to mask it. Dropping only DAC override/read-search capabilities made the focused fixture pass, then the entire package suite passed with ordinary file-permission semantics.

Build (the host sandbox needed escalation for SwiftPM local sockets):

```bash
PATH=/tmp/noop-swift/usr/bin:$PATH \
CLANG_MODULE_CACHE_PATH=/tmp/noop-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/noop-spm-module-cache \
swift test --package-path Packages/WhoopProtocol \
  --cache-path /tmp/noop-spm-cache \
  --config-path /tmp/noop-spm-config \
  --security-path /tmp/noop-spm-security \
  --scratch-path /tmp/noop-whoop-protocol-audit-build
```

Final complete run of the built test product:

```bash
setpriv --bounding-set=-dac_override,-dac_read_search \
  /tmp/noop-whoop-protocol-audit-build/out/Products/Debug-linux-x86_64/WhoopProtocolTests-test-runner \
  > /tmp/noop-whoop-protocol-final.log 2>&1
```

Final result: exit 0; `Executed 546 tests, with 0 failures (0 unexpected) in 5.855 (5.855) seconds`. Log preserved under `ble-audit-evidence/WhoopProtocol-546-final.log`.

Source-derived probes are preserved in `ble-audit-evidence/`. They compile literal production method bodies or control-flow blocks against small deterministic boundary stubs. These are **not** full app or native transport tests. The wrapper models the selected interleaving; actual-source assertions are separate from hardware claims.

```bash
python3 /tmp/noop-ble-release-probes/prepare.py
swiftc -module-cache-path /tmp/noop-ble-clang-cache \
  /tmp/noop-ble-release-probes/fallback.swift -o /tmp/noop-ble-release-probes/fallback
/tmp/noop-ble-release-probes/fallback
swiftc -parse-as-library -module-cache-path /tmp/noop-ble-clang-cache \
  /tmp/noop-ble-release-probes/cancellation.swift -o /tmp/noop-ble-release-probes/cancellation
/tmp/noop-ble-release-probes/cancellation

python3 /tmp/noop-ble-release-probes/ownership.py
# Compile/run bootstrap-before.swift and bootstrap-after.swift with -parse-as-library.
# Compile/run broadcaster-before.swift and broadcaster-after.swift normally.
python3 /tmp/noop-ble-release-probes/replay.py
# Compile/run replay-before.swift and replay-after.swift with -parse-as-library.
swiftc -parse-as-library -module-cache-path /tmp/noop-ble-clang-cache \
  Strand/App/SourceTransitionFence.swift /tmp/noop-source-identity-probe/main.swift \
  -o /tmp/noop-source-identity-probe/probe
/tmp/noop-source-identity-probe/probe
```

The `ownership.py` and `replay.py` generators read the exact base with `git show` and the working-tree production source, then produce both revisions. The identity fixture currently contains the corrected extracted methods; the report records the observed base result above. Snapshot wrappers are retained for direct inspection/recompilation. Generated probe binaries are not deliverables.

Final syntax verification ran `swiftc -frontend -parse` across the four modified production files and all six modified/new native test files listed below; exit 0. `git diff --check` also exited 0. These checks do not prove Apple-module type checking, strict concurrency acceptance, or runtime behavior. Parent/root owns final exact-commit native CI and release metadata.

## Required native and hardware checks

Run the new native tests plus existing connection-intent, background reconnect handoff, historical commit/ACK ownership, source-transition, provider-receipt, background expiration, and collector ownership suites. Then test WHOOP4 and WHOOP5/MG with Bluetooth off/on, resetting/restoration, Forget during history and standard HR buffering, rapid A→B→A selection, suspended restore/bootstrap, and background-task expiry before first execution. Verify durable samples remain under their captured source, no old ACK or command goes to the replacement strap, secure retry caps remain bounded, and incoming sampling/collection cadence is unchanged. Exercise the current-owner positive controls; a blanket refusal to initialize or adopt is not a passing fix.

Physical energy, whole-app CPU, memory growth, startup, and rendering results were not measured by this specialist. Synthetic counts describe avoided work only.

## Reviewed-file manifest

Paths below are relative to the repository. “Full” means implementation declarations/bodies and relevant lifecycle/parser comments were read; it does not claim a hardware test or every cross-package behavior. The directory lists are generated from the final source inventory after manual inspection.

### Full assigned implementation sources

- `Strand/BLE/BLEManager.swift`
- `Strand/BLE/DebouncedLogTailPersistence.swift`
- `Strand/BLE/ExperimentalBrand.swift`
- `Strand/BLE/FTMSSource.swift`
- `Strand/BLE/FrameRouter.swift`
- `Strand/BLE/GarminBroadcast.swift`
- `Strand/BLE/HistoricalSyncBackgroundScheduling.swift`
- `Strand/BLE/HrBroadcaster.swift`
- `Strand/BLE/HuamiHRSource.swift`
- `Strand/BLE/HuamiHeartRate.swift`
- `Strand/BLE/LiveHRSource.swift`
- `Strand/BLE/LiveHeartRateProviderSession.swift`
- `Strand/BLE/LiveHeartRateReceipt.swift`
- `Strand/BLE/LiveState+Battery.swift`
- `Strand/BLE/LiveState+Biometrics.swift`
- `Strand/BLE/LiveState+Log.swift`
- `Strand/BLE/LiveState.swift`
- `Strand/BLE/OuraLiveSource.swift`
- `Strand/BLE/PuffinDeepBufferLog.swift`
- `Strand/BLE/PuffinEventLog.swift`
- `Strand/BLE/PuffinExperiment.swift`
- `Strand/BLE/PuffinFrameRecorder.swift`
- `Strand/BLE/SourceCoordinator.swift`
- `Strand/BLE/StandardHRSource.swift`
- `Strand/BLE/StandardHeartRate.swift`
- `Strand/BLE/StuckStrapDetector.swift`
- `Strand/BLE/WhoopModel.swift`
- `Strand/Collect/Backfiller.swift`
- `Strand/Collect/ClockCorrelation.swift`
- `Strand/Collect/ClockPolicy.swift`
- `Strand/Collect/Collector.swift`
- `Strand/Collect/PrunePolicy.swift`
- `Strand/Collect/RawCaptureWindow.swift`
- `Strand/Collect/StorePaths.swift`
- `Packages/WhoopProtocol/Sources/WhoopProtocol/BadClockDiagnostics.swift`
- `Packages/WhoopProtocol/Sources/WhoopProtocol/DataRange.swift`
- `Packages/WhoopProtocol/Sources/WhoopProtocol/DeviceFamily.swift`
- `Packages/WhoopProtocol/Sources/WhoopProtocol/FTMSDecode.swift`
- `Packages/WhoopProtocol/Sources/WhoopProtocol/FitnessSensorDecode.swift`
- `Packages/WhoopProtocol/Sources/WhoopProtocol/Framing.swift`
- `Packages/WhoopProtocol/Sources/WhoopProtocol/HapticClock.swift`
- `Packages/WhoopProtocol/Sources/WhoopProtocol/HapticPayloads.swift`
- `Packages/WhoopProtocol/Sources/WhoopProtocol/HistoricalMeta.swift`
- `Packages/WhoopProtocol/Sources/WhoopProtocol/HistoricalStreams.swift`
- `Packages/WhoopProtocol/Sources/WhoopProtocol/Interpreter.swift`
- `Packages/WhoopProtocol/Sources/WhoopProtocol/LinkPolicy/BackfillDrainOwnership.swift`
- `Packages/WhoopProtocol/Sources/WhoopProtocol/LinkPolicy/BackfillPolicy.swift`
- `Packages/WhoopProtocol/Sources/WhoopProtocol/LinkPolicy/BatchedRetryingSink.swift`
- `Packages/WhoopProtocol/Sources/WhoopProtocol/LinkPolicy/ConnectionIntentPolicy.swift`
- `Packages/WhoopProtocol/Sources/WhoopProtocol/LinkPolicy/ContinuousHrvSchedule.swift`
- `Packages/WhoopProtocol/Sources/WhoopProtocol/LinkPolicy/FlushScheduler.swift`
- `Packages/WhoopProtocol/Sources/WhoopProtocol/LinkPolicy/HistoricalBurstPolicies.swift`
- `Packages/WhoopProtocol/Sources/WhoopProtocol/LinkPolicy/LinkDetectors.swift`
- `Packages/WhoopProtocol/Sources/WhoopProtocol/LinkPolicy/RawHistoryArchive.swift`
- `Packages/WhoopProtocol/Sources/WhoopProtocol/LinkPolicy/RealtimeArmPolicy.swift`
- `Packages/WhoopProtocol/Sources/WhoopProtocol/LinkPolicy/ReconnectPolicy.swift`
- `Packages/WhoopProtocol/Sources/WhoopProtocol/LinkPolicy/WhoopCommand.swift`
- `Packages/WhoopProtocol/Sources/WhoopProtocol/LiveSessionHaptics.swift`
- `Packages/WhoopProtocol/Sources/WhoopProtocol/PostHooks.swift`
- `Packages/WhoopProtocol/Sources/WhoopProtocol/PpgHr.swift`
- `Packages/WhoopProtocol/Sources/WhoopProtocol/PuffinCapture.swift`
- `Packages/WhoopProtocol/Sources/WhoopProtocol/Resources/whoop_protocol.json`
- `Packages/WhoopProtocol/Sources/WhoopProtocol/Schema.swift`
- `Packages/WhoopProtocol/Sources/WhoopProtocol/SleepSessionWindow.swift`
- `Packages/WhoopProtocol/Sources/WhoopProtocol/StrapClockRecoveryPlanner.swift`
- `Packages/WhoopProtocol/Sources/WhoopProtocol/Streams.swift`
- `Packages/WhoopProtocol/Sources/WhoopProtocol/Values.swift`
- `Packages/WhoopProtocol/Sources/WhoopProtocol/VersionCheck.swift`
- `Packages/WhoopProtocol/Sources/WhoopProtocol/Whoop4AlarmPhysicalTest.swift`
- `Packages/WhoopProtocol/Sources/WhoopProtocol/Whoop4AlarmTransaction.swift`
- `Packages/WhoopProtocol/Sources/WhoopProtocol/Whoop5Config.swift`
- `Packages/WhoopProtocol/Sources/WhoopProtocol/Whoop5RawImu.swift`
- `Packages/WhoopProtocol/Sources/WhoopProtocol/Whoop5RawOptical.swift`
- `Packages/WhoopProtocol/Sources/WhoopProtocol/Whoop5V18SpO2Candidate.swift`
- `Packages/WhoopProtocol/Sources/WhoopProtocol/WhoopDecoderSchema.swift`
- `Packages/WhoopProtocol/Sources/WhoopProtocol/WhoopGattServiceFamily.swift`
- `Packages/WhoopProtocol/Sources/WhoopProtocol/WhoopProtocol.swift`
- `Packages/WhoopProtocol/Sources/whoop-decode/main.swift`

### Full supporting files and focused test sources

- `AGENTS.md`
- `docs/CONTRIBUTING.md`
- `Packages/WhoopProtocol/Package.swift`
- `Packages/NoopPhase34Core/Sources/NoopPhase34Core/Whoop5SecureSession.swift`
- `Packages/NoopPhase34Core/Sources/NoopPhase34Core/ConfirmedWriteTokenQueue.swift`
- `Strand/App/SourceTransitionFence.swift`
- `StrandiOS/App/HistoricalSyncBackgroundTaskRegistrar.swift`
- `StrandiOS/App/BackgroundTaskLaunchPolicy.swift`
- `StrandiOSTests/BLEConnectionIntentTests.swift`
- `StrandiOSTests/BLEBackgroundReconnectHandoffTests.swift`
- `StrandiOSTests/BLELinkEpitaphTests.swift`
- `StrandiOSTests/BackgroundFlushOwnershipTests.swift`
- `StrandiOSTests/BackgroundTaskExpirationHandlerTests.swift`
- `StrandiOSTests/SourceCoordinatorTransitionRegressionTests.swift`
- `StrandiOSTests/HrBroadcasterRegressionTests.swift`
- `StrandiOSTests/BLEConnectionRetirementTests.swift` (new)
- `StrandiOSTests/BLEFallbackPublicationTests.swift` (new)
- `StrandiOSTests/HistoricalSyncCancellationTests.swift` (new)
- `StrandiOSTests/SourceIdentityAdmissionTests.swift` (new)
- `StrandiOSTests/BLEStoreBootstrapOwnershipTests.swift` (new)

### Targeted cross-domain/test inspection

- `Strand/App/AppModel.swift`: source coordinator composition, active source publication, durable transition dependencies, physical replacement, and make-active/restore/background callers (including 645–715, 1535–1605, 1650–2035).
- `Strand/Data/DeviceRegistry.swift`: full observable registry implementation, including active/pin mutation and source descriptor. This file was read but not changed.
- `Packages/WhoopStore/Sources/WhoopStore/DeviceRegistryStore.swift`: physical identity adoption and lineage/cursor epoch updates; no schema changes.
- `Packages/WhoopStore/Sources/WhoopStore/StreamStore.swift`: upsert/insert async boundary and original write contract.
- `Packages/WhoopStore/Sources/WhoopStore/Reads.swift`: battery sample read signature/ownership.
- `Packages/NoopPhase34Core/Sources/NoopPhase34Core/SourceTransitionRecoveryCoordinator.swift`: perform/quiescence/stop ordering, not a full independent recovery audit.
- `Strand/Screens/DataSourcesView.swift`: HR broadcaster construction, binding, onAppear/onDisappear lifecycle.
- `Strand/Screens/AddDeviceWizard.swift`: provider preview/scanner construction and `feedsLive: false` use.
- `StrandiOSTests/CollectorOwnershipTests.swift`: intake-owner fixtures, first 140 lines.
- `StrandiOSTests/LiveHeartRateReceiptTests.swift`: source receipt fixtures, first 75 lines.
- `StrandiOSTests/BackfillPolicyTests.swift`: selected background/admission and materialization generation fixtures, including 300–360 and 807–822.
- `Packages/WhoopProtocol/Tests/WhoopProtocolTests/RawHistoryArchiveRotationTests.swift`: exact failed fixture, 80–120; rerun unchanged under ordinary permission semantics.
- Protocol test sources for framing, WHOOP4/5 layouts, historical timestamps and fixture integrity were searched/read as needed while tracing their production implementations. The entire 546-test suite was run; this is not a claim that every test source was read line by line.

### Explicit exclusion

No Coach/AI prompt, template, instruction, scientific kernel, UI layout, release metadata, backend, signing, hardware, or repository publication action was edited/performed by this specialist. Other agents' changes in the shared checkout are outside this specialist's change ownership.
