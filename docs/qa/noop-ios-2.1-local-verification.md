# Noop iOS 2.1 local verification

GitHub Actions is not used as evidence for PR #20. Run this checklist from a clean checkout of the exact `release/noop-ios-2.1` head after refreshing it onto the current `release/noop-ios-2.0` base.

Noop iOS 2.1 is a **WHOOP-focused** RyanBR v9.1 compatibility release. Oura transport work is not part of this release gate.

## Record the candidate

```bash
git status --short --branch
git rev-parse HEAD
git rev-parse release/noop-ios-2.0
git merge-base --is-ancestor release/noop-ios-2.0 HEAD
xcodebuild -version
swift --version
xcodegen --version
mkdir -p qa-artifacts/noop-ios-2.1/{audits,packages,focused}
```

Copy all command output into the PR evidence bundle. A dirty worktree, stale base, or different head invalidates the run.

## Repository hygiene

```bash
git diff --check 2>&1 | tee qa-artifacts/noop-ios-2.1/git-diff-check.txt
git status --short 2>&1 | tee qa-artifacts/noop-ios-2.1/git-status.txt
```

## Source contracts

Run the existing seven iPhone audits plus the release-specific WHOOP compatibility audit:

```bash
set -o pipefail
status=0
for audit in \
  source_contract_audit.py \
  ui_unification_contract_audit.py \
  workout_runtime_contract_audit.py \
  workout_persistence_contract_audit.py \
  trends_snapshot_contract_audit.py \
  accessibility_localization_contract_audit.py \
  healthkit_sync_contract_audit.py \
  ryanbr_9_1_backend_contract_audit.py
do
  python3 "Tools/qa/$audit" 2>&1 \
    | tee "qa-artifacts/noop-ios-2.1/audits/${audit%.py}.txt"
  rc=${PIPESTATUS[0]}
  (( rc == 0 )) || status=1
done
(( status == 0 ))
```

## Generate and build

```bash
xcodegen generate 2>&1 | tee qa-artifacts/noop-ios-2.1/xcodegen.txt

xcodebuild \
  -scheme NOOPiOS \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build 2>&1 | tee qa-artifacts/noop-ios-2.1/xcodebuild-build.txt
```

Treat warnings as failures. Record the warning count explicitly:

```bash
grep -E '(^|: )warning:' qa-artifacts/noop-ios-2.1/xcodebuild-build.txt \
  | tee qa-artifacts/noop-ios-2.1/compiler-warnings.txt
wc -l qa-artifacts/noop-ios-2.1/compiler-warnings.txt
```

## iOS tests

Select an available iPhone simulator rather than assuming a model exists:

```bash
xcrun simctl list devices available | tee qa-artifacts/noop-ios-2.1/available-simulators.txt
UDID="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
payload = json.load(sys.stdin)
for runtime, devices in payload.get("devices", {}).items():
    if "iOS" not in runtime:
        continue
    for device in devices:
        if device.get("isAvailable") and device.get("name", "").startswith("iPhone"):
            print(device["udid"])
            raise SystemExit(0)
raise SystemExit("No available iPhone simulator")
')"

xcrun simctl bootstatus "$UDID" -b
xcrun simctl list devices | grep "$UDID" \
  | tee qa-artifacts/noop-ios-2.1/selected-simulator.txt

xcodebuild \
  -scheme NOOPiOS \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$UDID" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  -resultBundlePath qa-artifacts/noop-ios-2.1/NOOPiOSTests.xcresult \
  test 2>&1 | tee qa-artifacts/noop-ios-2.1/xcodebuild-test.txt
```

## Retained package tests

All retained packages remain mandatory because PR #20 is stacked on the complete 2.0 release line. OuraProtocol is still tested for repository health even though Oura is not a 2.1 release feature.

```bash
status=0
for package in \
  WhoopProtocol \
  OuraProtocol \
  WhoopStore \
  StrandAnalytics \
  StrandImport \
  StrandDesign \
  NoopLocalAccess
do
  echo "=== $package ==="
  swift test --package-path "Packages/$package" 2>&1 \
    | tee "qa-artifacts/noop-ios-2.1/packages/$package.txt"
  rc=${PIPESTATUS[0]}
  (( rc == 0 )) || status=1
done
exit "$status"
```

## Focused 2.1 checks

The complete suites remain mandatory. These filters are useful during iteration:

```bash
swift test --package-path Packages/StrandAnalytics \
  --filter 'HeartRateRecoveryTests|WorkoutDetectedBackfillTests' \
  2>&1 | tee qa-artifacts/noop-ios-2.1/focused/strand-analytics.txt

swift test --package-path Packages/WhoopProtocol \
  --filter 'StrapClockRecoveryPlannerTests|Whoop5RawImuStorageTests|Whoop5V18SpO2CandidateTests|Whoop5ExperimentalSpO2PipelineTests|WhoopGattServiceFamilyTests' \
  2>&1 | tee qa-artifacts/noop-ios-2.1/focused/whoop-protocol.txt

swift test --package-path Packages/WhoopStore \
  --filter DeviceRegistryStoreTests \
  2>&1 | tee qa-artifacts/noop-ios-2.1/focused/whoop-store.txt

swift test --package-path Packages/StrandImport \
  --filter WhoopV91JournalCompatibilityTests \
  2>&1 | tee qa-artifacts/noop-ios-2.1/focused/strand-import.txt
```

