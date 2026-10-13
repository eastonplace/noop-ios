# Research Decisions

- **Decision:** Extend the dated Spec 014 calendar model into a shared presentation contract. **Why:** the defect is caused by discarding dates before rendering. **Rejected:** screen-local index fixes, which fail again whenever a day is missing.
- **Decision:** Use the existing repository day key as authority and convert it once with an injected local `Calendar`. **Why:** this preserves NOOP's physiological-day ownership without UTC/local formatter drift.
- **Decision:** Missing values occupy real slots and are excluded from means. **Why:** absence is not zero and must not move later values.
- **Decision:** Trends weekday bars summarize the selected range. **Why:** the range control must govern every chart beneath it.
- **Decision:** Remove unsafe positional component initializers and migrate all in-repo callers atomically. **Why:** an integer offset cannot recover a real date.

