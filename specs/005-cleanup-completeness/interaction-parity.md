# T102b Interaction-parity Diff

Baseline: `pre-paper-reskin`  
Current audit baseline: T102 fixture build on `reskin/paper-ui`

The diff compared `NavigationLink`, `Button`, `onTapGesture`, presentation-state writes, and router destinations in every Swift file changed by the reskin. Original wiring is the restoration authority per E6.

## Lost destinations

| Reskinned surface | Pre-reskin source/wiring | Current state | Required T107b restoration |
|---|---|---|---|
| Today Live Heart Rate card | `LiquidTodayView.swift`: `NavigationLink { FullDayChartView() }` | RESTORED T107b — the Paper HR card is the link label and opens the HR-default Deep Timeline | [Today anchor](qa/t107b-today/page-1.png) · [destination](qa/t107b-interactions/live-hr-deep-timeline.png) |
| Today profile/avatar | `LiquidTodayView.swift`: profile button set `showSettings = true` | RESTORED T107b — 30pt avatar in the existing trailing header control group uses the retained Settings sheet binding | [Today anchor](qa/t107b-today/page-1.png) · [destination](qa/t107b-interactions/profile-settings.png) |
| Today Live Session | `LiquidTodayView.swift`: `showLiveSession = true` | RESTORED T107b — Start/Open occupies the existing Today-at-a-glance trailing slot and presents the current sport-picker + `LiveWorkoutView` flow | [Today anchor](qa/t107b-today/page-1.png) · [current flow](qa/t107b-interactions/current-workout-flow.png) |
| Today “Show all metrics” | `LiquidTodayView.swift`: `NavigationLink { MetricExplorerView() }` | RESTORED T107b — quiet Show all link in the existing Health Monitor header | [Today anchor](qa/t107b-today/page-1.png) · [destination](qa/t107b-interactions/show-all-metrics.png) |
| Today Data Sources | `LiquidTodayView.swift`: `NavigationLink { DataSourcesView() }` | RESTORED T107b — provenance link in the Health Monitor card's existing footer/link slot | [Today anchor](qa/t107b-today/page-1.png) · [destination](qa/t107b-interactions/data-sources.png) |

## Preserved interactions

- Day picker, Support, Devices/battery route, Quick Actions, dashboard customisation, score details, Workouts, Health, Stress, Updates, scoring guide, and card detail links remain wired.
- Root tab destinations and all 26 More rows remain present.
- Workouts, Sleep, Live workout, Settings, Support, alarms, and Test Centre show additions or equivalent wiring—not losses.

No lost destination will be reinvented: T107b must port the original destination and presentation behavior, then apply Paper chrome only.
