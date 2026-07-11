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
| Today | `TodayView.swift` / `today` | [pages 1–4](qa/today/) | PASS | NONE | PASS | Today tab | 5 lost destinations; see interaction-parity.md | Restore Deep Timeline tap in T107b |
| Trends | `TrendsView.swift` / `trends` | [pages 1–4](qa/trends/) | PASS rendered path | SUSPECT source-only builders | PASS | Trends tab | No lost destination | T106 prove/delete legacy builders |
| Sleep | `SleepView.swift` / `sleep` | [pages 1–4](qa/sleep/) | PASS | NONE | PASS | Sleep tab | No lost destination | Tap-through audit |
| More index | `RootTabView.swift` | [pages 1–4](qa/more/) | PASS | NONE | PASS | More tab | No lost destination | Tap every row/group |
| Quick Actions | `RootTabView.swift` / FAB | [page 1](qa/quick-actions/page-1.png) | PASS | NONE | PASS | Centre FAB | No lost destination | Tap every action |
| Recovery detail | `CoupledView.swift` / `recoverydetail` | [pages 1–4](qa/recoverydetail/) | PASS | NONE | DEAD known guide close path | Today Recovery | No lost destination | T108 scoring-guide close |
| Strain detail | `CoupledView.swift` / `straindetail` | [pages 1–4](qa/straindetail/) | PASS | NONE | PASS | Today Strain | No lost destination | Tap-through audit |
| Stress detail | `StressView.swift` / `stress` | [pages 1–4](qa/stress/) | PASS | NONE | PASS | Today / More | No lost destination | Tap-through audit |
| Workouts | `WorkoutsView.swift` / `workouts` | [pages 1–4](qa/workouts/) | FAIL lower history | STACKED | PASS | More / workout flows | No lost destination | E1 full history Paper pass |
| Workout detail | `WorkoutDetailView.swift` / `workoutdetail` | [pages 1–4](qa/workoutdetail/) | PASS | NONE | PASS | Workouts rows | No lost destination | Tap-through audit |
| Pre-workout | `LiveWorkoutView.swift` / `preworkout` | [pages 1–4](qa/preworkout/) | PASS | NONE | PASS | Start workout | No lost destination | Tap-through audit |
| Live workout | `LiveWorkoutView.swift` / `liveworkout` | [pages 1–4](qa/liveworkout/) | PASS | NONE | PASS | Pre-workout Start | No lost destination | Audit controls/map/chart |
| Live console | `LiveView.swift` / `live` | [pages 1–4](qa/live/) | FAIL lower diagnostics | STACKED | PASS | More / FAB | No lost destination | E2 move diagnostics to Test Centre |
| Health | `HealthView.swift` / `health` | [pages 1–4](qa/health/) | PARTIAL | NONE | PASS | More | No lost destination | Coverage refresh candidate |
| Insights | `InsightsView.swift` / `insights` | [pages 1–4](qa/insights/) | PARTIAL | NONE | PASS | More | No lost destination | Coverage refresh candidate |
| Insights hub | `InsightsHubView.swift` / `insightshub` | [pages 1–4](qa/insightshub/) | PARTIAL | NONE | PASS | More / Insights | No lost destination | Coverage refresh candidate |
| Intelligence | `IntelligenceView.swift` | [pages 1–4](qa/intelligence/) | PARTIAL | NONE | PASS | More | No lost destination | Coverage refresh candidate |
| Coach | `CoachView.swift` | [pages 1–4](qa/coach/) | PARTIAL | NONE | PASS | More | No lost destination | Coverage refresh candidate |
| Explore catalog | `MetricExplorerView.swift` / `explore` | [pages 1–4](qa/explore/) | PARTIAL | NONE | PASS | More | Today Show-all entry lost | E4/T107 alignment |
| Metric detail | `MetricExplorerView.swift` | [pages 1–4](qa/metric-detail/) | PARTIAL | NONE | PASS | Explore metric row | No lost destination | T107 full alignment |
| Compare | `CompareView.swift` / `compare` | [pages 1–4](qa/compare/) | PARTIAL | NONE | PASS | More / Explore | No lost destination | Coverage refresh candidate |
| Full-day chart / Deep Timeline | `FullDayChartView.swift` | [pages 1–4](qa/full-day-chart/) | PARTIAL | NONE | PASS | Explore metric row | Today HR entry lost | E6 restore Today wiring + Paper chrome |
| Lab Book | `LabBookView.swift` / `labbook` | [pages 1–4](qa/labbook/) | PARTIAL | NONE | PASS | More | No lost destination | Empty-state coverage refresh candidate |
| Marker detail | `LabBookView.swift` | [blocked empty state](qa/labbook/page-1.png) | BLOCKED | N/A | BLOCKED: no seeded marker | Lab Book row | No lost destination | Add deterministic marker fixture |
| Marker editor | `MarkerEditorView.swift` | [blocked empty state](qa/labbook/page-1.png) | BLOCKED | N/A | BLOCKED: no seeded marker/add affordance | Lab Book add/edit | No lost destination | Reachability audit in T103 |
| Fused record | `FusedRecordView.swift` / `fused` | [pages 1–4](qa/fused/) | PARTIAL | NONE | PASS | More / Health | No lost destination | Coverage refresh candidate |
| Conflict compare | `FusedRecordView.swift` | [blocked no-conflict state](qa/fused/page-1.png) | BLOCKED | N/A | BLOCKED: demo record has no conflict | Fused record conflict | No lost destination | Add deterministic conflict fixture |
| Rhythm consent | `RhythmView.swift` / `rhythmconsent` | [pages 1–4](qa/rhythmconsent/) | PARTIAL | NONE | PASS | More / Rhythm | No lost destination | Audit accept/cancel |
| Rhythm | `RhythmView.swift` / `rhythm` | [page 1](qa/rhythm/page-1.png) | PARTIAL | NONE | PASS | More | No lost destination | Coverage refresh candidate |
| Breathing | `BreathingView.swift` | [pages 1–4](qa/breathing/) | PARTIAL | NONE | PASS | FAB / More | No lost destination | Audit all modes |
| Resonance mode | `BreathingView.swift` | [host pages](qa/breathing/) | PARTIAL | NONE | PASS | Breathing | No lost destination | Direct mode audit in T102 |
| Calm mode | `BreathingView.swift` | [host pages](qa/breathing/) | PARTIAL | NONE | PASS | Breathing | No lost destination | Direct mode audit in T102 |
| Intervals | `IntervalTimerView.swift` / `intervals` | [pages 1–4](qa/intervals/) | PARTIAL | NONE | PASS | More | No lost destination | Audit timer controls |
| Hydration | `HydrationView.swift` | [blocked toggle-off state](qa/settings/) | BLOCKED | N/A | BLOCKED: seeded preference off | Health | No lost destination | Enable and audit during T102 |
| Hydration amount sheet | `HydrationView.swift` | [blocked toggle-off state](qa/settings/) | BLOCKED | N/A | BLOCKED: parent disabled | Hydration add | No lost destination | Enable and audit during T102 |
| Weekly Digest | `WeeklyDigestView.swift` | [host pages](qa/insights/) | PARTIAL | NONE | PASS | Insights / Today | No lost destination | Direct interaction audit in T102 |
| Trends report | `TrendsReportView.swift` / `trendsreport` | [pages 1–4](qa/trendsreport/) | PARTIAL | NONE | PASS | Trends | No lost destination | Coverage refresh candidate |
| Scoring guide | `ScoringGuideView.swift` / `scoringguide` | [pages 1–4](qa/scoringguide/) | PARTIAL | NONE | DEAD known path | Recovery detail | No lost destination | T108 fix pushed close + stale copy |
| How NOOP Works | `HowNoopWorksView.swift` | [pages 1–4](qa/how-noop-works/) | PARTIAL | NONE | PASS | Settings / guide | No lost destination | Coverage refresh candidate |

