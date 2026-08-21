# NOOP UI file coverage matrix

Branch: `design/whoop-unified-ui-20260821`

This matrix records each iPhone UI source group reviewed for the WHOOP-aligned dark-theme pass.

## Status key

- **Direct**: source changed in this branch.
- **Inherited**: source uses shared design tokens or components and receives the new visual contract without a component rewrite.
- **Verify**: simulator or screenshot review is required.
- **Logic-adjacent**: affects UI state, data, timing, or formatting. Visual source was not changed.
- **Excluded**: no user-interface ownership in this pass.

## App roots and system surfaces

| File | Status | Review contract |
|---|---|---|
| `StrandiOS/App/StrandiOSApp.swift` | Inherited, Verify | Root resolves every stored appearance to dark. Check launch and sheet transitions for white flashes. |
| `StrandiOS/App/RootTabView.swift` | Inherited, Verify | Tab bar, navigation stacks, active color, safe-area fill, and tab restoration. |
| `StrandiOS/App/Component41QAGallery.swift` | Inherited, Verify | Use as a component screenshot gallery. Confirm type, cards, buttons, charts, and empty states. |
| `StrandiOS/App/DesignLabAtomGallery.swift` | Inherited, Verify | Review primitive spacing, corner radii, icon plates, labels, and number roles. |
| `StrandiOS/App/ShortcutExportSettingsView.swift` | Inherited, Verify | Native settings rows, navigation title, buttons, and sheet surface. |
| `StrandiOS/App/SiriShortcutsSettingsView.swift` | Inherited, Verify | Native rows, labels, disclosure indicators, and empty/error states. |
| `StrandiOSWidgets/NOOPWidget.swift` | Verify | Widget does not automatically inherit app environment. Check every family in light and dark system settings. |
| `StrandiOSWidgets/NOOPLiveActivity.swift` | Verify | Lock Screen and Dynamic Island colors need separate evidence. |
| `StrandiOSWidgets/NOOPWidgetBundle.swift` | Logic-adjacent | Bundle registration only. |
| `StrandiOSShared/WidgetSnapshot.swift` | Logic-adjacent | Snapshot data contract only. Confirm missing/stale values render safely in widgets. |
| `StrandiOSShared/LiveActivityAttributes.swift` | Logic-adjacent | Live Activity data contract only. |

## Shared design system

