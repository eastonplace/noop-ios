# 54 notification families

Ten explicitly authored positive scenarios belong to each family. All new push groups remain off until selected. Phase is a proposed rollout priority, subject to data dependencies.

| Family | Name | Domain | Phase | Scenario IDs | Local / In app / Digest | Data readiness |
| --- | --- | --- | --- | --- | --- | --- |
| SLP01 | Sleep opportunity planning | Sleep | P1 | SR001 to SR010 | 3 / 7 / 0 | existing_data_new_rule |
| SLP02 | Wind-down reminders | Sleep | P1 | SR011 to SR020 | 5 / 5 / 0 | existing_data_new_rule |
| SLP03 | Wake schedule and alarm readiness | Sleep | P1 | SR021 to SR030 | 4 / 6 / 0 | existing_data_new_rule |
| SLP04 | Sleep need and debt review | Sleep | P2 | SR031 to SR040 | 2 / 5 / 3 | existing_data_new_rule |
| SLP05 | Caffeine timing goals | Habits | Deferred | SR041 to SR050 | 2 / 7 / 1 | new_data_dependency |
| SLP06 | Planned naps | Sleep | Deferred | SR051 to SR060 | 2 / 7 / 1 | new_data_dependency |
| SLP07 | Sleep schedule consistency | Sleep | P2 | SR061 to SR070 | 1 / 1 / 8 | existing_data_new_rule |
| SLP08 | Circadian schedule plans | Sleep | Deferred | SR071 to SR080 | 4 / 6 / 0 | new_data_dependency |
| SLP09 | Completed sleep recap | Sleep | P1 | SR081 to SR090 | 9 / 1 / 0 | pr62_dependency |
| SLP10 | Sleep duration review | Sleep | P2 | SR091 to SR100 | 2 / 4 / 4 | existing_data_new_rule |
| SLP11 | Sleep continuity review | Sleep | P2 | SR101 to SR110 | 0 / 10 / 0 | existing_data_new_rule |
| SLP12 | Estimated restorative sleep trends | Sleep | P2 | SR111 to SR120 | 0 / 9 / 1 | existing_data_new_rule |
| SLP13 | Sleep record review | Data | P1 | SR121 to SR130 | 2 / 8 / 0 | existing_data_new_rule |
| REC01 | Morning recovery and readiness | Recovery | P1 | SR131 to SR140 | 7 / 3 / 0 | pr62_dependency |
| REC02 | Recovery trend and rebound | Recovery | P2 | SR141 to SR150 | 1 / 3 / 6 | pr62_dependency |
| REC03 | Personal vital observations | Recovery | P2 | SR151 to SR160 | 0 / 10 / 0 | pr62_dependency |
| REC04 | Training and recovery balance | Recovery | P2 | SR161 to SR170 | 2 / 6 / 2 | pr62_dependency |
| REC05 | Recovery planning estimates | Recovery | Deferred | SR171 to SR180 | 0 / 10 / 0 | pr62_dependency |
| WT01 | Saved workout recap | Workouts | P1 | WT001 to WT010 | 9 / 1 / 0 | existing_data_new_rule |
| WT02 | Workout comparison review | Workouts | P2 | WT011 to WT020 | 7 / 3 / 0 | existing_data_new_rule |
| WT03 | Saved Lift schedule reminders | Strength | P1 | WT021 to WT030 | 10 / 0 / 0 | existing_data_new_rule |
| WT04 | Routine preparation review | Strength | P2 | WT031 to WT040 | 9 / 1 / 0 | existing_data_new_rule |
| WT05 | Strength session receipt | Strength | P1 | WT041 to WT050 | 9 / 1 / 0 | existing_data_new_rule |
| WT06 | Strength record review | Strength | P2 | WT051 to WT060 | 8 / 1 / 1 | existing_data_new_rule |
| WT07 | Exercise progression review | Strength | P2 | WT061 to WT070 | 7 / 1 / 2 | existing_data_new_rule |
| WT08 | Muscle set distribution review | Strength | P2 | WT071 to WT080 | 0 / 8 / 2 | existing_data_new_rule |
| WT09 | Strength Strain explanation | Strength | P2 | WT081 to WT090 | 0 / 10 / 0 | existing_data_new_rule |
| WT10 | Weekly workout review | Workouts | P1 | WT091 to WT100 | 10 / 0 / 0 | existing_data_new_rule |
| WT11 | Workload ratio transition | Training | P2 | WT101 to WT110 | 9 / 1 / 0 | existing_data_new_rule |
| WT12 | Longer-term load trend | Training | P2 | WT111 to WT120 | 8 / 2 / 0 | existing_data_new_rule |
| WT13 | Tomorrow load scenarios | Training | P2 | WT121 to WT130 | 8 / 1 / 1 | existing_data_new_rule |
| WT14 | Active workout continuity | Workouts | P1 | WT131 to WT140 | 0 / 10 / 0 | existing_data_new_rule |
| WT15 | Return to a saved routine | Strength | P3 | WT141 to WT150 | 7 / 2 / 1 | existing_data_new_rule |
| WT16 | Aerobic and anaerobic load review | Training | Deferred | WT151 to WT160 | 7 / 3 / 0 | new_data_dependency |
| WT17 | Explicit training commitments | Training | Deferred | WT161 to WT170 | 9 / 0 / 1 | new_data_dependency |
| WT18 | Daily Strain target reached | Training | P1 | WT171 to WT180 | 6 / 3 / 1 | pr62_dependency |
| HC01 | Selected journal check-ins | Habits | P1 | HC001 to HC010 | 10 / 0 / 0 | existing_data_new_rule |
| HC02 | Chosen hydration check-ins | Habits | P2 | HC011 to HC020 | 10 / 0 / 0 | existing_data_new_rule |
| HC03 | Hydration log reviews | Habits | P2 | HC021 to HC030 | 7 / 0 / 3 | existing_data_new_rule |
| HC04 | Chosen movement breaks | Habits | P2 | HC031 to HC040 | 7 / 0 / 3 | existing_data_new_rule |
| HC05 | User-created habit routines | Habits | Deferred | HC041 to HC050 | 9 / 1 / 0 | new_data_dependency |
| HC06 | Journal association reviews | Habits | P3 | HC051 to HC060 | 7 / 0 / 3 | pr62_dependency |
| HC07 | Planned breathing practice | Stress | P2 | HC061 to HC070 | 10 / 0 / 0 | existing_data_new_rule |
| HC08 | Opt-in physiological check-ins | Stress | P3 | HC071 to HC080 | 6 / 4 / 0 | existing_data_new_rule |
| HC09 | Stress and context reflections | Stress | Deferred | HC081 to HC090 | 6 / 0 / 4 | new_data_dependency |
| HC10 | Requested coaching follow-ups | Coaching | Deferred | HC091 to HC100 | 9 / 1 / 0 | new_data_dependency |
| HC11 | Explicit coaching commitments | Coaching | Deferred | HC101 to HC110 | 9 / 1 / 0 | new_data_dependency |
| HC12 | Weekly habits review | Coaching | P3 | HC111 to HC120 | 5 / 0 / 5 | existing_data_new_rule |
| HC13 | Battery charge planning | Device | P1 | HC121 to HC130 | 7 / 3 / 0 | existing_data_new_rule |
| HC14 | Requested charge completion | Device | P2 | HC131 to HC140 | 6 / 3 / 1 | existing_data_new_rule |
| HC15 | Device connection and wear help | Device | P1 | HC141 to HC150 | 0 / 10 / 0 | existing_data_new_rule |
| HC16 | Data freshness and sync help | Data | P1 | HC151 to HC160 | 0 / 10 / 0 | existing_data_new_rule |
| HC17 | Source and record quality review | Data | P2 | HC161 to HC170 | 0 / 10 / 0 | existing_data_new_rule |
| HC18 | Requested analysis completion | Data | Deferred | HC171 to HC180 | 9 / 1 / 0 | new_data_dependency |

