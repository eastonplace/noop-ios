# Notification failure and platform test matrix

96 test specifications. App tests were not run in this research task.

These cases are separate from the 540 user-visible notification possibilities.

## Freshness and finality

| ID | Given | When | Expected result |
| --- | --- | --- | --- |
| QA001 | Yesterday recovery is carried on Today | Morning evaluation starts | Suppress a current-day recovery claim; keep the dated UI value. |
| QA002 | Sleep session is still recording | A partial score appears | Wait for the finalized episode; send no completed-night recap. |
| QA003 | Workout score is pending Strength settlement | The workout ends | Show pending state in app; delay a scored-result message. |
| QA004 | Current strain observation is 31 minutes old | Target rule evaluates with a 30-minute limit | Suppress until a current observation exists. |
| QA005 | Battery observation is 31 minutes old | A live low-battery rule evaluates | Reject live wording; only an eligible last-seen rule can describe it. |
| QA006 | Morning data arrives after the configured noon deadline | A new score commits at 14:00 | Update the app; do not replay a morning push. |
| QA007 | Weekly data arrives more than 24 hours after its selected window | The digest completes | Keep the report in app and expire its old scheduled notice. |
| QA008 | Phone is locked and the health store is unavailable | An observer wakes the app | Keep data unknown; do not interpret the failed read as a physiological change. |

## Source identity and ownership

| ID | Given | When | Expected result |
| --- | --- | --- | --- |
| QA009 | User changes the active source while a candidate waits | The coordinator is about to submit | Revalidate source context and withdraw the old-source candidate. |
| QA010 | WHOOP RMSSD and Apple SDNN are present | HRV trend evaluation starts | Compare compatible measurement types only; do not join them into one baseline. |
| QA011 | A workout exists from two imported sources | Both ingest callbacks complete | Use the canonical duplicate-collapsed session identity for one result. |
| QA012 | Two paired straps both have low battery | Their readings arrive together | Keep device identities separate; select useful device-specific messages under the budget. |
| QA013 | A local sleep score and imported WHOOP score disagree | The daily recap is built | Use the selected production source and label it; do not average the scores. |
| QA014 | A user-edited sleep record exists | Historical sync sends its older boundary | Preserve user authority and prevent an obsolete correction alert. |
| QA015 | The database context changes after restore | Old pending notifications are reconciled | Withdraw requests that cannot prove matching source and event ownership. |
| QA016 | The same stable source and event have a new database generation | A fact builder compares revisions | Reject stale facts but preserve the event and attention claims; generation alone is not a new occurrence. |

## Metric values and versions

| ID | Given | When | Expected result |
| --- | --- | --- | --- |
| QA017 | A recovery input is missing | A rule needs a recovery target | Keep the target unknown and suppress the target-based notice. |
| QA018 | A valid measured zero is present | The policy validates the value | Preserve zero where the metric permits it; do not treat it as missing. |
| QA019 | A metric contains NaN or infinity | The fact builder creates evidence | Reject the value before thresholds or copy render. |
| QA020 | Daily strain is stored on 0 to 100 and target uses 0 to 21 | A crossing is checked | Convert once through the canonical formatter and compare one declared scale. |
| QA021 | Training Load has a 7/42 ratio and Readiness has a 7/28 ratio | A trend message is built | Use the correct named ratio and destination; never swap their labels. |
| QA022 | PR62 is merged but cached rows still use the old model | A dependent notification evaluates | Keep the dependency gate closed until repaired current data is available. |
| QA023 | A historical scoring migration updates 200 days | Each updated row publishes | Allow UI refresh; create no new current-event notifications from the backfill. |
| QA024 | No aerobic/anaerobic producer is installed | The deferred split-load family is loaded | Leave it disabled; do not derive the split from sport labels or HR alone. |

## Clock and schedule changes

| ID | Given | When | Expected result |
| --- | --- | --- | --- |
| QA025 | A wind-down for Monday sleep occurs on Sunday evening | Weekday requests are built | Use the previous weekday correctly and create one Sunday occurrence. |
| QA026 | DST spring transition removes a selected one-shot wall-clock minute | App code resolves the occurrence | Choose the first valid local time after the gap once and show the resolved time; separately test repeating OS calendar behavior on device. |
| QA027 | DST fall transition repeats a selected one-shot wall-clock minute | App code resolves both matches | Choose the first occurrence and one stable identifier; do not assume app code runs at each OS repeating trigger. |
| QA028 | The user travels to a new timezone | A significant time change arrives | Rebuild future local schedules; preserve completed event identity and budget history. |
| QA029 | The clock moves backward by two hours | A scheduled slot appears due again | Do not repeat a claimed occurrence or reset the rolling budget. |
| QA030 | The date changes during an active night-shift sleep | A daily rule evaluates | Use the physiological wake day and completed episode; do not force a midnight recap. |
| QA031 | A wake time changes after a wind-down request exists | Settings save succeeds | Cancel the old revision and schedule the new correct local occurrence. |
| QA032 | The device reboots with reminders already pending | The app later starts | Reconcile by stable identifiers; avoid adding a second set of weekday requests. |

