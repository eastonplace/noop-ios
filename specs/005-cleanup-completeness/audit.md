# Cleanup & Completeness Audit

Baseline: `pre-cleanup` (`2fc5e5b8`)  
Parity baseline: `pre-paper-reskin`  
Runtime: iPhone 17 Pro Max, `--demo-seed`  
Evidence rule: each link must resolve to a complete stepped scroll set under `qa/<screen>/page-N.png`; a single top-fold image is not evidence.

## Verdict legend

- Paper: `PASS`, `PARTIAL`, `FAIL`, or `N/A` for invisible behavior-only tools.
- Duplication: `NONE`, `STACKED`, `SUSPECT`, or `N/A`.
- Tap-through: `PASS`, `DEAD`, `MISROUTE`, `CRASH`, `BLOCKED`, or `PENDING`.
- Parity: lost/restored interaction destinations relative to `pre-paper-reskin`.

## Primary surfaces and routes

| Surface | Source / route | Full-page evidence | Paper | Duplication | Tap-through | Reachable from | Parity: lost/restored | Action needed |
|---|---|---|---|---|---|---|---|---|
| Today | `TodayView.swift` / `today` | PENDING | PENDING | PENDING | PENDING | Today tab | PENDING | Audit |
| Trends | `TrendsView.swift` / `trends` | PENDING | PENDING | SUSPECT | PENDING | Trends tab | PENDING | Audit legacy week-review builders |
| Sleep | `SleepView.swift` / `sleep` | PENDING | PENDING | PENDING | PENDING | Sleep tab | PENDING | Audit |
| More index | `RootTabView.swift` | PENDING | PENDING | PENDING | PENDING | More tab | PENDING | Audit every row/group |
| Quick Actions | `RootTabView.swift` / FAB | PENDING | PENDING | PENDING | PENDING | Centre FAB | PENDING | Audit every action |
| Recovery detail | `CoupledView.swift` / `recoverydetail` | PENDING | PENDING | PENDING | PENDING | Today Recovery | PENDING | Audit scoring-guide close path |
| Strain detail | `CoupledView.swift` / `straindetail` | PENDING | PENDING | PENDING | PENDING | Today Strain | PENDING | Audit |
| Stress detail | `StressView.swift` / `stress` | PENDING | PENDING | PENDING | PENDING | Today / More | PENDING | Audit |
| Workouts | `WorkoutsView.swift` / `workouts` | PENDING | PENDING | STACKED | PENDING | More / workout flows | PENDING | E1 full history Paper pass |
| Workout detail | `WorkoutDetailView.swift` / `workoutdetail` | PENDING | PENDING | PENDING | PENDING | Workouts rows | PENDING | Audit |
| Pre-workout | `LiveWorkoutView.swift` / `preworkout` | PENDING | PENDING | PENDING | PENDING | Start workout | PENDING | Audit |
| Live workout | `LiveWorkoutView.swift` / `liveworkout` | PENDING | PENDING | PENDING | PENDING | Pre-workout Start | PENDING | Audit controls/map/chart |
| Live console | `LiveView.swift` / `live` | PENDING | PENDING | STACKED | PENDING | More / FAB | PENDING | E2 move diagnostics to Test Centre |
| Health | `HealthView.swift` / `health` | PENDING | PENDING | PENDING | PENDING | More | PENDING | Audit all deep links |
| Insights | `InsightsView.swift` / `insights` | PENDING | PENDING | PENDING | PENDING | More | PENDING | Audit |
| Insights hub | `InsightsHubView.swift` / `insightshub` | PENDING | PENDING | PENDING | PENDING | More / Insights | PENDING | Audit |
| Intelligence | `IntelligenceView.swift` | PENDING | PENDING | PENDING | PENDING | More | PENDING | Add runtime route/evidence path if needed |
| Coach | `CoachView.swift` | PENDING | PENDING | PENDING | PENDING | More | PENDING | Audit |
| Explore catalog | `MetricExplorerView.swift` / `explore` | PENDING | PENDING | PENDING | PENDING | More | PENDING | E4/T107 alignment |
| Metric detail | `MetricExplorerView.swift` | PENDING | PARTIAL | PENDING | PENDING | Explore metric row | PENDING | T107 full alignment |
| Compare | `CompareView.swift` / `compare` | PENDING | PENDING | PENDING | PENDING | More / Explore | PENDING | Audit |
| Full-day chart / Deep Timeline | `FullDayChartView.swift` | PENDING | PENDING | PENDING | PENDING | Explore metric row | Today HR tap known lost | E6 restore Today wiring + Paper chrome |
| Lab Book | `LabBookView.swift` / `labbook` | PENDING | PENDING | PENDING | PENDING | More | PENDING | Audit |
| Marker detail | `LabBookView.swift` | PENDING | PENDING | PENDING | PENDING | Lab Book row | PENDING | Audit |
| Marker editor | `MarkerEditorView.swift` | PENDING | PENDING | PENDING | PENDING | Lab Book add/edit | PENDING | Audit save/cancel |
| Fused record | `FusedRecordView.swift` / `fused` | PENDING | PENDING | PENDING | PENDING | More / Health | PENDING | Audit |
| Conflict compare | `FusedRecordView.swift` | PENDING | PENDING | PENDING | PENDING | Fused record conflict | PENDING | Audit |
| Rhythm consent | `RhythmView.swift` / `rhythmconsent` | PENDING | PENDING | PENDING | PENDING | More / Rhythm | PENDING | Audit accept/cancel |
| Rhythm | `RhythmView.swift` / `rhythm` | PENDING | PENDING | PENDING | PENDING | More | PENDING | Audit |
| Breathing | `BreathingView.swift` | PENDING | PENDING | PENDING | PENDING | FAB / More | PENDING | Audit all modes |
| Resonance mode | `BreathingView.swift` | PENDING | PENDING | PENDING | PENDING | Breathing | PENDING | Audit |
| Calm mode | `BreathingView.swift` | PENDING | PENDING | PENDING | PENDING | Breathing | PENDING | Audit |
| Intervals | `IntervalTimerView.swift` / `intervals` | PENDING | PENDING | PENDING | PENDING | More | PENDING | Audit timer controls |
| Hydration | `HydrationView.swift` | PENDING | PENDING | PENDING | PENDING | Health | PENDING | Audit |
| Hydration amount sheet | `HydrationView.swift` | PENDING | PENDING | PENDING | PENDING | Hydration add | PENDING | Audit save/cancel |
| Weekly Digest | `WeeklyDigestView.swift` | PENDING | PENDING | PENDING | PENDING | Insights / Today | PENDING | Audit |
| Trends report | `TrendsReportView.swift` / `trendsreport` | PENDING | PENDING | PENDING | PENDING | Trends | PENDING | Audit |
| Scoring guide | `ScoringGuideView.swift` / `scoringguide` | PENDING | PENDING | PENDING | DEAD known path | Recovery detail | PENDING | T108 fix pushed close + stale copy |
| How NOOP Works | `HowNoopWorksView.swift` | PENDING | PENDING | PENDING | PENDING | Settings / guide | PENDING | Audit |