## Scenario index

### SLP01: Sleep opportunity planning

Choose a feasible bedtime before the selected wake time.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| SR001 | Earlier weekday wake | local_notification | Review bedtime |
| SR002 | Later wake offers schedule choice | in_app | Compare timing |
| SR003 | Planned opportunity below the current need estimate | in_app | Adjust sleep plan |
| SR004 | Remaining opportunity after a delayed bedtime | in_app | Review remaining time |
| SR005 | Date-sensitive after-midnight sleep plan | in_app | Confirm sleep dates |
| SR006 | Upcoming weekday wake override | local_notification | Review tomorrow |
| SR007 | Canonical need update changes planned bedtime | in_app | Review reminder time |
| SR008 | Longer wind-down lead changes preparation time | in_app | Review routine |
| SR009 | Clock change alters actual opportunity | local_notification | Review clock change |
| SR010 | Timezone change requires schedule review | in_app | Confirm local schedule |

### SLP02: Wind-down reminders

Start the user-selected evening routine at the right time.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| SR011 | Standard routine start | local_notification | Open sleep plan |
| SR012 | Early-wake routine occurrence | local_notification | Review early wake |
| SR013 | Routine lands on previous calendar day | local_notification | Check sleep dates |
| SR014 | Short routine after a workout ends | in_app | Review time left |
| SR015 | User-requested one-time snooze | local_notification | Open routine |
| SR016 | Reminder moved into the past by an edit | in_app | Review tonight |
| SR017 | Zero-lead bedtime reminder | local_notification | Open bedtime plan |
| SR018 | User reviews a newly changed reminder | in_app | Review scheduled time |
| SR019 | Weekly reminder schedule contains different times | in_app | Review weekly schedule |
| SR020 | Wind-down authorization needs a user decision | in_app | Open notification settings |

### SLP03: Wake schedule and alarm readiness

Review a wake schedule or repair an alarm setup before it matters.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| SR021 | Firmware wake time differs from the saved plan | local_notification | Review alarm settings |
| SR022 | No confirmed strap alarm before bedtime | local_notification | Check alarm status |
| SR023 | Backup notification authorization denied | in_app | Review notification access |
| SR024 | Next weekday is intentionally excluded | in_app | Review selected days |
| SR025 | Global alarm-time edit acknowledged by device | in_app | Review backup |
| SR026 | Strap and ordinary backup have different times | local_notification | Review both times |
| SR027 | First alarm setup explains backup limits | in_app | Review wake setup |
| SR028 | Clock change creates ambiguous wake time | in_app | Confirm wake occurrence |
| SR029 | Device changed after alarm setup | local_notification | Check this strap |
| SR030 | Backup scheduling failed after an edit | in_app | Review backup status |

### SLP04: Sleep need and debt review

Use the app sleep ledger to choose a realistic next sleep opportunity.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| SR031 | First usable sleep ledger | in_app | View sleep ledger |
| SR032 | Meaningful estimated shortfall first appears | local_notification | Review tonight's plan |
| SR033 | Shortfall increases across three valid nights | local_notification | Review the three nights |
| SR034 | Shortfall materially decreases | digest | Review recent nights |
| SR035 | Ledger reaches the on-target band | digest | View the ledger |
| SR036 | Recorded sleep exceeds the ledger nightly targets | in_app | Review sleep need |
| SR037 | Full fourteen-night view becomes available | digest | Review two weeks |
| SR038 | Corrected exact-day need changes the ledger | in_app | Review recalculation |
| SR039 | Corrected sleep record changes estimated balance | in_app | Review updated ledger |
| SR040 | Shortfall meets a constrained plan | in_app | Review feasible timing |

### SLP05: Caffeine timing goals

Follow an explicitly chosen caffeine cutoff without pretending to measure clearance.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| SR041 | Upcoming selected cutoff | local_notification | Review caffeine goal |
| SR042 | Selected cutoff arrives | local_notification | Open caffeine goal |
| SR043 | Earlier bedtime moves the modeled cutoff | in_app | Confirm cutoff goal |
| SR044 | Later bedtime creates an optional goal change | in_app | Review saved cutoff |
| SR045 | Dose-unknown intake after the selected cutoff | in_app | Review caffeine entry |
| SR046 | Known late intake in a bedtime review | in_app | Review model details |
| SR047 | Several known intakes contribute to the estimate | in_app | Review contributions |
| SR048 | Imported caffeine entry conflicts with the manual log | in_app | Review matching entries |
| SR049 | After-midnight intake belongs to a later sleep plan | in_app | Confirm sleep plan |
| SR050 | Weekly review of logged timing choices | digest | Review caffeine week |

### SLP06: Planned naps

Carry out or review a nap the user deliberately scheduled.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| SR051 | Planned nap start reminder | local_notification | Open nap plan |
| SR052 | User-requested nap duration ends | local_notification | Review nap |
| SR053 | Nap plan overlaps the selected bedtime | in_app | Review overlapping plans |
| SR054 | Nap reminder follows a user time change | in_app | Review nap time |
| SR055 | Late start shortens the saved nap interval | in_app | Choose nap end |
| SR056 | Recorded nap ready for plan matching | in_app | Review recorded nap |
| SR057 | Requested nap ended without a matching record | in_app | Review nap record |
| SR058 | Nap timer permission setup failed | in_app | Review timer access |
| SR059 | User-defined quiet nap interval | in_app | Review nap quiet time |
| SR060 | Weekly planned-nap review | digest | Review nap timing |

### SLP07: Sleep schedule consistency

