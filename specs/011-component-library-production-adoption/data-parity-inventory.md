# Data Parity Inventory 011

| Surface | Required production parity | Status |
|---|---|---|
| Today rings | Recovery/Sleep optional scores, Strain 0–21, calibration, routes | Mapped to existing production values and destinations; no scoring changes. |
| Today Stress | 24 real hourly slots, daily value, honest calibration, Stress route | Mapped; main module and lower entry now share the canonical Stress destination. |
| Today HR | bounded recent samples, resting HR, waiting state, HR route | Mapped; live trace and summaries retain the existing repository inputs and empty state. |
| Heart Rate | HR, HRV, skin temperature, respiratory rate, SpO2, motion, band sleep; days, sources, sleep/workout annotations, zoom/pan/scrub | Mapped; production timeline retains all metric tabs, provenance filters, annotations, and interaction state. |
| Recovery | score, yesterday/baseline/7d/14d, HRV, RHR, sleep, respiratory rate, skin temperature, scoring/recommendation action | Mapped; all factors and the methodology action remain present. |
| Strain | score, target, yesterday/baseline/7d, daily curve, workouts, average/max HR, calories, duration, zones, Workouts action | Mapped; all contributors, activities, zones, and drill-ins remain present. |
| Trends | Recovery, Strain, Sleep Performance, HRV, ranges, weekly digest/insight, drill-ins, offline/empty behavior, PDF | Mapped to Trends V2 while retaining production series, week navigation, digest, drill-ins, and export action. |
| Navigation | title, subtitle/date, back, trailing actions, one accessible header, tab clearance | Mapped to shared collapsing navigation; Sleep's duplicate date is removed from the sticky/inline overlap. |

Rows may be marked mapped, retained, duplicate removed, or intentionally retired with
evidence. No unique item can be marked dropped without explicit product approval.

## Validation evidence

- `swift test --disable-sandbox`: 55/55 StrandDesign tests passed.
- `xcodegen generate`: completed from the build mirror.
- Generic iOS Simulator `NOOPiOS` build: passed, including `NOOPiOSWidgets`.
- Design Lab simulator build against the promoted package components: passed.
- Release iPhone build: passed with both NOOP and widget provisioning profiles embedded.
- Route screenshots reviewed: Today, Stress, Sleep, Recovery, Strain, Trends V2, and Heart Rate Deep Timeline.
- Physical iPhone 17 Pro: installed in place and launched successfully; existing application data preserved.
