#!/usr/bin/env bash
# Capture the screenshot matrix on one booted simulator.
#   capture.sh <udid> <app-path> <out-dir> <matrix-file> <device-label> <tag-filter>
# Matrix lines: id | tags | wait-seconds | launch args (space separated)
# tag-filter: "primary" captures every line; any other value captures only lines whose tags contain it.
# A line tagged "xl" is captured a second time at accessibility-extra-large text (suffix -xl).
set -uo pipefail
udid="$1"; app="$2"; out="$3"; matrix="$4"; label="$5"; filter="$6"
bundle="com.eastonplace.noop"
mkdir -p "$out"

xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b >/dev/null
xcrun simctl ui "$udid" appearance dark
xcrun simctl ui "$udid" content_size large
xcrun simctl status_bar "$udid" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100 || true
xcrun simctl privacy "$udid" grant all "$bundle" 2>/dev/null || true
xcrun simctl install "$udid" "$app"
xcrun simctl privacy "$udid" grant all "$bundle" 2>/dev/null || true

# First launch creates the container; then mark onboarding, terms and What's New as done through the
# simulator's own cfprefsd so the shell opens straight onto the tabs.
xcrun simctl launch "$udid" "$bundle" --demo-seed >/dev/null 2>&1 || true
sleep 6
xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
data=$(xcrun simctl get_app_container "$udid" "$bundle" data)
prefs="$data/Library/Preferences/$bundle"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Info.plist" 2>/dev/null || echo "9.0.1")
xcrun simctl spawn "$udid" defaults write "$prefs" noop.onboarded -bool YES
xcrun simctl spawn "$udid" defaults write "$prefs" noop.acceptedTermsVersion -string "2.0"
xcrun simctl spawn "$udid" defaults write "$prefs" noop.lastSeenChangelogVersion -string "$version"
echo "prefs written ($version)"

# Warm-up: let the demo seed fill the store once, then every route reads the same seeded week.
xcrun simctl launch --terminate-running-process "$udid" "$bundle" --demo-seed --demo-tab today >/dev/null 2>&1 || true
sleep 25
xcrun simctl io "$udid" screenshot --type=png "$out/$label-00-warmup.png" >/dev/null 2>&1 || true

shoot() {
  local id="$1" wait="$2" size="$3" suffix="$4"; shift 4
  xcrun simctl ui "$udid" content_size "$size"
  # `@scroll=N` is not a launch argument: the scroll driver reads N points from a per-shot file once the screen
  # has loaded, so the frame shows content below the fold.
  local scroll="" launch_args=() arg
  for arg in "$@"; do
    if [[ "$arg" == @scroll=* ]]; then scroll="${arg#@scroll=}"; else launch_args+=("$arg"); fi
  done
  local scroll_file="/tmp/noop-qa-scroll-$label-$id$suffix.txt"
  rm -f "$scroll_file"
  if [[ -n "$scroll" ]]; then launch_args+=(--noop-qa-scroll-poll --noop-qa-scroll-file "$scroll_file"); fi
  local pid
  pid=$(xcrun simctl launch --terminate-running-process "$udid" "$bundle" "${launch_args[@]}" 2>&1 < /dev/null | tail -1)
  sleep "$wait"
  if [[ -n "$scroll" ]]; then echo "$scroll" > "$scroll_file"; sleep 2.5; fi
  local file="$out/$label-$id$suffix.png"
  xcrun simctl io "$udid" screenshot --type=png "$file" >/dev/null 2>&1
  local alive="dead"
  xcrun simctl spawn "$udid" launchctl list 2>/dev/null | grep -q "$bundle" && alive="alive"
  echo "shot $label-$id$suffix [$alive] launch=($pid) args=($*)"
}

while IFS='|' read -r -u 3 id tags wait args; do
  id="$(echo "$id" | xargs)"; tags="$(echo "$tags" | xargs)"; wait="$(echo "$wait" | xargs)"
  [[ -z "$id" || "$id" == \#* ]] && continue
  if [[ "$filter" != "primary" && " $tags " != *" $filter "* ]]; then continue; fi
  # shellcheck disable=SC2086
  shoot "$id" "$wait" large "" $args
  if [[ "$filter" == "primary" && " $tags " == *" xl "* ]]; then
    # shellcheck disable=SC2086
    shoot "$id" "$wait" accessibility-extra-large "-xl" $args
  fi
done 3< "$matrix"
xcrun simctl ui "$udid" content_size large

echo "::group::app log ($label)"
xcrun simctl spawn "$udid" log show --last 40m --style compact \
  --predicate 'process == "NOOP" AND (eventMessage CONTAINS "qa-route" OR eventMessage CONTAINS "qa-scroll" OR messageType == fault OR messageType == error)' \
  2>/dev/null | tail -150 || true
echo "::endgroup::"
ls ~/Library/Logs/DiagnosticReports 2>/dev/null | grep -i noop || echo "no NOOP crash reports"
xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
xcrun simctl shutdown "$udid" 2>/dev/null || true
