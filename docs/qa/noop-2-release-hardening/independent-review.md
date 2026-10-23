# Independent review: NOOP 2.0 release hardening

Date: 2026-10-23. Base: `a7ade2598d439d33cd20816d69ccc991b29322fc`. Branch: `audit/noop-2-release-hardening-20261023`.

## Review outcome

The independent functional review found **two additional P2 correctness defects**. Both have been fixed by their implementation owners and independently reproduced as passing after the fixes. No unresolved confirmed defect introduced by the reviewed patch remains in the inspected production diff. The later F16 follow-up below records a separately confirmed, inherited P1 calendar/storage-key release blocker. This supports preparing the authorized draft PR with its native validation gates; it does not establish release readiness or authorize merge, installation, or publication.

This was a read-only review of application and test sources. The reviewer did not edit production code, commit, push, access real health records, send an external model request, or operate hardware. Isolated synthetic probes were written outside the repository; this report and its manifest were subsequently copied into the repository and updated with review-only follow-ups. `AGENTS.md` and `docs/CONTRIBUTING.md` were read and the held 2.0 batch policy was respected.

The final root-owned CI fixture update was reviewed before handoff. Its existing assertions remain intact and its new radio-state cases demonstrate the intended production gate.

## Independent findings and resolutions

### R1 — P2 — An internal compatibility retry could retransmit a retired source's data

**Location:** `Strand/AI/AICoach.swift:785–797`, `Strand/AI/AIProvider.swift:126–146`; retry callers in `Strand/AI/Providers/Custom.swift` and `Strand/AI/Providers/OpenAI.swift`.

**Reproduction:** Start a Coach request with current source A. While the first HTTP attempt is in flight, fence and reopen the repository source, advancing its invalidation epoch. Return a 400 response stating that `max_tokens` is unsupported. The preliminary request-ownership implementation checked ownership around the complete provider operation, but Custom/OpenAI retried internally. It therefore made a second HTTP request containing A's obsolete context before rejecting the eventual response. Correct final-publication fencing did not prevent this extra transmission.

The independent full-engine/provider test initially failed with **two requests instead of one**. The UI owner reproduced the same failure for both providers, while stable-source retry positive controls passed.

**Minimum fix implemented:** Scope a request-specific ownership check through `AIRequestAdmission` for the duration of `provider.send`. The shared `performRequest` checks task cancellation, checks ownership on the main actor, and checks cancellation again immediately before every HTTP attempt. The original Custom/OpenAI compatibility logic and provider instruction strings remain unchanged. This is admission of each attempt, not a claim that already-transmitted bytes can be recalled.

**Verification:** The independent original regression passed against the corrected complete engine/provider source copies: one selected test, zero failures, exit 0. The UI owner's final 30-case source harness also passed, including both retired-source cases and both stable-retry controls. The native tests are `testSourceRetirementDuringHTTPPreventsCompatibilityRetry`, `testSourceRetirementDuringOpenAIHTTPPreventsCompatibilityRetry`, `testCurrentCustomRequestStillRetriesCompatibleParameters`, and `testCurrentOpenAIRequestStillRetriesCompatibleParameters` in `StrandiOSTests/AICoachRequestOwnershipTests.swift:301–359`.

Evidence: `/tmp/noop-independent-coach-review/retry-green.log`; the UI owner's reproducible before/after snapshots and logs are in `/workspace/scratch/fc582a8e42a6/coach-audit-evidence.tar.gz`.

### R2 — P2 — An A → B → A selection could admit a stale bootstrap registry owner

**Location:** `Strand/BLE/BLEManager.swift:961–979`; native coverage in `StrandiOSTests/BLEStoreBootstrapOwnershipTests.swift:17–53`.

**Reproduction:** Bootstrap captures manager owner A and a nil heart-rate source, then awaits the detached registry read. The registry snapshot observes B. Before the read returns, explicit selection changes A → B → A while HR stays nil. The old gate compares only the device ID and HR identity, both of which now match their original values. It assigns the stale registry result B to `deviceId`, allowing the following collector/backfiller initialization to use B despite the latest selection being A.

