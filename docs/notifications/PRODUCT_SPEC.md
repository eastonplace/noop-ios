# Noop notification design

Date: October 20, 2026. Owner: Easton Place. Target: `eastonplace/noop-ios`.

## 1. Product decision

Build one local system that chooses the most useful message for the current situation. Give it a catalog of 540 cases. Start with eight small feature groups. Add other groups after the first release proves useful.

An alert should help a person make a decision while that decision still matters. It should use a valid measurement or a reminder the person chose. It should open the screen that explains the message.

The catalog is a design library. Its rows describe possible user-visible outcomes, including local notifications, in-app cards, and digest items. A person should see only the few outcomes that fit their data and choices. The 540 count excludes silence tests and wording-only variations.

### Approach options

| Approach | Benefit | Cost | Decision |
| --- | --- | --- | --- |
| Shared local policy with existing Noop data | Works with current storage. Gives stable decisions and small tests. Can reuse current alert rules. | Needs common state, route handling, and source adapters. | Recommended. |
| Continue adding independent notifier classes | Fast for the next alert. | Each class needs its own permission, timing, state, and repeat controls. Related alerts can collide. | Use existing classes only as temporary adapters. |
| Let a model decide each notification | Can produce varied wording. | Adds network timing, cost, consent, and decision uncertainty. A model call cannot make iOS wake on time. | Consider optional wording after deterministic selection. |

### Launch scope

| Group | Useful moment | First action | Delivery choice |
| --- | --- | --- | --- |
| Morning summary | A complete new sleep episode and current recovery result are ready. | Review the current day. | Optional local notice, or an in-app card if already read. |
| Wind-down | The selected bedtime approaches, using the current sleep plan. | View the plan. | Explicitly scheduled local reminder. |
| Workout plan check | A workout the user scheduled is approaching. | Open that workout. | Explicit reminder. A change in the evidence can replace its content. |
| Workout summary | A new workout finishes and its current score settles. | Open the session result. | Optional local notice if the summary is not already visible. |
| Daily strain target | Current canonical strain first reaches a valid target. | Review the day and remaining plan. | Optional local notice, usually combined with the workout result. |
| Charge before recording | Battery evidence indicates a charging action before sleep or a planned session. | View the device. | One combined alert per charging episode. |
| Weekly review | A complete review period has enough valid observations. | Review the week. | Chosen weekly schedule, with details inside the app. |
| Journal check-in | A user-selected check-in is due and the relevant entry is incomplete. | Open that entry. | Off until the person selects a schedule. |

Improve current health-pattern and alarm behavior during the foundation work. Introduce new health-pattern pushes only after the recovery repair and source checks pass.

### Defaults and settings

Preserve each installed user's current feature choices. Introduce new push groups in the off state. Offer an Essentials selection with a preview of the messages and expected frequency. A preset is a user choice, not a silent upgrade migration.

Keep Breathe and Hydrate off until selected. A hidden tool must not create a new reminder. Keep privacy controls separate from tool visibility. A user can hide a tool from navigation while keeping a previously chosen reminder; show that state clearly in settings.

Provide category controls for Sleep, Recovery, Training, Habits, Device, and Reviews. Each group can use Off, In app, or Notify when useful. Time-based features also expose a schedule. Use one place for quiet hours and preview privacy.

## 2. Message policy

### Three delivery lanes

| Lane | Examples | Proposed rule |
| --- | --- | --- |
| Proactive advice | Morning result, changed training context, charge warning, new pattern | At most 2 local notices per local calendar day, 10 per rolling 7 days, and 3 hours between notices. |
| Explicit reminders | Selected wind-down, workout time, journal time, weekly review | Keep the schedule the person chose. Show its expected count before enablement. Coalesce reminders for the same action. |
| Alarm or session control | Existing wake backup and user-started session timer | Preserve the current explicit alarm/session contract. Keep it separate from the advice budget. |

