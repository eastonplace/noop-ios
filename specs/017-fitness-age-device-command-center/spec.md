# Feature 017 — Fitness Age, Device Command Center, and Widgets & Live

## Goal

Productionize Design Lab components 39–41 with real NOOP data. Tapping the compact Fitness Age surface opens a dedicated Fitness Age screen; Devices becomes a single-scroll command center for the active device while retaining pairing and multi-device management; Home/Lock widgets and Live Activity adopt the Design Lab hierarchy with canonical Strain.

## User scenarios

### US1 — Understand Fitness Age (P1)

A user taps Fitness Age from Health or the Today card and opens a full detail screen showing the latest value, its relationship to calendar age, the real inputs that drive the value, and the real six-month history.

**Acceptance:** the screen uses production metric series/profile data, preserves the current uncertainty disclaimer, and never presents fixture values or unsupported causal claims.

### US2 — Understand calibration (P1)

A user without enough data opens the same destination and sees what is missing, how much wear is needed, and which profile fields can be fixed in Settings.

**Acceptance:** missing values remain placeholders; readiness uses `FitnessAgeEngine.assessReadiness`; settings and trend actions remain reachable.

### US3 — Diagnose the active device (P1)

A user opens Devices and can answer whether the active device is connected, fully encrypted, current enough to sync history, clock-correct, powered, and reporting packets.

**Acceptance:** the highest-priority real issue is visible without expanding a card; full bond is based only on `encryptedBond`; unsupported checks are omitted or marked unavailable rather than guessed.

### US4 — Run safe recovery commands (P1)

A user can sync now, test vibration, refresh battery, or refresh the link from the same screen, with actions enabled only when their existing backend preconditions are met.

**Acceptance:** the view calls thin `AppModel` wrappers, overlapping sync is prevented, and local feedback explains disabled/in-flight/sent states.

### US5 — Keep managing multiple devices (P2)

A user can still add, rename, activate, remove, re-add, or delete data for paired devices after the active command center is introduced.

**Acceptance:** existing confirmations, data-preservation rules, and `DeviceRegistry` mutations remain intact; no database migration is introduced.

### US6 — See the day and workout outside the app (P1)

A user can glance at real Recovery, Strain, Sleep, vitals, stress, and strap status from Home/Lock widgets, and can follow a manually active workout from the Lock Screen or Dynamic Island.

**Acceptance:** Recovery remains available as a circular accessory, a separate selectable circular Strain accessory uses canonical 0–21 Strain, larger accessories show both, and the rich Live Activity renders only for an active workout.

## Functional requirements

- Component 39 is a dedicated `FitnessAgeDetailView` opened by tapping the compact Fitness Age surface; it is not expanded inline on Health.
- The Fitness Age hero shows the real latest weekly `fitness_age`, real profile age, a dynamic shared age rail, and `FitnessAgeEngine.displayBandYears`.
- Six-month history uses real `fitness_age` metric-series points and a calendar-age reference that does not imply birthday precision NOOP does not store.
- A pace-of-aging value may render only from a documented, tested real-series calculation with sufficient history; otherwise it reads Calibrating.
- Year-impact rows are limited to inputs that mathematically drive NOOP's current equation. The Design Lab's nine fixture impacts are not production truth and must not ship as causal claims.
- Supporting inputs such as VO2max/profile readiness may be shown as context without an impact bar or implied contribution.
- Devices remains one vertically scrolling screen with the active command center first and existing other/removed-device management below.
- Device state is resolved by one deterministic pure resolver, not by logic duplicated in SwiftUI.
- Device health priority is: Bluetooth unavailable, reconnect guide, pairing hint/live-HR-only link, RTC warning, sync error, reboot requirement, critical battery, experimental history, standard-HR fallback.
- WHOOP 5/MG experimental history and standard-HR fallback are informational unless a higher-severity issue exists.
- Sync progress reports acknowledged chunk counts, never a percentage.
- R22 labels are limited to Off, Requires full bond, Applying N/15, Accepted 15/15, or Configured · Monitoring; wording never describes R22 as a confirmed live deep-data stream.
- Power status reports charge, charging, runtime estimate, and connection uptime; it must not claim battery degradation or signal quality.
- `connectedAt` is stamped for every established link and cleared on disconnect, Bluetooth-off, forget-device, failed teardown, and model switch.
- Last-packet freshness updates in a timer-driven leaf so the full Devices screen does not refresh every second.
- Existing safe action paths are preserved: `syncNow`, `buzzStrapOnce`, `refreshBattery`, and scan/connect.
- Non-WHOOP active devices receive only applicable status and actions; WHOOP-specific rows/actions remain unavailable with an honest reason.
- Both screens follow the approved flat NOOP direction: continuous canvas, spacing/type/dividers, and bounded chrome only for real interactive controls.
- Widget snapshots add only optional backward-compatible fields; old snapshots continue decoding.
- Slow dashboard publication reads score/history data, while fast live publication updates HR, battery, connection, and Strain without repeating history queries.
- Small, medium, and large Home widgets use real snapshot fields and honest placeholders.
- Lock Screen keeps Recovery circular, adds a separate Strain circular widget, and shows both metrics in rectangular and inline accessories.
- Live Activity preserves the existing simple live-HR mode outside workouts and uses real sport, elapsed time, HR, Building/scored workout Strain, calories, HR trace, and zones during a manual workout.
- Live Activity state additions remain optional and backward compatible; old activities decode as live-HR mode.
- iPhone is the visual target; macOS continues compiling and receives a functional detail presentation without a separate redesign.

## Edge cases

- No Fitness Age points, one point, sparse points, or points older than six months.
- Calendar age or biological sex missing; partial RHR/activity coverage; no waist/VO2max.
- Fitness Age equals, exceeds, or falls below profile age; values near engine bounds.
- No active device, multiple paired devices, removed devices, or a non-WHOOP active source.
- Connected with live HR but no encrypted bond.
- Bluetooth unavailable, reconnect loop, stale/broken RTC, sync error, mid-sync disconnect, rejected frames, reboot warning, critical/unknown battery, experimental history, and standard-HR fallback.
- App relaunch while already connected and rapid disconnect/reconnect transitions.
- Old widget snapshots/activities, unscored Strain, workout Building state, workout relaunch, duplicate activity starts, and disconnect/end cleanup.

## Success criteria

- Every Fitness Age number and trend point on component 39 matches the production repository for the same profile and date window.
- No production row claims a year impact unless the current Fitness Age equation can reproduce it.
- Seven required device-health resolver scenarios and all four action gates pass deterministic tests.
- Connection uptime resets correctly across connect, reconnect, disconnect, Bluetooth-off, and forget-device tests.
- Existing device registry actions and Fitness Age readiness/trend routing remain regression-safe.
- Every widget family and Live Activity mode reads canonical snapshot/state values without fixture fallbacks in production.
- Signed Release installs in place on the connected iPhone with the existing bundle ID and populated database preserved.
- Physical-phone QA verifies both screens in real connected, syncing, and available missing-data states before the branch is considered review-ready.

## Assumptions and gates

- Design Lab 39–41 are visual sources, not production data sources.
- The current NOOP Fitness Age equation has two direct variable drivers: resting HR and measured activity. The nine Design Lab fixture impacts are intentionally not copied.
- A real pace-of-aging definition will be documented in the plan and must meet the minimum-history gate before rendering numerically.
- PR #5 remains the delivery lane against PR #4; neither PR is merged without explicit approval.
- No uninstall, reset, production database replacement, demo seed, or backend schema change is authorized.