Understand repeat timing patterns and choose whether to adjust the schedule.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| SR061 | Repeated later bedtimes against a chosen plan | digest | Review bedtime target |
| SR062 | Repeated earlier wakes than the chosen plan | digest | Review wake timing |
| SR063 | Variable bedtime with a stable wake | digest | Review preparation time |
| SR064 | Stable bedtime with variable wake | digest | Review wake overrides |
| SR065 | Different timing on two saved schedule patterns | digest | Compare schedule groups |
| SR066 | Gradual timing drift over five nights | digest | Review current schedule |
| SR067 | Chosen timing met on most recorded nights | digest | Review the week |
| SR068 | Steadier timing after an intentional schedule edit | digest | Compare schedule periods |
| SR069 | Recorded routine differs from an old saved schedule | local_notification | Review saved wake |
| SR070 | A new stable timezone block is ready to review | in_app | Review current-zone nights |

### SLP08: Circadian schedule plans

Follow an explicitly chosen schedule-shift plan with transparent estimated timing.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| SR071 | Chosen daylight window begins | local_notification | Open daylight plan |
| SR072 | Chosen dimming window begins | local_notification | Review evening step |
| SR073 | Next gradual earlier-schedule step | local_notification | Review next plan day |
| SR074 | Next gradual later-schedule step | in_app | Review later step |
| SR075 | Confirmed arrival uses destination clock | in_app | Review destination plan |
| SR076 | Predeparture step chosen by the user | local_notification | Open today's plan |
| SR077 | User skips a step and asks for a revised plan | in_app | Review revised plan |
| SR078 | Low-confidence phase estimate with a chosen schedule | in_app | Review estimate limits |
| SR079 | Accepted schedule plan reaches its final day | in_app | Choose ongoing schedule |
| SR080 | Same-day edit changes the next remaining step | in_app | Review remaining steps |

### SLP09: Completed sleep recap

See the finalized night and the one most useful next action.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| SR081 | Complete current-night recap | local_notification | View night summary |
| SR082 | Sleep result available while recovery is unavailable | local_notification | Review sleep summary |
| SR083 | Duration-only recap without stages | local_notification | View sleep record |
| SR084 | Recap below the exact-night need estimate | local_notification | Review night and plan |
| SR085 | Longer recorded night than the recent median | local_notification | Review the longer night |
| SR086 | Recorded wake differs from the saved wake | local_notification | Review recorded wake |
| SR087 | Same-day recap after delayed sync | local_notification | View synced night |
| SR088 | Main night contains distinct sleep periods | local_notification | Review sleep periods |
| SR089 | First final night after a capture gap | local_notification | View the new record |
| SR090 | Corrected recap after user-reviewed boundary change | in_app | View revised summary |

### SLP10: Sleep duration review

Notice meaningful duration changes without judging or prescribing more sleep.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| SR091 | Single short night with a feasible next opportunity | local_notification | Review tonight's plan |
| SR092 | Three consecutive short recorded nights | local_notification | Review recent duration |
| SR093 | First target-length night after a short run | digest | Review that night |
| SR094 | Exact-night need met across most of the week | digest | Review the week |
| SR095 | Two-week median duration increases | digest | Compare the two weeks |
| SR096 | Two-week median duration decreases with unchanged wake | digest | Review bedtime opportunity |
| SR097 | Longer-than-usual duration merits boundary review | in_app | Check sleep boundaries |
| SR098 | Duration differs between main sleep and added nap | in_app | Review sleep episodes |
| SR099 | Shorter night ends earlier without later bedtime | in_app | Review wake and context |
| SR100 | Longer opportunity did not become longer recorded sleep | in_app | Review plan and record |

### SLP11: Sleep continuity review

Review recorded awakenings and efficiency without claiming a sleep disorder.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| SR101 | Lower efficiency despite target duration | in_app | Review sleep timeline |
| SR102 | Repeated lower-efficiency nights | in_app | Review three timelines |
| SR103 | More recorded awakenings than usual | in_app | View interruptions |
| SR104 | One long recorded awake interval | in_app | Inspect awake interval |
| SR105 | Many short recorded awake intervals | in_app | Review interval pattern |
| SR106 | Boundary edit changes efficiency | in_app | View revised timeline |
| SR107 | High recorded efficiency on a short night | in_app | Review duration and timing |
| SR108 | Long recorded window with lower efficiency | in_app | Review boundaries |
| SR109 | Continuity moves toward the prior pattern | in_app | Compare recent nights |
| SR110 | User asks whether a changed source can be compared | in_app | Review source groups |

### SLP12: Estimated restorative sleep trends

Explore stage estimates and their uncertainty as a lower-priority summary.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| SR111 | Weekly deep-sleep estimate lower with stable duration | in_app | Review stage estimates |
| SR112 | Weekly REM estimate changes with shorter nights | in_app | Compare full sleep windows |
| SR113 | More stage minutes mainly reflect a longer night | in_app | Review minutes and share |
| SR114 | Higher stage share on a shorter night | in_app | Compare stage amounts |
| SR115 | Stage estimates become available after sparse captures | in_app | Open the stage view |
| SR116 | Sleep edit materially changes stage totals | in_app | Review revised stages |
| SR117 | Algorithm update introduces a different stage estimate | in_app | Review calculation change |
| SR118 | Two valid sources disagree on stage distribution | in_app | Compare source timelines |
| SR119 | Week-to-week stage estimate is stable | digest | Review the full pattern |
| SR120 | Restorative-stage share falls below confidence gate | in_app | Review capture details |

### SLP13: Sleep record review

Correct an ambiguous or revised sleep record before relying on it.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| SR121 | Late data moves the sleep boundary | local_notification | Review updated timing |
| SR122 | Overlapping source records need a preference | in_app | Review sleep sources |
| SR123 | New recorded blocks change the selected main night | in_app | Review selected periods |
| SR124 | User edit preserved after a later import | in_app | Compare with new data |
| SR125 | Sleep record overlaps a logged active workout | local_notification | Review overlapping records |
| SR126 | HR-only sleep estimate needs context | in_app | Review estimate coverage |
| SR127 | Changing the preferred source updates today summary | in_app | Review selected source |
| SR128 | Duplicate episode removed and totals corrected | in_app | View corrected total |
| SR129 | Undo restores a deleted sleep episode | in_app | Review restored record |
| SR130 | User removes a mistaken sleep record | in_app | Review updated day |

### REC01: Morning recovery and readiness

Choose an appropriate day plan using multiple current signals.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| SR131 | Primed signals and adequate recorded sleep | local_notification | Review today's plan |
| SR132 | Balanced current readiness | local_notification | View recovery summary |
| SR133 | Strained read driven by HRV | local_notification | Review HRV context |
| SR134 | Strained read driven mainly by recent load | local_notification | Review recent load |
| SR135 | Several current signals contribute to rundown | local_notification | Review today's readings |
| SR136 | Favorable recovery with short recorded sleep | local_notification | Review the mixed picture |
| SR137 | Lower recovery despite target-length sleep | local_notification | Open recovery breakdown |
| SR138 | Current signals point in different directions | in_app | Review mixed signals |
| SR139 | First usable readiness read is still building | in_app | Review baseline coverage |
| SR140 | Current vitals available without a recovery score | in_app | View available readings |