## Permissions and user choices

| ID | Given | When | Expected result |
| --- | --- | --- | --- |
| QA033 | Notification authorization is denied | An eligible event arrives | Record the reason and update in-app state without another permission prompt. |
| QA034 | Authorization is provisional | A routine local request is eligible | Respect the OS quiet-delivery state and the category choice; do not demand full authorization. |
| QA035 | The user has never been asked for permission | A background data event arrives | Do not show a surprise permission prompt; request permission from a chosen foreground setup action. |
| QA036 | HealthKit returns no sleep samples | A repair rule evaluates | Use neutral data-availability wording; do not claim read permission was denied. |
| QA037 | A new app version adds ten groups | Preference migration runs | Keep new push groups off and preserve every existing choice. |
| QA038 | The user turns off a group during an awaited add | The add completes | Recheck the preference and remove the now-obsolete pending/delivered request where possible. |
| QA039 | Selected schedules exceed the 24-request management target | The schedule manager reconciles | Preserve accepted schedules, use generic recurring requests or a bounded one-shot horizon, and surface actual setup failure without silently dropping a chosen reminder. |
| QA040 | Breathe or Hydrate was never selected | A catalog rule references that tool | Keep its push disabled even when a related health pattern appears. |

## Concurrency and process recovery

| ID | Given | When | Expected result |
| --- | --- | --- | --- |
| QA041 | Two callbacks contain the same evidence revision | Both evaluate concurrently | One transaction claims the occurrence and one budget slot. |
| QA042 | Durable state proves the process exited before the submitting transition and before add could run | It starts again | Revalidate and allow a still-valid initial submission; a generic reserved row with ambiguous invocation history is not enough. |
| QA043 | The process exits after accepted add and before ledger update | It starts again | Find the existing request and mark submitted without posting a duplicate. |
| QA044 | The add call fails with a known error | The coordinator records failure | Release its reservation and allow at most one retry before expiry. |
| QA045 | The add outcome is unknown and no pending or delivered record remains | Another evaluation requests a retry | Record submission_uncertain and keep its attention charge; a dismissed notice may have been seen, so do not retry the proactive occurrence. |
| QA046 | A background task expires during evidence collection | Its handler completes | Cancel unfinished work and do not create a partial-data candidate. |
| QA047 | A new snapshot supersedes the in-flight snapshot | The older task resumes | Reject the stale generation and process the latest immutable facts. |
| QA048 | The same sleep episode is rescored with a new generation | It still supports the same action | Replace or update the same occurrence; do not use generation as a fresh event ID. |

## Budget and collision policy

| ID | Given | When | Expected result |
| --- | --- | --- | --- |
| QA049 | Two proactive notices have been submitted today | A third ordinary candidate becomes eligible | Keep it in app or digest; do not exceed the daily limit. |
| QA050 | Ten proactive notices were submitted in the prior seven days | Another candidate arrives | Keep it out of the proactive lane until a slot ages out. |
| QA051 | Last proactive submission was 179 minutes ago | An ordinary candidate arrives | Enforce the 180-minute gap; submit later only if it remains useful. |
| QA052 | Last proactive submission was exactly 180 minutes ago | A valid candidate arrives and all other gates pass | Allow its priority evaluation; do not add an off-by-one delay. |
| QA053 | An explicit wind-down reminder is due in 20 minutes | A proactive insight appears | Yield the proactive notice and preserve the chosen reminder. |
| QA054 | Sleep, recovery, and a plan conflict describe one morning | Separate callbacks arrive before and after submission and restart | Use the same persisted attention key so one combined morning action consumes one slot and later families cannot post again. |
| QA055 | Battery percentage and runtime describe the same low-charge episode | Their rules arrive in separate callbacks after a restart | Use the shared device-episode attention claim and submit one charge message with the best supported explanation. |
| QA056 | A user-requested wake alarm is due after the advice budget fills | The alarm occurrence runs | Preserve its existing alarm lane and do not drop it because advice slots were used. |

## Privacy and presentation

| ID | Given | When | Expected result |
| --- | --- | --- | --- |
| QA057 | Private previews are enabled | A recovery candidate renders | Public content contains no health value; detailed data stays in the destination. |
| QA058 | A journal entry contains alcohol or mood context | A related insight renders | Keep that sensitive context out of the public preview. |
| QA059 | The relevant detail screen is already visible | Its new data commits | Update the screen without a routine banner or sound. |
| QA060 | The app is active on a different screen | A routine result arrives | Use unobtrusive in-app presentation according to category policy. |
| QA061 | The user disables detailed previews | Old detailed notifications remain visible | Remove exposed delivered items where supported and rebuild future generic content. |
| QA062 | OS Focus delays presentation beyond app expiry | The app records add success | Record submitted only; do not promise presentation by expiry or automatic removal, and revalidate current status on tap. |
| QA063 | Apple Watch mirroring is enabled | iOS routes a notice to the watch | Respect system routing and do not create a second manual watch alert. |
| QA064 | Diagnostic logging is enabled | A candidate is suppressed | Log event IDs and reason codes without raw health or journal text. |

