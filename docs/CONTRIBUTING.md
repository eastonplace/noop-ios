# Contributing to NOOP for iPhone

NOOP is an iPhone-only, offline companion for supported WHOOP straps. The current product consists of the `NOOPiOS` app, `NOOPiOSWidgets`, `NOOPiOSTests`, and reusable Swift packages. The repository does not ship Android, macOS app, or watchOS clients.

> NOOP is independent interoperability software, is not affiliated with WHOOP, and is not a medical device. Preserve the credits in [ATTRIBUTION.md](../ATTRIBUTION.md) and the limits in [DISCLAIMER.md](../DISCLAIMER.md).

## Ground rules

1. Keep biometric data local unless a user explicitly invokes and configures the optional AI Coach.
2. Never send unreviewed or destructive commands to physical hardware.
3. Keep protocol and analytics behavior deterministic and testable.
4. Preserve compatibility with existing iPhone databases and exports unless a migration is part of the change.
5. Do not commit real health data, personal identifiers, device captures, signing material, or secrets.

## Repository layout

```text
project.yml             XcodeGen source of truth
Strand/                 Shared iPhone application code
StrandiOS/              iPhone entry point and iOS integrations
StrandiOSShared/        App/extension shared models
StrandiOSWidgets/       WidgetKit and Live Activity extension
StrandiOSTests/         iOS app tests
StrandTests/            Shared app-logic tests compiled by NOOPiOSTests
Packages/               Protocol, persistence, analytics, import, and design packages
Tools/                  Release, source-audit, localization, and protocol utilities
```

Linux protocol-capture utilities and macOS SwiftPM host declarations are intentionally retained. They are development/test infrastructure, not shipped application targets.

## Where changes belong

| Concern | Location |
|---|---|
| BLE frames, CRC, commands, decoded values | `Packages/WhoopProtocol` |
| SQLite migrations, streams, cached records | `Packages/WhoopStore` |
| Recovery, strain, sleep, HRV, projections | `Packages/StrandAnalytics` |
| WHOOP/Apple Health and file import | `Packages/StrandImport` |
| Shared SwiftUI tokens and components | `Packages/StrandDesign` |
| iPhone app behavior, Bluetooth, screens | `Strand/`, `StrandiOS/` |
| Widgets and Live Activities | `StrandiOSWidgets/`, `StrandiOSShared/` |

Package code must not gain app-layer state or CoreBluetooth dependencies. Platform guards that keep reusable packages portable are allowed even when NOOP itself ships only on iPhone.

## Build and test

Install XcodeGen, generate the project, then build the iPhone scheme:

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

Run a package directly while iterating:

```bash
swift test --package-path Packages/StrandAnalytics
```

Run `NOOPiOSTests` on an available iPhone simulator before marking app work ready. Device-dependent Bluetooth, HealthKit, background execution, widgets, Live Activities, and signing behavior require proportionate physical-iPhone verification.

## BLE safety

- Treat the strap as real hardware, not a mock transport.
- Route writes through the existing command allowlist and readiness checks.
- Keep device-family distinctions explicit.
- Add parser/encoding fixtures before changing byte layouts.
- Record whether validation covered WHOOP 4, WHOOP 5/MG, or both.

## Database changes

Add forward-only migrations with deterministic tests. Verify upgrade from the previous schema, idempotent reopen, and preservation of existing data. Do not silently reinterpret persisted keys just to simplify a new implementation.

## UI changes

Use `StrandDesign` tokens and components. Validate the actual iPhone surface at supported Dynamic Type sizes, with VoiceOver for interactive controls, and include screenshot evidence for visual changes.

## Pull-request checklist

- [ ] `xcodegen generate`
- [ ] affected package tests
- [ ] `NOOPiOS` simulator build
- [ ] `NOOPiOSTests` when app code changed
- [ ] source audits and `git diff --check`
- [ ] physical iPhone/strap evidence where behavior depends on hardware
- [ ] no generated projects, secrets, or personal health data