### REC02: Recovery trend and rebound

Notice sustained changes against a personal baseline and review the context.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| SR141 | Three consecutive downward recovery changes | local_notification | Review recovery trend |
| SR142 | Three upward readings after a lower period | digest | Review the upward trend |
| SR143 | Return to the personal recovery range | digest | Review the current breakdown |
| SR144 | Weekly median recovery is lower | digest | Compare recovery weeks |
| SR145 | Weekly median recovery is higher | digest | Compare recorded context |
| SR146 | Recovery variability increases while median is stable | digest | Review day-by-day recovery |
| SR147 | HRV trend changes while recovery stays similar | in_app | Review HRV component |
| SR148 | Resting heart rate normalizes before the aggregate score | in_app | Review remaining contributors |
| SR149 | Trend available again after a data interruption | in_app | View the new comparison |
| SR150 | Stable recovery trend across two weeks | digest | Review the two-week view |

### REC03: Personal vital observations

Review current multi-signal deviations and optional context without diagnosing illness.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| SR151 | Lower HRV and higher resting HR contribute together | in_app | Review personal ranges |
| SR152 | Temperature deviation contributes to a multi-signal result | in_app | Review temperature source |
| SR153 | Respiration contributes to a multi-signal result | in_app | Review overnight readings |
| SR154 | Mild descriptive observation | in_app | View the measurements |
| SR155 | Logged alcohol context changes interpretation | in_app | Review journal context |
| SR156 | Explicit workout journal context accompanies the reading | in_app | Review workout entry |
| SR157 | User has already logged feeling unwell | in_app | Review your entry |
| SR158 | Current readings return toward the prior range | in_app | Review the current readings |
| SR159 | User adds context after reviewing an observation | in_app | Review updated context |
| SR160 | New valid measurement completes the current observation | in_app | View the fuller record |

### REC04: Training and recovery balance

Review recent load alongside current sleep and recovery before choosing today effort.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| SR161 | Lower recovery with elevated recent load | local_notification | Review today's options |
| SR162 | Favorable recovery does not erase accumulated load | local_notification | Review load and recovery |
| SR163 | Lower recovery with ordinary recent load | in_app | Review overnight contributors |
| SR164 | Recorded effort rises while sleep duration falls | digest | Compare sleep and load |
| SR165 | Load monotony rather than total load is flagged | digest | Review daily distribution |
| SR166 | Measured lower-load days with improving current recovery | in_app | Review a gradual return |
| SR167 | Current recovery remains available across a load-history gap | in_app | Review available recovery |
| SR168 | Evening review keeps morning recovery beside completed work | in_app | Review the day in context |
| SR169 | Later workout leaves a shorter chosen sleep opportunity | in_app | Review remaining evening |
| SR170 | Current high load with a known incomplete recovery picture | in_app | Review available context |

### REC05: Recovery planning estimates

Explore an uncertain tomorrow estimate when the user asks for a planning comparison.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| SR171 | Baseline planning estimate for a confirmed opportunity | in_app | Review estimate inputs |
| SR172 | User compares a longer sleep opportunity | in_app | Compare plan inputs |
| SR173 | User compares a shorter unavoidable opportunity | in_app | Review scenario assumptions |
| SR174 | Higher current effort explains a forecast adjustment | in_app | Review effort input |
| SR175 | Lower current effort explains a forecast adjustment | in_app | Review the model input |
| SR176 | Thin baseline produces a wider tentative estimate | in_app | Review history coverage |
| SR177 | Variable baseline yields a broad model band | in_app | Review uncertainty |
| SR178 | User explores a hypothetical sleep-need assumption | in_app | Review scenario assumption |
| SR179 | Displayed range touches a score boundary | in_app | Review scale limits |
| SR180 | New committed data changes an open planning estimate | in_app | Review changed inputs |

### WT01: Saved workout recap

Review the useful facts of a newly saved workout without opening several screens.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| WT001 | First scored workout saved | local_notification | Review workout |
| WT002 | Route workout with final distance | local_notification | View route |
| WT003 | Session dominated by one recorded zone | local_notification | Review zones |
| WT004 | Paused workout time explained | local_notification | Review timing |
| WT005 | Imported workout with original score | local_notification | Review imported result |
| WT006 | Two sources reconciled into one session | local_notification | Review combined record |
| WT007 | Final score arrived after a delayed save | local_notification | Open completed recap |
| WT008 | Distance-only session recap | local_notification | Review recorded facts |
| WT009 | Strength session linked to its HR record | local_notification | Review strength workout |
| WT010 | Requested recap after a manual correction | in_app | Review correction |

### WT02: Workout comparison review

Put a session beside comparable saved evidence without treating a difference as a fitness verdict.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| WT011 | Higher Strain with a longer session | local_notification | Compare session |
| WT012 | Higher Strain at a similar duration | local_notification | Review intensity |
| WT013 | Lower Strain after an intentionally shorter session | local_notification | Compare duration |
| WT014 | Same duration with more recorded distance | local_notification | Compare routes |
| WT015 | Pause pattern changed the wall-clock comparison | local_notification | Review pauses |
| WT016 | Baseline becomes useful after several sessions | local_notification | View comparison |
| WT017 | A dated comparison after a long recording gap | local_notification | View dated comparison |
| WT018 | Changed zones require a different reading | in_app | Review comparison basis |
| WT019 | Imported score shown beside local history | in_app | Review source details |
| WT020 | Manual edit changes a comparison | in_app | Review revised comparison |

### WT03: Saved Lift schedule reminders

Remember a personally scheduled routine and decide whether to open it.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| WT021 | Chosen routine time approaching | local_notification | Open planned routine |
| WT022 | Date-only Coach plan at chosen reminder time | local_notification | Review today's plan |
| WT023 | First scheduled use of a new routine | local_notification | Preview new routine |
| WT024 | Reminder after the person reschedules | local_notification | Open updated schedule |
| WT025 | Two routines saved for one day | local_notification | Review the day |
| WT026 | Next routine after an early completion | local_notification | Review remaining routine |
| WT027 | Weekend schedule with different chosen time | local_notification | Open weekend plan |
| WT028 | User requested an evening check of tomorrow | local_notification | Review tomorrow |
| WT029 | User snoozed one reminder to a precise time | local_notification | Review routine |
| WT030 | Reminders resumed for an existing schedule | local_notification | Open next routine |

### WT04: Routine preparation review

Review a meaningful change or missing context before starting a saved routine.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| WT031 | Exercise list changed since last use | local_notification | Review exercises |
| WT032 | Rep targets changed since last use | local_notification | Review targets |
| WT033 | Rest plan changed | local_notification | Review rest plan |
| WT034 | Working-set targets added | local_notification | Review set targets |
| WT035 | New exercise has no personal set history | local_notification | Review new exercise |
| WT036 | Reviewed Coach plan ready for first use | local_notification | Review saved plan |
| WT037 | Routine has only old working-load references | local_notification | Review reference sets |
| WT038 | Routine changed training mode | local_notification | Review routine setup |
| WT039 | Upcoming routine has incomplete catalog mapping | local_notification | Review routine entry |
| WT040 | Preview records a deliberate last-minute revision | in_app | Review updated preview |

