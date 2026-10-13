# Surface Inventory 010

## Baseline families

- `PaperCard`: 51 source files — ordinary content; flattened through the app-scoped
  presentation environment.
- `NoopCard`: 15 source files — ordinary content; flattened through the same environment.
- `StrandCard`: 15 source files — ordinary content/empty state; flat in the opted-in iOS
  app and bounded by default elsewhere.
- Direct rounded backgrounds: 39 screen files — reviewed as controls, fields, selected
  pills, alerts/status notes, chat bubbles, setup choices, or bespoke content.

## Explicit bespoke migrations

| Site | Disposition |
|---|---|
| Today score/HR/Stress/Health modules | Flatten via shared card environment |
| Today “Your Cards” rows | Flatten via `contentRowSurface` |
| Fitness Age/Vitality expandable content | Flatten via `contentRowSurface` |
| Shared pending/coming-together note | Flatten via `contentRowSurface` |
| Buttons, text fields, segmented controls | Retain bounded control |
| `NoteCard` warning/info/privacy states | Retain bounded status/alert |
| Sheets, dialogs, tooltips, chart hover | Retain bounded overlay |
| Chat bubbles and setup choices | Retain bounded interaction context |
| macOS/watchOS/widgets/Design Lab | Non-iOS; existing presentation retained |

## Frozen boundary

The migration changes no Repository, BLE, HealthKit, persistence, scoring, fixture,
mock-data, or router file. Fable’s `TodayView.stressDetail` route remains the canonical
destination for both Stress entry points.