## Routes and explicit actions

| ID | Given | When | Expected result |
| --- | --- | --- | --- |
| QA065 | The app is cold when a workout notice is tapped | The route arrives before data load | Queue the typed route and open the correct canonical workout after startup. |
| QA066 | The linked workout was deleted | Its older notice is tapped | Show a neutral removed-record state and avoid opening a different workout. |
| QA067 | A notification payload has an unsupported version | The presenter handles it | Reject unsafe fields and open a supported neutral destination. |
| QA068 | An active Lift session is recording | A routine-plan notice is tapped | Preserve the active session and offer review without starting or replacing exercise. |
| QA069 | A snooze would end after the candidate expiry | The user selects snooze | Do not schedule stale content; show that the original reminder has expired. |
| QA070 | The user chooses Turn off this type | The preference saves | Cancel that family only; preserve other groups and alarms. |
| QA071 | A Mark done action fails to save | The action handler returns | Keep the item incomplete and show a local error; do not consume success state. |
| QA072 | Onboarding or terms covers the shell | A notification is tapped | Hold the route until the required screen completes without losing its identity. |

## Battery and device episodes

| ID | Given | When | Expected result |
| --- | --- | --- | --- |
| QA073 | Battery oscillates between 14 and 15 percent | Several updates arrive | Emit one low event; preserve the existing 25-percent rearm threshold. |
| QA074 | Battery is low and charging is confirmed | The low rule evaluates | Suppress the low-charge action while charging. |
| QA075 | The charging flag changes true to unknown at low battery | The next packet arrives | Do not rearm solely from charging-flag changes. |
| QA076 | Battery reaches 25 percent after a prior low event | The policy updates | Rearm the next genuine discharge episode without posting a low notice now. |
| QA077 | A full-charge notification exists and battery drops to 99 percent | Fresh data arrives | Remove the stale full-charge item and rearm the full event. |
| QA078 | Device runtime estimate is unavailable | Sleep recording runway is evaluated | Do not invent remaining hours or a guaranteed failure time. |
| QA079 | The strap was last seen at 12 percent four hours ago | A selected connection-help rule evaluates | Use last-seen time and percentage, not a claim about current charge. |
| QA080 | A device disconnects briefly during an ordinary reconnect | No action is yet needed | Suppress a repair push and wait for the rule's actual persistence requirement. |

## Sleep and health-pattern episodes

| ID | Given | When | Expected result |
| --- | --- | --- | --- |
| QA081 | A persistent health pattern remains raised across midnight | The app restarts | Keep the same episode and avoid a new warning from date rollover. |
| QA082 | A raised pattern is followed by unknown data | The engine reevaluates | Keep the episode unresolved; unknown must not rearm it. |
| QA083 | A valid clear observation follows a raised pattern | Later valid data raises a new pattern | Allow one new episode after the real clear transition. |
| QA084 | The user already logged feeling unwell | The health engine emits its support path | Do not describe that user report as a new detected illness. |
| QA085 | A sleep stage series is sparse | A restorative-stage trend rule runs | Keep stage-based advice suppressed or clearly unavailable in app. |
| QA086 | A user corrects the sleep boundary | The canonical episode changes | Update related pending copy and dedupe by the preserved episode identity. |
| QA087 | A nap credit changes current Sleep Need | The planner commits | Reconcile wind-down using the current plan and preserve the selected wake time. |
| QA088 | A forecast has a wide uncertainty band | A user opens a planning comparison | Show the estimate and its uncertainty in app; do not promise tomorrow's exact recovery. |

## Workouts and optional habits

| ID | Given | When | Expected result |
| --- | --- | --- | --- |
| QA089 | A workout summary is already open | Strength settlement completes | Refresh the result without another completion notice. |
| QA090 | A lift import has totals but no sets | A Strength explanation is built | Describe the available contribution only; do not claim muscular-set scoring. |
| QA091 | Warm-up sets and working sets are both logged | A record rule compares volume | Use the established set definition and do not inflate the record. |
| QA092 | A scheduled workout completes before its saved reminder | Completion is committed or observed while the app can execute | Cancel the pending reminder and link completion to the plan; if suspended execution prevents cancellation, generic copy must remain neutral and the tap shows current completion. |
| QA093 | A workout is active with low heart rate during a rest interval | Stress-onset data qualifies | Suppress routine stress prompts using explicit active-lift state. |
| QA094 | No water has been logged today | A selected hydration reminder runs | Ask about logging only; do not state the person is dehydrated. |
| QA095 | A new journal association uses too few valid observations | The insight rule evaluates | Keep it unavailable; do not present correlation as a proven cause. |
| QA096 | A Coach commitment was mentioned in chat but never confirmed | Its inferred deadline arrives | Do not create a reminder until a structured user commitment exists. |
