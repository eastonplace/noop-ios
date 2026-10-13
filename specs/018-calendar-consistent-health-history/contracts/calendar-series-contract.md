# Calendar Series Contract

- Calendar-shaped views accept dated optional slots, never value-only positional arrays.
- All inputs are normalized to local start-of-day with an injected calendar.
- Week windows always begin Monday and contain exactly seven slots.
- Rolling windows always contain the requested number of consecutive calendar slots.
- Missing past and future values remain distinguishable presentation states.
- A value is “today” or “yesterday” only when its date equals that exact calendar date.
- Trend point x-position and scrub copy derive from point dates and the explicit domain.
- Accessibility output names actual dates and missing observations.

