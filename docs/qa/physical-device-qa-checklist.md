# NOOP physical-device QA checklist

> **Do not mark the integration PR ready based on simulator output alone.** Every completed row must identify the exact integration commit and retain observable evidence.

## Run identity — complete for every session

| Field | Value |
|---|---|
| Integration SHA | |
| App build number | |
| Test date/time and time zone | |
| Tester | |
| iPhone model | |
| iOS version | |
| Strap model | |
| Strap firmware | |
| Notification authorization | |
| Focus status | |
| Silent-mode state | |
| Battery / Low Power Mode / charger state | |
| Network state | |

Evidence naming convention: `<sha>-<area>-<case>-<timestamp>.<ext>`. Attach a screenshot, screen recording, exported log, xcresult, or strap readback for every pass or failure.

## Alarm

| Case | Expected evidence | Pass/fail | Evidence |
|---|---|---:|---|
| WHOOP 4 arm and readback | Strap readback proves the endpoint is armed; UI must not say **Armed** before readback | | |
| WHOOP 5/MG Experimental off | No speculative command; clear unsupported/experimental status | | |
| WHOOP 5/MG Experimental on | Explicit experimental labeling plus command/readback evidence | | |
| Disconnected strap | Honest unavailable state; backup behavior recorded | | |
| Reconnect | One generation reconciles; no duplicate arm/rearm | | |
| Delayed notification authorization | Pending path recovers after authorization | | |
| Notification denial | Honest backup-unavailable status | | |
| Focus enabled | Strap behavior and best-effort phone limitation recorded | | |
| Silent mode | Strap behavior and phone limitation recorded | | |
| App backgrounded | Endpoint remains armed; scheduled work evidence | | |
| App killed | Endpoint/readback and delivery behavior recorded | | |
| BG expiration | Exactly one failed completion; no late second completion | | |
| Spring-forward presentation | Endpoint clock remains correct; elapsed countdown is seven real hours in the specified case | | |
| Fall-back presentation | Endpoint clock remains correct; elapsed countdown is nine real hours in the specified case | | |
| Actual wake delivery | Test time, delivery channel, readback, and recording/log | | |

## Workout

| Case | Expected evidence | Pass/fail | Evidence |
|---|---|---:|---|
| Three-hour session | Full duration, bounded chart, final persistence/readback | | |
| Multiple HR callback rates | Equivalent canonical one-second samples and scoring | | |
| Background → foreground | No duplicate lifecycle publication or lost samples | | |
| Kill/relaunch before file write | Last committed checkpoint restored | | |
| Kill/relaunch after file fsync | Uncommitted bytes ignored or committed metadata recovered | | |
| Kill/relaunch before metadata commit | Prior commit restored | | |
| Kill/relaunch after metadata commit | New commit restored | | |
| Finish/readback | Finished session cannot be resurrected by delayed writes | | |
| GPS session | Location and workout persistence behavior | | |
| Non-GPS session | Workout persistence behavior | | |
| Memory/allocation profile | Three-hour and overnight traces; peak allocation and main-thread time | | |

Record final file size, total bytes read, total bytes written, checkpoint latency distribution, peak allocation, and main-thread time for both the three-hour and overnight profiles.

## HealthKit

| Case | Expected evidence | Pass/fail | Evidence |
|---|---|---:|---|
| Overlapping observer A/B | Serialized/coalesced reconciliation; no lost anchor/window | | |
| Old correction | Original and destination days reconcile | | |
| 90-day-old deletion | Exact or conservatively widened authoritative replacement removes stale local data | | |
| Only-value deletion | Day no longer retains the deleted Apple Health value | | |
| Deleted workout | Workout disappears locally | | |
| Large history | Bounded memory and paging evidence | | |
| Kill after pending-window persistence | Relaunch retries the pending window before committing anchor | | |
| Initial paging failure | Partial anchor is never committed | | |

## Accessibility and localization

| Case | Expected evidence | Pass/fail | Evidence |
|---|---|---:|---|
| VoiceOver | Alarm switch, wake time/modes, charts, and primary navigation are operable | | |
| Switch Control | Logical focus order and actionable controls where practical | | |
| Maximum supported Dynamic Type | No app-wide cap; flexible alarm layouts; 44-point weekday targets | | |
| 12-hour locale | Locale-aware clock and duration strings | | |
| 24-hour locale | Locale-aware clock and duration strings | | |
| Long localized strings | No clipping that hides meaning or controls | | |
| Increased Contrast | Controls/status remain distinguishable | | |
| Reduce Motion | No required information depends on animation | | |
| Light appearance | Contrast and chart legibility | | |
| Dark appearance | Contrast and chart legibility | | |

## Release disposition

- [ ] Exact integration SHA matches the draft integration PR header.
- [ ] Warning-clean generated-project build is attached.
- [ ] Complete `NOOPiOSTests` xcresult is attached.
- [ ] Every retained Swift package test log is attached.
- [ ] All seven source-audit logs are attached.
- [ ] No optional skip lacks a written reason.
- [ ] All mandatory WHOOP, HealthKit, background-execution, persistence, and accessibility gates pass.
- [ ] Nothing was merged into `main` during QA.
