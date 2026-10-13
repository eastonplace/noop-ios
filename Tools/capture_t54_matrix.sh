#!/usr/bin/env bash
set -euo pipefail

app_path="${1:-build/T53Build/Build/Products/Debug-iphonesimulator/NOOP.app}"
output="specs/002-noop-ui-completion/qa/T54-matrix"
bundle="com.eastonplace.noop"
devices=(
  "16pro:4425C98D-9F53-456B-B493-B058D8FA81DA"
  "se:4C6C38F2-E905-4454-9B71-A4920579EFF6"
  "promax:602CD04D-E0CD-4A41-986C-74427759C06A"
)
routes=(
  today trends sleep live workouts devices addwizard data backup settings support
  insights labbook rhythmconsent rhythm automations alarms testcentre recoverydetail
  straindetail sleepdetail stress preworkout liveworkout
)

mkdir -p "$output"
for device in "${devices[@]}"; do
  name="${device%%:*}"
  udid="${device#*:}"
  xcrun simctl shutdown all 2>/dev/null || true
  xcrun simctl boot "$udid" 2>/dev/null || true
  open -g -a Simulator --args -CurrentDeviceUDID "$udid"
  xcrun simctl bootstatus "$udid" -b
  xcrun simctl install "$udid" "$app_path"
  for appearance in light dark; do
    xcrun simctl ui "$udid" appearance "$appearance"
    for route in "${routes[@]}"; do
      screenshot="$output/${name}-${appearance}-${route}.png"
      [[ -f "$screenshot" ]] && continue
      xcrun simctl launch --terminate-running-process "$udid" "$bundle" \
        --demo-seed --demo-screen "$route" >/dev/null
      # SwiftUI needs a full render beat after process replacement; shorter waits
      # capture the launch background rather than the requested route.
      sleep 2
      xcrun simctl io "$udid" screenshot "$screenshot" >/dev/null
    done
  done
  xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
done
