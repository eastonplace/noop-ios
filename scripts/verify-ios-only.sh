#!/usr/bin/env bash
set -euo pipefail

failures=0

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  failures=$((failures + 1))
}

for path in \
  android \
  NOOPWatch \
  NOOPWatchComplications \
  Packages/NoopLocalAccess \
  Strand/App/StrandApp.swift \
  Strand/App/RootView.swift \
  Strand/App/ContentView.swift \
  Strand/MenuBar \
  Strand/Data/WatchSessionBridge.swift \
  Packages/StrandDesign/Sources/StrandDesign/WatchScoreSnapshot.swift \
  Strand/System/MacActions.swift \
  Strand/Resources/Strand.entitlements; do
  if [[ -e "$path" ]]; then
    fail "forbidden non-iOS product path still exists: $path"
  fi
done

mapfile -t android_files < <(
  find . -type f \( \
    -name '*.kt' -o -name '*.kts' -o -name '*.gradle' -o \
    -name 'AndroidManifest.xml' -o -name 'gradlew' -o -name 'gradlew.bat' \
  \) -not -path './.git/*' -print | sort
)
if ((${#android_files[@]})); then
  printf '%s\n' "${android_files[@]}" >&2
  fail "Android source/build files remain"
fi

if grep -Eq 'platform:[[:space:]]*(macOS|watchOS)|NOOPWatch|NOOPWatchComplications|scheme:[[:space:]]*Strand' project.yml; then
  grep -En 'platform:[[:space:]]*(macOS|watchOS)|NOOPWatch|NOOPWatchComplications|scheme:[[:space:]]*Strand' project.yml >&2 || true
  fail "project.yml still declares a non-iOS product"
fi

if ! grep -Eq '^[[:space:]]+NOOPiOS:' project.yml; then
  fail "project.yml does not declare NOOPiOS"
fi
if ! grep -Eq '^[[:space:]]+NOOPiOSWidgets:' project.yml; then
  fail "project.yml does not declare NOOPiOSWidgets"
fi
if ! grep -Eq '^[[:space:]]+NOOPiOSTests:' project.yml; then
  fail "project.yml does not declare NOOPiOSTests"
fi

mapfile -t platform_imports < <(
  grep -RInE --include='*.swift' \
    '^[[:space:]]*import[[:space:]]+(AppKit|WatchKit|WatchConnectivity)|os\((macOS|watchOS)\)' \
    Strand StrandiOS StrandiOSShared StrandiOSWidgets Packages 2>/dev/null | sort || true
)
if ((${#platform_imports[@]})); then
  printf '%s\n' "${platform_imports[@]}" >&2
  fail "active Swift source still contains macOS/watchOS imports or compile branches"
fi

mapfile -t workflow_hits < <(
  grep -RInE --include='*.yml' --include='*.yaml' \
    'android|macOS|watchOS|NOOPWatch|NOOPWatchComplications|scheme:[[:space:]]*Strand' \
    .github/workflows 2>/dev/null | grep -v 'verify-ios-only' | sort || true
)
if ((${#workflow_hits[@]})); then
  printf '%s\n' "${workflow_hits[@]}" >&2
  fail "active CI still contains a non-iOS product lane"
fi

if ((failures)); then
  printf '\niOS-only audit failed with %d issue group(s).\n' "$failures" >&2
  exit 1
fi

printf 'iOS-only audit passed.\n'
