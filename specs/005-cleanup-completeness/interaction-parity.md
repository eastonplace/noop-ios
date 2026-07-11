# T102b Interaction-parity Diff

Baseline: `pre-paper-reskin`  
Current audit baseline: T102 fixture build on `reskin/paper-ui`

The diff compared `NavigationLink`, `Button`, `onTapGesture`, presentation-state writes, and router destinations in every Swift file changed by the reskin. Original wiring is the restoration authority per E6.

## Lost destinations

| Reskinned surface | Pre-reskin source/wiring | Current state | Required T107b restoration |
|---|---|---|---|
| Today Live Heart Rate card | `LiquidTodayView.swift`: `NavigationLink { FullDayChartView() }` | Paper live-HR card has no action | Port link to `FullDayChartView` opening on HR. |
| Today profile/avatar | `LiquidTodayView.swift`: profile button set `showSettings = true` | `showSettings` sheet still exists but no iOS control sets it | Restore an equivalent Paper header/profile entry using the original sheet wiring. |
| Today Live Session | `LiquidTodayView.swift`: `showLiveSession = true` | No Today entry invokes the live-session flow | Restore the original start route through the current router/sheet host. |
| Today “Show all metrics” | `LiquidTodayView.swift`: `NavigationLink { MetricExplorerView() }` | Key-metric section/editor remains, but the catalog link is absent | Restore the original Metric Explorer destination. |
| Today Data Sources | `LiquidTodayView.swift`: `NavigationLink { DataSourcesView() }` | Data Sources remains reachable from More only | Restore the original Today provenance/data-sources tap-through. |

## Preserved interactions

- Day picker, Support, Devices/battery route, Quick Actions, dashboard customisation, score details, Workouts, Health, Stress, Updates, scoring guide, and card detail links remain wired.
- Root tab destinations and all 26 More rows remain present.
- Workouts, Sleep, Live workout, Settings, Support, alarms, and Test Centre show additions or equivalent wiring—not losses.

No lost destination will be reinvented: T107b must port the original destination and presentation behavior, then apply Paper chrome only.

