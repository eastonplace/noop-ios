# Noop notification evidence

Reviewed on October 20, 2026. Repository access was read-only. This review did not build or run either app.

## Repository snapshot

| Repository | Inspected head | Relevant state |
| --- | --- | --- |
| [eastonplace/noop-ios](https://github.com/eastonplace/noop-ios) | [00eadc67c23fee97fd064f1aeb6d79b7a7f2e537](https://github.com/eastonplace/noop-ios/commit/00eadc67c23fee97fd064f1aeb6d79b7a7f2e537) | Main includes merged Strength Strain PR #61. |
| [ryanbr/noop](https://github.com/ryanbr/noop) | [8e4b0c16e7640607600fa6bde5424095eba6034e](https://github.com/ryanbr/noop/commit/8e4b0c16e7640607600fa6bde5424095eba6034e) | Upstream main is a testing-oriented line. Platform support differs from Easton's iOS app. |

[PR #62](https://github.com/eastonplace/noop-ios/pull/62) remains open and draft at `35d6cd8ce20469397f0425f2edff2c61f30cf294`. It repairs RR processing, recovery baselines, overnight RHR, HRV, caches, and historical calculations. Its test results are claims recorded by that PR. This notification review did not rerun them.

[PR #63](https://github.com/eastonplace/noop-ios/pull/63) remains open and draft at `e4c39dcdc4da00b7f0813542b557961c0d08b539`. It changes routine Start, Live HR, Breathe, and selected settings. It starts from main and excludes #62. Recheck both PRs before implementation because their state can change.

## Existing iOS alerts

The inspected producer paths contain eight distinct OS alert intents. The count describes user-visible reasons. It does not count weekday schedules or registered Apple action categories.

| Intent | Current behavior | Evidence |
| --- | --- | --- |
| Low battery | At or below 15%; charging suppresses it. Rearms at or above 25%. | [Battery policy](https://github.com/eastonplace/noop-ios/blob/00eadc67c23fee97fd064f1aeb6d79b7a7f2e537/Strand/System/BatteryNotifier.swift#L18-L52) |
| Full battery | At 100%; rearms below 100%. Removes the old full-charge message after discharge. | [Battery notification lifecycle](https://github.com/eastonplace/noop-ios/blob/00eadc67c23fee97fd064f1aeb6d79b7a7f2e537/Strand/System/BatteryNotifier.swift#L66-L98) |
| Low estimated runtime | At or below 24 hours; rearms at 36 hours. Requires a usable estimate and the relevant toggles. | [Runtime alert](https://github.com/eastonplace/noop-ios/blob/00eadc67c23fee97fd064f1aeb6d79b7a7f2e537/Strand/System/BatteryNotifier.swift#L101-L118) |
| Health-pattern warning | Posts when the health banner changes to a raised state. Has a local daily limit. | [Illness notifier](https://github.com/eastonplace/noop-ios/blob/00eadc67c23fee97fd064f1aeb6d79b7a7f2e537/Strand/System/IllnessNotifier.swift#L20-L44) |
| Wind-down | Uses selected wake time, cached canonical Sleep Need, and a lead time. Supports daily or weekday requests. | [Wind-down scheduler](https://github.com/eastonplace/noop-ios/blob/00eadc67c23fee97fd064f1aeb6d79b7a7f2e537/Strand/System/WindDownNudge.swift#L225-L265) |
| Inactivity mirror | Mirrors a detected sedentary wrist nudge. It uses its own feature and wrist settings. | [Wrist alert hooks](https://github.com/eastonplace/noop-ios/blob/00eadc67c23fee97fd064f1aeb6d79b7a7f2e537/Strand/App/AppModel.swift#L3309-L3320) |
| Smart-alarm fired mirror | Posts after the strap alarm callback. | [Alarm mirror](https://github.com/eastonplace/noop-ios/blob/00eadc67c23fee97fd064f1aeb6d79b7a7f2e537/StrandiOS/App/SmartAlarmRuntimeController.swift#L174-L198) |
| Smart-alarm phone backup | Uses generation-scoped calendar requests at the latest wake endpoint. | [Alarm backup requests](https://github.com/eastonplace/noop-ios/blob/00eadc67c23fee97fd064f1aeb6d79b7a7f2e537/StrandiOS/App/SmartAlarmRuntimeController.swift#L670-L778) |

Stress check-ins and heart-rate zone cues use separate in-app or strap-haptic paths. They are not additional phone notification types. The stress callback currently supplies no motion observation and uses the pending stress card as its session guard. Add an explicit active-workout and active-lift check before expanding this path. [Stress callback](https://github.com/eastonplace/noop-ios/blob/00eadc67c23fee97fd064f1aeb6d79b7a7f2e537/Strand/App/AppModel.swift#L3025-L3055)

## What to reuse from upstream

| Upstream capability | Fork gap or difference | Recommended treatment |
| --- | --- | --- |
| [Daily strain target notifier](https://github.com/ryanbr/noop/blob/8e4b0c16e7640607600fa6bde5424095eba6034e/Strand/System/StrainTargetNotifier.swift) | No equivalent notifier appears in the fork tree. The fork has target guidance. | Adapt the pure rule. Use canonical daily strain and one episode claim. Check units and source freshness. |
| [Battery runway and last-seen alerts](https://github.com/ryanbr/noop/blob/8e4b0c16e7640607600fa6bde5424095eba6034e/Strand/System/BatteryNotifier.swift) | Fork has percentage and runtime alerts. Upstream adds critical, before-bed, and last-seen-low reasons. | Combine charge reasons. Preserve honest last-seen copy. Do not copy time-sensitive priority or hardware cutoffs without review. |
| [Scheduled Coach brief](https://github.com/ryanbr/noop/blob/8e4b0c16e7640607600fa6bde5424095eba6034e/Strand/System/CoachBriefScheduler.swift) | Fork lacks this scheduler. Its Coach stack has changed. | Reuse consent, master-off, and pending-state ideas. Start with deterministic local summaries. |
| [Android morning and workout reports](https://github.com/ryanbr/noop/blob/8e4b0c16e7640607600fa6bde5424095eba6034e/android/app/src/main/java/com/noop/notif/ScheduledReportNotifier.kt) | These are Android code. | Port behavior into the shared Swift policy. Dedupe morning results by sleep episode. |
| [Android persisted health-pattern state](https://github.com/ryanbr/noop/blob/8e4b0c16e7640607600fa6bde5424095eba6034e/android/app/src/main/java/com/noop/notif/IllnessAlertNotifier.kt) | Apple's edge state can reset with the process. | Persist raised, clear, and unknown states. A new date must not create a new pattern episode. |
| [Upstream tap handler](https://github.com/ryanbr/noop/blob/8e4b0c16e7640607600fa6bde5424095eba6034e/Strand/System/NotificationPresenter.swift#L26-L45) | Only Coach has a specific route upstream. The fork has no response handler here. | Add typed routes for every launch group in the fork's own navigation system. |

Upstream's Coach scheduler uses a configured provider request. A local schedule does not make model inference local. Its failure path can also send another retry notice after later failures. Avoid importing that failure behavior into the launch release. [Coach generation and posting](https://github.com/ryanbr/noop/blob/8e4b0c16e7640607600fa6bde5424095eba6034e/Strand/System/CoachBriefScheduler.swift#L230-L322)

Upstream has 13 Apple alert intents in the inspected producers. Android also has the two report behaviors above. The sources do not establish that iOS has Android's complete notification behavior.

## Changes that should come first

| Finding | Why it matters | Exact source |
| --- | --- | --- |
| Separate producers post directly | Battery percentage and runtime can create two notices for one action. Additional health rules would add similar collisions. | [BatteryNotifier](https://github.com/eastonplace/noop-ios/blob/00eadc67c23fee97fd064f1aeb6d79b7a7f2e537/Strand/System/BatteryNotifier.swift) |
| Permission checks differ | Some paths accept only authorized status. Others accept provisional status. Some consume a repeat flag before submission. | [Battery posting](https://github.com/eastonplace/noop-ios/blob/00eadc67c23fee97fd064f1aeb6d79b7a7f2e537/Strand/System/BatteryNotifier.swift#L120-L134), [wind-down permission](https://github.com/eastonplace/noop-ios/blob/00eadc67c23fee97fd064f1aeb6d79b7a7f2e537/Strand/System/WindDownNudge.swift#L181-L208) |
| Presenter always asks for banner, sound, and list | A routine update can interrupt a person already viewing the result. | [NotificationPresenter](https://github.com/eastonplace/noop-ios/blob/00eadc67c23fee97fd064f1aeb6d79b7a7f2e537/Strand/System/NotificationPresenter.swift#L15-L28) |
| Wind-down refresh depends on a view | A valid repeating request can retain an old sleep plan. The merged weekday fix needs schedule reconciliation on launch. | [Canonical need refresh](https://github.com/eastonplace/noop-ios/blob/00eadc67c23fee97fd064f1aeb6d79b7a7f2e537/Strand/Screens/SmartAlarmView.swift#L170-L176), [PR #60](https://github.com/eastonplace/noop-ios/pull/60) |
| Health-pattern caller reads recent rows and text questions | New data checks need explicit event dates and typed journal context. | [Health-pattern evaluation](https://github.com/eastonplace/noop-ios/blob/00eadc67c23fee97fd064f1aeb6d79b7a7f2e537/Strand/App/AppModel.swift#L3494-L3600) |
| Snapshot carry has a valid UI purpose | A carried score must retain its day when the notification engine evaluates it. | [TodayHealthSnapshotResolver](https://github.com/eastonplace/noop-ios/blob/00eadc67c23fee97fd064f1aeb6d79b7a7f2e537/Packages/WhoopStore/Sources/WhoopStore/TodayHealthSnapshotResolver.swift) |

## Data the design can use

The fork already has canonical sleep, recovery, stress, strain, source metadata, workout history, saved Lift schedules, journal entries, and several habit stores. Availability still depends on the selected device, coverage, and user input. [Canonical read model](https://github.com/eastonplace/noop-ios/blob/00eadc67c23fee97fd064f1aeb6d79b7a7f2e537/Strand/Data/CanonicalHealthReadModel.swift), [Repository canonical days](https://github.com/eastonplace/noop-ios/blob/00eadc67c23fee97fd064f1aeb6d79b7a7f2e537/Strand/Data/Repository.swift#L988-L1027)

Training Load uses 7/42-day exponential values. Its page has current-load ratios and hypothetical Tomorrow scenarios. Readiness uses a different 7/28-day rolling ratio. Keep their names, units, and meanings separate. [TrainingLoadEngine](https://github.com/eastonplace/noop-ios/blob/00eadc67c23fee97fd064f1aeb6d79b7a7f2e537/Packages/StrandAnalytics/Sources/StrandAnalytics/TrainingLoadEngine.swift), [TrainingLoadPageModel](https://github.com/eastonplace/noop-ios/blob/00eadc67c23fee97fd064f1aeb6d79b7a7f2e537/Packages/StrandAnalytics/Sources/StrandAnalytics/TrainingLoadPageModel.swift), [ReadinessEngine](https://github.com/eastonplace/noop-ios/blob/00eadc67c23fee97fd064f1aeb6d79b7a7f2e537/Packages/StrandAnalytics/Sources/StrandAnalytics/ReadinessEngine.swift)

The inspected Training Load files have one load series. They do not define aerobic and anaerobic load. Separate split-load notifications therefore depend on a new reviewed calculation and data contract. Workout type or high heart rate alone is not that contract.

## Verified WHOOP behavior

The table separates a phone notification from a vibration or an in-app item. The sources establish capabilities, not WHOOP's full internal policy.

| WHOOP feature | Confirmed channel and boundary | Source |
| --- | --- | --- |
| Daily Recovery, Strain, Sleep notices | Official troubleshooting names these phone notification categories. It does not publish their complete trigger rules. | [WHOOP app notification support](https://support.whoop.com/s/article/Resolving-WHOOP-App-Errors-Crashes?language=en_US) |
| Contextual coaching | WHOOP describes push prompts based on shared goals and life context. It also describes morning and evening summaries. The page does not establish that every summary is a phone push. | [WHOOP AI guidance, April 30, 2026](https://www.whoop.com/us/en/thelocker/new-ai-guidance-from-whoop/) |
| Stress summary | Evening summary notifications have user controls for time and frequency. The current source does not establish a push for every stress spike. | [Stress Monitor, September 3, 2025](https://support.whoop.com/s/article/Get-to-Know-the-Stress-Monitor?language=en_US) |
| Strain target | Haptics are documented for 4.0, 5.0, and MG. The documented 4.0 behavior requires an active Strain Target session. | [Strain Target, June 30, 2025](https://support.whoop.com/s/article/Strain-Coach?language=en_US) |
| Wake alarm | Band vibrations support a fixed time or a goal window with a latest wake time. This is not proof of sleep-stage wake detection. | [Haptic Alarm, October 30, 2025](https://support.whoop.com/s/article/The-Haptic-Alarm-Dashboard?language=en_US) |
| Health Monitor | Personal-baseline deviations appear as color-coded in-app alerts. The source does not specify a phone-push channel. | [Health Monitor, July 22, 2025](https://support.whoop.com/s/article/WHOOP-Health-Monitor-Report?language=en_US) |
| Irregular rhythm | A regulated feature has specific hardware, membership, age, and region limits. It is outside this wellness notification plan. | [IHRN support, October 6, 2026](https://support.whoop.com/s/article/Irregular-Heart-Rhythm-Notifications-Data-Accuracy-Best-Practices?language=en_US) |

Exact WHOOP battery push thresholds, bedtime push timing, journal push policy, quiet hours, and general ranking rules remain unverified. Use Noop's code or explicit product choices for those decisions.

## Apple constraints

| Constraint | Design consequence | Primary source |
| --- | --- | --- |
| Local requests contain saved content and triggers | Use time-based requests for chosen reminders. Cancel obsolete requests after the relevant state changes. | [Scheduling local notifications](https://developer.apple.com/documentation/usernotifications/scheduling-a-notification-locally-from-your-app) |
| A background request's earliest time is not a guaranteed run time | Data-based advice runs when the app gets valid data and execution time. Avoid exact-time claims for fresh scores. | [earliestBeginDate](https://developer.apple.com/documentation/backgroundtasks/bgtaskrequest/earliestbegindate) |
| HealthKit hides whether a user denied read access | Empty results cannot prove denied permission, missing sleep, or poor health. | [Authorizing health data](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data) |
| Apple advises concise, private, nonduplicate notifications | Use private previews, event grouping, and quiet foreground updates. | [Notification design guidance](https://developer.apple.com/design/human-interface-guidelines/notifications) |
| Watch delivery depends on device and user settings | Do not promise that both devices will alert or that phone notifications control a strap vibration. | [Apple Watch notifications](https://support.apple.com/en-us/108369) |

Some official support pages returned a CSS error when opened. Their full indexed article text supplied the relevant evidence. WHOOP's AI article opened directly. This review did not inspect a signed-in WHOOP notification settings screen.
