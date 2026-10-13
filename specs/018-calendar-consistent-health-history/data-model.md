# Data Model

## CalendarMetricDay

- `date: Date` — local start-of-day for the canonical repository day key.
- `value: Double?` — scored observation or explicit absence.
- `id: Date` — stable identity; one slot per calendar date.

## Window semantics

- Strain: seven Monday-Sunday slots containing the selected anchor day.
- Recovery: fourteen consecutive slots ending on the selected anchor day.
- Trends: 7/30/90/180 consecutive slots ending on local today.
- Summary values: exact date lookup; means exclude nil observations inside the exact requested window.

