# Sleep Stage Focus Implementation Plan

**Goal:** Make the approved Sleep emphasis visible on the phone and make a tap reveal the selected period.

**Design:** Preserve the single-row KPIs and compact stage totals. Give the plot a minimum useful height independent of smaller text settings. Keep large KPI values without the shared strip silently stepping them back down. A tap or hold selects the period near the finger; other periods and guides dim. Show stage, recorded time window and duration in a compact callout away from the selected lane. A tap in empty space or on the selected period dismisses it. Retain held dragging and ordinary vertical scrolling. Reconstructed timelines must never invent recorded times.

**Evidence:** Installed 2.0.2/build254 and merged source823a329e verified. Actual phone screenshot captured. Current tap handler only clears selection, hold hit testing is limited to the10pt ink, and selection does not drive dimming. Shared FactStrip can reduce requested25pt values to21.25pt or18pt. Plot height scales down with smaller text settings.

**Scope:** SleepScreenParts.swift, focused existing Sleep native/UI tests, release metadata and changelog. No scoring, alarm scheduling, sync, stored-data or shared app-wide typography changes.

- [x] Reproduce tap failure and small-text plot shrink with the two existing affected UI methods.
- [x] Repair local Sleep geometry and stage selection; keep exact clock/gap semantics.
- [x] Run affected native/UI checks and inspect phone-sized Simulator screenshots.
- [ ] Open a focused follow-up PR with source/visual evidence. Apply the already requested in-place phone delivery once the correction is qualified.

**Release:** 2.0.3/build255, a corrective patch to the intended2.0.2 Sleep behavior. No release tag/publication.

**Validation:** Both baseline UI checks failed for the reported behavior: the XS chart measured133.13pt and a normal tap showed no readout. Final focused UI checks passed for small-text layout, tap selection, recorded window and duration, held dragging into REM, dismissal and ordinary scrolling. The SleepScreenPartsTests suite passed, including expanded-target lane/gap controls. Final screenshots were visually inspected at XS and default text sizes. Source, UI, accessibility/localization, paper-string and release audits passed; CI policy tests passed. Independent source review found no blocking issue. The normal repository CI lane still applies; no new pending-check merge exception is granted.