## Devices, data, settings, and support

| Surface | Source / route | Full-page evidence | Paper | Duplication | Tap-through | Reachable from | Parity: lost/restored | Action needed |
|---|---|---|---|---|---|---|---|---|
| Devices | `DevicesView.swift` / `devices` | [pages 1–4](qa/devices/) | PASS | NONE | PASS | Header / More | No lost destination | Tap-through audit |
| Device catalog | `DevicesView.swift` / `devicescatalog` | [pages 1–4](qa/devicescatalog/) | PARTIAL | NONE | PASS | Add device | No lost destination | Coverage refresh candidate |
| Add-device wizard | `AddDeviceWizard.swift` / `addwizard` | [pages 1–4](qa/addwizard/) | PARTIAL | NONE | PASS | Devices Add | No lost destination | Audit every step |
| Oura onboarding | `AddDeviceWizard.swift` / `ouraonboarding` | [pages 1–4](qa/ouraonboarding/) | PARTIAL | NONE | PASS | Add-device wizard | No lost destination | Coverage refresh candidate |
| Oura device | demo host / `ouradevice` | [pages 1–4](qa/ouradevice/) | PARTIAL | NONE | PASS | Devices | No lost destination | Coverage refresh candidate |
| Xiaomi band | `XiaomiBandView.swift` / `xiaomi` | [pages 1–4](qa/xiaomi/) | PARTIAL | NONE | PASS | Devices / More | No lost destination | Coverage refresh candidate |
| Apple Watch setup | `AppleWatchSetupView.swift` / `watchsetup` | [pages 1–4](qa/watchsetup/) | PARTIAL | NONE | PASS | Devices / Settings | No lost destination | Coverage refresh candidate |
| Apple Watch about | `AppleWatchAboutView.swift` / `watchabout` | [pages 1–4](qa/watchabout/) | PARTIAL | NONE | PASS | Watch setup/settings | No lost destination | Coverage refresh candidate |
| Apple Health | `AppleHealthView.swift` / `applehealth` | [pages 1–4](qa/applehealth/) | PARTIAL | NONE | PASS | Data Sources / More | No lost destination | Coverage refresh candidate |
| Data Sources | `DataSourcesView.swift` / `data` | [pages 1–4](qa/data/) | PASS | NONE | PASS | More / Settings | Today provenance entry lost | Tap-through audit |
| Backup & Sync | `BackupSyncView.swift` / `backup` | [pages 1–4](qa/backup/) | PASS | NONE | PASS | More / Settings | No lost destination | Tap-through audit |
| Restore picker | `BackupSyncView.swift` | [blocked no-backup state](qa/backup/) | BLOCKED | N/A | BLOCKED: no backup fixture | Backup & Sync | No lost destination | Add deterministic backup fixture |
| Storage | `StorageView.swift` / `storage` | [pages 1–4](qa/storage/) | PARTIAL | NONE | PASS | Settings | No lost destination | Coverage refresh candidate |
| Settings | `SettingsView.swift` / `settings` | [pages 1–4](qa/settings/) | PASS | NONE | PASS | More | Today profile entry lost | Audit every row/toggle |
| Notification settings | `NotificationSettingsView.swift` | [entry absent in Settings sweep](qa/settings/) | BLOCKED | N/A | BLOCKED: no visible entry | Settings | No lost destination | T103 reachability failure candidate |
| Diagnostics sheet | `SettingsView.swift` | [page 1](qa/diagnostics/page-1.png) | PARTIAL | NONE | PASS | Settings | No lost destination | Tap Copy/Close in T102 |
| Steps calibration | `SettingsView.swift` | [entry visible in Settings sweep](qa/settings/) | PARTIAL | NONE | PASS | Settings | No lost destination | Direct sheet audit in T102 |
| Siri & Shortcuts | `SiriShortcutsSettingsView.swift` | [pages 1–4](qa/siri-shortcuts/) | PARTIAL | NONE | PASS | More / Settings | No lost destination | Coverage refresh candidate |
| Shortcuts export | `ShortcutExportSettingsView.swift` | [Data group state](qa/more/) | BLOCKED | N/A | BLOCKED: Data group not exercised yet | More / Settings | No lost destination | Expand/verify in T102/T103 |
| Automations | `AutomationsView.swift` / `automations` | [pages 1–4](qa/automations/) | PARTIAL | NONE | PASS | More | No lost destination | Audit toggles/persistence |
| Smart alarms | `SmartAlarmView.swift` / `alarms` | [pages 1–4](qa/alarms/) | PARTIAL | NONE | PASS | More | No lost destination | Coverage refresh candidate |
| Test Centre | `TestCentreView.swift` / `testcentre` | [pages 1–4](qa/testcentre/) | PARTIAL | NONE | PASS | More | No lost destination | E2 destination; audit current tools |
| Test report review | `TestCentreView.swift` | [blocked no-report state](qa/testcentre/) | BLOCKED | N/A | BLOCKED: no generated report | Test Centre | No lost destination | Generate report during T102 |
| Support | `SupportView.swift` / `support` | [pages 1–4](qa/support/) | PARTIAL | NONE | PASS | More / Settings | No lost destination | Audit all sub-screens |
| Updates inbox | `UpdatesInboxView.swift` / `updates` | [pages 1–4](qa/updates/) | PASS | NONE | PASS | Header Updates | No lost destination | Tap-through audit |
| What's New | `WhatsNewView.swift` | [pages 1–4](qa/whats-new/) | PARTIAL | NONE | PASS | launch / Updates | No lost destination | Audit close/links |
| Dashboard cards editor | `DashboardCardsEditorSheet.swift` / `dashboardeditor` | [pages 1–4](qa/dashboardeditor/) | PARTIAL | NONE | PASS | Today Customise | No lost destination | Audit persistence |
| Key metrics editor | `KeyMetricsEditorSheet.swift` / `keymetricseditor` | [page 1](qa/keymetricseditor/page-1.png) | PARTIAL | NONE | PASS | Today / Settings | No lost destination | Audit persistence |
| Manual workout | `ManualWorkoutSheet.swift` | [pages 1–4](qa/manual-workout/) | PARTIAL | NONE | PASS | Workouts Add / FAB | No lost destination | Audit create/cancel |
| Start workout sheet | `ManualWorkoutSheet.swift` | [parent sheet pages](qa/manual-workout/) | PARTIAL | NONE | PASS | Manual workout | No lost destination | Direct interaction audit in T102 |

