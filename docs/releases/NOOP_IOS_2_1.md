# NOOP iOS 2.1 — Unified Release Candidate

Branch: `release/noop-ios-2.1-rc`

Status: **Draft release candidate. Production wiring and automated/simulator qualification are recorded; do not merge until physical-device WHOOP and assistive-technology gates are recorded.**

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

## Production recovery integrations

- `WorkoutHeartRateRecoveryCard` is in the live workout-detail Overview, after the summary stats and before heart-rate zones.
- `WorkoutDetectedBackfill` runs on the detected-versus-real collision path with the real row's owning namespace; failed persistence retains the detected row and emits a diagnostic.
- `StrapClockRecoveryPlanner` is connected to BLE timeouts, retries, Data Range fallback, and connection-generation resets.
- Unsupported diagnostic GATT scans fail closed before GATT traffic, and approximate clock reference state is cleared on connection reset.

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

## Remaining release gates

1. Exercise WHOOP 4.0 and WHOOP 5/MG connection, reconnect, background, clock recovery, and backfill behavior on physical hardware.
2. Exercise real missed-night recovery, post-workout recovery, and sleep-session editing/recovery with recorded strap data.
3. Complete assistive-technology checks: VoiceOver, Switch Control, maximum Dynamic Type, Reduce Motion, and 12/24-hour time.
4. Recheck the draft PR's hosted CI after the repaired head is published; no earlier failing run is evidence for this head.

## Automated and simulator qualification

Completed on 2026-07-26:

1. Regenerated `Strand.xcodeproj` with XcodeGen.
2. Passed all eight repository source/contract audits.
3. Passed all seven retained Swift package suites: 2,179 tests, zero failures, and one intentional Xiaomi real-database skip.
4. Passed the complete `NOOPiOSTests` simulator target: 210 tests, zero failures or skips.
5. Built and launched `NOOPiOS` on the iPhone 17 Pro simulator.
6. Visually checked populated Today, workout detail, and Sleep flows. The heart-rate recovery card rendered recorded 1-, 2-, and 5-minute drops in both light and dark appearance.

Still required before release are the physical-device and assistive-technology checks listed above. The automated iOS coverage includes recovered-session reprocessing/rekeying, malformed timestamp fail-closed behavior, collision backfill, and bounded clock-recovery contracts.

## Required physical-device QA

- WHOOP 4.0 and WHOOP 5/MG connect, reconnect, background, clock, and backfill behavior.
- Real missed-night recovery with recorded strap data.
- Long workout ingestion and post-workout HR recovery after integration.
- Locked/background/killed app behavior and Live Activity lifecycle.
- HealthKit read/write boundaries and deletion reconciliation.
- Backup, restore, export, and delete-all-data.
- VoiceOver, Switch Control, maximum Dynamic Type, Reduce Motion, light/dark mode, and 12/24-hour time.

## Qualification limitations

The local clone still cannot resolve `github.com`, so the repaired head is published through the GitHub connector rather than `git push`. Physical-device/WHOOP and assistive-technology evidence is deliberately not inferred from simulator results.