### WT05: Strength session receipt

Confirm what was logged and choose the next review step after lifting.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| WT041 | Routine targets completed | local_notification | Open receipt |
| WT042 | Session ended before every saved target | local_notification | Review logged session |
| WT043 | Free-form strength session saved | local_notification | Review free-form session |
| WT044 | Warm-ups and working sets separated | local_notification | Review set breakdown |
| WT045 | Explicit effort ratings included | local_notification | Review effort notes |
| WT046 | Bodyweight work recorded without load volume | local_notification | Review reps |
| WT047 | Session linked to its scheduled routine | local_notification | View completed routine |
| WT048 | A restored session reaches durable completion | local_notification | Review resumed session |
| WT049 | Receipt has useful notes on changed exercises | local_notification | Review session notes |
| WT050 | Correction to a saved set is reflected | in_app | Review corrected receipt |

### WT06: Strength record review

Recognize a supported record and let the person inspect the exact set behind it.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| WT051 | Estimated strength record from heavier work | local_notification | Review record set |
| WT052 | Estimated record from more reps at the same load | local_notification | Review rep progression |
| WT053 | Repetition record without an estimated-max record | local_notification | Review rep record |
| WT054 | Bodyweight repetition record | local_notification | View bodyweight record |
| WT055 | Several exercises set records in one session | local_notification | Review session records |
| WT056 | Later set supersedes an earlier session record | local_notification | View final record |
| WT057 | Record after an extended gap in this exercise log | local_notification | Review dated record |
| WT058 | First record after a baseline session | local_notification | View first record |
| WT059 | Weekly grouped records for digest-only preference | digest | Review weekly records |
| WT060 | Edited record receives an updated explanation | in_app | Review updated record |

### WT07: Exercise progression review

Use a sequence of logged sets to review a routine without prescribing automatic weight increases.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| WT061 | Repeatedly reaches the saved rep target | local_notification | Review progression |
| WT062 | More reps while explicitly rated effort stays similar | local_notification | Review reps and effort |
| WT063 | Targets repeatedly exceeded by choice | local_notification | Review saved target |
| WT064 | Repeatedly chooses fewer working sets | local_notification | Review set plan |
| WT065 | Explicit effort rose at unchanged work | local_notification | Review effort trend |
| WT066 | Load changed and reps fell as planned | local_notification | Review revised progression |
| WT067 | Exercise substitution starts a new reference | local_notification | Review new reference |
| WT068 | Several metrics move in different directions | digest | Review exercise trends |
| WT069 | Stable work across repeated recorded exposures | digest | Review current setup |
| WT070 | User requests review after correcting past sets | in_app | Review updated trend |

### WT08: Muscle set distribution review

See where logged working sets went and review the routine without treating reference bands as compulsory targets.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| WT071 | Direct and assisting sets differ materially | in_app | Review set credit |
| WT072 | One group dominates the logged week | in_app | Review exercise mix |
| WT073 | Saved split covered across different days | digest | Review weekly split |
| WT074 | One scheduled focus was not recorded | in_app | Review schedule links |
| WT075 | Substitution changed the credited muscle mix | in_app | Review substitution |
| WT076 | Same focus recorded on consecutive days | in_app | Review session spacing |
| WT077 | Weekly direct sets rose with more sessions | digest | Review weekly change |
| WT078 | Unmapped exercises limit the muscle chart | in_app | Review chart coverage |
| WT079 | Warm-up-heavy week and working-set bars | in_app | Review set definitions |
| WT080 | Reference band explained on first visit | in_app | Review the chart guide |

### WT09: Strength Strain explanation

Explain a session's score and its limits when logged lifting changes the cardiovascular-only picture.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| WT081 | First session with a settled muscular contribution | in_app | Review score breakdown |
| WT082 | Sets add context to a modest HR score | in_app | View both contributions |
| WT083 | Day floor already exceeds the combined activity part | in_app | Review daily components |
| WT084 | Model effort defaults are distinguished from ratings | in_app | Review effort inputs |
| WT085 | Bodyweight fallback used in the calculation | in_app | Review calculation inputs |
| WT086 | Bodyweight exercises have modeled effective mass | in_app | Review bodyweight contribution |
| WT087 | Warm-ups remain recorded but do not count as work | in_app | Review counted sets |
| WT088 | Unsupported held work is explained | in_app | Review score coverage |
| WT089 | Unknown muscle mapping used a documented fallback | in_app | Review mapped inputs |
| WT090 | Set edit changes the settled current-day score | in_app | Review updated components |

### WT10: Weekly workout review

Review a week's recorded activity, decide what to keep, and see gaps honestly.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| WT091 | First closed week with several recorded sessions | local_notification | Review your week |
| WT092 | More frequent but shorter recorded sessions | local_notification | Review session pattern |
| WT093 | Fewer but longer recorded sessions | local_notification | Review time distribution |
| WT094 | Saved routine week has linked completions | local_notification | Review completed plan |
| WT095 | Unlinked completed sessions and saved schedule | local_notification | Review schedule matches |
| WT096 | Mixed sources in one weekly review | local_notification | Review sources in the week |
| WT097 | A week of strength with sparse HR coverage | local_notification | Review strength week |
| WT098 | Varied recorded activity week | local_notification | Review activity mix |
| WT099 | Weekly review with explicit coverage gaps | local_notification | Review available week |
| WT100 | First recorded week after a chosen return | local_notification | Review return week |

### WT11: Workload ratio transition

Notice a material change in the existing load model and review recent training choices.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| WT101 | Holding moves into building | local_notification | Review workload change |
| WT102 | Building moves into the high ratio band | local_notification | Review recent load |
| WT103 | High ratio returns to building | local_notification | Review the load trend |
| WT104 | Holding moves into easing | local_notification | Review the quieter period |
| WT105 | Easing returns to holding | local_notification | Review the return in load |
| WT106 | Near-high zone persists before a saved session | local_notification | Review load and plan |
| WT107 | Observed rest days alter both horizons | local_notification | Review modeled change |
| WT108 | Available model contains a tolerated gap | in_app | Review model coverage |
| WT109 | Model reaches the existing building gate | local_notification | Explore training load |
| WT110 | Model reaches established history | local_notification | Review established history |

### WT12: Longer-term load trend