## Onboarding and embedded tools/cards

| Surface | Source / route | Full-page evidence | Paper | Duplication | Tap-through | Reachable from | Parity: lost/restored | Action needed |
|---|---|---|---|---|---|---|---|---|
| First-run onboarding | `OnboardingWizard.swift` | [steps 1–12](qa/onboarding/) | FAIL legacy dark/glow system | NONE | PASS through all steps | clean install | No lost destination | E4/T110 complete Paper refresh |
| Terms gate | app root / shared Terms view | [page 1](qa/terms-gate/page-1.png) | PARTIAL | NONE | PASS all four acknowledgements + accept | clean install/version gate | No lost destination | Coverage refresh candidate |
| Journal log card | `JournalLogCard.swift` | [Quick Actions host](qa/quick-actions/page-1.png) | PARTIAL | N/A | PASS | Today / FAB | No lost destination | Tap-through audit |
| Caffeine log card | `CaffeineLogCard.swift` | [Today host sweep](qa/today/) | BLOCKED | N/A | BLOCKED: not in seeded card selection | Today | No lost destination | Conditional-state fixture needed |
| Stress check-in card | `StressCheckInCard.swift` | [Stress host sweep](qa/stress/) | BLOCKED | N/A | BLOCKED: not rendered in current state | Today / Stress | No lost destination | Conditional-state fixture needed |
| Skin-temperature cards | `SkinTempCardsView.swift` | [Health host sweep](qa/health/) | PARTIAL | N/A | PASS | Health / Today | No lost destination | Audit variants in refresh wave |
| Auto-workout card | `AutoWorkoutCard.swift` | [Workouts host sweep](qa/workouts/) | BLOCKED | N/A | BLOCKED: no auto-detection state | Today / Workouts | No lost destination | Conditional-state fixture needed |
| Health alert banner | `HealthAlertBanner.swift` | [healthy host state](qa/health/) | BLOCKED | N/A | BLOCKED: healthy seed suppresses alert | Today / Health | No lost destination | Alert-state fixture needed |
| Mind section | `MindSection.swift` | [Health host sweep](qa/health/) | PARTIAL | N/A | PASS | Health / Insights | No lost destination | Coverage refresh candidate |
| HRV snapshot | `HRVSnapshotView.swift` | [Health host sweep](qa/health/) | BLOCKED | N/A | BLOCKED: no HRV sample state | Health | No lost destination | Conditional-state fixture needed |
| Profile/avatar | `ProfileAvatarView.swift` | [Settings host sweep](qa/settings/) | PARTIAL | N/A | PASS | Settings | No lost destination | Direct editor audit in T102 |
| Biofeedback preferences | `BiofeedbackPrefs.swift` | [Breathing host sweep](qa/breathing/) | PARTIAL | N/A | PASS | Breathing/settings | No lost destination | Persistence audit in T102 |
| Biofeedback controller | `BiofeedbackController.swift` | [Breathing host sweep](qa/breathing/) | N/A | N/A | PASS | Breathing | No lost destination | Exercise behavior in T102 |

## Phase A generated inventories

- Empty-closure/control-site grep + runtime results: [complete](tap-through.md) (T102)
- Interaction-parity diff: [complete](interaction-parity.md) (T102b)
- Reachability matrix: PENDING (T103)
- Proposed retirements: none assumed; any candidate requires gate review.

## T101 full-page capture result

- 60 evidence folders, 233 stepped screenshots, all captured on iPhone 17 Pro Max from the dedicated clone.
- All 46 deterministic demo routes captured; the real-shell More index, Quick Actions, 12-step onboarding, Terms gate, and in-app-only secondary surfaces were captured separately.
- Conditional sheets without seeded prerequisites are explicitly marked `BLOCKED` with host-state evidence proving why they could not render. These are audit failures/action items, not silent passes.
- Confirmed visual failures: stacked legacy content on Workouts and Live; legacy onboarding; partial Paper alignment across Metric Detail, Deep Timeline, the Health/Insights family, device/support utilities, and several settings tools.
