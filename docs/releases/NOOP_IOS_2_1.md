# NOOP iOS 2.1 — Unified Release Candidate

Branch: `release/noop-ios-2.1-rc`

Status: **Draft release candidate. Do not merge until remaining integration, simulator, and physical-device QA pass.**

## Release purpose

NOOP iOS 2.1 combines two previously stacked workstreams into one review and qualification line:

1. WHOOP backend compatibility and protocol hardening from former PR #20.
2. Bounded missed-sleep recovery from former PR #21.

The unified branch includes the qualified `main`/iOS 2.0 head and both 2.1 histories. It has no stacked PR dependency.

## Live user-visible changes

### Recover a missed night

When NOOP cannot confidently detect a night, the Sleep empty state offers:

- **Retry automatic detection** to run a fresh normal analysis pass.
- **Set the sleep window** to provide approximate bedtime and wake boundaries.

The interval is a search constraint, not a declaration that every minute was sleep. NOOP derives stages, resting HR, HRV, Rest, and Charge only from recorded evidence. Sparse motion can preserve real overnight vitals while leaving stages and Rest unavailable.

### WHOOP 5/MG compatibility

The live release candidate includes stricter family detection, model correction, raw-frame validation, bounded journal compatibility, and opt-in experimental controls. Unsupported or unknown protocol families fail closed.

### SpO₂ Candidate (Beta)

Selected WHOOP 5/MG sleep records can produce a separately labelled approximate candidate value. It is isolated from canonical Blood Oxygen, Apple Health, Charge, Rest, illness detection, widgets, Trends, alerts, and medical claims.

## Included foundations still requiring live integration

The branch contains tested engines and presentation foundations for:

- signed 1-, 2-, and 5-minute workout heart-rate recovery;
- conservative missing-field workout backfill;
- bounded strap clock-recovery planning.

The complete-diff audit found that their final production call sites are not all wired. They are therefore not described as shipped user features and remain explicit release gates.

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
- DST spring-forward behavior;
- stage totals, Rest, and baseline readiness;
- heart-rate recovery fixtures;
- missing-workout-field merge validation.

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
- default last-night time seed;
- seeded WHOOP model safeguards.

## Remaining integration gates

1. Place `WorkoutHeartRateRecoveryCard` in the live workout-detail hierarchy.
2. Invoke `WorkoutDetectedBackfill` from the detected-versus-real collision path using the real row's owning namespace.
3. Wire `StrapClockRecoveryPlanner` into the BLE timeout and clock-correlation lifecycle per connection generation.
4. Complete the remaining app-level protocol diagnostics listed in `docs/qa/noop-ios-2.1-implementation-handoff.md`.
5. Reconcile or remove compatibility helpers once equivalent logic is folded into moving core files.

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
12. Relaunch and verify the recovered result survives.
13. Confirm SpO₂ Candidate (Beta) never appears in canonical health surfaces.
14. After live wiring, validate workout HR recovery, workout backfill, and clock recovery end-to-end.

## Required physical-device QA

- WHOOP 4.0 and WHOOP 5/MG connect, reconnect, background, clock, and backfill behavior.
- Real missed-night recovery with recorded strap data.
- Long workout ingestion and post-workout HR recovery after integration.
- Locked/background/killed app behavior and Live Activity lifecycle.
- HealthKit read/write boundaries and deletion reconciliation.
- Backup, restore, export, and delete-all-data.
- VoiceOver, Switch Control, maximum Dynamic Type, Reduce Motion, light/dark mode, and 12/24-hour time.

## Current verification limitation

The connected environment can inspect and modify the private GitHub repository but cannot clone it or run Xcode because outbound DNS and macOS simulator access are unavailable. Repository GitHub Actions have also been failing before checkout. Source-level audit and test additions are included, but compilation and simulator results must be recorded from a working macOS/Xcode environment.
