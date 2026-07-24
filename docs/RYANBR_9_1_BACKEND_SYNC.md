# RyanBR NOOP v9.1 backend sync

This document is the compatibility contract and implementation inventory for **Noop iOS 2.1**.

The release line selectively synchronizes the retained iPhone protocol, storage, import, and analytics backend with relevant behavior from [`ryanbr/noop`](https://github.com/ryanbr/noop) **v9.1.0**. It is not a wholesale source import and it does not replace NOOP iOS's product architecture.

## Upstream reference

- Repository: `ryanbr/noop`
- Release tag: `v9.1.0`
- Release commit: `3679751`
- Integration branch: `release/noop-ios-2.1`
- Stacked base: `release/noop-ios-2.0`
- Review PR: `#20`

## Compatibility rules

1. Preserve NOOP iOS's current authoritative Strain implementation and stored-score versioning.
2. Preserve NOOP iOS's current Sleep scoring, editing, snapshot, and presentation authority.
3. Import new independent metrics and protocol facts only when they do not silently change those authorities.
4. Keep WHOOP 5.0/MG behavior explicitly experimental where the upstream evidence is experimental.
5. A sent command is never presented as confirmed device state without readback evidence.
6. The v18 byte-82 SpO₂ candidate may appear only in a **separate, explicitly labelled experimental beta surface**. It must never populate canonical `spo2Pct`, HealthKit, Recovery, illness detection, or an unqualified medical/health claim.
7. Keep all biometric processing local and on-device.
8. Keep this repository iPhone-only. Do not restore Android, watchOS, or the retired macOS app.
9. GitHub Actions is not used as evidence for this release line.

## Implemented end to end

### Real WHOOP journal Boolean compatibility

The import coordinator now recognizes the real WHOOP `Answered yes` column (`answered_yes` after header normalization) for both explicit and auto-detected WHOOP imports. TRUE/FALSE values remain verbatim and flow through the existing local journal persistence and correlation path.

### Seeded WHOOP generation correction

Older stores seeded a generic `model = "WHOOP"` registry row. After a real WHOOP connection settles and the existing transport has selected the hardware family, the app corrects only that generic row to either `WHOOP 4.0` or `WHOOP 5.0 / MG`. Specific model labels are never overwritten. This repairs downstream generation-sensitive interpretation, including skin-temperature scaling, without sending a command or changing the active device.

### WHOOP 5 raw-IMU storage helpers

The existing verified 100 Hz 6-axis decoder now also exposes the exact six signed i16 wire columns and a timestamp-only read. The helpers preserve lossless raw values for later storage or analysis and reject wrong-length buffers.

### WHOOP 5/MG byte-82 experimental SpO₂ candidate

The v18 parser already exposes raw byte 82. The historical-stream path now classifies it through `Whoop5V18SpO2Candidate` and, only when the same record reports the band asleep and the byte is 70–100, keeps at most one candidate per minute.

The compact row reuses the existing raw SpO₂ storage shape without changing the database schema:

- `red` carries the candidate percentage.
- `ir = -82` is an impossible marker that cannot collide with ordinary non-negative WHOOP 4 red/IR ADC channels.
- the normal nightly cache averages those minute samples into `DailyMetric.spo2Red` while preserving the `-82` marker in `spo2Ir`.

The Health vitals grid then adds a distinct **“SpO₂ Candidate (Beta)”** tile only when such a nightly value exists. Its caption identifies WHOOP 5/MG and says Experimental beta. It is not banded against a clinical range, does not replace the normal Blood O₂ tile, and its VoiceOver description says it may be inaccurate and is not used for scoring, HealthKit, or medical decisions.

This is an intentional product decision to expose the data honestly rather than hide it, while keeping the uncertainty impossible to miss.

## Implemented metric and integration seams

These components are production-quality pure logic with focused tests. They are intentionally isolated so a local integration pass can wire them into the moving PR #19 base without replacing whole app files through GitHub's contents API.

### Heart-rate recovery

`HeartRateRecovery` calculates signed heart-rate drops at 1, 2, and 5 minutes from the local HR stream. It requires sustained Zone-3-or-higher effort near cessation, one canonical reading per stored second, continuous coverage, and at least three distinct seconds around each measurement. Missing coverage remains nil.

A repository read seam and reusable SwiftUI card are included. The remaining app-file integration is one placement of `WorkoutHeartRateRecoveryCard` in the workout-detail overview after PR #20 is refreshed onto the current PR #19 head.

### Missing-field workout backfill

`WorkoutDetectedBackfill` fills only absent average HR, peak HR, calories, and Strain from a computed overlapping bout. Existing manual/imported facts, natural-key identity, route metadata, notes, zones, and score-version ownership remain untouched.

The remaining production integration is a narrow call from the existing detected-versus-real collision branch in `IntelligenceEngine`; the pure merge and non-overwrite behavior are already tested.

### Bounded GET_CLOCK recovery policy

`StrapClockRecoveryPlanner` models at most three GET_CLOCK retries followed by an explicitly approximate Data Range fallback when the newest banked timestamp exists. A precise clock correlation always wins. Actual BLE command scheduling and `ClockRef` installation remain a transport-layer wiring task and require a physical strap that drops GET_CLOCK responses.

## Implemented diagnostic-only protocol support

### Additional WHOOP GATT families

The v9.1 Puffin-1150, Monument, and Symphony service/characteristic families are represented as metadata with a fail-closed scan decision. They have no `DeviceFamily`, CLIENT_HELLO, command builder, or write path. A future broadened diagnostic scan may log them, but must never connect or command them without independently validated framing.

### Oura feature status

Read-only SpO₂ and real-steps feature-status query builders use the `0x20` read verb. The diagnostic decoder excludes the existing daytime-HR acknowledgement from new status output. No server-gated feature is enabled or represented as an offline measurement.

### Oura wear/charger inference

A pure tracker infers worn, charging, off, or unknown from real live-HR pulses and charger state strings. Banked overnight IBI records are explicitly excluded from current-wear evidence.

### Oura IBI timestamp policy

The policy persists IBI only at a ring-time-derived Unix timestamp when an anchor exists; otherwise it parks the event. It never stamps a banked overnight event at drain-arrival wall time. Transport queue/cursor wiring remains device-gated.

## Already present or independently superseded

- HRV readiness.
- WHOOP 5.0 raw IMU decoding and feature extraction.
- Wrap-aware step-counter derivation.
- Motion-aware wake refinement.
- Coarse workout-type classification.
- NOOP iOS's newer Strain, Sleep, Trends, alarm, workout-runtime, HealthKit, and local persistence architecture.
- Existing iPhone notification permission handling and silent strap-alarm honesty.
- Existing second-strap workout HR routing and source-aware workout detail reads.

## Intentionally not copied

- Upstream Android, watchOS, and retired macOS application work.
- Upstream UI rewrites that conflict with the retained iPhone interface.
- Upstream Recovery, Strain, or Sleep formula replacements where NOOP iOS already has a newer authoritative model.
- Configurable bundle/team infrastructure unrelated to backend metric compatibility.
- Any canonical or medically presented SpO₂ value sourced from the contested WHOOP 5.0 byte-82 candidate.
- Any command for a newly observed WHOOP GATT family whose framing is not independently validated.
- Android-only Sleep Schedule rendering fixes; NOOP iOS does not use that rendering path.

## Deferred or device-gated

- Refreshing the feature branch onto the latest moving `release/noop-ios-2.0` head before build qualification.
- Inserting the HR-recovery card into the current workout-detail composition.
- Calling the missing-field workout merge from the current `IntelligenceEngine` collision branch.
- Wiring the clock recovery planner to BLE retries and approximate clock installation.
- Wiring broadened WHOOP service discovery for diagnostic logging only.
- Wiring Oura status, wear, and anchored IBI queues into the iPhone transport.
- Physical verification of WHOOP 4.0 and WHOOP 5.0/MG family correction.
- Cross-device comparison of the byte-82 beta tile against official-app readings. The tile remains experimental regardless of a single-device match.
- Oura feature-status, IBI, wear, and charger behavior on owned hardware.
- Background execution and post-workout HR coverage on a physical iPhone.

## Verification policy

Run the existing seven iPhone audits plus `Tools/qa/ryanbr_9_1_backend_contract_audit.py`, regenerate with XcodeGen, build and test on an available iPhone simulator, and run all retained Swift packages locally. Exact commands and evidence requirements are in [`docs/qa/noop-ios-2.1-local-verification.md`](qa/noop-ios-2.1-local-verification.md).