This was a **preexisting adjacent gap**, discovered while independently reviewing the expanded bootstrap ownership fix. An isolated probe executed the unchanged production admission block with a deterministic inert registry reader. It reported source epoch 3 and final owner `strap-b`, then exited 1.

**Minimum fix implemented:** Capture `historicalSourceEpoch` before the registry await and require it to remain equal before applying the registry result. A stale result is discarded while store bootstrap continues for the latest explicit owner. The default registry read still uses the original detached database read. A narrow injectable read closure makes the interleaving deterministic in native tests.

**Verification:** Re-extracting the corrected production block into the independent probe preserves `strap-a` at source epoch 3 and exits 0. A stable-startup positive control still adopts the selected registry owner. The new native tests also check that rejecting the stale registry result does not prevent collector/backfiller initialization. Native execution remains pending.

Evidence: `/tmp/noop-independent-bootstrap-review/registry-aba-before.swift`, `registry-aba-red.log`, `registry-aba-after.swift`, and `registry-aba-green.log`.

## Reviewed production boundaries

The review examined the full functional diff and its new tests, then followed the affected callers and ownership models. This is broader than checking test assertions, but is not a claim of reviewing every production line in the repository.

| Area | Production paths inspected and conclusions |
|---|---|
| Cloud Coach | Immutable provider/model/endpoint/key-owner/consent/source configuration; request ID and generation ownership; parent/child cancellation; outbound versus visible history; context awaits; stale model-list success/error; endpoint pinning; all four clients and shared HTTP helper. R1 closes the identified retry gap. |
| Weekly Coach and Trends | Persisted source/database ownership, legacy cache decoding, same-day generation, fence invalidation, consent changes, task ID cleanup, hydration ordering, and current-source Trends access. No new cache or cancellation defect was confirmed. |
| Sleep transactions | Exact owner/key lookup, complete row/auxiliary-track/recovery-overlay snapshots, transactional delete, compare-and-swap edits, database identity, conflicting restore, and recovery override restoration against current non-sleep daily activity. Restore avoids rolling back newer strain/steps merely to undo sleep deletion. |
| Repository sleep and UI | Canonical/read-namespace resolution with existing precedence, effective-bound idempotent reclip, raw-restaging fallback, tombstones only after successful deletion, undo result handling, and banner UUID ownership across timers and repeated taps. No additional reachable corruption race was confirmed. |
| Habitual timing | Repository and intelligence adapters use the same main-night deduplication and each midpoint's time-zone offset. Calendar/DST and minimum-day tests were inspected. Calculation kernels remain intact. |
| Numeric imports | Finite/representable conversion helper and actual Apple Health/WHOOP import call sites, including daily/workout integer conversions, fractional rounding behavior, accumulator overflow rejection, mapping-version changes, and real-adapter synthetic tests. |
| Workout projections | Production ingest/restore mutation contract, cache signature and rebuild fallbacks, existing incremental last-second replacement, calorie interval and zone semantics, paused segments, append after correction, and benchmark construction. No unsafe prefix assumption was added by the tail optimization. |
| BLE lifecycle and sources | Shared retirement, radio state changes, Forget, callback/write admission, captured collector flushing, history cancellation/ACK ownership, preserved reconnect intent, secure holds/caps, fallback state publication after sample intake, registry observation generation, captured bond proof, bootstrap open/upsert/read/replay ownership, and broadcaster replay cache clearing. R2 closes the additional bootstrap ABA gap. |
| Background synchronization | Cancellation before task-body admission and immediately before `requestSync`, existing expiration/completion ownership, and the production operation-factory regression tests. |
| Packaging and release metadata | App/widget required-API manifests, resource inclusion through project configuration, bundle-resource tests, staged 2.0 release notes, build metadata, and the QA report's distinction between host evidence and release qualification. Actual archive/resource validation requires native tooling. |

The benchmark uses the existing accumulator and calculation implementations and compares corrected output against a fresh authoritative projection. Its synthetic Linux timing evidence supports the measured projection path only. It does not demonstrate whole-app startup, scrolling, memory, radio, or battery improvement.

