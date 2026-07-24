# RyanBR NOOP v9.1 WHOOP backend sync

This document is the compatibility contract and implementation inventory for **Noop iOS 2.1**.

The release line selectively synchronizes the retained iPhone WHOOP protocol, storage, import, and analytics backend with relevant behavior from [`ryanbr/noop`](https://github.com/ryanbr/noop) **v9.1.0**. It is not a wholesale source import and it does not replace NOOP iOS's product architecture.

Oura work is explicitly **out of scope for the 2.1 release gate**. Experimental Oura primitives already present on the branch may remain isolated, but they are not represented as completed 2.1 behavior and do not block WHOOP qualification.

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
3. Import new independent WHOOP metrics and protocol facts only when they do not silently change those authorities.
4. Keep WHOOP 5.0/MG behavior explicitly experimental where the upstream evidence is experimental.
5. A sent command is never presented as confirmed device state without readback evidence.
6. The v18 byte-82 SpO₂ candidate may appear only in a **separate, explicitly labelled experimental beta surface**. It must never populate canonical `spo2Pct`, HealthKit, Recovery, illness detection, or an unqualified medical/health claim.
7. Keep all biometric processing local and on-device.
8. Keep this repository iPhone-only. Do not restore Android, watchOS, or the retired macOS app.
9. GitHub Actions is not used as evidence for this release line.

## Implemented end to end

### Real WHOOP journal Boolean compatibility

The import coordinator recognizes the real WHOOP `Answered yes` column (`answered_yes` after header normalization) for both explicit and auto-detected WHOOP imports. TRUE/FALSE values remain verbatim and flow through the existing local journal persistence and correlation path.

The current compatibility pass is intentionally bounded, but folding `answered_yes` directly into the core WHOOP CSV parser remains a useful cleanup to remove the second parse of the journal file.

### Seeded WHOOP generation correction

Older stores seeded a generic `model = "WHOOP"` registry row. After a real WHOOP connection settles and the transport has selected the hardware family, the app corrects only that generic row to either `WHOOP 4.0` or `WHOOP 5.0 / MG`.

The repair now:

- captures the connected peripheral and family evidence before its async store open;
- aborts if that connection evidence changes;
- performs the generic-model predicate atomically inside the database update;
- reports success only when exactly one generic row changed;
- never overwrites an already-specific model label.

This repairs generation-sensitive interpretation, including skin-temperature scaling, without sending a command or changing the active device.

### WHOOP 5 raw-IMU storage helpers

The existing verified 100 Hz 6-axis decoder exposes the exact six signed i16 wire columns and a timestamp-only read. All three interpretations now share the complete frame-shape validator, so an unrelated long frame cannot be accepted merely because it has bytes at the timestamp offset.

### WHOOP 5/MG byte-82 experimental SpO₂ candidate

The v18 parser exposes raw byte 82. The historical-stream path classifies it through `Whoop5V18SpO2Candidate` and accepts it only when:

- the same record reports `sleep_state == 2`;
- the byte is in `70...100`;
- the frame passed the existing decode and CRC gates.

All accepted values from the same minute in one extraction batch are folded into one **order-independent rounded minute mean**. Reversing those frames therefore cannot change the emitted candidate. The compact beta row currently reuses the existing raw SpO₂ storage shape:

- `red` carries the candidate percentage;
- `ir = -82` is an impossible marker that cannot collide with ordinary non-negative WHOOP 4 red/IR ADC channels;
- the normal nightly cache carries the candidate into `DailyMetric.spo2Red` while preserving the `-82` marker in `spo2Ir`.

The Health vitals grid adds a distinct **“SpO₂ Candidate (Beta)”** tile only when such a nightly value exists. It:

- uses an approximate `≈` value marker;
- uses neutral, unvalidated presentation metadata rather than an “in range” state;
- does not show a clinical sparkline or range judgement;
- visibly says the result is experimental and may be inaccurate;
- keeps the ordinary **Blood O₂** tile sourced only from canonical `spo2Pct`;
- tells VoiceOver that it is not used for scoring, HealthKit, or medical decisions.

This is an intentional product decision to expose the candidate honestly rather than hide it. A dedicated experimental storage/export schema and cross-extraction-chunk aggregation remain follow-up work before the value can be considered structurally complete.

## Implemented metric and integration seams

These components are production-quality pure logic with focused tests. Some still require a narrow placement into moving app files after PR #20 is refreshed onto the current PR #19 head.

### Heart-rate recovery

`HeartRateRecovery` calculates signed heart-rate drops at 1, 2, and 5 minutes from the local HR stream. It now requires the **single longest contiguous** Zone-3-or-higher run to meet the two-minute eligibility threshold; disconnected high-intensity bursts cannot add together. It also requires one canonical reading per stored second and at least three distinct seconds around each measurement. Missing coverage remains nil.

The reusable SwiftUI card performs one read for a mature workout and automatically refreshes only at still-pending 1/2/5-minute coverage deadlines when the detail screen was opened immediately after Finish. Its identity includes the workout source because source controls the HR namespace.

The remaining app-file integration is one placement of `WorkoutHeartRateRecoveryCard` in the workout-detail overview.

### Missing-field workout backfill

`WorkoutDetectedBackfill` fills only absent average HR, peak HR, calories, and Strain from a computed overlapping bout. It now fails closed for:

- average HR above peak HR;
- a computed HR value that contradicts an existing real peer;
- nonfinite or out-of-range values;
- stored Strain outside `0...100`;
- computed Strain without explicit version provenance.

Existing manual/imported facts, natural-key identity, route metadata, notes, zones, and score-version ownership remain untouched.

The remaining production integration is a narrow call from the detected-versus-real collision branch in `IntelligenceEngine`.

### Bounded GET_CLOCK recovery policy

`StrapClockRecoveryPlanner` models at most three GET_CLOCK retries followed by one explicitly approximate Data Range fallback when the newest banked timestamp exists and is not materially in the future. A precise clock correlation always wins. The fallback is one-shot per planner generation and reset only for a new connection.

Actual BLE command scheduling and `ClockRef` installation remain a transport-layer wiring task and require a physical strap that drops GET_CLOCK responses.

## Implemented diagnostic-only WHOOP protocol support

### Additional WHOOP GATT families

The v9.1 Puffin-1150, Monument, and Symphony service/characteristic families are represented as metadata. They have no `DeviceFamily`, CLIENT_HELLO, command builder, or write path.

The scan decision now validates that the **selected** family is a known connectable family before applying CoreBluetooth's empty-advertisement exception. Selecting an unsupported or unknown UUID therefore fails closed even when that UUID is advertised or the advertised-service list is empty.

A future broadened diagnostic scan may log these families, but must never connect or command them without independently validated framing.

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
- Configurable bundle/team infrastructure unrelated to WHOOP backend metric compatibility.
- Any canonical or medically presented SpO₂ value sourced from the contested WHOOP 5.0 byte-82 candidate.
- Any command for a newly observed WHOOP GATT family whose framing is not independently validated.
- Oura feature/status, wear, IBI, adoption, or transport work as a Noop iOS 2.1 release requirement.
- Android-only Sleep Schedule rendering fixes; NOOP iOS does not use that rendering path.

## Deferred or device-gated

- Refreshing the feature branch onto the latest moving `release/noop-ios-2.0` head before build qualification.
- Inserting the HR-recovery card into the current workout-detail composition.
- Calling the missing-field workout merge from the current `IntelligenceEngine` collision branch.
- Wiring the clock recovery planner to BLE retries and approximate clock installation.
- Wiring broadened WHOOP service discovery for diagnostic logging only.
- Folding `answered_yes` into the core WHOOP CSV parser and removing the compatibility second pass.
- Replacing the beta candidate's red/IR marker representation with dedicated experimental storage and explicit export columns.
- Aggregating one candidate minute authoritatively across separate extraction/store chunks.
- Adding the upstream `<200 HR samples` sleep-skip log to the current large `IntelligenceEngine` file.
- Adding live HR-at-arm to the current large alarm debug path.
- Physical verification of WHOOP 4.0 and WHOOP 5.0/MG family correction.
- Cross-device comparison of the byte-82 beta tile against official-app readings. The tile remains experimental regardless of a single-device match.
- GET_CLOCK retry/Data Range fallback behavior on a strap that actually drops the response.
- Background execution and post-workout HR coverage on a physical iPhone.

## Verification policy

Run the existing seven iPhone audits plus `Tools/qa/ryanbr_9_1_backend_contract_audit.py`, regenerate with XcodeGen, build and test on an available iPhone simulator, and run all retained Swift packages locally. Exact commands and evidence requirements are in [`docs/qa/noop-ios-2.1-local-verification.md`](qa/noop-ios-2.1-local-verification.md).
