# Workout and journal experience refresh

Status: implementation for draft PR review. Do not merge without the acceptance gates below.

## Delivery correction

The original branch matched main at `1051ccb5ac55cc9f64383cce88d71714741235bc`.
The previous assistant had not published the claimed UI draft. This implementation was rebuilt
from the verified main sources and the surviving design notes. PR #51 is the review destination.
No claim about the earlier 23-test local draft is used as evidence for this code.

## Screen and interaction changes

### Focused task navigation

The screenshot's extra Done row came from a native navigation toolbar above ScreenScaffold's
app-status chrome and wordmark. `noopFocusedTask()` uses the existing settings-detail
presentation to give these sheets one native title/action row. Dashboard tabs keep their chrome.
Workout and journal flows own one navigation stack each. The quick-action menu now waits for
actual dismissal before presenting a selected tool; its old timed 50 ms transition is gone.
No custom safe-area offsets or global negative padding were added.

### Active workouts

The session uses large elapsed time, a fresh heart-rate readout, recorded average/peak values,
a bounded heart-rate trace and canonical strain progress. An older reading stops appearing as
current after 20 seconds. Indoor, strength, mobility and general timed sessions omit GPS modules.
The outdoor route panel requires the recorder's session ID to match the active workout.
An old route retained by the recorder therefore cannot leak into a new workout.

Distance/rate tiles appear only with real data. Cycling uses speed; swimming and rowing use
appropriate pace units. There are no unsupported live calorie, elevation or cadence placeholders.
Minimize retains the existing AppModel recorder. Finish requires confirmation and enters the
summary only after the existing durable finish reports success. Failed saves remain visible.

### Saved sessions

The summary displays the saved sport/date/source, duration, canonical strain and available metrics.
The chart uses native Swift Charts selection, a stable readout, accessible previous/next controls,
a 15-minute zoom option and a bounded list of plotted readings. Time gaps remain separate line
series. These are time-bucket averages from the existing repository, not raw beat measurements.
Summary averages are kept separate from chart averages. Imported and derived zone splits carry
source labels; zone percentages use zone-observed time. Tapping a zone explains its source.

Route tabs appear only for recorded geometry. Each captured segment remains separate.
The fake Save button, inert share icon, static moderate-run claim and unrecorded elevation card
were removed. Share invokes the native sheet with summary text and excludes coordinates.
The existing WorkoutHeartRateRecoveryCard remains connected to its production data path.

### Journal

The home screen has a morning-date navigator, saved-answer progress, an editable mood check-in,
14 days of native history, quick-entry routes and existing routines. It makes wake-day attribution
explicit. All-off memberships remain all-off. Quick entries open the appropriate editor rather
than writing an arbitrary Boolean for a numeric item.

The editor pins its date when opened, supports search and unanswered filtering, groups related
questions and keeps Yes, No, unanswered and numeric zero distinct. Decimal input uses the user's
locale. Raw numeric text lives in the editor, so collapsing a group or changing the search does not
lose invalid input. Cancel confirms discarded edits. The previous-day action fills only missing
active answers into the draft and requires an explicit save.

Native answer changes compare their original rows, write only changed keys and verify the result
inside one existing GRDB transaction. A concurrent edit causes a conflict instead of lost work.
Errors retain the draft. Exact retries are idempotent. Journal notes and immutable question keys
remain intact. Native writes remain hard-scoped to `noop-journal`; imported rows are untouched.
Routine answers and the existing coachingStackUse provenance row now commit together.

Question settings provide active/quick-entry toggles, real move-up/down controls, rename, groups,
number/unit configuration and confirmed hide/delete. Existing catalog methods retain history.
The inline Insights journal and existing Coaching entry points route into these same components.
Mood remains in its existing `noop-mood` source and is read back before success is displayed.

## Performance boundaries

- Static live-session structure is Equatable and reference-owned. Streaming observations stay in leaves.
- Existing incremental HR projection remains bounded at 360 points and is not rebuilt from full samples.
- Map previews refresh at most every five seconds while visible and retain at most 800 actual points.
- Summary chart preparation happens once in a detached load task. Plotting is capped at 480 points.
- Crosshair and arrow lookup use binary search, without sorting or scanning all readings on each drag.
- Summary loading queries the selected workout window. The former 4,000-day comparison read is removed.
- Journal day changes read a bounded 14-day native window. Configuration is reused within the home screen.
- Source/date identities and cancellation checks prevent stale loads replacing a newly selected day/session.

These are implementation bounds, not measured iPhone frame-time or energy results. No best-in-class
runtime claim is made without Instruments measurements at the exact final commit.

## Research used

Apple's Human Interface Guidelines informed the use of a single toolbar owner, real action controls,
contextual metrics, readable labels, explicit state and accessible chart alternatives:

- https://developer.apple.com/design/human-interface-guidelines/toolbars
- https://developer.apple.com/design/human-interface-guidelines/charts
- https://developer.apple.com/design/human-interface-guidelines/accessibility
- https://developer.apple.com/design/human-interface-guidelines/entering-data
- https://developer.apple.com/videos/play/wwdc2023/10037/

Native Swift Charts supplies chart navigation and accessibility semantics. The text reading list and
44-point previous/next controls provide another way to inspect data without a drag gesture.

## Verification and acceptance

Portable policy command: `bash scripts/test_experience_policies.sh`.
The command copies the exact two Foundation-only production policy files into an isolated Swift
package. It does not mock their implementation. The iOS test target also compiles these tests.
`NativeJournalEditsTests` exercises real GRDB transactions in the existing iOS test target, including
injected verification/provenance failures. Its result must be taken from Xcode/CI, not Linux parsing.

Before merging, Codex must record the exact tested SHA and complete:

1. Run the repository's nine source audits, XcodeGen, NOOPiOS Debug/Release builds and all iOS/package tests.
2. Render the actual app on small and large iPhones at default and accessibility text sizes. Inspect
   Intervals, the workout picker/live/summary, journal home/editor/settings and routine sheets. Confirm
   one navigation row, no clipping, reachable bottom actions and visible error feedback. Save screenshots.
3. Exercise treadmill/indoor cycle with no GPS, an outdoor route, denied location, no HR, stale HR,
   interrupted recording, a session over one hour, save failure/retry and completed summary. Confirm that
   minimize preserves recording, balances live-HR leases and restores the screen-idle setting.
4. Exercise No/unanswered/zero, locale decimals, a numeric field hidden by search, tomorrow/yesterday,
   midnight/DST, all questions inactive, partial previous-day copy, concurrent edit conflict, failed save,
   question rename/hide/restore, mood failure and atomic routine/provenance failure.
5. Use VoiceOver and Reduce Motion. Measure live body invalidations, scrolling/crosshair stalls,
   memory and battery with Instruments during a long real session. Verify physical strap and GPS behavior.

The current container is Linux. Swift syntax checks are not SwiftUI type checks, simulator screenshots
or hardware evidence. GitHub's existing macOS CI is the available build/test gate. Keep this PR draft
until its exact-head results and rendered/device acceptance evidence are attached.

## Preserved boundaries

No merge, main-branch update, install, phone database change, migration, signing change, new service,
telemetry, dependency, scoring formula, BLE command, strap protocol or HealthKit ownership change.
