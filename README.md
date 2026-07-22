# NOOP for iPhone

NOOP is an independent, account-free iOS app that reads supported wearable data locally and computes its own health and fitness views on the device.

The repository now targets **iPhone and iPad only**. The iOS widget and Live Activity extension remain part of the product. macOS, watchOS, and Android application products are not part of this codebase.

> NOOP is experimental software, not a medical device. Its scores are local estimates and are not official WHOOP cloud results.

## What it does

- Connects directly to supported wearables over Bluetooth.
- Stores data in a local SQLite database.
- Shows live heart rate and workout feedback.
- Computes local recovery, strain, sleep, HRV, stress, and trend views from available inputs.
- Imports supported wearable and Apple Health exports.
- Publishes a separately throttled Home Screen widget.
- Publishes an approximately two-second Lock Screen / Dynamic Island BPM view while keeping expensive workout projections on a bounded cadence.
- Keeps the active workout screen on the full incoming heart-rate cadence.

## Runtime contract

The performance architecture deliberately separates high-frequency ingestion from slower consumers:

```text
BLE / Health samples
        │
        ▼
Immediate workout ingestion
        │
        ├── in-app BPM and zones: every accepted sample
        ├── incremental workout metrics
        ├── serialized/coalesced persistence
        ├── ActivityKit BPM: approximately every 2 seconds
        ├── expensive Live Activity projection: bounded cadence
        └── WidgetKit publication: separately throttled
```

A slow widget, database write, or ActivityKit operation must not delay the next workout heart-rate sample.

## Supported app targets

| Target | Purpose |
|---|---|
| `NOOPiOS` | Main iPhone/iPad application |
| `NOOPiOSWidgets` | Home Screen widgets and Live Activity UI |
| `NOOPiOSTests` | iOS-hosted unit and regression tests |

Shared Swift packages remain under `Packages/` so protocol, analytics, storage, import, and design logic can be tested independently.

## Requirements

- iOS 17 or later
- Xcode with the required iOS SDK
- XcodeGen
- A physical iPhone for Bluetooth and final performance validation

## Build

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

To run the iOS tests, choose an available iPhone Simulator and run:

```bash
xcodebuild \
  -scheme NOOPiOS \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=latest' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  test
```

The GitHub Actions iOS workflow generates the project, builds the app plus extensions, selects an available iPhone Simulator, and runs `NOOPiOSTests`.

## WHOOP support

### WHOOP 4.0

The established path includes live heart rate, supported history offload, and local analysis from the data NOOP can decode.

### WHOOP 5.0 / MG

Live heart rate is available through the standard Bluetooth heart-rate profile. Deeper history and sensor layouts remain experimental and firmware-dependent.

The optional R22 configuration path only asks the strap to emit richer raw inputs. It does **not** download official recovery, strain, or sleep scores. NOOP computes its own outputs from whatever raw data is actually available.

## Data and privacy

- No NOOP account is required.
- Core wearable processing is local.
- Raw data and derived metrics remain in the app's local storage unless the user explicitly exports them.
- The optional AI Coach is disabled until configured and is the only feature designed to contact a selected model endpoint.
- Debug exports redact supported identifiers before sharing.

See `docs/PRIVACY_SECURITY.md` for the detailed data-flow and threat-model notes.

## Repository layout

```text
StrandiOS/          iOS application shell, HealthKit, system integration
StrandiOSWidgets/   WidgetKit and Live Activity extension UI
StrandiOSShared/    tiny App Group snapshot models shared with the extension
Strand/             iOS application features reused by the app target
Packages/           protocol, storage, analytics, import, and design packages
StrandiOSTests/     iOS-hosted tests
```

## Performance work

The current stabilization roadmap is tracked in:

- `docs/PERFORMANCE_STABILIZATION_PLAN.md`
- `docs/IOS_ONLY_QA_REPORT_2026-07-22.md`

Performance changes stay on draft branches until the iOS build, tests, simulator scenarios, and physical-device workout checks are trustworthy.

## Contributing

Keep changes focused and preserve these invariants:

1. Do not throttle the active workout screen's incoming heart-rate updates.
2. Do not introduce synchronous disk work into high-frequency UI paths.
3. Serialize lifecycle-sensitive writes and ActivityKit mutations.
4. Add regression coverage for races, cancellation, stale generations, and final flush behavior.
5. Do not invent protocol offsets or health fields without real capture evidence.
6. Do not merge performance changes solely because the code looks cleaner; collect behavioral or count-based evidence.

## License and attribution

See `LICENSE` and `ATTRIBUTION.md`.
