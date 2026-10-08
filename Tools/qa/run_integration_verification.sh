#!/usr/bin/env bash
# Reproducible NOOP iPhone integration verification. Run from any directory on a macOS host.
# The script deliberately continues after individual failures so the output directory records every
# gate that could be attempted. Its final exit status is non-zero when any required gate failed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="${1:-$ROOT/qa-artifacts/integration-$STAMP}"
mkdir -p "$OUT/audits" "$OUT/packages"
cd "$ROOT"

STATUS_FILE="$OUT/command-status.tsv"
printf 'gate\texit_code\n' > "$STATUS_FILE"

record_status() {
  printf '%s\t%s\n' "$1" "$2" >> "$STATUS_FILE"
}

run_logged() {
  local gate="$1"
  local log="$2"
  shift 2
  echo "===== $gate ====="
  "$@" 2>&1 | tee "$log"
  local rc=${PIPESTATUS[0]}
  record_status "$gate" "$rc"
  return 0
}

run_shell_logged() {
  local gate="$1"
  local log="$2"
  local command="$3"
  echo "===== $gate ====="
  bash -lc "$command" 2>&1 | tee "$log"
  local rc=${PIPESTATUS[0]}
  record_status "$gate" "$rc"
  return 0
}

{
  printf 'integration_sha='; git rev-parse HEAD
  printf 'branch='; git branch --show-current
  printf 'captured_at_utc=%s\n' "$STAMP"
  printf 'host='; scutil --get ComputerName 2>/dev/null || hostname
  printf 'macos='; sw_vers -productVersion 2>/dev/null || true
} | tee "$OUT/integration-metadata.txt"

git status --short --branch | tee "$OUT/git-status-before.txt"
run_logged "git-diff-check" "$OUT/git-diff-check.txt" git diff --check

if command -v xcodebuild >/dev/null 2>&1; then
  xcodebuild -version | tee "$OUT/xcode-version.txt"
else
  printf 'xcodebuild not found\n' | tee "$OUT/xcode-version.txt"
fi
if command -v swift >/dev/null 2>&1; then
  swift --version | tee "$OUT/swift-version.txt"
fi
if command -v xcodegen >/dev/null 2>&1; then
  xcodegen --version | tee "$OUT/xcodegen-version.txt"
else
  printf 'xcodegen not found\n' | tee "$OUT/xcodegen-version.txt"
fi

AUDITS=(
  source_contract_audit.py
  ui_unification_contract_audit.py
  workout_runtime_contract_audit.py
  workout_persistence_contract_audit.py
  trends_snapshot_contract_audit.py
  accessibility_localization_contract_audit.py
  healthkit_sync_contract_audit.py
)
for audit in "${AUDITS[@]}"; do
  run_logged "audit:${audit%.py}" "$OUT/audits/${audit%.py}.txt" \
    python3 "Tools/qa/$audit"
done

if command -v xcodegen >/dev/null 2>&1; then
  run_logged "xcodegen" "$OUT/xcodegen.txt" xcodegen generate
else
  printf 'xcodegen unavailable\n' | tee "$OUT/xcodegen.txt"
  record_status "xcodegen" 127
fi

BUILD_COMMAND="xcodebuild -scheme NOOPiOS -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build"
printf '%s\n' "$BUILD_COMMAND" > "$OUT/build-command.txt"
if command -v xcodebuild >/dev/null 2>&1; then
  run_shell_logged "ios-build" "$OUT/xcodebuild-build.txt" "$BUILD_COMMAND"
else
  printf 'xcodebuild unavailable\n' | tee "$OUT/xcodebuild-build.txt"
  record_status "ios-build" 127
fi

SIMULATOR_UDID=""
if command -v xcrun >/dev/null 2>&1; then
  xcrun simctl list devices available | tee "$OUT/available-simulators.txt"
  SIMULATOR_UDID="$(xcrun simctl list devices available -j 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
for runtime, devices in data.get("devices", {}).items():
    if "iOS" not in runtime:
        continue
    for device in devices:
        if device.get("isAvailable") and device.get("name", "").startswith("iPhone"):
            print(device["udid"])
            raise SystemExit(0)
')"
fi

if [[ -n "$SIMULATOR_UDID" ]]; then
  xcrun simctl list devices | grep -F "$SIMULATOR_UDID" | tee "$OUT/selected-simulator.txt" || true
  RESULT_BUNDLE="$OUT/NOOPiOSTests.xcresult"
  rm -rf "$RESULT_BUNDLE"
  TEST_COMMAND="xcodebuild -scheme NOOPiOS -configuration Debug -destination 'platform=iOS Simulator,id=$SIMULATOR_UDID' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -resultBundlePath '$RESULT_BUNDLE' test"
  printf '%s\n' "$TEST_COMMAND" > "$OUT/test-command.txt"
  run_shell_logged "ios-tests" "$OUT/xcodebuild-test.txt" "$TEST_COMMAND"
  if [[ -d "$RESULT_BUNDLE" ]]; then
    xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE" --format json \
      > "$OUT/xcode-test-summary.json" 2> "$OUT/xcode-test-summary.stderr.txt" || true
  fi
else
  printf 'No available iPhone simulator found\n' | tee "$OUT/selected-simulator.txt"
  printf 'No test command: no iPhone simulator was available.\n' > "$OUT/test-command.txt"
  record_status "ios-tests" 125
fi

PACKAGES=(WhoopProtocol OuraProtocol WhoopStore StrandAnalytics StrandImport StrandDesign NoopLocalAccess)
for package in "${PACKAGES[@]}"; do
  run_logged "package:$package" "$OUT/packages/$package.txt" \
    swift test --package-path "Packages/$package"
done

{
  grep -hE 'warning:' "$OUT"/xcodebuild-*.txt 2>/dev/null || true
} > "$OUT/compiler-warnings.txt"
printf '%s\n' "$(wc -l < "$OUT/compiler-warnings.txt" | tr -d ' ')" > "$OUT/compiler-warning-count.txt"

git status --short --branch | tee "$OUT/git-status-after.txt"
python3 Tools/qa/summarize_verification.py "$OUT" | tee "$OUT/verification-summary.md"

if awk -F '\t' 'NR > 1 && $2 != 0 { failed = 1 } END { exit failed ? 0 : 1 }' "$STATUS_FILE"; then
  exit 1
fi
exit 0