Review how recorded recent load and the longer baseline are changing over weeks.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| WT111 | Recent load rose faster than the longer baseline | local_notification | Review recent drivers |
| WT112 | Longer baseline rose with stable recent load | local_notification | Review longer trend |
| WT113 | Both model lines moved down through a chosen break | local_notification | Review the quieter weeks |
| WT114 | Weekly mean changed with more training days | local_notification | Review four-week pattern |
| WT115 | Weekly mean changed without more training days | local_notification | Review load drivers |
| WT116 | Recorded non-workout days contribute appreciably | local_notification | Review daily load |
| WT117 | One session is the week's strongest scored driver | local_notification | Review the leading session |
| WT118 | Stable four-week recorded pattern | local_notification | Review steady pattern |
| WT119 | Model rebuilt after a longer data gap | in_app | Review model history |
| WT120 | Selected weekly review after a source repair | in_app | Review repaired trend |

### WT13: Tomorrow load scenarios

Open the existing what-if model before choosing tomorrow's activity, without treating it as a prescription.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| WT121 | Rest scenario remains in the high ratio band | local_notification | Explore Tomorrow |
| WT122 | Rest and moderate scenarios land in different bands | local_notification | Compare tomorrow's options |
| WT123 | Moderate example stays in the current band | local_notification | Review scenario assumptions |
| WT124 | Higher-load illustration reaches the high band | local_notification | Compare the example days |
| WT125 | All three examples stay in one band | local_notification | Review the scenario values |
| WT126 | Building history labels the scenarios honestly | local_notification | Explore with history context |
| WT127 | Tomorrow includes a saved strength routine | local_notification | Review plan and examples |
| WT128 | Late final session changes the evening examples | local_notification | Review updated examples |
| WT129 | Person explicitly compares a scenario on screen | in_app | Review this example |
| WT130 | Weekly review opens the next-day options | digest | Review tomorrow's options |

### WT14: Active workout continuity

Keep an intentionally running or restored session understandable without interrupting exercise with routine pushes.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| WT131 | Active cardio session restored on launch | in_app | Open active workout |
| WT132 | Active Lift session restored | in_app | Open active lift |
| WT133 | Paused session remains paused after return | in_app | Review paused workout |
| WT134 | Live HR becomes unavailable while screen is open | in_app | Review active recording |
| WT135 | Fresh HR returns to the active record | in_app | View active trace |
| WT136 | GPS checkpoint restored for an outdoor workout | in_app | Review active route |
| WT137 | Start request meets an existing active session | in_app | Open current session |
| WT138 | Set target reached in the active routine | in_app | Review next exercise |
| WT139 | Rest interval ends while the Lift screen is visible | in_app | Return to your sets |
| WT140 | Workout reopened from its Live Activity | in_app | Review active session |

### WT15: Return to a saved routine

Help someone returning after a recording gap review their previous routine and choose a manageable restart.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| WT141 | Return scheduled with an old routine reference | local_notification | Review previous session |
| WT142 | New routine chosen for the return | local_notification | Preview return routine |
| WT143 | Old schedule entries remain when returning | local_notification | Review old schedule entries |
| WT144 | Person chose a shorter return session | local_notification | Review current return plan |
| WT145 | Return shifts from loaded to bodyweight exercises | local_notification | Review bodyweight plan |
| WT146 | First return session supplies a fresh reference | local_notification | Review fresh reference |
| WT147 | Return session includes explicit effort notes | local_notification | Review return effort notes |
| WT148 | A first return week contains one chosen session | digest | Review your chosen week |
| WT149 | An old unfinished session is discovered on return | in_app | Review unfinished session |
| WT150 | Return review distinguishes a repaired gap | in_app | Review updated history |

### WT16: Aerobic and anaerobic load review

Review a future validated component trend alongside Tomorrow when the underlying data becomes available.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| WT151 | First fully supported component week | local_notification | Review component definitions |
| WT152 | Aerobic component rises with longer eligible sessions | local_notification | Review aerobic drivers |
| WT153 | Anaerobic estimate concentrated in one supported session | local_notification | Review component session |
| WT154 | Similar total with a different component mix | local_notification | Compare component mix |
| WT155 | Strength contribution kept distinct from the future split | in_app | Review contribution meanings |
| WT156 | Future aerobic trend and Tomorrow reviewed together | local_notification | Review Tomorrow and trend |
| WT157 | Short sessions alter the anaerobic component trend | local_notification | Review shorter-session mix |
| WT158 | Only one component has enough coverage | in_app | Review component coverage |
| WT159 | User-selected component pattern differs from the log | local_notification | Review chosen pattern |
| WT160 | Model revision changes a viewed historical split | in_app | Review model change |

### WT17: Explicit training commitments

Remind someone about a commitment they deliberately recorded, with a direct way to review it.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| WT161 | Chosen weekly session commitment has a planned opening | local_notification | Review commitment |
| WT162 | User selected a duration goal for a personal HR zone | local_notification | Review chosen zone goal |
| WT163 | A flexible commitment offers two chosen dates | local_notification | Review date options |
| WT164 | Exercise-practice commitment uses recorded technique notes | local_notification | Review practice plan |
| WT165 | User chose a quieter day in the plan | local_notification | Review today's plan |
| WT166 | Equipment preparation checklist requested | local_notification | Review preparation list |
| WT167 | User asks for a post-session effort reflection | local_notification | Open session reflection |
| WT168 | User-selected weekly plan review | local_notification | Review the chosen topic |
| WT169 | Time-bounded return commitment | local_notification | Review return commitment |
| WT170 | Commitment review explicitly requests weekly evidence | digest | Review commitment evidence |

### WT18: Daily Strain target reached

Notice a first supported crossing of the existing daily target and review the rest of the day without being told to stop or add exercise.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| WT171 | First target crossing after a completed cardio session | local_notification | Review today's Strain |
| WT172 | First crossing after Strength settlement | local_notification | Review combined daily load |
| WT173 | Range reached before a later saved routine | local_notification | Review day and routine |
| WT174 | A fresh result passes the whole target range | local_notification | Review the day |
| WT175 | Lower recovery-derived range reached | local_notification | Review today's context |
| WT176 | First final Recovery makes the target available | local_notification | Review the new range |
| WT177 | Corrected Recovery changes the visible range | in_app | Review the revised range |
| WT178 | Range reached while the person is recording | in_app | Review active workout |
| WT179 | User-selected evening review includes the crossing | digest | Review the recorded day |
| WT180 | Requested current-day edit creates a new explanation | in_app | Review edited day |

### HC01: Selected journal check-ins

Help people capture their chosen behaviors at a time they requested.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| HC001 | Morning review of yesterday | local_notification | Open yesterday |
| HC002 | Same-day evening check-in | local_notification | Open journal |
| HC003 | One selected question | local_notification | Answer question |
| HC004 | Resume a partial entry by request | local_notification | Continue entry |
| HC005 | Numeric observation requested later | local_notification | Record value |
| HC006 | Check-in after selecting a shorter set | local_notification | Open check-in |
| HC007 | First custom question check-in | local_notification | Answer new question |
| HC008 | Requested correction review | local_notification | Review answer |
| HC009 | Restart after an explicit pause | local_notification | Open journal |
| HC010 | Weekend catch-up selected by user | local_notification | Review selected days |