The report also checked the final source-owner follow-ups: a pending SourceCoordinator UUID cannot adopt into a later registry owner; post-upsert bootstrap cannot install collectors for a retired store; battery read completion cannot mix another owner/store's samples; reject-archive insertion captures its original owner and only its current completion advances the replay gate; nil HR clears the value replayed to new broadcast subscribers. The default stale-pin re-adoption still emits nil followed by the bonded UUID, so the existing publisher's duplicate suppression does not consume the legitimate post-bond confirmation.

## Verification and preservation evidence

The reviewer independently executed:

- The Coach retry regression, failing before per-attempt admission and passing after it.
- The source-bootstrap ABA probe, failing before the epoch guard and passing after it, plus stable-startup adoption.
- The literal-preservation checker against the exact base: **32 AI/Coach Swift files passed**. Every original literal remains byte-for-byte present; only two transport-path literals were added. Manual diff review found no prompt/template/instruction changes.
- `git diff --check`, with no whitespace errors in the reviewed changes.

The reviewer inspected specialist tests and evidence for the real-GRDB sleep transaction harness (10 passing cases), cloud engine/provider harness (30), weekly method/cache harness (8), import numeric harness (5), BLE source-derived probes, and workout benchmark. Those runs were performed by their owners; they are not presented as independently rerun full native suites.

## Limits and required next evidence

No Xcode, simulator, Instruments session, signed iOS archive, physical iPhone, WHOOP 4, WHOOP 5, or MG was available to this reviewer. The cloud harness compiles actual engine/provider bodies with inert platform/domain/Keychain dependencies. Weekly and BLE probes execute extracted production methods or blocks with explicit boundaries stubbed. Those tests establish the reproduced logic, not CoreBluetooth callbacks, SQLite scheduling in the full app, HealthKit behavior, SwiftUI integration, packaged resource contents, or actual radio/background execution.

The exact final PR commit still needs the selected native app, XCTest, UI, and reverse-dependent package CI results. Native tests should exercise the final new regression files, existing BLE/source and Coach safety tests, actual importer adapters, repository sleep round trips, and app/widget manifest bundles. Device-dependent lifecycle and performance claims remain subject to the combined release-candidate qualification already described in the release-hardening QA README. The authorized output remains one unmerged draft PR.

## Final CI fixture follow-up

Reviewed the final diff of `Tools/qa/test_ble_connection_result_ownership.py` and the root's before/after logs. The fixture now represents `CBCentralManager.state`, defaulting to powered-on so the existing 11 scenarios keep their original conditions. Four additional scenarios cover late success and failure callbacks with powered-off and resetting central states. The temporary-directory module cache removes the fixed shared path without changing application code or assertions. The production callback extraction remains intact.

The base revision fails the four new radio-state assertions (exit 1). The final source passes all 15 scenarios with zero failed assertions (exit 0). These are source-derived Swift callback tests with a recording transport, not native CoreBluetooth execution. Evidence: `/workspace/scratch/fc582a8e42a6/audit-evidence/connection-admission-red.log` and `connection-admission-green.log`.

## Reviewed snapshot

`independent-review-manifest.json`, alongside this report, records SHA-256 hashes of every changed production/test Swift file, privacy manifest, project/release metadata file, and the two reviewed QA harness/benchmark scripts. The files were uncommitted during review. Later changes must be assessed against those reviewed bytes; no clean final commit or CI success is implied by this manifest.


## Metadata follow-up — draft PR79 and build 250

Reviewed the complete metadata diff since `b54cadbd4aff7dbd32f9f0618a56a9913bb9cd0e`. GitHub assigned this audit draft PR79 because a separate hardening draft PR78 appeared while the audit was in progress. The follow-up reserves build 250 above the separately reserved builds 248 and 249. Neither PR77 nor the separate PR78 is incorporated by this metadata change.