## Deterministic contracts to inspect in the logs

- Unsupported selected Puffin/Monument/Symphony and unknown service UUIDs always return `shouldConnect == false`, including an empty advertised-service list.
- Four dense but separated high-intensity HR bursts do not qualify as sustained HR-recovery effort.
- Workout backfill rejects average HR above peak HR, conflicts with existing real HR, Strain above 100, and unversioned Strain.
- GET_CLOCK emits at most three retries and one Data Range fallback; a future marker fails closed; reset rearms exactly one new generation.
- `Whoop5RawImu.baseTs` rejects an exact-length buffer with invalid sample counts.
- Reversing accepted byte-82 records in one minute produces the same single rounded minute candidate.
- Generic `WHOOP` registry rows are changed once; a specific model is never overwritten.
- A noncanonical `Answered yes` CSV cannot override the canonical `journal_entries.csv`.

## Experimental WHOOP 5/MG SpO₂ checks

Use synthetic data for simulator coverage and owned hardware for the real signal:

- A v18 record produces a candidate only when byte 82 is `70...100` **and** the same record reports `sleep_state == 2`.
- Awake, still, up, zero, sub-70 diagnostic codes, and high-bit sentinels produce no candidate.
- All accepted seconds in one extraction minute produce one order-independent rounded mean.
- The ordinary WHOOP 4 raw red/IR ADC path never matches the `-82` marker.
- Health shows a separate **SpO₂ Candidate (Beta)** tile only when a marked nightly value exists.
- The canonical **Blood O₂** tile continues to use only `spo2Pct` from validated/imported sources.
- The beta tile uses an approximate `≈` value, neutral unvalidated styling, no clinical range statement, and visible “Experimental; may be inaccurate” copy.
- VoiceOver states that the candidate may be inaccurate and is not used for scoring, HealthKit, or medical decisions.
- The candidate remains absent from Trends, widgets, HealthKit writes, Recovery, illness detection, and all medical alerts.
- Raw CSV currently exposes the compatibility marker under `spo2_red`/`spo2_ir`; treat that as diagnostic-only and never as calibrated oxygen. Dedicated beta export columns remain follow-up work.

## Manual simulator review

At ordinary and maximum Dynamic Type:

- Open an eligible workout with post-session HR. When opened immediately after Finish, verify the HRR card refreshes only as the 1/2/5-minute windows mature.
- Open a mature workout and verify the HRR card performs one load rather than repeated immediate reads.
- Confirm absent post-workout coverage produces no fabricated value.
- Import a synthetic WHOOP journal with `Answered yes` TRUE/FALSE values and verify the journal/correlation result distinguishes them.
- Exercise WHOOP device rows seeded as `WHOOP`, `WHOOP 4.0`, and `WHOOP 5.0 / MG`; only the generic row may be corrected.
- Seed a marked nightly candidate and verify the beta tile is visually neutral and distinct from canonical Blood O₂.
- Seed only ordinary raw WHOOP 4 red/IR values and verify no candidate-beta tile appears.
- Confirm long localized strings do not clip the workout or experimental-vital cards.
- Run VoiceOver over the candidate and HRR card.

## Device-only WHOOP gates

These cannot be replaced by simulator evidence:

- WHOOP 4.0 and WHOOP 5.0/MG family correction after a real settled connection.
- Unsupported Puffin/Monument/Symphony advertisements are logged and never connected to or commanded once diagnostic scanning is wired.
- WHOOP 5.0/MG v18 byte-82 comparison against the official app on multiple devices, firmware versions, nights, and wear conditions. Record candidate, official-app value, sleep state, raw byte, and minute coverage. The tile remains Experimental regardless of a match.
- Confirm no beta value is written to HealthKit or used by Recovery/illness logic on a physical device.
- Post-workout HR recovery at 1/2/5 minutes with the app foregrounded, backgrounded, and relaunched.
- GET_CLOCK retry/Data Range fallback behavior on a strap that actually drops the response after the planner is wired.
- Connection switch during seeded-model correction does not update the wrong registry row.

## Evidence summary

Attach or paste:

- Exact feature SHA and exact stacked-base SHA.
- Proof that the stacked base is an ancestor of the tested head.
- Xcode/Swift/XcodeGen versions.
- Simulator runtime, device, and UDID.
- Exact build and test commands.
- Per-suite pass/fail/skip totals.
- All eight audit outputs.
- Warning count.
- Every optional skip and its reason.
- Experimental SpO₂ synthetic fixture output and screenshots/VoiceOver evidence.
- Physical device, strap model, firmware, comparison source, notification, Focus, battery, and log evidence for device-only checks.
