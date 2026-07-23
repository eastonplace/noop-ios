# NOOP for iPhone — Install and Build

NOOP currently targets iPhone only. `project.yml` defines the `NOOPiOS` application, `NOOPiOSWidgets` extension, and `NOOPiOSTests`; it does not define Android, macOS application, or watchOS targets.

## Install

When an unsigned iPhone `.ipa` is attached to a project release, it can be signed and installed with a sideloading tool under your own Apple ID. Free signing can limit HealthKit, App Groups, widgets, and Live Activities and normally requires periodic refresh. Check the selected release's notes for the artifact and exact requirements.

Do not install artifacts from untrusted mirrors. An unsigned build is not proof of origin by itself.

## Build from source

Requirements:

- A current Xcode installation on macOS.
- XcodeGen.
- An iOS 17 or later simulator/device.

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

The generated Xcode project is disposable; edit `project.yml`, then regenerate.

## Signing a physical iPhone build

Use a development team and bundle identifiers valid for your Apple account. The app and widget extension must use the same App Group. `APP_GROUP_ID` in `project.yml` feeds the matching entitlements and runtime configuration.

Physical-device capabilities require the appropriate provisioning profile and user permissions:

- Bluetooth and background Bluetooth
- HealthKit read/write
- App Groups
- Widgets and Live Activities
- Location for workout routes

Build success, install success, and physical launch are separate verification gates.

## Tests

Select an available iPhone simulator:

```bash
xcrun simctl list devices available
xcodebuild \
  -scheme NOOPiOS \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  test
```

Bluetooth bonding, firmware commands, background execution, HealthKit observer behavior, notification authorization races, and long-running workout recovery need physical-device or targeted fault-injection evidence in addition to simulator tests.

## Source layout

```text
Strand/                 Shared iPhone app implementation
StrandiOS/              iOS entry point and system integrations
StrandiOSShared/        App/extension shared models
StrandiOSWidgets/       WidgetKit and Live Activity extension
StrandiOSTests/         iOS-specific tests
StrandTests/            Shared app tests included by NOOPiOSTests
Packages/               Reusable Swift packages
```

Package manifests retain macOS declarations solely as SwiftPM test-host compatibility. They do not ship a macOS app.
