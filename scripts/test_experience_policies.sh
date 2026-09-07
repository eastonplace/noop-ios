#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/noop-experience.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/Sources/ExperiencePolicies" "$TMP/Tests/ExperiencePoliciesTests"
cp "$ROOT/Strand/Data/WorkoutExperiencePolicy.swift" "$ROOT/Strand/Data/JournalExperiencePolicy.swift" "$TMP/Sources/ExperiencePolicies/"
cp "$ROOT/StrandiOSTests/WorkoutExperiencePolicyTests.swift" "$ROOT/StrandiOSTests/JournalExperiencePolicyTests.swift" "$TMP/Tests/ExperiencePoliciesTests/"
cat > "$TMP/Package.swift" <<'MANIFEST'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "ExperiencePolicies", targets: [
    .target(name: "ExperiencePolicies"),
    .testTarget(name: "ExperiencePoliciesTests", dependencies: ["ExperiencePolicies"])
])
MANIFEST
swift test --package-path "$TMP" "$@"