These limits are proposed Noop product settings. WHOOP does not publish an equivalent general budget in the sources reviewed.

The default quiet period for new proactive advice is 21:00 to 08:00 in the device's current timezone. The user can edit it. A selected reminder time permits that reminder only. A workout in progress suppresses routine advice. Sleep in progress suppresses coaching pushes. An existing wake alarm keeps its own contract.

When the person chooses Notify when useful, request normal interruption priority without sound by default, subject to the system's notification and Focus settings. Do not request time-sensitive or critical-alert privileges for these new coaching groups. Foreground updates remain unobtrusive.

A proactive notice must not fire within 30 minutes of a known explicit reminder. Prefer a combined useful message when both support the same action. Otherwise, retain the better candidate only if it remains useful after the interval.

### Eligibility order

1. Confirm the user enabled the group and the required data use.
2. Check source, event identity, measurement date, finality, coverage, and model version.
3. Check context, expiry, repeats, quiet hours, active sessions, and attention limits.
4. Choose one message per related event and select its delivery lane.
5. Claim the event, schedule it, record the result, and reconcile cancellation.

Return an explicit reason for silence. Examples include `missing_input`, `stale_metric`, `source_changed`, `historical_replay`, `already_seen`, `already_scheduled`, `active_workout`, `quiet_hours`, `expired`, `category_off`, `permission_denied`, and `budget_full`.

### Select a message

Sort eligible candidates by user-requested timing, action deadline, priority, and stable rule ID. Use a deterministic tie break. A rule's priority can select between useful messages; it cannot override consent, data validity, or an expiry.

Merge related morning facts into one morning summary. A low recovery score, short sleep, and changed workout plan should usually share one message. Merge a reached strain target into a completed workout summary when both describe that workout. Combine low battery percentage and low estimated runtime into one charge alert.

Persist a shared attention key for the coalesced event as well as each family occurrence. Separate callbacks for sleep and recovery must find the same claimed morning event, including after a restart. Battery percentage and runtime must claim the same device charging episode. A family-specific unique key alone cannot prevent these collisions.

Use an episode key for a persistent pattern. A process restart or a date change must not create another alert for the same pattern. Rearm only after a valid clearing observation. An unknown observation does not prove the pattern cleared.

### Time and freshness

| Data | Proposed notification eligibility | Expiry or failure behavior |
| --- | --- | --- |
| Completed sleep and overnight recovery | Current physiological wake day; finalized sleep identity; required source and model accepted | Morning push expires at the selected morning-window end, normally noon. Late data can update the app. |
| Intraday strain | Current logical day; canonical model; source observations no more than 30 minutes old | Suppress a target message until current data arrives. |
| Live stress or inactivity | Existing engine says eligible; stream freshness within that engine's limit; no active workout or lift | Drop after the useful moment. Keep the existing haptic path separate. |
| Battery percentage | A device-specific observation no more than 30 minutes old | Older data must use explicit last-seen wording and a distinct rule. |
| Runtime estimate | Valid device model, usable estimate, current reading, charging state known where required | Use percentage alone when the estimate is unavailable. Never turn unknown runtime into zero. |
| Workout result | Stable canonical workout identity; current scoring revision settled | Optional push within 60 minutes of the completed event. Historical repair updates only the app. |
| Weekly trend | Complete prior local week; required coverage and stable source/model across the comparison | Send in the selected review window, at most 24 hours after it. |
| Future reminder | Explicit saved schedule and current schedule revision | Schedule generic future copy. Refresh or cancel when the plan changes. |

The 30-minute, 60-minute, noon, and 24-hour values above are proposed defaults. Keep them configurable in one policy. Existing engine confidence thresholds remain authoritative. Do not alter scoring methods to make a notification pass.

Use the event's timezone and logical-day identity where needed. A current dashboard can legitimately show yesterday's completed recovery. That display policy does not authorize a new alert saying today's recovery changed.

