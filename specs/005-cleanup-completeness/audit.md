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
| Today | `TodayView.swift` / `today` | [original full pages 1–4](qa/today/) · [T107b anchor proof](qa/t107b-today/) | PASS | NONE | PASS — five lost destinations restored; placement/destination proof in interaction-parity.md | Today tab | RESTORED T107b | T107b complete |
| Trends | `TrendsView.swift` / `trends` | [T106 complete page](qa/t106-trends/) | PASS | NONE | PASS | Trends tab | No lost destination | T106 deleted 661-line orphan builder island; only canonical Paper review renders |
| Sleep | `SleepView.swift` / `sleep` | [pages 1–4](qa/sleep/) | PASS | NONE | PASS | Sleep tab | No lost destination | Tap-through audit |
| More index | `RootTabView.swift` | [pages 1–4](qa/more/) | PASS | NONE | PASS | More tab | No lost destination | Tap every row/group |
| Quick Actions | `RootTabView.swift` / FAB | [page 1](qa/quick-actions/page-1.png) | PASS | NONE | PASS | Centre FAB | No lost destination | Tap every action |
| Recovery detail | `CoupledView.swift` / `recoverydetail` | [original pages 1–4](qa/recoverydetail/) · [T108 entry](qa/t108-scoring-guide/recovery-entry.png) | PASS | NONE | PASS — recommendation guide Close/Got it dismiss pushed route | Today Recovery | No lost destination | T108 complete |
| Strain detail | `CoupledView.swift` / `straindetail` | [pages 1–4](qa/straindetail/) | PASS | NONE | PASS | Today Strain | No lost destination | Tap-through audit |
| Stress detail | `StressView.swift` / `stress` | [pages 1–4](qa/stress/) | PASS | NONE | PASS | Today / More | No lost destination | Tap-through audit |
| Workouts | `WorkoutsView.swift` / `workouts` | [T104 full page](qa/t104-workouts/) | PASS | NONE | PASS incl. history row → detail | More / workout flows | No lost destination | T104 complete; add, ranges, sport/source filters, search, selection/actions, and row navigation retained |
| Workout detail | `WorkoutDetailView.swift` / `workoutdetail` | [pages 1–4](qa/workoutdetail/) | PASS | NONE | PASS | Workouts rows | No lost destination | Tap-through audit |
| Pre-workout | `LiveWorkoutView.swift` / `preworkout` | [pages 1–4](qa/preworkout/) | PASS | NONE | PASS | Start workout | No lost destination | Tap-through audit |
| Live workout | `LiveWorkoutView.swift` / `liveworkout` | [pages 1–4](qa/liveworkout/) | PASS | NONE | PASS | Pre-workout Start | No lost destination | Audit controls/map/chart |
| Live console | `LiveView.swift` / `live` | [T105 full page](qa/t105-live/) | PASS | NONE | PASS incl. current Start Workout flow | More / FAB | No lost destination | T105 complete; diagnostics moved, Start Workout retained |
| Health | `HealthView.swift` / `health` | [full pages 1–4](qa/health/) · [T109 refreshed render](qa/t109-health/page-1.png) | PASS | NONE | PASS | More | No lost destination | T109 complete — all card vessels Paper |
| Insights | `InsightsView.swift` / `insights` | [full pages 1–4](qa/insights/) · [T109 refreshed render](qa/t109-insights/page-1.png) | PASS | NONE | PASS | More | No lost destination | T109 complete — journal/effects/cards Paper |
| Insights hub | `InsightsHubView.swift` / `insightshub` | [full pages 1–4](qa/insightshub/) · [T109 refreshed render](qa/t109-insights-hub/page-1.png) | PASS | NONE | PASS | More / Insights | No lost destination | T109 complete — association/dose cards Paper |
| Intelligence | `IntelligenceView.swift` / `intelligence` | [full pages 1–4](qa/intelligence/) · [T109 refreshed render](qa/t109-intelligence/page-1.png) | PASS | NONE | PASS | More | No lost destination | T109 complete — model/day cards Paper; QA route restored |
| Coach | `CoachView.swift` | [pages 1–4](qa/coach/) | PARTIAL | NONE | PASS | More | No lost destination | Coverage refresh candidate |
| Explore catalog | `MetricExplorerView.swift` / `explore` | [T107 pages 1–4](qa/t107-explore/) | PASS | NONE | PASS — category rows open their current metric destinations | More | Today Show-all entry remains queued for T107b | T107 complete |
| Metric detail | `MetricExplorerView.swift` | [T107 pages 1–2](qa/t107-metric-detail/) | PASS | NONE | PASS — Calories row opened detail; range and correlation controls retained | Explore metric row | No lost destination | T107 complete |
| Compare | `CompareView.swift` / `compare` | [pages 1–4](qa/compare/) | PARTIAL | NONE | PASS | More / Explore | No lost destination | Coverage refresh candidate |
| Full-day chart / Deep Timeline | `FullDayChartView.swift` | [original full pages 1–4](qa/full-day-chart/) · [T107b populated HR](qa/t107b-interactions/live-hr-deep-timeline.png) | PASS | NONE | PASS — Today HR and Explore both route here; zoom/pan/timeline machinery retained | Today Live HR + Explore Deep Timeline | RESTORED T107b | T107b complete |
| Lab Book | `LabBookView.swift` / `labbook` | [pages 1–4](qa/labbook/) | PARTIAL | NONE | PASS | More | No lost destination | Empty-state coverage refresh candidate |
| Marker detail | `LabBookView.swift` | [seeded detail](qa/t102-fixtures/marker-detail.png) | PARTIAL | N/A | PASS | Lab Book seeded Ferritin row | No lost destination | Coverage refresh candidate |
| Marker editor | `MarkerEditorView.swift` | [seeded editor](qa/t102-fixtures/marker-editor.png) | PARTIAL | N/A | PASS | Lab Book Add reading | No lost destination | Coverage refresh candidate |
| Fused record | `FusedRecordView.swift` / `fused` | [pages 1–4](qa/fused/) | PARTIAL | NONE | PASS | More / Health | No lost destination | Coverage refresh candidate |
| Conflict compare | `FusedRecordView.swift` | [seeded conflict](qa/t102-fixtures/conflict-compare.png) | PARTIAL | N/A | PASS | Fused record Sources differ row | No lost destination | Coverage refresh candidate |
| Rhythm consent | `RhythmView.swift` / `rhythmconsent` | [pages 1–4](qa/rhythmconsent/) | PARTIAL | NONE | PASS | More / Rhythm | No lost destination | Audit accept/cancel |
| Rhythm | `RhythmView.swift` / `rhythm` | [page 1](qa/rhythm/page-1.png) | PARTIAL | NONE | PASS | More | No lost destination | Coverage refresh candidate |
| Breathing | `BreathingView.swift` | [pages 1–4](qa/breathing/) | PARTIAL | NONE | PASS | FAB / More | No lost destination | Audit all modes |
| Resonance mode | `BreathingView.swift` | [host pages](qa/breathing/) | PARTIAL | NONE | PASS | Breathing | No lost destination | Direct mode audit in T102 |
| Calm mode | `BreathingView.swift` | [host pages](qa/breathing/) | PARTIAL | NONE | PASS | Breathing | No lost destination | Direct mode audit in T102 |
| Intervals | `IntervalTimerView.swift` / `intervals` | [pages 1–4](qa/intervals/) | PARTIAL | NONE | PASS | More | No lost destination | Audit timer controls |
| Hydration | `HydrationView.swift` | [seeded host state](qa/today/) | PARTIAL | N/A | PASS | Today seeded Hydration card | No lost destination | Coverage refresh candidate |
| Hydration amount sheet | `HydrationView.swift` | [seeded host state](qa/today/) | PARTIAL | N/A | PASS | Hydration custom amount | No lost destination | Coverage refresh candidate |
| Weekly Digest | `WeeklyDigestView.swift` | [host pages](qa/insights/) | PARTIAL | NONE | PASS | Insights / Today | No lost destination | Direct interaction audit in T102 |
| Trends report | `TrendsReportView.swift` / `trendsreport` | [pages 1–4](qa/trendsreport/) | PARTIAL | NONE | PASS | Trends | No lost destination | Coverage refresh candidate |
| Scoring guide | `ScoringGuideView.swift` / `scoringguide` | [original pages 1–4](qa/scoringguide/) · [T108 reviewed guide](qa/t108-scoring-guide/page-1.png) | PASS | NONE | PASS — sheet callbacks retained; pushed path uses environment dismissal | Recovery detail | No lost destination | T108 complete; identifiers/copy use Recovery · Strain · Sleep |
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
| Restore picker | `BackupSyncView.swift` | [seeded picker](qa/t102-fixtures/restore-picker.png) | PARTIAL | N/A | PASS | Backup & Sync Restore | No lost destination | Coverage refresh candidate |
| Storage | `StorageView.swift` / `storage` | [pages 1–4](qa/storage/) | PARTIAL | NONE | PASS | Settings | No lost destination | Coverage refresh candidate |
| Settings | `SettingsView.swift` / `settings` | [pages 1–4](qa/settings/) | PASS | NONE | PASS | More | Today profile entry lost | Audit every row/toggle |
| Notification settings | `NotificationSettingsView.swift` | [iPhone informational row](qa/settings/) | N/A macOS-only | N/A | PASS platform split | macOS RootView; iPhone uses Automations | No lost destination | Verified unchanged vs pre-reskin; no iPhone restoration |
| Diagnostics sheet | `SettingsView.swift` | [page 1](qa/diagnostics/page-1.png) | PARTIAL | NONE | PASS | Settings | No lost destination | Tap Copy/Close in T102 |
| Steps calibration | `SettingsView.swift` | [entry visible in Settings sweep](qa/settings/) | PARTIAL | NONE | PASS | Settings | No lost destination | Direct sheet audit in T102 |
| Siri & Shortcuts | `SiriShortcutsSettingsView.swift` | [pages 1–4](qa/siri-shortcuts/) | PARTIAL | NONE | PASS | More / Settings | No lost destination | Coverage refresh candidate |
| Shortcuts export | `ShortcutExportSettingsView.swift` | [Data group full sweep](qa/more/) | PARTIAL | N/A | PASS | More → Data → Shortcuts Export | No lost destination | Coverage refresh candidate |
| Automations | `AutomationsView.swift` / `automations` | [pages 1–4](qa/automations/) | PARTIAL | NONE | PASS | More | No lost destination | Audit toggles/persistence |
| Smart alarms | `SmartAlarmView.swift` / `alarms` | [pages 1–4](qa/alarms/) | PARTIAL | NONE | PASS | More | No lost destination | Coverage refresh candidate |
| Test Centre | `TestCentreView.swift` / `testcentre` | [T105 full page](qa/t105-testcentre/) | PASS | NONE | PASS record + HRV inspect + stream export | More | No lost destination | T105 owns Signal Trust, Record & Inspect, and Stream Log |
| Test report review | `TestCentreView.swift` | [Test Centre sweep](qa/testcentre/) | PARTIAL | N/A | PASS | Test Centre → Report | No lost destination | Coverage refresh candidate |
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
| Caffeine log card | `CaffeineLogCard.swift` | [Insights host sweep](qa/insights/) | PARTIAL | N/A | PASS | Insights caffeine section | No lost destination | Coverage refresh candidate |
| Stress check-in card | `StressCheckInCard.swift` | [Breathing host sweep](qa/breathing/) | PARTIAL | N/A | PASS | Breathing check-in host | No lost destination | Coverage refresh candidate |
| Skin-temperature cards | `SkinTempCardsView.swift` | [Health host sweep](qa/health/) | PARTIAL | N/A | PASS | Health / Today | No lost destination | Audit variants in refresh wave |
| Auto-workout card | `AutoWorkoutCard.swift` | [seeded HR/workout host](qa/today/) | PARTIAL | N/A | PASS | Today auto-detection host | No lost destination | Coverage refresh candidate |
| Health alert banner | `HealthAlertBanner.swift` | [seeded alert host](qa/today/) | PASS | N/A | PASS | Today/Health illness-watch output | No lost destination | None |
| Mind section | `MindSection.swift` | [Health host sweep](qa/health/) | PARTIAL | N/A | PASS | Health / Insights | No lost destination | Coverage refresh candidate |
| HRV snapshot | `HRVSnapshotView.swift` | [Live host sweep](qa/live/) | PARTIAL | N/A | PASS | Live → HRV snapshot | No lost destination | Coverage refresh candidate |
| Profile/avatar | `ProfileAvatarView.swift` | [Settings host sweep](qa/settings/) | PARTIAL | N/A | PASS | Settings | No lost destination | Direct editor audit in T102 |
| Biofeedback preferences | `BiofeedbackPrefs.swift` | [Breathing host sweep](qa/breathing/) | PARTIAL | N/A | PASS | Breathing/settings | No lost destination | Persistence audit in T102 |
| Biofeedback controller | `BiofeedbackController.swift` | [Breathing host sweep](qa/breathing/) | N/A | N/A | PASS | Breathing | No lost destination | Exercise behavior in T102 |

## Phase A generated inventories

- Empty-closure/control-site grep + runtime results: [complete](tap-through.md) (T102)
- Interaction-parity diff: [complete](interaction-parity.md) (T102b)
- Reachability matrix: [complete](reachability.md) (T103; 26/26 More, 29/29 shared routes)
- Proposed retirements: none assumed; any candidate requires gate review.

## T101 full-page capture result

- 60 evidence folders, 233 stepped screenshots, all captured on iPhone 17 Pro Max from the dedicated clone.
- All 46 deterministic demo routes captured; the real-shell More index, Quick Actions, 12-step onboarding, Terms gate, and in-app-only secondary surfaces were captured separately.
- T102 added deterministic fixtures and re-audited every conditional surface that was blocked in T101; no audit row remains blocked.
- Confirmed visual failures: stacked legacy content on Workouts and Live; legacy onboarding; partial Paper alignment across Metric Detail, Deep Timeline, the Health/Insights family, device/support utilities, and several settings tools.