The reviewed changes are limited to `project.yml`, `docs/releases/2.0-batch.json`, `CHANGELOG.md`, the release-hardening QA README, and the implementation plan. The project build changes from 249 to 250 while marketing version remains 2.0.0. The tentative batch endpoint changes from PR78 to PR79; staging status, the phone-install hold, and the publication hold remain unchanged. The explanatory text correctly keeps overlapping draft work outside the reviewed base and requires reconciliation before the combined release candidate is qualified.

SHA-256 comparison with the original 43-entry review manifest found **41 entries unchanged**. Only `project.yml` and `CHANGELOG.md` changed among those entries. All reviewed functional production sources, tests, privacy manifests, and QA code retain their reviewed bytes. The manifest now records refreshed hashes for those two entries and supplemental hashes for all five metadata files.

`git diff --check b54cadbd` passed. No functional tests were repeated for this metadata-only update, and no new native CI success, release approval, merge, installation, or publication is implied. The existing functional review findings remain resolved and the previously stated qualification limits remain in force. No new defect was found in this follow-up.


## Native CI follow-up — hold-timer fixture isolation

**The initial native run failed, and the corrected fixture still requires a native rerun.** Run `39971271690` tested merge commit `f0fa85d1d8eea0b8564a41df5991398a543ad641` for PR head `26e150d2bbd1fcdf14a65de06e834e8b0841d5da`. Its XCTest log records 3,321 cases: 3,316 passed, four skipped, and one failure. `BLEBackgroundReconnectHandoffTests.testTheHoldDeadlineEndsTheBackgroundTask` failed the existing nil-deadline assertion at line 163 after 2.167 seconds. The app/widget/test products compiled; the separate 300-case Swift Testing run passed with three recorded preexisting known issues. UI execution was withheld. The failed run remains failed evidence; see `native-ci-initial-result.json` and the retained full CI log.

The independent trace followed every reader and writer of `whoop5SecureHandshakeNotBefore`. The timer test created a real simulator central, armed a synthetic hold, and yielded. The new radio-unavailable retirement path can then cancel the held attempt, release timer, and background task while deliberately preserving the reconnect-series deadline. The native log does not directly timestamp that callback: its observed failure is consistent with this source-traced competing path, not an instrumented proof of the exact callback ordering. The test stops waiting when the background task ends, so this different lifecycle path can be mistaken for normal timer expiry. Clearing every deadline during retirement would violate the required preservation of an unexpired security delay. An elapsed timestamp with no held attempt does not itself block reconnect: `ReconnectPolicy.laterHandshakeHold` filters expired dates, the disconnect path ignores nonpositive remaining time, and `proceedToWhoop5ClientHello` clears an elapsed deadline before proceeding.

Reviewed correction: the existing **internal testing/preview initializer** gains `receiveBluetoothCallbacks: Bool = true`. The explicit opt-out keeps a real, nonnil central but supplies no delegate or restoration identifier. The public production initializer remains byte-for-byte unchanged, and default callers retain their existing callbacks and restoration behavior. Only the original timer fixture and two new explicit radio-retirement controls opt out.

The original timer test keeps its **0.2-second deadline, unchanged polling loop, real DispatchWorkItem/UIApplication background methods, and every existing assertion**. The new controls explicitly retire a future hold, verify its timer/background task stop without a stale hello write or notification-driven rearm, and verify the future delay survives pending-reconnect admission. A separate control retires an already overdue queued hold and confirms pending-reconnect admission discards that expired delay. Neither control adds a sleep.

Independent byte comparisons against `26e150d2bbd1fcdf14a65de06e834e8b0841d5da` confirm the public initializer, hold/timer/background/release/cancellation methods, connection-retirement/radio handler, handshake-hold admission, and `ReconnectPolicy` are unchanged. The original deadline test body is identical after removing only its setup argument and explanatory comments. The three-file diff introduces no policy adjustment, getter side effect, longer wait, omitted assertion, or native-gate bypass. The implementation owner reports syntax parsing for all three files, 15 project-hygiene tests, and the source-contract audit passing; these do not substitute for execution of the corrected native test. The independent `git diff --check` passed.

