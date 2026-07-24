<p align="center">
  <img src="docs/assets/logo-v3.png" alt="NOOP" width="72">
</p>

<h1 align="center">NOOP for iPhone</h1>

<p align="center"><b>Your strap. Your data. Your iPhone. Offline, on-device, no cloud.</b></p>

<p align="center">
  <img alt="Platform: iOS" src="https://img.shields.io/badge/platform-iOS%2017%2B-E8B84B?style=flat-square">
  <img alt="Local first" src="https://img.shields.io/badge/local-first-E8B84B?style=flat-square">
  <img alt="Account free" src="https://img.shields.io/badge/account-free-C8902F?style=flat-square">
  <img alt="WHOOP 4 and 5" src="https://img.shields.io/badge/works%20with-WHOOP%204.0%20%26%205.0-6B737B?style=flat-square">
</p>

NOOP is an independent iPhone app for reading supported WHOOP data directly over Bluetooth, storing it locally, and calculating health and workout metrics on-device. It does not require a WHOOP cloud account for its local features.

> **Not affiliated with WHOOP.** NOOP is an independent interoperability project. Use it only with hardware and data you own. It is not a medical device; derived metrics are estimates, not clinical measurements.

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

## Upstream backend baseline

**Noop iOS 2.1** synchronizes the relevant retained backend behavior with [`ryanbr/noop`](https://github.com/ryanbr/noop) **v9.1.0** while keeping this repository's newer iPhone interface and authoritative Strain and Sleep models.

This is a selective compatibility sync, not a wholesale fork update. Experimental upstream signals stay experimental: in particular, the WHOOP 5.0 v18 byte-82 SpO₂ candidate is diagnostic instrumentation only and is not exposed as a health metric. See [`docs/RYANBR_9_1_BACKEND_SYNC.md`](docs/RYANBR_9_1_BACKEND_SYNC.md) for the adopted, already-present, excluded, and device-gated inventory.

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

## Protocol and contribution notes

- Protocol documentation: [`docs/PROTOCOL.md`](docs/PROTOCOL.md)
- iOS notes: [`docs/IOS.md`](docs/IOS.md)
- Performance roadmap: [`docs/PERFORMANCE_STABILIZATION_PLAN.md`](docs/PERFORMANCE_STABILIZATION_PLAN.md)
- RyanBR v9.1 backend compatibility: [`docs/RYANBR_9_1_BACKEND_SYNC.md`](docs/RYANBR_9_1_BACKEND_SYNC.md)
- License: [`LICENSE`](LICENSE)

Do not commit real health exports, captures containing personal identifiers, databases, signing credentials, API keys, or generated build products.