Do not build a data-sensitive message before its observations exist. A scheduled 07:00 notice can say that the chosen morning check-in is due. It cannot claim a fresh recovery score unless a valid score has arrived. A new-data message should fire after a valid data commit, subject to actual iOS execution.

Expiry is the latest useful evaluation or submission time. It is not a guarantee that the OS will present or remove a notice by that time. A submitted local request cannot run eligibility code when its trigger fires. Focus and system behavior can delay presentation. Use generic future copy for pre-scheduled reminders, cancel obsolete requests at the next available execution opportunity, and show current status when the person opens one. The same limitation applies when a workout finishes while the app is suspended and its previously scheduled reminder is still pending.

### Private previews and wording

Default lock-screen content should avoid health values and sensitive journal details. Examples include “Your daily summary is ready” and “Your sleep plan has an update.” Show measurements, dates, source, and the reason inside the destination screen.

The catalog contains detailed templates plus fictional example values. Use that detailed text in the app. The user can separately choose to show health details in notifications, subject to iOS preview settings. Do not put alcohol, mood, cycle, medical, or similar sensitive context in a public preview.

Prefer one observation and one useful action. Use the same rounded figure and unit as the destination screen. Describe a model output as an estimate when needed. If a measurement is missing, omit the claim that requires it.

Suggested copy:

| Situation | Detailed example | Destination |
| --- | --- | --- |
| Complete morning result | “Your sleep and recovery results are ready. Review today's plan before your scheduled session.” | Current day summary |
| Bedtime changed after wake-time edit | “Your wake time is 06:00. Your sleep plan now starts at 22:00.” | Sleep plan |
| Workout result settled | “Your workout result is ready, including your logged sets. Review the session summary.” | That workout |
| Device has limited recording time | “Your strap has about 6 hours left. Charge it before your planned sleep.” | That device |
| Source has old data | “Your last device update was at 08:10. Current results will appear after the next sync.” | Device data status |

These are illustrative copy examples. They are not readings from Easton's health data.

Avoid diagnosis, emergency detection, injury probabilities, promises of tomorrow's recovery, or claims that load proves a workout is safe. A low score should not create shame. A high score should not demand harder exercise. Logged water is a record of logging, not a measurement of hydration need.

## 3. Data and implementation contract

### Current integration boundaries

The inspected app is `eastonplace/noop-ios` at `00eadc67c23fee97fd064f1aeb6d79b7a7f2e537`. The upstream reference is `ryanbr/noop` at `8e4b0c16e7640607600fa6bde5424095eba6034e`.

Draft PR #62 repairs recovery inputs and history. It is separate from main. Gate notifications that depend on those repairs until a reviewed version is integrated and repaired results are available. A successful merge alone does not make old cached results valid.

Draft PR #63 changes routine Start and selected UI. It also starts from the inspected main and excludes #62. Coordinate route and settings work with it. Preserve the current Training Load and Journal screens.

Use the existing canonical data path. `TodayHealthSnapshotResolver` tracks metric dates and authority. `CanonicalHealthReadModel` tracks source and generation. `Repository.canonicalDays` exposes the canonical strain chain. Notification code should consume those contracts.

Keep these metric distinctions:

- Stored daily strain uses 0 to 100. Display strain uses 0 to 21. Compare values on one declared scale.
- Training Load uses 7-day and 42-day exponential values. Readiness has a separate 7-day and 28-day rolling ratio.
- Noop's canonical strain differs from imported WHOOP strain. Imported values retain their source labels.
- Apple SDNN and WHOOP RMSSD differ. A shared “HRV” label cannot make them interchangeable.
- Sleep stages are estimates. Sparse or untrusted stage results cannot trigger stage-based coaching pushes.

Aerobic and anaerobic load need a reviewed data model before alerts can use them. The current Training Load model has one daily load input. Preserve Easton's requested placement for a future split trend under Tomorrow. Build that measurement contract before its notification rules.

