# Concept Reference Images — 2026-07 UI Reskin

This folder holds the AI-generated concept sheets that define the visual target for the
`001-concept-ui-reskin` spec. The implementing agent must open these images and compare
its output against them screen by screen. **Near pixel-for-pixel is the bar** — subject to
the Canonical Rulings in `../spec.md §3`, which resolve every known error in the concepts.

## Image manifest

Drop the five concept PNGs into this folder with exactly these names:

| File | Contents (left → right) |
|---|---|
| `sheet-1-main-screens.png` | 1. Today · 2. Trends · 3. Sleep · 4. Live · 5. Workouts · 6. Devices · 7. Data · 8. Insights · 9. Automations · 10. Settings |
| `sheet-2-run-flow.png` | 1. Pre-run Ready · 2. Live Run In Progress · 3. Paused Run · 4. Post-run Summary Preview |
| `sheet-3-pillar-details.png` | 1. Today (variant) · 2. Charge · 3. Effort · 4. Rest · 5. Stress |
| `sheet-4-device-data-settings.png` | 1. Devices · 2. Add Device · 3. Data Sources · 4. Backup & Sync · 5. Settings · 6. Support |
| `sheet-5-insights-labs.png` | 1. Insights · 2. Lab Book · 3. Rhythm Consent · 4. Rhythm · 5. Automations · 6. Alarms · 7. Test Centre (+ Quick Actions overlay) |

> STATUS: the PNGs are NOT in this folder yet — Easton needs to drag them in from the
> original chat. Everything visual about them has been transcribed into `../spec.md §6`
> (screen-by-screen requirements), so implementation can start from the spec alone;
> use the images for final visual comparison once present.

## How to use these images

1. These are **AI concept renders** — they contain internal inconsistencies (colors flip
   between sheets, scales are wrong, two different tab bars appear). Every known
   inconsistency has a ruling in `../spec.md §3`. Where an image and a ruling disagree,
   **the ruling wins**. Where the spec is silent, follow the image.
2. All numbers, dates, names, and device lists in the images are **sample data**. Bind
   real values from `Repository`. Never hardcode a value from a concept image.
3. Match: layout order, spacing rhythm, component shapes, stroke weights, color roles,
   typography hierarchy, copy tone. Don't match: data values, the "Alex Easton" profile,
   the run-flow tab bar, the 0–21-scale effort numbers.
