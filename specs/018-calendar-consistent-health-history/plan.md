# Calendar-Consistent Health History Plan

1. Add failing pure tests for calendar windows, gaps, historical anchors, summaries, range positioning, and week labels.
2. Promote Spec 014's dated observation into a shared calendar-metric contract with exact rolling/week builders.
3. Anchor Recovery and Strain details to Today's selected day and migrate their history components to dated optional slots.
4. Move the Trends range chart to dated points/domains and calculate weekday averages from the selected range.
5. Run package/app tests from local scratch, build a clean signed Release, install in place, and visually QA on iPhone.

## July 20 alignment follow-up

1. Union persisted canonical V2 Strain days with merged daily rows so every surface receives the same complete dated series.
2. Re-run a versioned, resumable source-backed history pass to fill canonical V2 days where raw HR exists; leave unsupported days empty.
3. Make Trends emphasize only the real current weekday/current heatmap date and remove maximum-average styling.
4. Make the average heading reflect the exact 7/30/90/180-day range, then repeat signed in-place iPhone QA.
5. Make the range chart and five-week heatmap inspect the exact pressed calendar slot; show `No data` for a gap instead of snapping to a nearby observation.

## Gates

- Work from isolated branch head `33502829d9a82163a353da2efe4d802aef510077`.
- Preserve Spec 014's five-week heatmap behavior.
- No merge without exact-source build evidence and physical-iPhone screenshots.