| File | Status | Review contract |
|---|---|---|
| `Appearance.swift` | **Direct** | Fixed dark mode, one chart grammar, no full-tree identity reset. |
| `Palette.swift` | **Direct** | Graphite surfaces, teal actions, fixed score colors, exact Recovery bands. |
| `Typography.swift` | **Direct** | Native semantic text roles, Dynamic Type, bold tabular numbers. |
| `StrandCard.swift` | **Direct** | One gradient card surface, border, tint wash, shadow, press/hover behavior. |
| `BevelGauge.swift` | Inherited, Verify | Gauge track contrast, tip glow, number alignment, clipping. |
| `BrandMark.swift` | Inherited, Verify | NOOP identity remains intact. No WHOOP mark or wordmark. |
| `ChartHover.swift` | Inherited, Verify | Tooltip text contrast, pointer tracking, focus behavior. |
| `ComponentLibraryAPI.swift` | Inherited, Verify | Public component aliases continue to resolve to shared tokens. |
| `Components.swift` | Inherited, Verify | Core cards, headers, rows, scaffolds, spacing, controls. Review 18-point spacing debt. |
| `ContentSection.swift` | Inherited, Verify | Section title, subtitle, divider, action alignment. |
| `DayNavBar.swift` | Inherited, Verify | Date navigation, selected day, disabled arrows, hit areas. |
| `DeviceCommandCenterComponents.swift` | Inherited, Verify | Status cards, sync states, command rows, dense diagnostics. |
| `DomainTheme.swift` | Inherited, Verify | Recovery, Strain, Sleep, and Stress keep distinct color worlds. |
| `FactorBands.swift` | Inherited, Verify | Band labels and ranges remain readable on dark graphite. |
| `FitnessAgeDetailComponents.swift` | Inherited, Verify | Age value hierarchy, charts, explanatory rows. |
| `GlowRing.swift` | Inherited, Verify | Bloom remains restrained and does not reduce score readability. |
| `HRModuleComponents.swift` | Inherited, Verify | Live HR, status labels, metric cards, loading states. |
| `Haptics.swift` | Logic-adjacent | No visual ownership. Keep haptic calls unchanged. |
| `HeartRateComponents.swift` | Inherited, Verify | HR charts, zones, labels, annotations, empty states. |
| `Hypnogram.swift` | Inherited, Verify | Stage colors, minimum band size, labels, scroll/scrub behavior. |
| `JournalCheckinsComponents.swift` | Inherited, Verify | Chips, selections, positive/negative states, long text. |
| `MetricCompareComponents.swift` | Inherited, Verify | Comparison direction, delta colors, axes, legends. |
| `MicroPrimitives.swift` | Inherited, Verify | Small labels, pips, badges, dividers, icon plates. |
| `Motion.swift` | Logic-adjacent, Verify | Animation timing. Test Reduce Motion. |
| `MotionTrace.swift` | Logic-adjacent | Performance trace only. |
| `NoopButton.swift` | Inherited, Verify | Teal primary action, neutral secondary, destructive red, disabled contrast. |
| `NoopMotion.swift` | Logic-adjacent, Verify | Shared motion system. Test tab, card, gauge, and sheet transitions. |
| `OverviewHRChart.swift` | Inherited, Verify | Plot contrast, annotations, gaps, live updates, scrub. |
| `PaperComponents.swift` | Inherited, Verify | Legacy-named shared components must render dark. Find white-specific assumptions. |
| `PaperSearchField.swift` | Inherited, Verify | Field fill, placeholder, clear control, focus ring, keyboard appearance. |
| `PaperToast.swift` | Inherited, Verify | Toast contrast, safe area, motion, action button. |
| `PipBar.swift` | Inherited, Verify | Filled/unfilled pips and metric-specific color meaning. |
| `RecoveryComponents.swift` | Inherited, Verify | Recovery bands and state labels use exact ranges. |
| `RecoveryRing.swift` | Inherited, Verify | Ring score, percent label, low/medium/high boundaries. |
| `SceneHeroBackground.swift` | Inherited, Verify | Dark scenic detail backgrounds. No time-of-day mode. |
| `SettingsCatalog.swift` | Inherited, Verify | Route labels, descriptions, search index. |
| `SettingsKitComponents.swift` | Inherited, Verify | Native settings surface, rows, destinations, toggles, segmented controls. |
| `SheetsAlerts.swift` | Inherited, Verify | Sheet canvas, drag indicator, alert contrast, destructive actions. |
| `SleepAlarmComponents.swift` | Inherited, Verify | Alarm editor, plan, wake time, enabled state, VoiceOver. |
| `SleepStressComponents.swift` | Inherited, Verify | Sleep stress timeline, labels, legends, no color collision. |
| `Sparkline.swift` | Inherited, Verify | Line contrast, empty/flat data, animation cost. |
| `SportIcon.swift` | Inherited, Verify | Icon weight, plate contrast, fallback symbol. |
| `StatePill.swift` | Inherited, Verify | Semantic pills remain distinct and readable. |
| `StrainComponents.swift` | Inherited, Verify | Strain cards, targets, explanatory labels, blue consistency. |
| `StrainGauge.swift` | Inherited, Verify | 0–21 or 0–100 display, arc, labels, scale selection. |
| `StrainScale.swift` | Inherited, Verify | Scale ticks and target ranges. |
| `StressModuleComponents.swift` | Inherited, Verify | Stress gauge, timeline, unavailable/calibrating states. |
| `StressPresentationMode.swift` | Logic-adjacent | Presentation-state contract only. |
| `TimeOfDayBackground.swift` | Verify, retirement candidate | Today no longer uses this scene. Confirm no active screen path depends on it before deletion. |
| `TodayDashboardComponents.swift` | Inherited, Verify | Daily score trio, health tiles, cards, edit affordances. |
| `TrendChart.swift` | Inherited, Verify | Axes, labels, scrubbing, loading, empty data. |
| `TrendsV2Components.swift` | Inherited, Verify | Range controls, delta tones, weekly charts, touch scrub. |
| `TypicalRangeBar.swift` | Inherited, Verify | Typical range, current marker, low contrast conditions. |
| `ValueToken.swift` | Inherited, Verify | Number/unit baseline and missing-value format. |
| `WidgetLiveComponents.swift` | Inherited, Verify | Shared widget and live-activity components across system families. |
| `YearHeatStrip.swift` | Inherited, Verify | Cell contrast, empty days, selection, accessibility labels. |
| `StrandDesign.swift` | Logic-adjacent | Compatibility shims and package entry point. |

