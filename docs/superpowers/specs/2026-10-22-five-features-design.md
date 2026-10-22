# Five NOOP feature additions

## Approved intent

Easton explicitly approved implementing Personal Stress Baseline, a Coach Brief widget,
better step filtering, Strength routine import, and GPS route export, adapting every UI
and data path to this app and opening an unmerged pull request. The preceding comparison
and product recommendation provide the approved feature scope. This document records
implementation decisions; it does not expand that scope.

Base: `eastonplace/noop-ios@6f49d855d6f747103f4dc2a60949cb933445c3c0`.
Upstream reference: `ryanbr/noop@8e4b0c16e7640607600fa6bde5424095eba6034e`.

## Product behavior

### Personal Stress Baseline

Add an opt-in personal scoring lens to the existing Stress screen and foreground Today
stress presentation. Build its quiet-HR reference from the previous 30 local calendar
days, excluding the displayed day. Preserve day-relative scoring as the default and
fallback when history is insufficient. Identify the mode and history state in the UI.
Do not invent percentage changes or same-time-of-day norms. Cache bounded history reads
with source and input identity; reject canceled or obsolete results. Background widget
publishing must not begin repeated 30-day raw scans.

### Coach Brief widget

Add a small/medium Home Screen and rectangular Lock Screen widget using the app's existing
widget typography, surfaces, and palette. Show a completed daily Coach brief and available
verified summary metrics; tapping opens Coach. Publish completed morning/evening briefs
from the existing local Coach flow, never partial, failed, weekly, or activity answers.
No model execution, Bluetooth work, network requests, or database access in the extension.
Scope prose to consent, source epoch, and current day; clear or suppress it on revocation,
source transitions, expiry, and invalid data. Show an honest empty state before a brief exists.

### Step filtering

Use one pure counter for plausible positive cumulative-counter deltas, timestamp ordering,
counter wraps, and walking/running classifications. Preserve the fallback for entirely
unclassified legacy records. Exclude isolated movements inside scored sleep while retaining
awake stages and coherent gait. Apply the same rules to daily and physiological Strain-day
steps without changing their day boundaries or calibration. Never alter raw step samples.
Version derived caches and provide bounded durable reanalysis for previously scored history.

### Strength routine import

Add CSV/XLSX file import to the current ReceiptLift Schedule/routine experience. Parse off
the UI thread, present routines and row diagnostics, and write only after confirmation.
Bound input/decompression, validate numeric fields, preserve existing routines, and create
new identities. Match known exercises exactly; unknown custom exercises need clear consent.
Use existing persistence and Strength scoring. Preserve planned weight in routine notes
where the current model has no planned-load field. No new hosted service.

### GPS route export

Retain measured timestamp/accuracy data for new GPS routes, preserving pause/restart segments
and active-session recovery. Existing polylines remain readable; absent measurements are not
fabricated. Export valid recorded routes as GPX or FIT from Workout detail and a discoverable
Shortcuts action. Tell users when legacy routes cannot be exported or a format omits summary
metrics. Validate finite coordinates/times, enforce limits, preserve backups and old decoders.

## Global constraints

- iPhone app, WHOOP 4.0/5.0/MG scope; deployment target remains iOS 17.
- Preserve custom UI, Strain V2, Strength Strain, raw observations, source ownership and restore.
- Use existing local persistence, App Group and verified publication contracts.
- Do not merge pending PRs #66/#67/#68 or push to main; document overlap for integration.
- Do not silently enable new collection, background polling, or external services.
- UI states cover loading, missing data, failure, cancellation, and accessibility text sizes.
- Tests must exercise production behavior, and reported verification must name real execution.

## Integration and review risks

Source switches during async work; local date/DST rollover; late history changing a cached
baseline; duplicate/out-of-order samples; old backup schemas; file imports containing
unrecognized names or oversized XML; partial Coach generation; GPS pause/relaunch boundaries;
and interactions with our pending release/reliability branches are the review focus.
