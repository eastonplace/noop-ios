<p align="center">
  <img src="docs/assets/logo-v3.png" alt="NOOP" width="72">
</p>

<h1 align="center">NOOP for iPhone</h1>

<p align="center"><b>Your strap. Your data. Your iPhone. Offline, on-device, no cloud.</b></p>

<p align="center">
  <img alt="Platform: iOS" src="https://img.shields.io/badge/platform-iOS%2017%2B-E8B84B?style=flat-square">
  <img alt="Release line" src="https://img.shields.io/badge/release-iOS%202.1%20RC-E8B84B?style=flat-square">
  <img alt="Local first" src="https://img.shields.io/badge/local-first-E8B84B?style=flat-square">
  <img alt="Account free" src="https://img.shields.io/badge/account-free-C8902F?style=flat-square">
  <img alt="WHOOP 4 and 5" src="https://img.shields.io/badge/works%20with-WHOOP%204.0%20%26%205.0-6B737B?style=flat-square">
</p>

NOOP is an independent iPhone app for reading supported WHOOP data directly over Bluetooth, storing it locally, and calculating health and workout metrics on-device. It does not require a WHOOP cloud account for its local features.

> **Not affiliated with WHOOP.** NOOP is an independent interoperability project. Use it only with hardware and data you own. It is not a medical device; derived metrics are estimates, not clinical measurements.

## NOOP iOS 2.1 release candidate

The unified iOS 2.1 release line combines the WHOOP backend compatibility work previously tracked in PR #20 with the missed-sleep recovery work previously tracked in PR #21. The consolidated release branch is `release/noop-ios-2.1-rc`.

### Live release-candidate features

- **Recover missed sleep:** retry automatic detection or set an approximate sleep window. NOOP reviews recorded HR, R-R, respiration, and motion inside that window and keeps unsupported stages or vitals unknown.
- **Stronger WHOOP 5/MG compatibility:** stricter protocol-family validation, improved model identification, raw-frame protections, bounded import compatibility, and opt-in deep-data experiments.
- **Experimental SpO₂ Candidate:** a separate, explicitly labelled beta surface for selected WHOOP 5/MG evidence. It never feeds canonical Blood Oxygen, Apple Health, Charge, illness detection, widgets, or medical claims.
- **Reliability and privacy hardening:** additional bounded processing, local persistence, migration, deletion, accessibility, and performance protections across sleep, imports, widgets, and background execution.

### Live recovery and reliability features

- **Workout heart-rate recovery:** eligible workout details show signed 1-, 2-, and 5-minute drops derived only from recorded post-workout heart-rate samples; NOOP does not interpolate missing coverage.
- **Collision-safe workout backfill:** detector output fills only safe missing fields on the real workout in its owning data namespace and never overwrites user or imported values.
- **Bounded strap clock recovery:** connection-generation resets, timeouts, retries, and fallback diagnostics now use the bounded clock-recovery planner.

Automated and simulator qualification is recorded, but the release remains a **draft release candidate** until physical WHOOP/iPhone and assistive-technology release gates are recorded. See [`docs/releases/NOOP_IOS_2_1.md`](docs/releases/NOOP_IOS_2_1.md) for complete scope, exclusions, and QA requirements.

## Platform scope

This repository intentionally targets **iPhone only**:

- `NOOPiOS` — the iPhone application.
- `NOOPiOSWidgets` — Home Screen widgets and Live Activities.
- `NOOPiOSTests` — iOS unit and integration tests.
- Shared Swift packages used by those iOS targets.

There is no Android application, macOS application, watchOS companion application, or WatchConnectivity bridge in the current product scope. Apple Health remains an optional **iPhone-side HealthKit data source** and does not require a NOOP watch app.

## Core behavior

- Live workout BPM and zone feedback receive every accepted heart-rate sample.
- Lock Screen and Dynamic Island BPM updates are coordinated at approximately two-second cadence.
- Expensive Live Activity calculations are incremental and bounded.
- Widget publication is semantic-change guarded and separately throttled.
- Workout recovery snapshots and diagnostic-log durability are serialized off the interactive UI path.
- Historical migrations analyze in resumable chunks and perform one final repository refresh.
- SQLite and local files remain compatible with existing iOS data.
- User-corrected sleep is preserved through later synchronization and rescoring.

## Upstream backend baseline

**NOOP iOS 2.1** selectively synchronizes relevant **WHOOP backend behavior** with [`ryanbr/noop`](https://github.com/ryanbr/noop) **v9.1.0** while keeping this repository's newer iPhone interface and authoritative Strain and Sleep models. Oura transport work is not part of the NOOP iOS 2.1 release gate.

This is a compatibility sync, not a wholesale fork update. The WHOOP 5.0/MG v18 byte-82 SpO₂ candidate is surfaced only as a **separate, explicitly labelled experimental beta value** when qualifying sleeping data exists. It remains unvalidated across devices and never populates canonical Blood O₂, HealthKit, Charge, illness detection, or any medical decision path. See [`docs/RYANBR_9_1_BACKEND_SYNC.md`](docs/RYANBR_9_1_BACKEND_SYNC.md) for the adopted, already-present, excluded, and device-gated inventory.

## Build from source

Requirements:

- macOS with a current Xcode installation.
- XcodeGen.
- iOS 17 or later simulator/device.

```bash
brew install xcodegen
xcodegen generate
xcodebuild \
  -scheme NOOPiOS \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build
```

To run tests, select an available iPhone simulator and execute:

```bash
xcodebuild \
  -scheme NOOPiOS \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  test
```

The generated `.xcodeproj` is not committed. `project.yml` is the source of truth.

## Architecture

```text
Bluetooth / HealthKit samples
            │
            ▼
High-frequency ingestion
            │
            ├── immediate in-app workout state
            ├── incremental workout metrics
            ├── serialized persistence
            ├── coalesced Live Activity updates
            └── throttled widget publication
```

Important directories:

```text
Strand/                 Shared iOS application code
StrandiOS/              iPhone entry point and iOS integrations
StrandiOSWidgets/       WidgetKit and Live Activity extension
StrandiOSShared/        Shared app/extension models
StrandiOSTests/         iOS tests
Packages/               Reusable protocol, storage, analytics, import, and design packages
```

## Privacy

Biometric data is stored and processed locally. The optional AI Coach is the only feature designed to make a network request, and only when configured by the user with their own provider credentials. See [`docs/PRIVACY_SECURITY.md`](docs/PRIVACY_SECURITY.md) and [`DISCLAIMER.md`](DISCLAIMER.md).

## Protocol, release, and contribution notes

- iOS 2.1 release notes: [`docs/releases/NOOP_IOS_2_1.md`](docs/releases/NOOP_IOS_2_1.md)
- Protocol documentation: [`docs/PROTOCOL.md`](docs/PROTOCOL.md)
- iOS notes: [`docs/IOS.md`](docs/IOS.md)
- Performance roadmap: [`docs/PERFORMANCE_STABILIZATION_PLAN.md`](docs/PERFORMANCE_STABILIZATION_PLAN.md)
- RyanBR v9.1 WHOOP compatibility: [`docs/RYANBR_9_1_BACKEND_SYNC.md`](docs/RYANBR_9_1_BACKEND_SYNC.md)
- License: [`LICENSE`](LICENSE)

Do not commit real health exports, captures containing personal identifiers, databases, signing credentials, API keys, or generated build products.
