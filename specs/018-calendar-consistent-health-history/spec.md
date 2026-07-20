# Calendar-Consistent Health History

## Objective

Keep every Recovery, Strain, and Trends value attached to its canonical calendar day so missing observations never shift under the wrong weekday or masquerade as today/yesterday.

## Requirements

- Pillar details follow the day selected on Today.
- Strain renders the Monday-Sunday week containing that selected day.
- Recovery renders the exact fourteen calendar days ending on that selected day.
- Today, yesterday, seven-day averages, baselines, contributors, workouts, and zones use the same selected-day key.
- Trends ranges cover exactly 7, 30, 90, or 180 calendar days ending today.
- Trends weekday bars average actual weekdays inside the selected range and identify the range in visible copy.
- Missing values remain missing; they are never carried forward, interpolated, or relabeled.
- The current-week header is Monday-Sunday in the user's local calendar.
- Scoring, persistence, BLE, widgets, Watch, iPad, and visual redesign remain unchanged.

