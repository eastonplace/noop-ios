# Calendar-Aligned Trends

## Objective

Represent calendar dates rather than a compacted score array so unavailable recovery/sleep days remain gray and later values never shift under the wrong weekday.

## Requirements

- Five complete Monday-Sunday rows use local calendar dates.
- Past missing values render visible gray; future dates render a dim placeholder.
- Best-day age is calculated from the actual date.
- Weekday summaries group dated observations and exclude absent values without shifting.
- Line charts may omit unavailable values but cannot feed compacted data into calendar layouts.
