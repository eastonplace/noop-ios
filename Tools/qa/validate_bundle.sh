#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

swift test --package-path "$ROOT/Packages/NoopPhase34Core" -Xswiftc -warnings-as-errors
python3 -m unittest discover -s "$ROOT/Tools/qa" -p "test_audit_phase34.py" -v
python3 "$ROOT/Tools/qa/validate_phase34_sql.py"

echo "PASS: bundle validation"
