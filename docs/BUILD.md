# Building NOOP for iPhone

NOOP is an iPhone-only, local-first companion for supported WHOOP devices. The app connects over Bluetooth, stores data in SQLite, imports supported WHOOP and Apple Health history, and computes its own metrics on-device.

> **Not affiliated with WHOOP and not a medical device.** Derived metrics are estimates. See [`DISCLAIMER.md`](../DISCLAIMER.md).

## Repository layout

```text
project.yml             XcodeGen source of truth
Strand/                 Shared iOS application code
StrandiOS/              iPhone entry point and iOS integrations
StrandiOSShared/        Models shared with the extension
StrandiOSWidgets/       WidgetKit and Live Activity extension
StrandiOSTests/         iOS tests
Packages/               Protocol, storage, analytics, import, and design packages
```

The repository does not define Android, macOS application, or watchOS application targets. Some packages continue to declare macOS as a **headless SwiftPM test host**; that does not ship a macOS product.

## Requirements

- A Mac running a current Xcode version.
- XcodeGen.
- An iOS 17 or later iPhone simulator or device.

Install XcodeGen:

```bash
brew install xcodegen
```

## Generate the project

The Xcode project is generated and should not be edited by hand:

```bash
xcodegen generate
```

`project.yml` defines exactly three targets:

- `NOOPiOS`
- `NOOPiOSWidgets`
- `NOOPiOSTests`

## Build the app and extension

```bash
xcodebuild \
  -scheme NOOPiOS \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build
```

This builds the iPhone application and its WidgetKit/Live Activity extension.

## Run iOS tests

Choose an installed iPhone simulator:

```bash
xcrun simctl list devices available
```

Then run:

```bash
xcodebuild \
  -scheme NOOPiOS \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  test
```

The test target covers app logic, workout persistence, migration orchestration, repository refresh coalescing, widget/Live Activity policies, and diagnostic-log durability.

## Run package tests

```bash
for package in WhoopProtocol WhoopStore OuraProtocol StrandAnalytics StrandImport StrandDesign; do
  swift test --package-path "Packages/$package"
done
```

The macOS platform declarations in package manifests exist so these headless package tests can run on a Mac without an iOS simulator. They are not application targets.

## Signing and physical devices

Simulator builds disable signing. A physical iPhone build requires a valid personal or team signing configuration. HealthKit, App Groups, Bluetooth background operation, widgets, and Live Activities must use matching entitlements across the app and extension.

The App Group identifier is defined once in `project.yml` as `APP_GROUP_ID` and is passed into both entitlements and Info.plist values.

## Required production QA

Before removing a performance PR from draft status:

1. Generate the Xcode project from a clean checkout.
2. Build `NOOPiOS` and `NOOPiOSWidgets` with warnings reviewed.
3. Run `NOOPiOSTests` and every package test.
4. Exercise Start, active recording, backgrounding, foregrounding, Finish, save, and restart on a simulator.
5. Run a physical-device workout with a real strap.
6. Verify every incoming HR sample reaches the in-app workout UI.
7. Verify Lock Screen/Dynamic Island BPM cadence and immediate workout-end transition.
8. Compare final calories, zones, Strain, sample count, and saved workout output with the baseline build.
9. Inspect CPU, memory, hangs, main-thread work, App Group writes, WidgetKit reloads, ActivityKit updates, and persistence writes.
10. Keep the pull request draft if Apple build or physical-device evidence is unavailable.

## Generated and private files

Do not commit:

- generated Xcode projects or build products;
- signing material or API keys;
- real WHOOP or Apple Health exports;
- SQLite databases;
- unsanitized Bluetooth captures or logs containing personal identifiers.
