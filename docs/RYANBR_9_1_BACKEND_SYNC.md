# RyanBR NOOP v9.1 backend sync

This document is the compatibility contract for **Noop iOS 2.1**.

The release line is syncing the retained iPhone protocol, storage, import, and analytics backend with the relevant behavior in [`ryanbr/noop`](https://github.com/ryanbr/noop) **v9.1.0**. It is not a wholesale code import and it does not replace NOOP iOS's product architecture.

## Upstream reference

- Repository: `ryanbr/noop`
- Release tag: `v9.1.0`
- Release commit: `3679751`
- Integration branch: `release/noop-ios-2.1`
- Stacked base: `release/noop-ios-2.0`

## Compatibility rules

1. Preserve NOOP iOS's current authoritative Strain implementation and stored-score versioning.
2. Preserve NOOP iOS's current Sleep scoring, editing, snapshot, and presentation authority.
3. Import new independent metrics and protocol facts only when they do not silently change those authorities.
4. Keep WHOOP 5.0/MG behavior explicitly experimental where the upstream evidence is experimental.
5. A sent command is never presented as confirmed device state without readback evidence.
6. The v18 byte-82 SpO₂ candidate remains **instrumentation only**. It must not populate `spo2Pct`, HealthKit, Recovery, illness detection, or any user-facing oxygen metric.
7. Keep all biometric processing local and on-device.
8. Keep this repository iPhone-only. Do not restore Android, watchOS, or the retired macOS app.

## v9.1 inventory

### Adopt in Noop iOS 2.1

- Heart-rate recovery at 1, 2, and 5 minutes after an eligible workout, derived from the existing local HR stream.
- Missing-field backfill for a manually entered workout when the detector already computed HR, peak, calories, or Strain for the overlapping bout.
- Real WHOOP journal export support for the `Answered yes` column.
- Seeded paired-device model correction so WHOOP 4.0 and WHOOP 5.0/MG use the correct device-family behavior and temperature scale.
- WHOOP 5.0 v18 byte-82 SpO₂ candidate decode as diagnostic instrumentation only.
- WHOOP 5.0 raw-IMU storage helpers added upstream in v9.1.
- Relevant GATT-family and data-range diagnostics that can be added without speculative commands.
- Oura feature-status/wear diagnostics where they remain read-only and do not invent offline measurements.

### Already present or independently superseded

- HRV readiness.
- WHOOP 5.0 raw IMU decoding and feature extraction.
- Wrap-aware step-counter derivation.
- Motion-aware wake refinement.
- Coarse workout-type classification.
- NOOP iOS's newer Strain, Sleep, Trends, alarm, workout-runtime, and local persistence architecture.

### Intentionally not copied

- Upstream Android, watchOS, and retired macOS application work.
- Upstream UI rewrites that conflict with the retained iPhone interface.
- Upstream Recovery/Strain/Sleep formula replacements where NOOP iOS already has a newer authoritative model.
- Configurable bundle/team infrastructure unrelated to backend metric compatibility.
- Any production SpO₂ metric sourced from the contested WHOOP 5.0 byte-82 candidate.

### Deferred or device-gated

- Physical verification of WHOOP 4.0 and WHOOP 5.0/MG family detection.
- Cross-device validation of the SpO₂ candidate against the official app.
- Oura ring feature-status and IBI behavior on real hardware.
- Background execution and post-workout HR coverage on a physical iPhone.

## Verification policy

GitHub Actions is not used as evidence for this release line. Verification is performed from an exact checked-out head with the repository audits, XcodeGen, iOS simulator build/tests, retained Swift-package tests, and physical-device checks where hardware is required.