The source correction is acceptable for the next native run; **native qualification remains blocked until the corrected final candidate passes its required gates**. At this fixture-review checkpoint the manifest contained 44 source/test/config entries, with refreshed hashes for `BLEManager.swift` and `BLEConnectionRetirementTests.swift` and a new entry for the now-modified `BLEBackgroundReconnectHandoffTests.swift`. Earlier metadata-follow-up hashes remain a time-stamped record of that earlier review.


## Documentation and calendar follow-up — F16 remains unresolved

**No unresolved confirmed introduced-patch defect was found in this follow-up. F16 / DL-05 is a separately confirmed, inherited P1 release blocker.** The corrected BLE fixture still requires its final-head native run, and the calendar finding must not be described as fixed or counted as a passing skipped test.

Reviewed the final QA README delta, `native-ci-initial-result.json`, `source-evidence-index.json`, the added syntax-parse record, and all four calendar evidence files. The README and machine-readable CI record retain the original failed run, its 3,321 XCTest cases (3,316 passed, four skipped, one failure), the separate 300 Swift Testing cases with known artwork issues, and withheld UI execution. Their radio-retirement explanation is now explicitly a path consistent with the observed state; the native log did not directly timestamp the internal callback. The source-evidence index points to the current declarations, including the three-line BLE initializer shift and the deliberately skipped DL-05 test.

The independent reviewer ran `calendar-key-probe.py` with Swift 6.4.1 into `/tmp/noop-independent-calendar-review`; it exited 0. Both its result JSON and extracted-source manifest exactly match the checked-in versions. All nine extracted helper declarations also match the original base `a7ade2598d439d33cd20816d69ccc991b29322fc` byte-for-byte. The script only creates synthetic scratch files and in-memory SQLite data; the inspected extraction preserves the helper bodies, and its deletion predicate is read verbatim from the unchanged production timestamp-heal implementation.

The reproduced production helpers give the same Bangkok midnight instant and day interval different keys: Gregorian `2026-10-12`, Buddhist `2569-10-12`, Japanese `0008-10-12`, Hebrew `5787-02-01`, and Islamic civil `1448-04-29`. Repository refresh and the store helper retain `2026-10-12`. This establishes a storage-key identity mismatch for the tested date without attributing it to the civil-day/DST interval arithmetic. The inverse parser also interprets a Gregorian-formatted key using the supplied non-Gregorian calendar, yielding a different instant.

Source inspection confirms the relevant production path: ordinary coordinator work passes the selected current calendar, while committed historical work uses its recorded Gregorian calendar. Engine analysis persists the resulting day key; repository refresh uses Gregorian-formatted ranges. Manual hydration and sleep-recovery producers also use repository/current-calendar day keys. The journal and metric-series primary keys have the same owner/day relationships represented in the synthetic SQL fixture. The probe demonstrates a Gregorian range omitting the alternate-key computed row, a missing hydration lookup after a helper-only change, a journal primary-key collision, and removal of a non-Gregorian computed row by the existing timestamp-heal predicate if that maintenance path runs.

These checks support the proposal's narrow disposition: unify producers and readers together with a migration that preserves source ownership, manual history, ambiguous calendar/era/zone provenance, collisions, and interruption recovery. A helper-only change would not repair existing buckets, and a blanket key rewrite could overwrite distinct records. The proposal is a design and acceptance matrix, not an implemented or executed migration. No raw sensor loss, live-user database impact, native non-Gregorian UI scenario, or completed migration is established by this probe. The existing test skip and production helpers remain unchanged.

The manifest now records **45 current source/test/configuration/script entries**, including the independently executed calendar probe, plus seven current supplementary documentation hashes. Earlier metadata hashes remain a dated record of the earlier review. All 45 current entries and the supplementary hashes were checked against their reviewed bytes. This bounded follow-up does not independently repeat external dependency research or native package execution. The release remains held for F16, the corrected exact-head native/UI gates, and the combined candidate qualification.


## Current-main integration follow-up — PR78 incorporated, combined CI pending

**No new confirmed integration defect was found in this bounded source review. The integrated candidate has not yet passed its own native/UI/package qualification. F16 / DL-05 remains an unresolved inherited P1 release blocker.** PR79 stays a draft; this review authorizes no merge, installation, publication, or hardware operation. The earlier dated sections and their hashes remain historical evidence, with the current integration overrides recorded separately in the manifest.

