# Noop iOS 2.1 local verification

GitHub Actions is not used as evidence for PR #20. Run this checklist from a clean checkout of the exact `release/noop-ios-2.1` head after refreshing it onto the current `release/noop-ios-2.0` base.

## Record the candidate

```bash
git status --short --branch
git rev-parse HEAD
git rev-parse release/noop-ios-2.0
xcodebuild -version
swift --version
xcodegen --version
mkdir -p qa-artifacts/noop-ios-2.1/{audits,packages}
```

Copy all command output into the PR evidence bundle. A dirty worktree, moving base, or different head invalidates the run.

## Source contracts

Run the existing seven iPhone audits plus the release-specific compatibility audit:

```bash
set -o pipefail
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
done
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

Treat warnings as failures. Record the warning count explicitly rather than relying on the command's exit status.

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
  --filter 'HeartRateRecoveryTests|WorkoutDetectedBackfillTests'

swift test --package-path Packages/WhoopProtocol \
  --filter 'Whoop5RawImuStorageTests|Whoop5V18SpO2CandidateTests|WhoopGattServiceFamilyTests'

swift test --package-path Packages/OuraProtocol \
  --filter 'OuraFeatureStatusTests|OuraWearTests'

swift test --package-path Packages/StrandImport \
  --filter WhoopV91JournalCompatibilityTests
```

## Manual simulator review

At both ordinary and maximum Dynamic Type:

- Open an eligible workout with post-session HR and verify the HR-recovery card only shows recorded 1/2/5-minute readings.
- Confirm absent post-workout coverage produces no fabricated value.
- Import a synthetic WHOOP journal with `Answered yes` TRUE/FALSE values and verify the journal/correlation result distinguishes them.
- Exercise WHOOP device rows seeded as `WHOOP`, `WHOOP 4.0`, and `WHOOP 5.0 / MG`; only the generic row may be corrected.
- Confirm no byte-82 candidate appears in Health, Trends, HealthKit, Recovery, or exported user metrics.
- Confirm long localized strings do not clip the workout card.

## Device-only gates

These cannot be replaced by simulator evidence:

- WHOOP 4.0 and WHOOP 5.0/MG family correction after a real connection.
- Unsupported Puffin/Monument/Symphony advertisements are logged and never connected to or commanded.
- WHOOP 5.0 v18 byte-82 correlation against the official app on multiple devices; instrumentation only regardless of result.
- Post-workout HR recovery at 1/2/5 minutes with the app foregrounded, backgrounded, and relaunched.
- Oura feature-status reads and live wear/charger transitions on owned hardware.
- GET_CLOCK retry/Data Range fallback behavior on a strap that actually drops the response.

## Evidence summary

Attach or paste:

- Exact feature SHA and exact stacked-base SHA.
- Xcode/Swift/XcodeGen versions.
- Simulator runtime, device, and UDID.
- Exact build and test commands.
- Per-suite pass/fail/skip totals.
- All eight audit outputs.
- Warning count.
- Every optional skip and its reason.
- Physical device, firmware, notification, Focus, battery, and log evidence for device-only checks.
