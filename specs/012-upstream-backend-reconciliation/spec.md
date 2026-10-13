# Spec 012 — Upstream iPhone Backend Reconciliation

## Goal

Reconcile the private NOOP iPhone/shared Swift backend from the `8.2.2` lineage through released upstream `9.0.1`, plus the two immutable Apple hotfixes selected by the attached implementation package, without replacing the Paper UI or damaging private data, coaching, signing identity, or component work.

## Source contract

- Private target: `42b868f5d7c580d55848592a3aaacb2e0ea11963`
- Common ancestor: `f099af097f88827b987fadaf0843326c0c793f8e`
- Released upstream: `25eb933a2563d490583ecd4c0051dff581874bb8`
- R22 correction: `f5f64977b9a83b2e74dccfee21daaeb5e7089a45`
- Recording-strap workout correction: `6a285e258c2443a2be64cbcb5eda9796878670e4`
- Authoritative package: `references/NOOP_Codex_Implementation_Package.md`
- Package SHA-256: `c16e9a4bfb9229650604b650296f8fcf90c00add129d5e1c339dea97a73a358e`

## Required outcomes

- Preserve private Paper screens, component library, coaching migrations/tables, demo-store isolation, team, App Group, bundle IDs, Stress/Sleep routes, and existing data.
- Add private migrations `v25-daily-spo2-raw`, `v26-rr-seq`, `v27-efficiency-heal`, and `v28-ppg-waveform` after private `v23`/`v24`.
- Preserve equal same-second R-R intervals with deterministic replay-safe sequence keys and gap-aware RMSSD/pNN50.
- Integrate released protocol, BLE, collection, storage, analytics, import/export, HealthKit, backup, identity, and diagnostic correctness from the package allowlist.
- End the WHOOP 5/MG R22 sequence with `enable_sig12 = 0x31` and reconcile detected workout HR from its recording strap.
- Wire Paper Today refresh through the existing central BLE `syncNow` gate and add Paper-compatible strap-battery power controls.
- Set private version/build to `9.0.1` / `204` without publishing an AltStore update.

## Exclusions

Android, Oura cloud, Polar/Huami/Garmin/Xiaomi additions, upstream Liquid/StrandDesign redesign, localization sweeps, telemetry, accounts, servers, firmware blobs, and all post-release commits except the two pinned hotfixes.

## Acceptance

All applicable checks in the package definition of done must pass. Hardware-only or live-HealthKit checks that cannot be safely executed must be labeled `UNVERIFIED`, never inferred from compilation.