### HC02: Chosen hydration check-ins

Offer the hydration reminders the user chose without inferring dehydration.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| HC011 | Start-of-day water routine | local_notification | Open hydration |
| HC012 | Midday logging check-in | local_notification | Review water log |
| HC013 | Bottle preparation cue | local_notification | Open water routine |
| HC014 | Refill reminder after explicit request | local_notification | Open hydration |
| HC015 | End-of-day log review | local_notification | Review water log |
| HC016 | Portable-container routine | local_notification | Open hydration |
| HC017 | Restart a paused water routine | local_notification | Review reminders |
| HC018 | Requested follow-up after dismissal | local_notification | Open hydration |
| HC019 | Goal review appointment | local_notification | Review water goal |
| HC020 | Check-in schedule review | local_notification | Edit check-ins |

### HC03: Hydration log reviews

Make logged progress and corrections clear without estimating actual hydration status.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| HC021 | Accepted goal first reached | local_notification | Review water log |
| HC022 | First daily water-log review | local_notification | Review entries |
| HC023 | Weekly review with varied totals | digest | Review water history |
| HC024 | Daily review below goal | local_notification | Review water log |
| HC025 | Correction changed the daily total | local_notification | Review correction |
| HC026 | Older day backfilled by request | local_notification | Review saved day |
| HC027 | Logged volume above chosen goal | digest | Review entries |
| HC028 | Custom container correction completed | local_notification | Review edited entries |
| HC029 | Month-end logging pattern | digest | Review routine |
| HC030 | Accepted goal change saved | local_notification | Review water goal |

### HC04: Chosen movement breaks

Offer a comfortable break when an opted-in user has fresh evidence of a long low-movement period.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| HC031 | First break opportunity in a fresh bout | local_notification | View break options |
| HC032 | Accessible seated break selected | local_notification | View seated options |
| HC033 | Standing option selected | local_notification | View break options |
| HC034 | Break at a user-selected boundary | local_notification | View break options |
| HC035 | Return from an explicit pause | local_notification | View break options |
| HC036 | Fresh bout after a completed break | local_notification | View break options |
| HC037 | User asked for a later break | local_notification | View break options |
| HC038 | Same-day movement review requested | digest | Review break windows |
| HC039 | Weekly low-movement pattern review | digest | Review break settings |
| HC040 | Chosen break schedule review | digest | Edit break settings |

### HC05: User-created habit routines

Remind people of their own nonmedical routine commitments and let them revise the plan.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| HC041 | Start a newly chosen routine | local_notification | Open routine |
| HC042 | Prepare for a chosen routine | local_notification | View preparation |
| HC043 | Single selected return reminder | local_notification | Open routine |
| HC044 | Resume on a saved restart date | local_notification | Review routine |
| HC045 | Weekday-specific routine | local_notification | Open routine |
| HC046 | Routine end-date review | local_notification | Review routine |
| HC047 | Requested simplified routine | local_notification | View revised routine |
| HC048 | Routine review after repeated skips | local_notification | Review routine |
| HC049 | User-set location-free transition cue | local_notification | Open routine note |
| HC050 | Time-zone change review | in_app | Review routine times |

### HC06: Journal association reviews

Offer cautious reviews of explicit behavior answers with transparent group sizes and no causal claim.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| HC051 | First comparison becomes available | local_notification | View comparison |
| HC052 | No clear average separation | local_notification | View group details |
| HC053 | Higher average on explicit yes days | local_notification | Review evidence |
| HC054 | Lower average on explicit yes days | local_notification | Review evidence |
| HC055 | Direction changed in a fresh window | local_notification | Compare periods |
| HC056 | One group dominates the comparison | digest | View group sizes |
| HC057 | Updated by explicit correction | local_notification | Review corrected comparison |
| HC058 | Enough new observations for a review | local_notification | View updated comparison |
| HC059 | Behavior labels remain joined after rename | digest | Review item history |
| HC060 | Selected comparison has mixed known contexts | digest | View context |

### HC07: Planned breathing practice

Support a breathing practice the user chose without inferring their emotional state.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| HC061 | Brief practice at chosen start time | local_notification | Open breathing |
| HC062 | Before a manually entered event | local_notification | Open breathing |
| HC063 | After a manually entered event | local_notification | Open breathing |
| HC064 | Midday practice by schedule | local_notification | Choose a practice |
| HC065 | Saved pace practice | local_notification | Review saved pace |
| HC066 | Short option selected for a busy period | local_notification | Open shorter practice |
| HC067 | One requested later reminder | local_notification | Open breathing |
| HC068 | Resume after a chosen break | local_notification | Review practice |
| HC069 | Practice plan review appointment | local_notification | Review routine |
| HC070 | Self-check before choosing a practice | local_notification | Open check-in |

### HC08: Opt-in physiological check-ins

Offer a cautious check-in from an existing live HRV-dip detector with user-controlled next steps.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| HC071 | First eligible check-in | local_notification | Open check-in |
| HC072 | Current-day explicit stress report | local_notification | Open breathing |
| HC073 | Current-day explicit calm report | local_notification | Compare your check-in |
| HC074 | User prefers recording context | local_notification | Record context |
| HC075 | User prefers viewing the measured signal | local_notification | View signal |
| HC076 | Saved comfortable pace preferred | local_notification | Review breathing pace |
| HC077 | App already showing the current signal | in_app | Inspect window |
| HC078 | Journal currently open | in_app | Review observation |
| HC079 | First check-in after source calibration | in_app | Review current signal |
| HC080 | User opens an unhandled recent event | in_app | View check-in |

### HC09: Stress and context reflections

Support later reflection on covered physiological observations and explicit self-reports.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| HC081 | Evening reflection with a self-report | local_notification | Review your day |
| HC082 | Physiological episodes without a self-report | local_notification | Record your context |
| HC083 | Self-report without a detected episode | local_notification | Review self-report |
| HC084 | Activity context available | digest | View context |
| HC085 | User-requested before-and-after practice review | local_notification | Review practice |
| HC086 | Signals and self-report diverged | local_notification | Review the interval |
| HC087 | Repeated time-of-day pattern | digest | Review timing |
| HC088 | Different weekly pattern | digest | Compare weeks |
| HC089 | No repeated pattern in the selected week | digest | Review the week |
| HC090 | User-selected reflection interval finished | local_notification | Open selected review |

### HC10: Requested coaching follow-ups