### Candidate model

Each candidate needs `ruleID`, `ruleVersion`, `subjectID`, `sourceContext`, `occurrenceID`, `attentionKey`, `evidenceRevision`, `logicalDay`, `observedAt`, `generatedAt`, `expiresAt`, `quality`, `lane`, `priority`, `route`, and `previewPolicy`.

Do not use a new scoring generation as a new event identity. Keep a stable event identity and a separate evidence revision. A correction can replace or withdraw the same pending notice. It should not create another alert about the same sleep or workout.

`sourceContext` describes the stable source authority and data lineage. Database generation is a separate evidence freshness token. A new generation must not make a previously claimed event new. A real database replacement requires ownership reconciliation before any request can remain valid. A battery occurrence belongs to a paired device. A sleep summary belongs to a canonical sleep episode. A workout summary belongs to the canonical workout identity after duplicate collapse.

### Minimum new components

| Proposed file | Responsibility |
| --- | --- |
| `Packages/StrandAnalytics/Sources/StrandAnalytics/NotificationModels.swift` | Immutable facts, candidates, decisions, routes, and reason codes. |
| `Packages/StrandAnalytics/Sources/StrandAnalytics/NotificationPolicy.swift` | Pure eligibility, priority, coalescing, budget, and expiry decisions. |
| `Packages/StrandAnalytics/Sources/StrandAnalytics/NotificationRules.swift` | Small launch rule set with versioned settings. |
| `Packages/WhoopStore/Sources/WhoopStore/NotificationDecisionStore.swift` | One durable ledger and atomic occurrence claims. |
| `Strand/System/NotificationFactBuilder.swift` | Map current canonical data to immutable facts. |
| `Strand/System/NotificationCoordinator.swift` | Own the platform request lifecycle and reconcile pending state. |
| `Strand/Data/NotificationPreferences.swift` | Shared user choices, versioned migration, and quiet hours. |

These are proposed names. Confirm package boundaries on the latest base before adding files. Use existing code where it already performs the same responsibility. A new package, server, polling daemon, or event bus is unnecessary for this scope.

Modify the existing presenter, route owner, settings route, and relevant producer hooks. Keep current alarm delivery in its own lane. Replace direct posting calls with the coordinator as each family moves over. Delete obsolete posting paths after their regression tests pass.

### Ledger and submission

Use unique occurrence and shared attention keys in SQLite. Claim them together before asynchronous work. Store evaluation state separately from scheduling state. The states should include evaluated, suppressed, reserved, submitting, submitted, submission_uncertain, failed, withdrawn, and acknowledged. Persist the transition to submitting before invoking the platform add call.

An accepted `UNUserNotificationCenter.add` call proves submission to the system. It does not prove the user saw the alert. Use “submitted” in logs and tests. Treat a returned delivered record or user action as separate evidence.

Reserve proactive budget atomically with the attention claim. Release a reservation after a known scheduling failure. Permit at most one retry after a known failure, while the candidate remains valid. A submission with an unknown result must be reconciled against pending and delivered identifiers.

On launch, reconcile interrupted rows with pending and delivered requests. If a matching request exists, record its submission. Absence of both records does not prove non-delivery because the user may have dismissed the notice. Mark that outcome submission_uncertain, retain its conservative attention charge, and do not resubmit that proactive occurrence. Only a durable pre-submission state that proves add was never invoked can proceed with a still-valid initial submission. A later distinct chosen reminder occurrence keeps its own schedule.

Store event metadata and reason codes. Keep detailed health text out of routine diagnostic logs. Retain ledger rows for 30 days by default; keep long-lived episode and user-preference state separately. Retention is a proposed product policy.

### Scheduling and cancellation