## Screen sources

| File | Status | Screen-specific visual and performance check |
|---|---|---|
| `AddDeviceWizard.swift` | Inherited, Verify | Step hierarchy, scan results, model selection, permissions, errors, long names. |
| `AppHeaderChrome.swift` | Inherited, Verify | Header canvas, title, profile/device actions, scroll transitions. |
| `AppleHealthView.swift` | Inherited, Verify | Permission rows, source states, cards, errors, long explanations. |
| `AppleHealthWearableViews.swift` | Inherited, Verify | Wearable-specific summary rows and empty states. |
| `AutoWorkoutCard.swift` | Inherited, Verify | Detection card, confidence copy, save/dismiss actions. |
| `AutomationsView.swift` | Inherited, Verify | Rule rows, toggles, conditions, empty state, sheets. |
| `BackupSyncView.swift` | Inherited, Verify | Backup status, progress, file actions, destructive restore warning. |
| `BiofeedbackController.swift` | Logic-adjacent | Timer and state ownership. Check it does not invalidate the whole screen at high frequency. |
| `BiofeedbackPrefs.swift` | Logic-adjacent | Preference storage only. |
| `BreathingView.swift` | Inherited, Verify | Full-screen canvas, timer, breath animation, controls, Reduce Motion. |
| `CaffeineLogCard.swift` | Inherited, Verify | Input rows, amount/time, validation, saved state. |
| `ChargeBreakdownFormat.swift` | Logic-adjacent | Recovery copy and value formatting only. |
| `CoachMarkdownTheme.swift` | Inherited, Verify | Markdown headings, body, code, links, lists, tables on dark. |
| `CoachView.swift` | Inherited, Verify | Chat bubbles, composer, tool cards, loading, errors, keyboard. |
| `CompareView.swift` | Inherited, Verify | Metric picker, charts, delta signs, legends, dense comparison tables. |
| `CoupledView.swift` | Inherited, Verify | Coupled metric cards, correlations, charts, no-data states. |
| `DashboardCards.swift` | Inherited, Verify | Dashboard card surface and action hierarchy. |
| `DashboardCardsEditorSheet.swift` | Inherited, Verify | Reorder controls, selected state, drag handles, sheet canvas. |
| `DashboardCatalogView.swift` | Inherited, Verify | Catalog grid/list, add state, descriptions. |
| `DataSourcesView.swift` | Inherited, Verify | Source ownership, sync status, disclosure rows, deletion flows. |
| `DeviceCommandCenterLiveSnapshot.swift` | Logic-adjacent | Deduplicated live snapshot. Verify no high-frequency root invalidation. |
| `DeviceCommandCenterStatus.swift` | Logic-adjacent | Status derivation and value wording. |
| `DevicesView.swift` | Inherited, Verify | Connection hero, device cards, sync progress, diagnostics, long logs. |
| `FitnessAgeDetailView.swift` | Inherited, Verify | Detail hero, contributing factors, trend chart, explanation. |
| `FullDayChartView.swift` | Inherited, Verify | Full-day plot, scrub, gaps, zoom, annotations. |
| `FusedRecordView.swift` | Inherited, Verify | Provenance rows, merged-source badges, timeline, technical detail. |
| `HRVSnapshotView.swift` | Inherited, Verify | HRV hero, trend, confidence, calibration and no-data states. |
| `HealthAlertBanner.swift` | Inherited, Verify | Warning contrast, icon, wrapping, dismissal. |
| `HealthView.swift` | Inherited, Verify | Health monitor grid, skin temperature, stress, alerts, stale/calibrating states. |
| `HowNoopWorksView.swift` | Inherited, Verify | Long-form education, section rhythm, links, diagrams. |
| `HydrationView.swift` | Inherited, Verify | Progress, add controls, units, daily history, opt-in state. |
| `InsightsHubView.swift` | Inherited, Verify | Hub cards, route grouping, empty states. |
| `InsightsView.swift` | Inherited, Verify | Insight hierarchy, charts, explanations, loading sequence. |
| `IntelligenceView.swift` | Inherited, Verify | Intelligence cards, confidence/provenance, loading and error states. |
| `IntervalTimerView.swift` | Inherited, Verify | Timer digits, phase colors, controls, screen-awake state, Reduce Motion. |
| `JournalLogCard.swift` | Inherited, Verify | Long behavior catalog, selections, search, saved states. |
| `KeyMetricsEditorSheet.swift` | Inherited, Verify | Reorder, add/remove, disabled state, sheet sizing. |
| `LabBookView.swift` | Inherited, Verify | Experiments, tables, filters, technical values, empty state. |
| `LiveView.swift` | Inherited, Verify | High-frequency HR, gauges, status, command buttons, battery impact. |
| `LiveWorkoutView.swift` | Inherited, Verify | Live timer, HR zones, pause/end actions, long-session stability. |
| `ManualWorkoutSheet.swift` | Inherited, Verify | Form fields, sport selection, date/time, validation, save. |
| `MarkerEditorView.swift` | Inherited, Verify | Marker form, time controls, delete action, keyboard. |
| `MetricExplorerView.swift` | Inherited, Verify | Metric search, date ranges, charts, tables, annotations. |
| `MindSection.swift` | Inherited, Verify | Stress/mind cards, breathing entry, unavailable state. |
| `MissedSleepRecoveryCard.swift` | Inherited, Verify | Debt/recovery message, action, conditional visibility. |
| `PaperDataPrimitives.swift` | Inherited, Verify | Legacy-named visual data primitives on dark. |
| `PaperOperationFeedback.swift` | Inherited, Verify | Progress, success, error, retry feedback. |
| `ProfileAvatarView.swift` | Inherited, Verify | Photo, initials, fallback, border, all background values. |
| `RhythmView.swift` | Inherited, Verify | Sleep rhythm chart, consistency, day labels, empty state. |
| `ScoringGuideView.swift` | Inherited, Verify | Recovery/Strain/Sleep explanation and exact semantic colors. |
| `ScreenScaffold.swift` | Inherited, Verify | Global canvas, top background, section padding, navigation role, safe area. |
| `SettingsRouteCatalog.swift` | Inherited, Verify | Settings grouping and search labels. |
| `SettingsView.swift` | Inherited, Verify, cleanup required | Fixed dark rendering. Remove duplicate day-cycle controls and stale theme copy after path verification. |
| `SkinTempCardsView.swift` | Inherited, Verify | Baseline, delta, missing sensor, calibrating state. |
| `SleepAlarmEditorSection.swift` | Inherited, Verify | Alarm time, plan, enabled state, schedule text, DST and VoiceOver. |
| `SleepRecoveryEmptyStateBridge.swift` | Inherited, Verify | Consistent empty/recovery bridge states. |
| `SleepView.swift` | Inherited, Verify, traced issue | Full hierarchy, staged loading, split sleep, naps, ledger source mismatch. |
| `SmartAlarmView.swift` | Inherited, Verify | Alarm settings, mode selection, warning states, schedule details. |
| `StorageView.swift` | Inherited, Verify | Storage totals, source rows, cleanup and delete confirmation. |
| `StressCheckInCard.swift` | Inherited, Verify | Check-in options, selected state, saved feedback. |
| `StressPresentation.swift` | Logic-adjacent | Stress words, colors, calibration state. |
| `StressView.swift` | Inherited, Verify | Gauge, timeline, live/stale state, check-in, detail charts. |
| `TestCentreView.swift` | Inherited, Verify | Dense diagnostics, controls, logs, warnings, long values. |
| `TodayView.swift` | Inherited, Verify | Daily score hero, section snapshots, one dark canvas, no day-cycle scene. |
| `TodayWorkoutsView.swift` | Inherited, Verify | Workout rows, strain, time, sport icons, empty state. |
| `TrendsExploreHubView.swift` | Inherited, Verify | Explore routes, cards, search/discovery. |
| `TrendsReportView.swift` | Inherited, Verify | Report sections, charts, export, long date ranges. |
| `TrendsSnapshotModels.swift` | Logic-adjacent | Snapshot timing and stable values. |
| `TrendsView+Preview.swift` | Inherited, Verify | Preview fixtures should show correct dark contract. |
| `TrendsView+SelectedRange.swift` | Inherited, Verify | Range summary, deltas, selected state. |
| `TrendsView+WeeklyReview.swift` | Inherited, Verify | Weekly readout, movers, chart hierarchy. |
| `TrendsView.swift` | Inherited, Verify | Root range navigation, loading, tab/scroll restoration. |
| `UpdatesInboxView.swift` | Inherited, Verify | Read/unread rows, badges, empty state. |
| `V5PillarHosts.swift` | Inherited, Verify | Pillar host surfaces and route transitions. |
| `VitalSignsSummary.swift` | Inherited, Verify | Dense metric grid, abnormal states, units, stale values. |
| `WeeklyDigestView.swift` | Inherited, Verify | Weekly report hierarchy, charts, highlights, no-data state. |
| `WhatsNewView.swift` | Inherited, Verify | Release-note typography, bullets, links, sheet canvas. |
| `WorkoutDetailView.swift` | Inherited, Verify | Hero, strain, HR zones, timeline, metrics, edit/delete actions. |
| `WorkoutHeartRateRecoveryCard.swift` | Inherited, Verify | Recovery curve, labels, unavailable state. |
| `WorkoutsView.swift` | Inherited, Verify | Workout list, filters, summaries, loading and empty states. |
| `XiaomiBandView.swift` | Inherited, Verify | Legacy device screen. Confirm whether it remains reachable before removal. |

## Direct test coverage

| File | Status | Contract |
|---|---|---|
| `Packages/StrandDesign/Tests/StrandDesignTests/WhoopThemeContractTests.swift` | **Direct** | Fixed dark resolution, fixed chart style, compatibility color behavior, exact score colors. |

## Files intentionally excluded from visual edits

The following categories were reviewed only for ownership boundaries:

- BLE and WHOOP protocol commands.
- Repository and database code.
- Health scoring and calibration code.
- Smart Alarm runtime, background registration, and command reconciliation.
- Widget signing and verified-envelope code.
- App entitlements and property lists, except during build verification.

These files must remain unchanged unless a visual defect is proven to originate from their state contract.

## Required evidence

A file marked **Verify** needs at least one of these forms of evidence:

- Simulator screenshot at a named device size.
- Interaction recording.
- Accessibility inspection.
- Test result.
- Instruments trace.
- Source-level proof that the path is unreachable.

Do not mark the full matrix complete from a successful compile alone.
