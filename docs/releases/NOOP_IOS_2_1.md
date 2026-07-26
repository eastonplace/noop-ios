# NOOP iOS 2.1 — Unified Release Candidate

Branch: `release/noop-ios-2.1-rc`

Status: **Draft release candidate. Do not merge until simulator and physical-device QA pass.**

## Release purpose

NOOP iOS 2.1 combines two previously stacked workstreams into one review and qualification line:

1. WHOOP backend compatibility and protocol hardening from the former PR #20.
2. Bounded missed-sleep recovery from the former PR #21.

The unified branch contains both histories and targets the NOOP iOS 2.0 release line directly. It does not require either former PR to merge first.

## User-visible changes

### Recover a missed night

When NOOP cannot confidently detect a night, the Sleep empty state now offers:

- **Retry automatic detection** to run a fresh normal analysis pass.
- **Set the sleep window** to give NOOP approximate bedtime and wake boundaries.

The selected interval is a search constraint, not a declaration that every minute was sleep. NOOP derives stages, resting HR, HRV, Rest, and Charge only from recorded evidence. Sparse motion can preserve real overnight vitals while leaving stages and Rest unavailable.

### Workout heart-rate recovery

Qualified workouts can surface signed 1-, 2-, and 5-minute heart-rate recovery calculated from local raw HR. The calculation requires a contiguous elevated-effort segment and adequate post-effort coverage; missing evidence remains unavailable rather than interpolated.

### WHOOP 5/MG compatibility

The release adds stricter family detection, safer timestamp and clock recovery, model correction, raw-frame validation, and opt-in experimental controls. Unsupported or unknown protocol families fail closed.

### SpO₂ Candidate (Beta)

Selected WHOOP 5/MG sleep records can produce a separately labelled approximate candidate value. This experimental value is intentionally isolated from:

- canonical Blood Oxygen;
- Apple Health;
- Charge and Rest;
- illness detection;
- widgets and Trends;
- alerts or medical claims.

## Data integrity and privacy

- Sleep recovery session, audit provenance, corrected daily values, Rest, and Charge are written atomically.
- Overlapping automatic sessions can be replaced; overlapping user-edited sessions are never silently overwritten.
- Reprocessing the same window is idempotent.
- Later analytics passes cannot erase a protected recovered night.
- Deleting the recovered session releases its protected daily values.
- Full device-data deletion removes recovery audits and overlays without trigger resurrection.
- No raw physiological samples are copied into the recovery audit table.

## Performance and reliability work

- Bounded reads and processing windows prevent unbounded sleep and workout analysis.
- High-frequency workout ingestion remains separate from slower persistence and external publication.
- Live Activity and widget work remains throttled/coalesced.
- Historical processing remains resumable and refreshes once at completion.
- Changelog history uses lazy rendering.
- New SQL work stays transactional and indexed by device/window or device/day.

## Compatibility boundaries

- iPhone only; no Android, macOS app, watchOS app, or WatchConnectivity product is restored.
- Existing NOOP Strain and Sleep authority remains intact.
- Oura transport work is outside the iOS 2.1 release gate.
- Experimental WHOOP commands remain opt-in.
- Existing databases must migrate without destructive reset.

## Automated coverage added

### StrandAnalytics

- high-HR automatic rejection followed by bounded recovery;
- short sleep recovery;
- sparse motion without fabricated stages;
- motion-only rejection;
- no-data and invalid-window behavior;
- DST spring-forward elapsed-time behavior;
- stage totals, Rest, and baseline readiness.

### WhoopStore

- recovery migration and index coverage;
- atomic replacement and rollback;
- overlap protection;
- idempotent reprocessing;
- partial-session persistence;
- durable audit provenance;
- overlay survival across engine writes/deletes;
- session-delete cleanup;
- device privacy deletion.

### iOS

- missed-sleep empty-state routing;
- default last-night time seed.

## Required simulator QA

1. Generate the Xcode project and build `NOOPiOS` warning-clean.
2. Run all retained Swift package test suites.
3. Run the complete `NOOPiOSTests` target.
4. Open Settings → What's New and verify the iOS 2.1 card at normal and maximum Dynamic Type.
5. Validate VoiceOver order and labels on the release card and missed-sleep recovery flow.
6. Validate Retry Detection success and failure states.
7. Validate a dense-data manual window creates one session and refreshes Sleep, Today, Rest, and Charge.
8. Validate sparse motion preserves only defensible vitals and does not fabricate stages/Rest.
9. Validate invalid, future, shorter-than-30-minute, and longer-than-16-hour windows are blocked.
10. Validate repeated submission is idempotent and edited-session overlap is refused.
11. Edit and delete a recovered session, force a rescore, and confirm persistence/cleanup behavior.
12. Relaunch the app and verify the recovered result survives.
13. Review the SpO₂ Candidate (Beta) presentation and confirm it does not appear in canonical health surfaces.
14. Review workout heart-rate recovery with complete, incomplete, and duplicate-callback fixtures.

## Required physical-device QA

- WHOOP 4.0 and WHOOP 5/MG connect, reconnect, background, clock-recovery, and backfill behavior.
- Real missed-night recovery with recorded strap data.
- Long workout ingestion and post-workout HR recovery.
- Locked/background/killed app behavior and Live Activity lifecycle.
- HealthKit read/write boundaries and deletion reconciliation.
- Backup, restore, export, and delete-all-data.
- VoiceOver, Switch Control, maximum Dynamic Type, Reduce Motion, light/dark mode, and 12/24-hour time.

## Current verification limitation

The connected environment can inspect and modify the private GitHub repository but cannot clone it or run Xcode because outbound DNS and macOS simulator access are unavailable. Repository GitHub Actions have also been failing before checkout. Source-level audit and test additions are included, but compilation and simulator results must be recorded from a working macOS/Xcode environment.