Evaluate after successful canonical commits, stable workout completion, device-state changes, or user schedule changes. Coalesce repeated callbacks for the same evidence revision. Reuse existing background and HealthKit completion hooks. Do not add a timer that scans all history every minute.

Use 24 routine pending requests as a soft management target, not a system-capacity claim or a reason to silently discard a selected schedule. Prefer generic recurring calendar requests for stable chosen schedules. Bound the horizon of one-shot requests. If a requested schedule cannot be represented or submitted, show its setup status and a concrete way to simplify or change it. Preserve already accepted schedules while resolving the limit. Keep existing alarm requests separately owned. Cancel obsolete requests by namespace and occurrence ID, never by clearing all pending notifications.

Reconcile time-based schedules on launch, app activation, significant clock change, timezone change, daylight-saving change, and relevant settings changes. The existing previous-weekday wind-down fix must survive the refactor.

For one-shot occurrences resolved by app code, a nonexistent spring-transition minute moves to the first valid local time after the gap; a repeated fall-transition minute uses its first occurrence. Preview the resolved date and time and persist one occurrence identity. Repeating OS calendar triggers use the platform's matching behavior while the app is suspended. Do not claim the ledger runs at each recurrence. Validate those triggers on a device through both clock transitions and reconcile them at the next lifecycle opportunity. Existing wake-alarm behavior remains separately owned.

Withdraw obsolete pending requests after a source switch, data deletion, plan edit, or category disablement. Remove delivered health details after privacy disablement where the API permits. Show current evidence when a person taps an old message. If the linked record was deleted, show a clear neutral explanation.

### Routes and actions

Use typed routes carrying a day, session, or device identity. Queue a cold-launch tap until the app has loaded its source and navigation state. Respect onboarding, terms, and active-workout presentation guards. Reject unknown payload versions with a safe destination.

Start with Open, Snooze, and Turn off this type where they fit. A tap opens a screen; it must not start a workout or change the plan. Snooze is available only while the action remains useful. Show completion of a habit only after an explicit user action and a successful saved change.

When the relevant screen is visible, update that screen. Use a subtle in-app message if needed. The current always-banner-and-sound presenter should gain per-category handling.

## 4. Rollout and measurement

Ship the foundation before expanding the rule list. Migrate existing producers first. Test the complete lifecycle with a fake clock and fake notification center.

Enable the eight launch groups as selectable options after their data dependencies pass. Keep each option off for existing installs until selected, except for choices already enabled. Run new advisory rules in a local dry-run mode first. Dry run records eligible candidates and silence reasons without scheduling alerts.

Add context-based habits and reviewed trend rules in a later release. Keep new load splits, future forecasts, and explicit Coach commitments behind their stated dependencies. A family in Deferred cannot be turned on by a catalog import.

Use local measures to assess value: completed action after a tap, unnecessary repeats, stale-content incidents, and category opt-outs. Do not treat notification count or screen-open count alone as success. An in-app “Useful” or “Less often” control can collect direct feedback.

Validate on a physical iPhone. Test locked data, delayed background work, Focus, denied and provisional permissions, timezone travel, interrupted sync, and process restarts. A simulator cannot establish the full background, strap, or power behavior.

## 5. Acceptance and evidence

The release passes when useful messages open the correct record, old evidence stays silent, and chosen schedules survive restarts. It must also preserve existing alarm behavior and source ownership.

The companion implementation plan maps the work to exact files and meaningful tests. The original design catalog describes 540 positive cases; it is a backlog, not 540 required production rules. The recovered original catalog and separate failure matrix are retained under `handoff/`. Their design validation is distinct from production rule coverage.

This handoff does not claim an iOS build or device test. See `REPO_AND_WHOOP_EVIDENCE.md` for pinned source links and `SOURCE_COVERAGE.md` for the first-release source audit. The recovered original `handoff/validation/VALIDATION_REPORT.json` records artifact validation for the supplied design library. Its checks do not establish production support for every row or executed app failure scenarios.
