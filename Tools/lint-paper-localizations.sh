#!/usr/bin/env bash
set -euo pipefail

catalogs=(
  "Strand/Resources/Localizable.xcstrings"
  "Packages/StrandDesign/Sources/StrandDesign/Resources/Localizable.xcstrings"
)

failed=0
for catalog in "${catalogs[@]}"; do
  matches="$(jq -r '.strings | keys[]' "$catalog" | grep -E '(^|[^[:alpha:]])(Charge|Effort|EFFORT)([^[:alpha:]]|$)' || true)"
  if [[ -n "$matches" ]]; then
    printf '%s\n%s\n' "$catalog" "$matches" >&2
    failed=1
  fi
done

if [[ "$failed" -ne 0 ]]; then
  echo "Legacy Paper pillar localization keys found." >&2
  exit 1
fi

echo "Paper localization keys clean across ${#catalogs[@]} catalogs."