Main advanced to `b7ebe85b2a7f5c0d25f2ef5a04b9d8dce8815679`, merging PR78's final head `b2e1c0d54e5aad6b993c4117e0ac60b3c161fd2b`. The prior overlap review covered PR78 head `859b7f48b1d5de164bf9e018260b737eb79fbf2d`, so this follow-up examined its subsequent six-file delta as well as the resolved integration with PR79 head `529adf2f652dcb1b98822665c6c4e895b27f5d32`. The final PR78 tree equals the new main tree. The reviewed integration was staged but not committed when these checks ran; a future commit identifier is not inferred.

Independent byte comparisons checked all **47 paths changed by new main from the original base**. Forty-three match main exactly. The four intended differences are `WhoopImporter.swift`, `AppChangelog.swift`, `CHANGELOG.md`, and `project.yml`. Of the earlier 45 reviewed source/test/configuration/script entries, 42 retain their reviewed bytes; only the importer and the two changelogs changed. Project configuration remains the already-reviewed build 250. The manifest's `integration_followup.reviewed_file_overrides` records current hashes for all four reconciliation paths without replacing the earlier dated entries.

### Conflict resolution and new-main boundaries

The resolved WHOOP importer differs from main only in `roundedImportedHeartRate`, which forwards to `ImportNumericSafety.integer(..., rounding: .toNearestOrAwayFromZero)`. This retains the previous finite/representable exact integer conversion and the original rounding rule. Every PR78 strain-scale guard, resting-HR metric-series check, stress-baseline admission, and workout admission remains. PR79's earlier parser rejection and Apple Health protections are unchanged. Importer revision 2 is retained; both unshipped branches had independently selected that revision.

The retained real CSV-to-parser-to-store `WhoopImporterNumericBoundaryTests` covers invalid daily/workout HR and strain, valid fractional RHR precision, metric-series/stress admission, and preserved valid sibling fields. Its direct helper test covers non-finite and unrepresentable values plus ordinary rounding and the source strain scale. PR79's parser/helper and Apple Health tests remain alongside it. The data specialist separately confirmed that these tests are sufficient for the forwarding resolution, and byte-checked 14 critical sleep/undo/DST/Apple numeric implementation and test files against `529adf2`. No extra implementation-mirroring test was required by this review.

The latest six-file PR78 delta was read in full. Its only additional production change labels each receipt row as the individual set ordinal, with or without a target, while leaving set identity and volume accounting intact. Its native regression checks both forms. The sleep interpolation test change only splits an expression into typed intermediate values. The routine-edit UI fixture still activates the actual Edit menu item, requires dismissal and a ready Save control, and retains edit/save/start separation assertions; the revised finite, contained, enabled-element check does not bypass the app's menu route. No rendered-result or new simulator pass is inferred from this source review.

The review also inspected the incoming production diffs for readiness numeric/calendar eligibility, sleep interpolation, training-load overflow, CSV formatter serialization and timezone bounds, geodesic clamping, WHOOP RR/FTMS payload bounds, plausible PPG coverage, Shortcut import admission, HealthKit query cancellation and deletion boundaries, Oura shared-frame reassembly and cursor retirement, widget Coach Brief epoch recovery/clearing, Lift personal-record caching, workout-summary task lifetime, and route-intent authentication. These changes are complementary to the previously reviewed source/connection fencing, recovery-preserving sleep undo, weekly Coach ownership, and incremental workout projection. In particular:

- HealthKit one-shot continuation settlement and stop ownership remain on the main actor; cancellation checks surround anchored reads and destructive deletion admission. They supplement source-generation checks rather than removing them.
- Oura framing and app routing arrive together, retaining partial-byte cursor admission and teardown epoch retirement. Native and physical notification/teardown behavior still needs proportionate qualification.
- The sleep interpolation neighbor search does not change stored-summary re-clipping or exact-owner recovery undo. The incoming readiness and coverage changes do not migrate persisted calendar keys, so they do not fix F16.
- Lift PR-history invalidation follows completed-session mutation and is separate from the live physiological projection cache. Coach Brief widget cleanup and the weekly insight owner/cache are likewise distinct privacy boundaries.