Return to a question only when the user asked for follow-up and the required evidence is available.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| HC091 | Journal question now has both groups | local_notification | Revisit question |
| HC092 | Requested hydration history available | local_notification | Open saved question |
| HC093 | Requested source explanation ready | local_notification | Review source question |
| HC094 | New custom question history joined | local_notification | Review saved question |
| HC095 | Requested bounded trend interval ended | local_notification | Open trend question |
| HC096 | Requested correction changed the evidence | local_notification | Review updated evidence |
| HC097 | Saved question at chosen time | local_notification | Open saved question |
| HC098 | Coach consent restored by the user | local_notification | Open follow-up |
| HC099 | One requested multi-topic review completed | local_notification | Open combined review |
| HC100 | Follow-up evidence expired before opening | in_app | Open updated view |

### HC11: Explicit coaching commitments

Keep user-approved coaching commitments visible and easy to revise without letting AI create obligations.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| HC101 | First approved commitment | local_notification | Review commitment |
| HC102 | Preparation before a commitment | local_notification | View preparation |
| HC103 | User-requested accountability check | local_notification | Record an update |
| HC104 | Shorter alternative approved | local_notification | View revised step |
| HC105 | Single approved postponement | local_notification | Review commitment |
| HC106 | Requested end-of-trial reflection | local_notification | Review the trial |
| HC107 | Explicit success recorded | local_notification | Close the commitment |
| HC108 | Pause ending by choice | local_notification | Review commitment |
| HC109 | User-requested obstacle review | local_notification | Review options |
| HC110 | Conflicting commitment revisions | in_app | Review versions |

### HC12: Weekly habits review

Combine useful habit observations into one optional review rather than separate daily interruptions.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| HC111 | First eligible habit week | local_notification | Review your week |
| HC112 | Broad journal coverage | local_notification | Open weekly review |
| HC113 | Different logging coverage by behavior | digest | Review coverage |
| HC114 | First observations for a selected item | local_notification | Review new item |
| HC115 | Hydration and journal in one review | local_notification | Open combined review |
| HC116 | Selected shorter review set | digest | Review routine |
| HC117 | Explicit skips recorded | digest | Review check-ins |
| HC118 | Stable answers across a week | digest | Review the pattern |
| HC119 | Requested comparison across two weeks | local_notification | Compare your weeks |
| HC120 | Decide what to keep tracking | digest | Review journal questions |

### HC13: Battery charge planning

Help the user charge a supported device while there is time to preserve a chosen recording.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| HC121 | Low percent without an estimate | local_notification | View device |
| HC122 | Measured runtime crosses the existing warning | local_notification | View battery estimate |
| HC123 | Rated fallback estimate | local_notification | View battery details |
| HC124 | Both warning policies fire together | local_notification | View device |
| HC125 | Armed alarm exceeds measured battery estimate | local_notification | Check device battery |
| HC126 | User-requested later charge cue | local_notification | Check current battery |
| HC127 | Low battery while device page is open | in_app | Review battery |
| HC128 | Charge state confirmed after a warning | in_app | View charge progress |
| HC129 | Fresh battery warning after recording ends | local_notification | View current battery |
| HC130 | Low off-body device viewed before reuse | in_app | Review device |

### HC14: Requested charge completion

Close a chosen charging task without repeatedly announcing every percent change.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| HC131 | Device first reports full | local_notification | View device |
| HC132 | Chosen partial target reached | local_notification | Review charge target |
| HC133 | Chosen estimated runtime reached | local_notification | Review estimate |
| HC134 | Full off-body device ready for review | local_notification | View device |
| HC135 | Full charge during active recording | in_app | View battery details |
| HC136 | Completion already visible on device page | in_app | Review battery |
| HC137 | Full reading with unknown charging flag | local_notification | Check device status |
| HC138 | Requested follow-up to an earlier low warning | local_notification | Review battery |
| HC139 | Charging summary chosen instead of an alert | digest | View current battery |
| HC140 | Requested partial top-up status | in_app | Review top-up |

### HC15: Device connection and wear help

Offer a concrete repair in the device view when an observed device state blocks the user’s task.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| HC141 | Bluetooth is turned off | in_app | Review connection |
| HC142 | Bluetooth permission is explicitly blocked | in_app | Review device access |
| HC143 | Selected device remains disconnected | in_app | Review connection |
| HC144 | Device reports off-body | in_app | Review device fit |
| HC145 | Existing re-pair guidance is active | in_app | Open pairing guide |
| HC146 | Chosen source lacks live RR support | in_app | Review source features |
| HC147 | Battery reading is no longer current | in_app | Review connection |
| HC148 | Clock recovery needs attention | in_app | Review device time |
| HC149 | Reconnect attempts paused by existing policy | in_app | Review reconnect options |
| HC150 | Intentional device change needs selection | in_app | Choose a source |

### HC16: Data freshness and sync help

Explain which observations are available and offer a grounded next step without turning gaps into health warnings.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| HC151 | Latest record belongs to an earlier day | in_app | Review data sources |
| HC152 | No Apple Health samples for the requested range | in_app | Review source settings |
| HC153 | Protected health store unavailable | in_app | Review source status |
| HC154 | Live source stopped updating | in_app | Review active source |
| HC155 | Imported history stops before today | in_app | View import coverage |
| HC156 | Raw data received while analysis continues | in_app | View processing status |
| HC157 | User-requested history work paused | in_app | Review sync progress |
| HC158 | Restored app has no active source | in_app | Choose data source |
| HC159 | Current value uses a supported fallback source | in_app | Review metric source |
| HC160 | Saved edit awaiting verified recomputation | in_app | View processing status |

### HC17: Source and record quality review

Help the user understand source, date, unit, and edit choices before comparing records.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| HC161 | Source change affects a comparison | in_app | Review sources |
| HC162 | Imported and local journal answers differ | in_app | Review journal answer |
| HC163 | Numeric journal unit changed | in_app | Review numeric item |
| HC164 | Potential repeated hydration entry | in_app | Review entries |
| HC165 | Time-zone change affects an open view | in_app | Review dated records |
| HC166 | Algorithm versions differ | in_app | Review calculation sources |
| HC167 | Display rename preserved canonical journal key | in_app | Review item history |
| HC168 | Archived source appears only in history | in_app | Review source history |
| HC169 | Future-dated record needs review | in_app | Review record date |
| HC170 | Manual edit is the active authority | in_app | Review edit provenance |

### HC18: Requested analysis completion

Notify once when a specifically requested local review is ready and still useful.

| ID | Situation | Delivery | Action |
| --- | --- | --- | --- |
| HC171 | Requested history import review complete | local_notification | Review import |
| HC172 | Requested recalculation complete | local_notification | Review recalculation |
| HC173 | Requested journal comparison complete | local_notification | Open comparison |
| HC174 | Requested source comparison complete | local_notification | Compare sources |
| HC175 | Requested hydration-history review complete | local_notification | Open water review |
| HC176 | Requested nonmedical metric trend complete | local_notification | Review selected trend |
| HC177 | Requested battery-history report complete | local_notification | Review battery history |
| HC178 | Requested local export completed | local_notification | Review local export |
| HC179 | One requested batch review complete | local_notification | Open combined result |
| HC180 | Completed result already open | in_app | Review updated result |

