# Independent review: NOOP 2.0 release hardening

Date: 2026-10-23. Base: `a7ade2598d439d33cd20816d69ccc991b29322fc`. Branch: `audit/noop-2-release-hardening-20261023`.

## Review outcome

The independent functional review found **two additional P2 correctness defects**. Both have been fixed by their implementation owners and independently reproduced as passing after the fixes. No other evidence-backed blocker remains in the reviewed production diff. This supports preparing the authorized draft PR with its native validation gates; it does not establish release readiness or authorize merge, installation, or publication.

This was a read-only review of application and test sources. The reviewer did not edit production code, commit, push, access real health records, send an external model request, or operate hardware. Isolated synthetic probes and this report were written outside the repository. `AGENTS.md` and `docs/CONTRIBUTING.md` were read and the held 2.0 batch policy was respected.

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
