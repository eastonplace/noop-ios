# NOOP 2.0 release-hardening audit

Audit date: 2026-10-23. Repository: `eastonplace/noop-ios`.

## Release decision

**NO-GO for production publication at this stage.** The confirmed fixes are intended for one unmerged draft PR. Native iOS qualification, the exact combined 2.0 candidate, physical WHOOP lifecycle checks and device performance/energy measurements remain release gates. Passing a host test or a source audit is not evidence that a physical strap, an app suspension, or an App Store archive has been qualified.

The user clarified that PR78 is the intended output, not a prerequisite merge. The audit started from the verified default branch, `main` at `a7ade2598d439d33cd20816d69ccc991b29322fc`, which merges PR74. Recent merged work from PR68 onward and the CI/release changes were considered. GitHub assigned this audit [PR79](https://github.com/eastonplace/noop-ios/pull/79) because another hardening draft, [PR78](https://github.com/eastonplace/noop-ios/pull/78), appeared during the audit at 14:26 UTC. At 17:57:42 UTC, that separate PR merged into main as `b7ebe85b2a7f5c0d25f2ef5a04b9d8dce8815679`. This branch now incorporates that main revision and resolves its three conflicts while preserving both sets of fixes. PR77 remains a separate open, unmerged PR and is **not incorporated**. Build 250 stays above current main's 249; marketing version remains 2.0.0 under the held batch policy.

No scientific formula, physiological threshold, collection cadence, backend contract, database schema, historical migration, Coach prompt, prompt template, or model instruction is intentionally changed. No phone installation, release, tag, deployment, device command or production health-data access was performed.

## Findings and changes

Priorities describe the concrete impact: P0 release-blocking catastrophic defect, P1 high-priority correctness/reliability/privacy, P2 important performance/stability, P3 lower-priority improvement. No P0 defect has been demonstrated in the inspected paths; that is not a certification that none exist elsewhere.

The audit confirmed **16 finding groups: 13 correctness/reliability/privacy bug groups, two performance bottlenecks and one release-configuration gap**. This patch addresses **15 groups**, including 12 of the 13 bugs. **F16, the existing non-Gregorian calendar/storage-key defect, remains an unresolved P1 and a production release gate** because its correction requires a coordinated multi-store data migration. Nine findings are P1 and seven are P2. No P3 speculative optimization is included. The separate PR78 may repair some of the same underlying import defects; these counts describe this audit against its verified base, not additive unique defects across both drafts.

Source references below are repository-relative paths. Base references describe `a7ade259`; fix references describe this patch. Specialist appendices retain the detailed execution paths, coverage boundaries and reproduction evidence. Several closely related symptoms are counted as one root-cause group rather than inflating the count for each assertion.

### F01 · P1 · Bluetooth radio loss and Forget leave connection work alive

**Root cause and path.** On the base, `BLEManager.centralManagerDidUpdateState` invalidates historical admission but does not perform the complete normal-disconnect teardown. CoreBluetooth need not deliver that callback for each peripheral when the central leaves powered-on. Forget also clears the peripheral before the later callback can satisfy the active-peripheral guard. Secure state, timers, connection proof, queued writes and buffered work can survive a retired link.

**Fix.** `Strand/BLE/BLEManager.swift` factors normal cleanup into `retireConnectionState(reason:)` and invokes it synchronously for radio loss and Forget. It advances connection ownership, ends secure/history work, clears characteristics and timers, and flushes the **captured original collector**. Pending callbacks and writes require a powered-on central. Invalidated peripheral objects are discarded for the central states that invalidate them. Retry intent, caps, pause deadlines and requested realtime mode survive according to the existing policy. No received sample is intentionally discarded to save energy.

**Evidence and tests.** A source-derived lifecycle probe reproduces stale connected state on radio loss. Six native connection-retirement tests passed in the first complete app run. That run failed in an existing deadline-timer test with state consistent with simulator-radio interference: an initial unavailable-state callback can retire its synthetic link before the timer completes. The callback timing was not instrumented in the native log; the competing retirement path is source-traced and exercised by deterministic controls. The follow-up isolates only that timer fixture from unsolicited callbacks, retains its original assertions and adds explicit future/expired reconnect-delay retirement controls. The production initializer and secure retry policy are unchanged; exact final-head CI remains the gate. The existing source-extracted connection-callback harness now includes powered-off/resetting surfaces: 15 scenarios pass; the base fails four new radio-admission assertions. Existing protocol tests pass 546/546 on the host. Physical disconnect/restoration and background Bluetooth behavior remain required.

### F02 · P2 · An expired background launch can start another transfer

**Root cause and path.** `StrandiOS/App/HistoricalSyncBackgroundTaskRegistrar.swift` constructs an unstructured main-actor operation. Expiration can cancel it before its body first executes, yet the old body calls `requestSync` without checking cancellation. Cancellation does not prevent a Swift task from beginning execution.

**Fix.** Check cancellation at operation admission and before requesting synchronization. Keep normal operation completion/expiration ownership unchanged.

**Reproduction.** Cancel the task before allowing its first actor turn: the old path makes one sync request, the corrected path makes zero; a noncancelled positive control still makes one. `HistoricalSyncCancellationTests` exercises the production operation factory. This is an operation-count result, not a measured energy percentage.

### F03 · P2 · WHOOP 5/MG fallback republishes identical state for every reading

**Root cause and path.** Standard-HR notifications during an unverified/paused secure session repeatedly assign identical `@Published` mode text and append the same log, after processing the reading. Continuous notifications produce repeated observer, UI and logging work.

**Fix.** `BLEManager.updateWhoop5StandardHRFallback()` publishes/logs only a mode transition. `parseStandardHR` still processes every notification first. No characteristic subscription, sampling rate, sensor accuracy or history completeness is reduced.

**Measured operation counts.** A source-derived probe with 3,600 identical notifications records 3,600 mode/log events before and one after. Another 3,600 notifications after entering the paused mode bring the total to 7,200 before and two after. Physical radio activity and battery use were not measured.

### F04 · P1 · Coach can mix credentials, destinations, consent and request lifetimes

**Root cause and path.** `Strand/AI/AICoach.swift` reads a credential before awaiting context, then reads mutable provider/model/endpoint state to send. A settings change during that suspension can combine the old key and data with a new destination. Custom-provider compatibility retries reread the server URL. Stale completion/defer can publish under changed ownership or reset a newer request. Previously consented conversation history remains eligible for later outbound requests after consent changes.

**Fix.** Capture an immutable request configuration, including client, key owner, model, server, source/database invalidation state, consents and existing system prompt. Request IDs and a generation fence own cancellation/completion. Validate before network admission and before publication. Custom clients pin both endpoints across retries. Provider/consent/source changes invalidate outbound history while retaining the visible transcript. Concurrent sends are guarded. Model-list publication uses the same configuration validation.

**Evidence.** Deterministic URLProtocol tests suspend context/model/network responses, change settings or ownership, and inspect synthetic destinations, headers, state and history. They use no real key or external endpoint. The focused full-engine harness passes 30/30 cases, including previous provider races. The baseline fails 15 newly added cases with 21 assertions. All existing literals across the 32 reviewed AI/Coach Swift files are preserved; the only new provider literals are the two transport endpoint paths. An independent reviewer additionally reproduced a retired-source compatibility retry: the preliminary fix rejected the final reply but still made a second HTTP attempt. Per-attempt admission in the shared HTTP boundary now rejects that retry for both Custom and OpenAI, while stable 400-retry positive controls pass. The complete app and all 20 native request-ownership cases compiled and passed in the initial native run. The run as a whole failed on the separate Bluetooth timer-fixture issue documented below.

### F05 · P2 · Weekly Coach insight cache crosses source/database ownership

**Root cause and path.** The weekly insight store is keyed by week/day only. Trends displays a matching-week value regardless of source. A same-day source change or replacement database can display prior records' private insight and suppress regeneration. An older suspended task can also clear a newer task handle or publish after context invalidation.

**Fix.** Add an optional durable source/database owner to the existing Codable cache. Legacy caches remain decodable but production readers require current ownership. `LocalCoachEngine` captures the full scope, fences task IDs, propagates cancellation and clears weekly state on owner/consent changes. Trends filters cached text against the repository's current scope and fence.

**Evidence.** Eight focused actual-method/store cases pass; the old implementation fails six cases with ten assertions. Tests cover legacy/foreign caches, same-day refresh, source/database fence and task/cancellation ownership. Weekly model instructions and prompt text are byte-preserved. No high-risk cache redesign or migration was introduced.

### F06 · P1 · Visible canonical sleep cannot be reliably edited, deleted or snapshotted

**Root cause and path.** At base `Repository.swift:3503–3509,3562–3570,3628–3650`, writes use only the active device namespaces while reads include canonical history after re-pairing. Undo snapshots perform an interval read at the immutable detected onset; a forward-edited effective onset no longer overlaps that second. A missing snapshot can still create a tombstone and deletion can lose its undo context.

**Fix.** Resolve the exact natural key across existing computed/imported read namespaces, preserving the established computed-first precedence. Snapshot/delete together in the store transaction. A missing/failed deletion is not success and does not create a tombstone. Restore uses the original saved namespace.

**Evidence.** Synthetic SQLite reproduces zero-row legacy edits after re-pair and the missing snapshot for a row adjusted from 1000 to 3400. Native repository tests exercise actual visible canonical rows, moved onsets, no-op/error deletes and ownership round trips. See [data review](data-review.md) for exact SQL/source evidence.

### F07 · P2 · Repeated sleep edits remove minutes repeatedly

**Root cause and path.** Base `Repository.swift:3497–3499` gives the reclip kernel the immutable detected onset, even after stage totals already reflect a previous edit. Saving unchanged edited bounds clips the same period again.

**Fix.** Use the currently stored effective onset, end and stages. Retain existing raw-stream restaging precedence and the exact reclip formula. Before committing, compare the complete fresh snapshot so a concurrently added recovery overlay or auxiliary track cannot be silently overwritten.

**Evidence.** The production kernel with the old caller contract changes light sleep from 270 to 230 minutes on the second unchanged save. The corrected contract preserves 270 and all other literal stage totals. A review-discovered overlay race failed three assertions before strengthening the snapshot comparison; the final real-GRDB transaction suite passes.

### F08 · P2 · Sleep UI and engine disagree across DST/duplicate history

**Root cause and path.** Base `Repository.swift:3406–3429` uses the current UTC offset for 28 historical nights and omits the engine's overlap deduplication. `IntelligenceEngine.swift:4708–4747` already uses each midpoint's historical offset and existing dedup policy. The same records can produce different habitual times and selected main nights.

**Fix.** Align the repository adapter with those existing engine inputs. The learner, selector and scoring formulas remain unchanged. Only helper visibility changes in the engine for a direct parity test.

**Evidence.** Twenty-eight synthetic New York nights with 03:00 local midpoint across autumn DST produce 02:30 in the old UI adapter versus 03:00 in the engine. Two eligible same-wake-day groups are consequently selected differently. Corrected native tests compare the actual repository with the actual engine, and verify seven real nights plus shifted duplicates do not incorrectly satisfy a fourteen-day history gate.

### F09 · P1 · Undo of recovered sleep loses protected Rest/Charge and can appear successful after failure

**Root cause and path.** The session-delete trigger intentionally invalidates the recovery override, daily fields and Rest series (`SleepRecoverySchema.swift:216–282`). Base undo (`Repository.swift:3589–3614`) stores only the session and decoded tracks, lifts the tombstone first and performs separate best-effort writes. It cannot restore protected recovery evidence atomically. The UI ignores the Boolean restore result.

**Fix.** `SleepSessionUndoStore.swift` snapshots the session, original owner, database identity, raw auxiliary JSON and all attached recovery overrides. One transaction restores them and the derived protected daily/Rest fields while preserving current non-sleep activity. Replacement databases, occupied session keys or conflicting protected days fail closed. Tombstones are lifted only after success. SleepView retains failed undo with retry copy and scopes completion/timeouts to a banner UUID.

**Evidence.** Legacy delete/reinsert of a recovered row with Charge 78 and Rest 88 leaves zero overrides, NULL recovery and zero Rest points. Ten real-GRDB tests now pass, including failure rollback, full auxiliary/provenance round trip, newer activity preservation, replacement-database and conflicting-row refusal, and the edit/overlay race. Nine added app tests cover the repository adapters. The existing transient undo/UserDefaults tombstone mechanism remains separate; cross-store crash atomicity is not claimed.

### F10 · P1 · Malformed imported numbers can terminate the app

**Root cause and path.** Apple XML permits `Double("NaN")` into daily HR aggregation; `AppleHealthImport` then performs a trapping `Int` conversion. WHOOP CSV's finite-number guard still admits a finite `1e100`, which later traps similarly. A large sum of individually representable steps can also overflow the destination integer.

**Fix.** `ImportNumericSafety` checks representability with `Int(exactly:)` after the existing rounding policy. Apple aggregation rejects nonfinite and unrepresentable integer-bound fields before they contaminate means; summed steps are checked again. WHOOP cycle/workout HR fields and both persistence adapters use the same safety boundary. Valid fractional inputs retain the original nearest/truncation behavior. Importer revisions advance for mapping changes.

**Evidence.** An actual-source XML/parser/aggregator probe on the base terminates with signal 4 at NaN-to-Int conversion. Five actual-source package regression methods pass for NaN, infinities, integer bounds, finite huge numbers, sum overflow and valid rounding. Two native import-to-store tests cover a real temporary XML export and WHOOP CSV while preserving valid recovery, duration and readings. This does not claim comprehensive validation of every malformed field type.

### F11 · P2 · Canonical HR tail correction rebuilds the whole live-workout projection

**Root cause and path.** `WorkoutLiveProjectionCache.swift` treats a corrected BPM at the existing final timestamp as a structural history change, sorting/replaying the entire workout. `ActiveWorkout` legitimately replaces the canonical current second. The accumulator already provides an exact `replaceCurrentSecond` operation.

**Fix.** Use that existing operation for the matching timestamp; retain rebuilds for timestamp changes, shrink, profile changes and rejected incremental operations. No math or collection/update cadence changes.

**Evidence.** Four optimized Swift host benchmarks run 20 warmups plus 200 measured iterations each. Every correction/appending update is compared against a fresh authoritative projection outside timing: 880 exact calorie/zone/trace comparisons per revision. The six-hour, unpaused case falls from median 2.5878565 ms / p95 3.379067 ms to 0.0057885 ms / 0.007371 ms. These numbers apply to that synthetic processing path only. Native tests additionally cover repeated corrections, pauses, profile changes, shrink and timestamp fallbacks.

### F12 · P1 · App and widget lack required-reason API manifests

**Root cause and path.** The base contains no `PrivacyInfo.xcprivacy` in either target, although app/extension code uses required-reason APIs. Dependency manifests do not declare the app's own usage. This is a distribution-configuration gap, not an observed App Store rejection.

**Fix and rationale.** Add narrowly scoped API declarations: own-app defaults (`CA92.1`), same-group defaults (`1C8F.1`), own-container file metadata (`C617.1`), user-selected file metadata (`3B52.1`), elapsed-time/boot-clock use (`35F9.1`), and write-capacity checks (`E174.1`). The widget declares shared defaults only. No unsupported blanket data-collection/tracking statement is added.

**Source evidence.** `WidgetSnapshot`/`WidgetPersonalZones` use group defaults; `IntelligenceAnalysisCoordinator:167–168`, `AppModel:3934,4163` and `BackupSync:312` read own-container metadata; `DataBackup:746,899` reads selected-file metadata; `IOSDiagnostics:70,91,106,131` and history deadlines use elapsed uptime; `DataBackup:907–918` checks restore capacity. Apple references: [required-reason policy](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api), [API categories and approved reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).

**Verification.** Both files parse as valid property lists. Both new native tests passed against the compiled app and embedded `NOOPWidgets.appex`; source presence alone cannot pass. The signed archive's aggregate privacy report and actual distribution declarations still require release qualification.

### F13 · P1 · A delayed connection identity can be assigned to a different source

**Root cause and path.** `SourceCoordinator.connectedPeripheralChanged` queues a raw peripheral UUID behind `SourceTransitionFence`, then resolves the active source only when admitted. During an A-to-B transition, A can finish connecting while the transition awaits quiescence. The queued callback then runs after B commits and can persist A's UUID into unpinned B. Reading encrypted-bond state at that later time can also borrow proof that did not exist when the notification arrived.

**Fix.** Capture active device, observation generation and bond proof at callback intake. Validate owner and generation inside the fence. Source transitions and newer identity observations invalidate older admissions, including leave-and-return to the same source ID. Retain legitimate current-source identity adoption.

**Evidence.** A probe using the actual transition fence and extracted coordinator methods reproduces A remaining unpinned while B acquires `uuid-from-strap-a`. Added native tests hold the actual coordinator's fence and cover source switch, same-ID reactivation, latest observation and pre-bond proof. See the Bluetooth appendix for final red/green results.

### F14 · P1 · Suspended store bootstrap can resurrect retired handles or another source's battery history

**Root cause and path.** `BLEManager.bootstrapStore` checks store generation after opening and registry lookup, but not after the awaited device upsert before installing its collector/backfiller. A database replacement during that await can therefore be followed by publication of old handles. The later battery seed similarly reads one owner and can publish after the source/database has changed.

**Fix.** Revalidate store identity/generation and restore state after suspended writes. Capture and validate battery owner, source epoch and HR-source identity around the read, including an A-to-B-to-A sequence. Rejected-history replay also captures its owner and revalidates store/source ownership before every family insert and before advancing its completion stamp; the legacy archive format is unchanged. Injectable store operations exercise these real production continuation boundaries without physical hardware.

**Evidence.** Native tests replace the database during device upsert and switch source, replace storage, or leave-and-return during battery reads. The expected outcome is no retired collector/backfiller and no old-source battery seed. Nine native bootstrap tests cover these paths, same-owner success and obsolete replay admission/completion. Source-derived probes reproduce collector resurrection, mixed battery seeds and stale replay stamping and verify the narrow guards. The independently reproduced registry A-to-B-to-A case is also guarded by the source epoch, with stable startup adoption retained. These checks protect persistence ownership; they do not measure battery life.

### F15 · P2 · Heart-rate rebroadcast retains the retired source's value

**Root cause and path.** `HrBroadcaster.update` ignores nil/invalid readings without clearing `lastBpm`. `LiveState.clearBiometrics` publishes nil on retirement, but a later subscriber/readiness callback can still replay the prior strap's cached BPM.

**Fix.** Clear the replay value when current HR becomes unavailable or invalid; continue sending nothing for that state. A subsequent valid reading resumes the existing behavior. No fabricated zero BPM, new notification or cadence change is introduced.

**Evidence.** The regression feeds valid HR, retires the source through nil and verifies the replay cache is empty, then verifies a later valid reading is retained. Existing one-subscription/rebinding tests remain intact.

### F16 · P1 · Non-Gregorian calendar settings split persisted day identity — unresolved

**Root cause and path.** Normal analysis in `IntelligenceAnalysisCoordinator` passes `Calendar.current` to `IntelligenceEngine.civilDayWindows`. The latter formats that calendar’s era/year/month/day directly into storage keys. `Repository.localDayKey` and `logicalDayKey` do the same. Imports, refresh ranges, exact historical receipt work and `WhoopStore.localDayKey` already use Gregorian keys. Thus the same actual local day can be written, queried and displayed under incompatible identifiers. Daily metrics, metric series, manual journal entries/day notes, recovery overrides and hydration buckets are implicated. The preexisting native DL-05 test explicitly skips this known mismatch; this patch neither introduces nor hides that skip.

**Reproducible evidence.** A synthetic probe compiles nine unchanged production helper declarations. At 06:00 Bangkok on Gregorian 2026-10-12, normal engine/local/logical keys are `2569-10-12` under Buddhist settings, `0008-10-12` under Japanese, `5787-02-01` under Hebrew and `1448-04-29` under Islamic Civil. Refresh/store keys remain `2026-10-12`. All five calendars produce the same start instant, `1791738000`, and 86,400-second interval for this date, isolating a key-identity defect rather than a DST arithmetic defect. A separate synthetic SQLite contract probe demonstrates a Gregorian range missing the computed Buddhist row, a missing hydration lookup after changing only the key helper, a journal primary-key collision during naive re-key, and removal of the non-Gregorian computed row by the existing timestamp-heal predicate. These are extracted-helper and SQL-contract reproductions, not an executed end-to-end device migration.

**User impact.** Related screens and analysis lanes can omit or disagree about the same day’s metrics; changing calendar settings can strand manual history. The existing timestamp-heal filter can remove derived rows whose alternate-calendar strings appear implausibly old or future-dated. No raw sensor loss is demonstrated by this reproduction.

**Disposition.** No partial production fix is included. An engine-only change leaves persisted/manual keys inconsistent; a blanket string rewrite risks overwriting distinct entries, losing source ownership or converting ambiguous historical calendar/era values incorrectly. [The migration proposal and exact source trace](calendar-key-migration-proposal.md) define the required canonical helper, provenance/collision policy, resumable cross-store migration and native regression matrix. [The runnable probe](calendar-key-probe.py) and its recorded results accompany the proposal. Resolve and qualify this coordinated change before production publication.

## Measured performance

The host is Linux x86_64, glibc 2.39, Swift 6.4.1 with `-O`. The benchmark compiles the production cache, accumulator, pause ledger, calories and zone implementations; only the app/ProfileStore object boundary is stubbed. Inputs are synthetic one-Hz HR streams, a corrected tail and ten appended readings per iteration. The pause case includes a three-minute gap. No personal health data is used. The raw JSON reports and reproducible [benchmark script](../../../Tools/qa/workout_projection_benchmark.py) accompany this report.

| Projection input | Median before | Median after | p95 before | p95 after |
|---|---:|---:|---:|---:|
| 3,600 samples | 0.538209 ms | 0.004307 ms | 0.666878 ms | 0.006380 ms |
| 3,600 samples, pause | 0.542951 ms | 0.004447 ms | 0.782823 ms | 0.006029 ms |
| 21,600 samples | 2.587857 ms | 0.005789 ms | 3.379067 ms | 0.007371 ms |
| 21,600 samples, pause | 2.683892 ms | 0.005408 ms | 3.235060 ms | 0.007912 ms |

| Requested area | Before | After | Measured improvement |
|---|---|---|---|
| Cold/warm app startup | Not measured | Not measured | Unavailable without native runtime/device |
| Screen loading/navigation | Not measured | Not measured | Unavailable |
| Scrolling/chart rendering | Not measured | Not measured | Unavailable |
| CPU consumption | Not measured | Not measured | No whole-app CPU percentage claimed |
| Memory/extended sessions | Not measured | Not measured | No allocation/RSS/leak improvement claimed |
| Data processing, six-hour corrected projection | Median 2.587857 ms; p95 3.379067 ms | Median 0.005789 ms; p95 0.007371 ms | 99.78% lower median for this host path |
| Background launch already cancelled | 1 admitted history request | 0 requests | One unnecessary request prevented per reproduced launch |
| BLE fallback mode/log work, 3,600 events | 3,600 publications/logs | 1 publication/log | 3,599 redundant events eliminated |
| Physical Bluetooth/radio/energy usage | Not measured | Not measured | No radio/WHOOP/iPhone battery percentage claimed |

Expected benefit is reduced repeated work, faster long-workout projection updates and fewer obsolete operations. The frequency and device-level magnitude are not established by these host measurements.

## Reproduction artifacts

The [reproduction archive](reproduction-evidence.tar.gz) retains the synthetic source-derived harnesses, baseline/final logs and source snapshots described in the specialist reports. [Its manifest](reproduction-manifest.json) lists every file and SHA-256. It contains no build products, credentials, device captures or real health data. The committed native XCTest files remain the authoritative complete-app regressions. [Exact fix references](source-evidence-index.json) map each finding to a file and line.

## Verification boundaries

- Baseline source/CI audits: 20/20 pass. Final local results are recorded in `final-source-audits.json`; native results must be read from the draft PR checks for the exact pushed head.
- Portable package suites: NoopPhase34Core 111/111, WorkoutRouteExport 11/11, WhoopProtocol 546/546. WhoopProtocol's read-only-directory test initially fails under uid0 DAC override; it passes unchanged when that privilege is dropped, and the final full 546-test run passes. No assertion was weakened.
- Focused source-derived tests: real-GRDB sleep transaction suite 10/10; full cloud-Coach engine/provider suite 30/30; weekly Coach methods/cache suite 8/8; import numeric suite 5/5. These are not full iOS app or full Apple-platform package test results.
- New native tests target real production managers/repositories, persisted database transactions, importer entry points and built resource bundles. All 71 cases in the new or extended regression suites passed in the initial native run. The entire run was not accepted as passing because one preexisting timer fixture failed with state consistent with an unsolicited simulator radio callback retiring its synthetic connection. See the retained result below; final-head execution is required after the correction.
- No Xcode, simulator, Instruments, physical iPhone, WHOOP4, WHOOP5 or MG was attached to this Linux environment. Full native package compilation is blocked here by existing Apple-specific modules such as SQLite3, Compression and CryptoKit. Product code was not weakened or reconfigured solely to make a Linux harness look like native validation.
- Exact preexisting prompt literals are checked against the base. Existing calculation kernels are reused unchanged. The independent reviewer completed the combined functional diff and new tests with no unresolved confirmed defect introduced by the reviewed patch. F16 remains an independently documented, preexisting release blocker outside those fixes. Both additional independently reproduced patch-review findings (Coach retry and bootstrap A-to-B-to-A) were fixed and rerun green. See [independent review](independent-review.md) and its source/test/configuration fingerprint manifest, updated for the fixture follow-up.

## Initial native CI and follow-up

The [initial native run](https://github.com/eastonplace/noop-ios/actions/runs/39971271690) tested head `26e150d2bbd1fcdf14a65de06e834e8b0841d5da` through merge `f0fa85d1d8eea0b8564a41df5991398a543ad641`; their trees are identical. Xcode 26.6 / Apple Swift 6.3.3 compiled the app, widget and test products. Source audits and all nine native safety harnesses passed. XCTest completed 3,321 cases: **3,316 passed, four preexisting skips, one failure**. Swift Testing completed 300 cases in 41 suites with three preexisting known artwork issues. No XCTest case was silently retried. UI execution was correctly withheld after the native failure.

The failure was `BLEBackgroundReconnectHandoffTests.testTheHoldDeadlineEndsTheBackgroundTask`. Its test manager registers for a real simulator central’s initial unavailable-state callback. If that callback arrives while the async test yields, synchronous radio-loss retirement cancels the synthetic attempt’s timer/background task while retaining its future secure reconnect deadline. The test would then stop waiting because its background task has ended and mistake retirement for deadline expiry. The native log does not timestamp the internal radio callback; the observed retained deadline with cleared attempt/timer/background state is consistent with this source-traced path, which the new controls exercise deterministically. Expired dates are already rejected by reconnect admission. Continuing a timer/background task merely to clear the stored date would add unnecessary work and contradict the retirement contract.

The follow-up retains every original timer assertion and the real timer/background-task path. An opt-in flag in the existing internal test/preview initializer suppresses unsolicited central delegate callbacks only for isolated synthetic tests; defaults and the production initializer remain unchanged. Two deterministic radio-loss controls independently require no retired hello, no surviving task/timer, preservation of a future reconnect delay and rejection of an expired delay. The independent reviewer inspects this change; passing exact final-head native/UI checks remains mandatory. [The machine-readable initial result](native-ci-initial-result.json) deliberately preserves the failure rather than relabeling that run as passing.

The [same-head package workflow](https://github.com/eastonplace/noop-ios/actions/runs/39971271696) passed all nine jobs: **3,693 passing cases, one existing optional real-export fixture skip, zero failures**. The skip requires `XIAOMI_REAL_DB`. The native skips additionally include two unavailable local-model-asset cases, the optional real-export integration fixture and the known DL-05 non-Gregorian calendar case discussed separately. Known artwork issues concern SidePlank, FacePull and DeadHang; none was disabled or newly marked expected by this patch.

Read the [draft PR checks and description](https://github.com/eastonplace/noop-ios/pull/79) for the final head’s result. This dated earlier-run evidence does not certify a later commit.

## Current-main integration and retained passing results

After the timer-fixture correction, head `529adf2f652dcb1b98822665c6c4e895b27f5d32` was tested through merge `3679f704708a8b1a45d3791954b58e2ed610973f`; both have tree `b7365556df1ec6ad8cfdb2fd7dee957c76b6395a`. [Native workflow 39977563756, attempt 1](https://github.com/eastonplace/noop-ios/actions/runs/39977563756/attempts/1) compiled the app/widget/test products and passed the full native execution: **3,319 XCTest passes, four existing skips, zero failures**, plus **300 Swift Testing passes with three existing known artwork issues**. All **21 selected UI cases** and all **73 new or extended regression-suite cases** passed. Independent log review paired all 3,344 unique XCTest starts/completions without repeated execution within the attempt. The original deadline test passed once in 0.212 seconds; both new radio-retirement controls passed once.

The aggregate gate then failed on **GitHub HTTP 502** while reading the already-successful package run's attempt-1 job inventory. A subsequent identical read succeeded; this does not relabel the failed gate as green. [Package workflow 39977563656](https://github.com/eastonplace/noop-ios/actions/runs/39977563656) passed all nine jobs with 3,693 passing tests, one existing optional fixture skip and no failures. Neither tests nor gate policy were weakened.

One infrastructure-driven retry was requested from `change-plan` and its dependent jobs because the unchanged workflow's plan/results artifacts and validator are bound to a run attempt. GitHub records attempt 2 starting at **18:08:50 UTC**, after PR78 had merged into main. That retry retains the original head and tested merge; its successful plan does **not** certify the new main integration. Preserve this historical attempt separately from the fresh combined-code CI linked from the draft PR.

The merge from current main retains PR78's complete imported strain/RHR metric-series admission and direct CSV-to-store regression tests. Its `roundedImportedHeartRate` helper now delegates to the same shared safe conversion used by this audit's parser, preserving rounding, malformed-value rejection and valid fractional values. The other conflict resolutions retain build 250 and one cumulative nine-item 2.0 What's New entry; all earlier release history and both installation/publication holds remain intact. `CHANGELOG.md` retains both sets of implemented work. The independent review and integration evidence record the exact reconciled files. All source/test files inherited only from PR78 are preserved; this audit does not count those separate fixes as additional findings.

The final combined source requires fresh native/UI and reverse-dependent package execution. Read the [draft PR](https://github.com/eastonplace/noop-ios/pull/79) for its current commit, workflow identities and actual result. Earlier passing runs are evidence for their stated source only.

## Combined native result and dashboard test synchronization follow-up

The combined head `346da5302250cdff9b57532f18375e561eb06eeb` was tested through merge `e516579ef7da5e30c3674ac627500e1e58ab37a7`; both have tree `1ad4789173e00a5cfd7c8592b56c605c0f5dd826`. [Workflow 40002121607, attempt 1](https://github.com/eastonplace/noop-ios/actions/runs/40002121607) **failed** its selected UI stage and aggregate gate. Native XCTest completed 3,338 cases: **3,334 passed, four existing skips, zero failures**. Swift Testing passed **302 tests in 41 suites with three existing known artwork issues**. All 73 targeted release-hardening cases and all 15 native cases added by integrated main passed exactly once. All nine safety harnesses and source audits succeeded. The separate [package workflow 40002121569](https://github.com/eastonplace/noop-ios/actions/runs/40002121569) passed all nine jobs: **3,716 passing cases, one existing optional fixture skip, zero failures**.

All 21 protected-plan UI methods executed: **20 passed, one failed, none skipped**. Independent log review paired all 3,359 native/UI XCTest starts and completions uniquely, with no repeated execution. The gate correctly rejected the UI failure; this is not the earlier HTTP 502. [The retained machine-readable result](native-ci-combined-result.json) records source identities, exact counts, both diagnostic readbacks, artifact digests, and the original failed outcome.

The failure is `ApprovedDashboardUITests.testDashboardSettingsSelectionPersists`. Its first exact-selection predicate wait timed out while disabling `today.health.sleep`; subsequent diagnostic saved-value and independently parsed reads both exactly matched the intended ordered selection. The error triggered cleanup, whose `today.health.skinTemp` wait also timed out; both subsequent readbacks again exactly matched the expected selection, and the native switch reported enabled. That cleanup assertion masked the original thrown error. The later process-relaunch and Today-rendering assertions did not run, so this failed test is not persistence qualification.

The failing helper re-resolved an app-wide accessibility query inside a predicate callback, then separately read existence and value. The log shows slow/repeated accessibility lookups spanning its eight-second budget. Both the test file and production dashboard-settings view were byte-identical to the earlier passing `529adf2` revision. These facts demonstrate failed readback synchronization; they do not demonstrate lost preferences or prove an application performance regression.

The bounded follow-up changes only the UI test's wait: an exact identifier-and-full-value query uses `waitForExistence(timeout: 8)`. This avoids the interleaved existence/value requests in the callback, follows the repository's existing native-picker test pattern, and retains the original deadline. The physical toggle, preconditions, exact order checks, diagnostics, post-wait selection/native-row checks, relaunch, rendering, and restoration assertions remain unchanged. No production implementation, timeout, test selection, or gate policy is changed. The existing failed UI case is the regression reproduction; **the correction still requires fresh exact-head native UI execution**. Read the [draft PR's current validation record](https://github.com/eastonplace/noop-ios/pull/79) for the later result. This test synchronization follow-up is not counted as an additional application bug or a measured app-speed improvement.

## Reviewed scope and remaining leads

The starting-base source inventory contains 951 tracked production Swift files. Inventory/search coverage is **not** a claim that every line was manually reviewed. The specialist manifests distinguish full-file from targeted inspection, and the root review covers launch/publication, widgets, Live Activities, HealthKit/cleanup, imports/exports, backup capacity, release configuration, CI policy, recent PRs and dependency pins. Large repositories and hardware-dependent failure modes cannot honestly be certified exhaustive from this environment.

Already robust inspected paths include durable history commit/ack ownership, RR source/order policy, measured-HR precedence, civil-day training-load gaps, as-of baseline construction, HealthKit cleanup ownership and notification IPC/claim serialization. These are retained, not counted as newly fixed bugs.

Unconfirmed leads are kept out of the release patch: optional session-relative WHOOP4 range validation can lose its range when an offload begins; blindly retaining an old upper bound could drop valid new history, so range freshness must be designed and tested. Apple Health duplicate bookkeeping still scales with records and warrants realistic memory profiling. Some sleep/chart loaders have awaits that merit controlled navigation/source-change tests. Metric Explorer view computations warrant a rendering profile before changing caches or invalidation. Experimental non-WHOOP provider radio-loss timers/buffers also need controlled qualification; this patch does not claim to harden their complete lifecycle. A PPG arm of a count helper should be checked against its producer constraints before assigning a defect. None of these are represented as reproduced fixed issues.

Dependency review verified the same five external pins across all six resolved lockfiles: GRDB 6.29.3, ZIPFoundation 0.9.20, MarkdownUI 2.4.1, NetworkImage 6.0.1 and swift-cmark 0.9.0. The [ZIPFoundation advisory GHSA-c2cc-3569-6jh2](https://github.com/advisories/GHSA-c2cc-3569-6jh2) affects versions through 0.9.17 and is fixed in 0.9.18, before the pinned version. The exact swift-cmark pin `08ddb528923cc1a6527e02b7a1aee9e516ca749a` contains the maintainer’s [CVE-2023-37463 fix](https://github.com/swiftlang/swift-cmark/pull/61), verified by Git ancestry. Maintainer advisories, releases and reported issues did not establish another applicable defect at these exact pins. This is a bounded check, not an exhaustive vulnerability certification. No speculative dependency upgrade or dead-code deletion was included.

## Required before production

1. Resolve F16 with a coordinated calendar/storage-key correction and migration for existing metrics and manual history. Preserve ambiguous/colliding records, verify restart/rollback behavior, and enable the currently skipped DL-05 test only once complete production behavior is correct. The proposal defines the required regression matrix.
2. Resolve any independent-review or exact-head CI failures. Require actual success for the selected native app, UI and reverse-dependent package jobs, with the existing required contexts intact.
3. Bring together the intended 2.0 batch, including PR77 if it remains in the release; PR78 is now incorporated here. Reconcile any further overlapping patches, then qualify that **exact combined commit** with the repository's full release-candidate validation. Check version/build and cumulative release notes at that point.
4. Run WHOOP4, WHOOP5 and MG physical tests for radio off/on, disconnection mid-transfer, Forget/re-pair/source switch, cold restoration after app/phone restart, repeated foreground/background and prolonged history sync. Verify no sample/ACK ownership loss, unwanted reconnect loop or changed collection cadence.
5. Run minimum-supported iOS17 and the current supported release through permissions denied/revoked, network loss/recovery, interrupted import/restore, low-memory termination and repeated rapid navigation/undo. Exercise midnight/DST and large imported histories in the native app.
6. Capture cold/warm startup, common-screen and chart median/p95, scrolling hitches, long-session memory growth, CPU and background energy/radio traces on a physical iPhone. Compare the same dataset/device/build configuration before and after. Measure WHOOP battery impact over a controlled representative session rather than extrapolating from log counts.
7. Inspect a signed archive's app/widget privacy manifests and aggregate privacy report against actual usage and distribution metadata. Keep the release and all phone installations on hold until Easton calls the combined candidate ready.

Passing the draft's code review and CI permits further qualification; it does not authorize publication or merge.