## Devices, data, settings, and support

| Surface | Source / route | Full-page evidence | Paper | Duplication | Tap-through | Reachable from | Parity: lost/restored | Action needed |
|---|---|---|---|---|---|---|---|---|
| Devices | `DevicesView.swift` / `devices` | PENDING | PENDING | PENDING | PENDING | Header / More | PENDING | Audit |
| Device catalog | `DevicesView.swift` / `devicescatalog` | PENDING | PENDING | PENDING | PENDING | Add device | PENDING | Audit |
| Add-device wizard | `AddDeviceWizard.swift` / `addwizard` | PENDING | PENDING | PENDING | PENDING | Devices Add | PENDING | Audit every step |
| Oura onboarding | `AddDeviceWizard.swift` / `ouraonboarding` | PENDING | PENDING | PENDING | PENDING | Add-device wizard | PENDING | Audit |
| Oura device | demo host / `ouradevice` | PENDING | PENDING | PENDING | PENDING | Devices | PENDING | Audit |
| Xiaomi band | `XiaomiBandView.swift` / `xiaomi` | PENDING | PENDING | PENDING | PENDING | Devices / More | PENDING | Audit |
| Apple Watch setup | `AppleWatchSetupView.swift` / `watchsetup` | PENDING | PENDING | PENDING | PENDING | Devices / Settings | PENDING | Audit |
| Apple Watch about | `AppleWatchAboutView.swift` / `watchabout` | PENDING | PENDING | PENDING | PENDING | Watch setup/settings | PENDING | Audit |
| Apple Health | `AppleHealthView.swift` / `applehealth` | PENDING | PENDING | PENDING | PENDING | Data Sources / More | PENDING | Audit |
| Data Sources | `DataSourcesView.swift` / `data` | PENDING | PENDING | PENDING | PENDING | More / Settings | PENDING | Audit |
| Backup & Sync | `BackupSyncView.swift` / `backup` | PENDING | PENDING | PENDING | PENDING | More / Settings | PENDING | Audit |
| Restore picker | `BackupSyncView.swift` | PENDING | PENDING | PENDING | PENDING | Backup & Sync | PENDING | Audit |
| Storage | `StorageView.swift` / `storage` | PENDING | PENDING | PENDING | PENDING | Settings | PENDING | Audit |
| Settings | `SettingsView.swift` / `settings` | PENDING | PENDING | PENDING | PENDING | More | PENDING | Audit every row/toggle |
| Notification settings | `NotificationSettingsView.swift` | PENDING | PENDING | PENDING | PENDING | Settings | PENDING | Audit every toggle |
| Diagnostics sheet | `SettingsView.swift` | PENDING | PENDING | PENDING | PENDING | Settings | PENDING | Audit |
| Steps calibration | `SettingsView.swift` | PENDING | PENDING | PENDING | PENDING | Settings | PENDING | Audit |
| Siri & Shortcuts | `SiriShortcutsSettingsView.swift` | PENDING | PENDING | PENDING | PENDING | More / Settings | PENDING | Audit |
| Shortcuts export | `ShortcutExportSettingsView.swift` | PENDING | PENDING | PENDING | PENDING | More / Settings | PENDING | Audit |
| Automations | `AutomationsView.swift` / `automations` | PENDING | PENDING | PENDING | PENDING | More | PENDING | Audit toggles/persistence |
| Smart alarms | `SmartAlarmView.swift` / `alarms` | PENDING | PENDING | PENDING | PENDING | More | PENDING | Audit |
| Test Centre | `TestCentreView.swift` / `testcentre` | PENDING | PENDING | PENDING | PENDING | More | PENDING | E2 destination; audit current tools |
| Test report review | `TestCentreView.swift` | PENDING | PENDING | PENDING | PENDING | Test Centre | PENDING | Audit |
| Support | `SupportView.swift` / `support` | PENDING | PENDING | PENDING | PENDING | More / Settings | PENDING | Audit all sub-screens |
| Updates inbox | `UpdatesInboxView.swift` / `updates` | PENDING | PENDING | PENDING | PENDING | Header Updates | PENDING | Audit |
| What's New | `WhatsNewView.swift` | PENDING | PENDING | PENDING | PENDING | launch / Updates | PENDING | Audit close/links |
| Dashboard cards editor | `DashboardCardsEditorSheet.swift` / `dashboardeditor` | PENDING | PENDING | PENDING | PENDING | Today Customise | PENDING | Audit persistence |
| Key metrics editor | `KeyMetricsEditorSheet.swift` / `keymetricseditor` | PENDING | PENDING | PENDING | PENDING | Today / Settings | PENDING | Audit persistence |
| Manual workout | `ManualWorkoutSheet.swift` | PENDING | PENDING | PENDING | PENDING | Workouts Add / FAB | PENDING | Audit create/cancel |
| Start workout sheet | `ManualWorkoutSheet.swift` | PENDING | PENDING | PENDING | PENDING | Manual workout | PENDING | Audit |

