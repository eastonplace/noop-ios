# T125 verification — healthy-day fidelity stack

- Device: iPhone 17 Pro Max simulator (`602CD04D-E0CD-4A41-986C-74427759C06A`).
- Launch fixture: `--demo-seed --demo-scenario healthy`; healthy is also the new default and the prior alert/illness fixture remains opt-in with `--demo-scenario illness`.
- Light evidence: `qa/t125/light/` — Today, Trends (populated prior week), Sleep, Live, Workouts, Recovery detail, Strain detail, and Insights.
- Dark evidence: `qa/t125/dark/` — the same eight routes with the app preference explicitly forced to Dark.
- Acceptance stack: `qa/t125/data-prominence-stack.jpg` — eight labeled rows, reference at left and current healthy-day light capture at right.
- Dark graphics strip: `qa/t125/dark-strip.jpg` — all eight routes in one inspection row.

## Visual inspection

- The healthy Today capture is fully populated (Recovery 52, Strain 7.2, Sleep 93) and its Health Monitor agrees with the absence of an alert banner.
- Trends uses the populated prior-week route so all three series demonstrate the F5 line weight, dots, real variance, and full card height rather than a one-day Monday trace.
- Recovery and Strain details show the larger hero metrics and visibly varied over-time charts without clipped cards.
- The dark strip was re-shot after forcing `theme.appearance=dark`; it is not a recolored or duplicated light set.
- Values remain ink/white by surface role; semantic color is carried by rings, chart marks, chips, dots, bars, and glyphs.
