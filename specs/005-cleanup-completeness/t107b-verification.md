# T107b restoration gate

Build: `NOOPiOS`, Debug iPhone Simulator, iPhone 17 Pro Max, `--demo-seed` — PASS.

## Placement decisions and route proof

| Restoration | Paper placement | Original/current wiring | Proof |
|---|---|---|---|
| Profile | 30pt avatar appended to Today's existing trailing header controls; no new header row | Original `showSettings = true` binding and retained `settingsSheet` | [anchor](qa/t107b-today/page-1.png) · [Settings](qa/t107b-interactions/profile-settings.png) |
| Live HR | Entire existing Paper Live Heart Rate card is a `NavigationLink`, preserving its composition | Original destination `FullDayChartView`; its default metric remains `.hr` | [anchor](qa/t107b-today/page-1.png) · [populated Deep Timeline](qa/t107b-interactions/live-hr-deep-timeline.png) |
| Live session | `Start`/`Open` uses the existing Today-at-a-glance trailing link slot | Current `StartWorkoutSheet` → `AppModel.startWorkout` → `LiveWorkoutView`; the deleted Liquid session is not referenced | [anchor](qa/t107b-today/page-1.png) · [current pre-run flow](qa/t107b-interactions/current-workout-flow.png) |
| Show all metrics | Quiet link in the existing Health Monitor header | Original `MetricExplorerView` destination | [anchor](qa/t107b-today/page-1.png) · [Explore](qa/t107b-interactions/show-all-metrics.png) |
| Data Sources | Existing Health Monitor footer/link slot, below its metrics | Original `DataSourcesView` destination | [anchor](qa/t107b-today/page-1.png) · [Data Sources](qa/t107b-interactions/data-sources.png) |

## Week in Review browsing rider

- Ported `weekOffset`, `minWeekOffset`, Monday anchoring, clamped stepping, and `WeeklyDigestSource.digest` selection from `d46584a2^`.
- The Paper card header owns small previous/next chevrons and the required `This week` / `Last week` / `N weeks ago` label.
- Current-week forward is disabled; the earliest-week back control disables through the same original clamp.
- The score tiles, chart, review bullets, and insight all resolve from the selected engine digest—no view math was introduced.
- Proof: [This week](qa/t107b-week-review/page-1-this-week.png) · [Last week](qa/t107b-week-review/page-2-last-week.png).

## Carry-along

Metric Detail's Average, Min, Max, Latest, and delta tile numerals now all use primary ink. Metric-specific color remains only on chart/sparkline data.

## Behavior preservation

`FullDayChartView`'s `zoomDomain`, pinch, pan, scrub, day stepping, adaptive reload, and `timelineSeries` paths are unchanged. The seeded destination proof renders populated HR plus the existing “Pinch to zoom · drag to pan · hold to read” interaction surface.
