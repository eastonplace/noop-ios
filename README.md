<p align="center">
  <img src="docs/assets/logo-v3.png" alt="NOOP logo" width="76">
</p>

<h1 align="center">NOOP</h1>

<p align="center"><strong>Your strap. Your data. Your iPhone.</strong></p>

<p align="center">
  <img alt="Platform: iOS 17+" src="https://img.shields.io/badge/platform-iOS%2017%2B-E8B84B?style=flat-square">
  <img alt="Local-first" src="https://img.shields.io/badge/local--first-E8B84B?style=flat-square">
  <img alt="Account free" src="https://img.shields.io/badge/account--free-C8902F?style=flat-square">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white">
</p>

NOOP is an independent iPhone app for reading supported WHOOP data over Bluetooth, storing it locally, and calculating health and workout metrics on-device. Local features do not require a WHOOP cloud account.

> NOOP is an independent interoperability project. It is not affiliated with WHOOP. It is not a medical device, and derived metrics are estimates rather than clinical measurements.

## Why this project matters

NOOP is a systems-heavy product. It combines a high-frequency Bluetooth connection with a privacy-first data model and a native iPhone experience.

- **Protocol compatibility:** model identification, protocol-family validation, bounded strap-clock recovery, raw-frame protections, retries, and timeout diagnostics.
- **On-device product behavior:** workout BPM and zones, Lock Screen and Dynamic Island updates, WidgetKit, Live Activities, HealthKit input, and local persistence.
- **Reliable data repair:** missed-sleep recovery, collision-safe workout backfill, resumable history migrations, and user-corrected sleep that survives later synchronization.
- **Trust in the data:** missing coverage stays missing, unsupported values stay unknown, and imported or user-owned values are not silently overwritten.

## Product surface

| Surface | What it does |
| --- | --- |
| Live workouts | Shows heart rate, zones, elapsed time, and workout state from accepted samples. |
| Sleep history | Loads canonical history, supports missed-sleep recovery, and preserves corrections. |
| Recovery metrics | Calculates bounded, traceable metrics from recorded data. |
| Widgets and Live Activities | Publishes useful state without blocking the interactive UI path. |
| Privacy controls | Keeps biometric data local and supports export and deletion workflows. |

## Architecture

~~~text
WHOOP strap / HealthKit
          |
          v
Bounded sample ingestion
          |
          +--> immediate workout state
          +--> incremental metrics
          +--> local persistence
          +--> Live Activity updates
          +--> throttled widget publication
          |
          v
SwiftUI views and historical projections
~~~

The code is organized around a shared domain layer and separate iPhone and WidgetKit targets.

- <code>Strand/</code> contains shared application code.
- <code>StrandiOS/</code> contains the iPhone entry point and iOS integrations.
- <code>StrandiOSWidgets/</code> contains widgets and Live Activities.
- <code>StrandiOSShared/</code> contains shared app and extension models.
- <code>Packages/</code> contains reusable protocol, storage, analytics, import, and design packages.
- <code>StrandiOSTests/</code> contains iOS tests.

## Status

The current release line is an **iOS 2.1 release candidate**. Automated and simulator qualification is recorded. Physical WHOOP/iPhone behavior and assistive-technology release gates remain open.

See the [iOS 2.1 release notes](docs/releases/NOOP_IOS_2_1.md) for the exact scope and remaining gates.

## Build from source

Requirements:

- macOS with Xcode
- XcodeGen
- iOS 17 or later simulator or device

~~~bash
brew install xcodegen
xcodegen generate

xcodebuild \
  -scheme NOOPiOS \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build
~~~

Run the iOS test suite on an installed simulator:

~~~bash
xcodebuild \
  -scheme NOOPiOS \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  test
~~~

<code>project.yml</code> is the XcodeGen source of truth. Do not commit real health exports, personal captures, databases, signing credentials, API keys, or generated build products.

## Read more

- [Protocol notes](docs/PROTOCOL.md)
- [Privacy and security](docs/PRIVACY_SECURITY.md)
- [iOS notes](docs/IOS.md)
- [Performance roadmap](docs/PERFORMANCE_STABILIZATION_PLAN.md)
- [Backend compatibility sync](docs/RYANBR_9_1_BACKEND_SYNC.md)
- [License](LICENSE)