This was an integration-focused source review, not a new line-by-line audit of every PR78 subsystem or independent execution of PR78's historical CI claims. The data specialist reached the same no-new-conflict conclusion for the combined importer and sleep/data paths. Root reports all 20 affected source audits, syntax parsing of the two resolved Swift files, and the 32-file Coach literal-preservation check passing on the integration. The reviewer independently ran both staged and unstaged `git diff --check`; both passed. No Coach prompt/template/instruction edit was introduced by the reconciliation.

The single cumulative 2.0.0 release entry retains nine features, the earlier release history, source/privacy ownership and recovery-preserving sleep undo descriptions. CHANGELOG retains both PR78's added bullets and PR79's release-hardening section. Its integration paragraph correctly includes PR78, leaves PR77 separate, and requires fresh combined validation. Marketing version remains **2.0.0**, build **250** remains above main's 249, tentative endpoint stays **PR79**, and staging/install/publication holds remain intact.

### Historical final-head CI evidence and obsolete retry

Before main advanced, the reviewer independently checked the pushed bytes and complete logs for head `529adf2f652dcb1b98822665c6c4e895b27f5d32`, tree `b7365556df1ec6ad8cfdb2fd7dee957c76b6395a`, tested merge `3679f704708a8b1a45d3791954b58e2ed610973f`, and original base `a7ade2598d439d33cd20816d69ccc991b29322fc`:

| Historical check | Independently verified outcome |
|---|---|
| Package workflow `39977563656`, attempt 1 | Nine required package jobs succeeded: 3,693 passed, one explicit optional-fixture skip, zero failures. |
| Native XCTest in workflow `39977563756`, attempt 1 | 3,323 cases: 3,319 passed, four preexisting skips, zero failures. The original hold-deadline test and both deterministic retirement controls passed once each. |
| Swift Testing | 300 tests in 41 suites passed, with three recorded preexisting known artwork issues. |
| Selected UI | All 21 exact planned methods passed once; the full discovered UI inventory contained 42 methods. This is not a claim that all 42 ran. |
| Focused new/affected native suites | All 73 selected target cases passed once. No repeated XCTest starts/completions or test retry flags were found in the complete native/UI log. |
| Aggregate native workflow | **Failed** at `NOOP CI Gate` job `120529594647`: GitHub returned HTTP 502 while the gate fetched the successful package run's attempt-1 jobs. Successful test execution did not make the whole workflow green. |

The four native skips include the still-unresolved Buddhist-calendar assertion, two unavailable on-device-model fixtures, and the optional real Xiaomi database fixture. They are not converted into passes. The retained native/UI log has SHA-256 `64ad2d0775c31168777827c45ec5381298ad0bcd0405b825016e2d7fdbfc2699`; evidence is retained under `native-ci-39977563756`, with package evidence under `packages-ci-39977563656` in the audit workspace. A later read of the exact failed package API endpoint succeeded, but does not erase the original gate failure.

The root's attempt-2 retry began at the change-plan job because plan and app-result artifacts are attempt-scoped. Its new plan still identifies the old base/head/merge, and its carried-forward source-audit result is not fresh execution. Once main advanced, that retry became obsolete for qualification of the integrated candidate; monitoring stopped and no completed attempt-2 case-level or aggregate success is asserted here. Its retained plan/source evidence is under `native-ci-39977563756-attempt2`.

The integration requires a new exact-head protected plan, app/widget/test build, full selected native execution, exact selected UI methods, required package jobs, and successful aggregate evidence validation. Existing skips/known issues must remain visible. F16 needs its own coordinated preservation-aware key migration and qualification; PR77 and the complete combined batch still require reconciliation and final release-candidate testing. Physical WHOOP/iPhone/HealthKit/background validation and measured device performance remain separate gates. The historical 529 results substantiate that earlier tree only.