## Onboarding and embedded tools/cards

| Surface | Source / route | Full-page evidence | Paper | Duplication | Tap-through | Reachable from | Parity: lost/restored | Action needed |
|---|---|---|---|---|---|---|---|---|
| First-run onboarding | `OnboardingWizard.swift` | PENDING | PENDING | PENDING | PENDING | clean install | PENDING | E4/T110 full flow audit |
| Terms gate | app root / shared Terms view | PENDING | PENDING | PENDING | PENDING | clean install/version gate | PENDING | Audit accept/links |
| Journal log card | `JournalLogCard.swift` | PENDING | PENDING | N/A | PENDING | Today / FAB | PENDING | Audit |
| Caffeine log card | `CaffeineLogCard.swift` | PENDING | PENDING | N/A | PENDING | Today | PENDING | Audit |
| Stress check-in card | `StressCheckInCard.swift` | PENDING | PENDING | N/A | PENDING | Today / Stress | PENDING | Audit |
| Skin-temperature cards | `SkinTempCardsView.swift` | PENDING | PENDING | N/A | PENDING | Health / Today | PENDING | Audit all variants |
| Auto-workout card | `AutoWorkoutCard.swift` | PENDING | PENDING | N/A | PENDING | Today / Workouts | PENDING | Audit |
| Health alert banner | `HealthAlertBanner.swift` | PENDING | PENDING | N/A | PENDING | Today / Health | PENDING | Audit |
| Mind section | `MindSection.swift` | PENDING | PENDING | N/A | PENDING | Health / Insights | PENDING | Audit |
| HRV snapshot | `HRVSnapshotView.swift` | PENDING | PENDING | N/A | PENDING | Health | PENDING | Audit |
| Profile/avatar | `ProfileAvatarView.swift` | PENDING | PENDING | N/A | PENDING | Settings | PENDING | Audit |
| Biofeedback preferences | `BiofeedbackPrefs.swift` | PENDING | PENDING | N/A | PENDING | Breathing/settings | PENDING | Audit persistence |
| Biofeedback controller | `BiofeedbackController.swift` | PENDING | N/A | N/A | PENDING | Breathing | PENDING | Exercise behavior |

## Phase A generated inventories

- Empty-closure/control-site grep: PENDING (T102)
- Interaction-parity diff: PENDING (T102b)
- Reachability matrix: PENDING (T103)
- Proposed retirements: none assumed; any candidate requires gate review.
