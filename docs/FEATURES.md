# NOOP for iPhone — Feature Guide

NOOP is an iPhone-only, local-first companion for supported WHOOP straps. It reads supported data over Bluetooth, stores it in SQLite on the iPhone, imports selected health/history formats, and computes independent health and workout estimates on-device.

There are no Android, macOS app, or watchOS clients in the current product. Historical release notes may describe clients that are no longer present.

> NOOP is not affiliated with WHOOP and is not a medical device. Charge, Strain, Rest, HRV, sleep, calorie, and related values are estimates rather than WHOOP or clinical scores.

## Main iPhone surfaces

- **Today** — daily Charge, Strain, Rest, vitals, recent workouts, and source status.
- **Live** — connection state, current heart rate, strap state, and diagnostic controls.
- **Sleep and Alarms** — sleep history, staging, planning, and the smart-alarm editor/runtime.
- **Workouts** — live recording, zones, route support, summaries, and recovered sessions.
- **Trends** — calendar-aligned history, comparisons, charts, and weekly review.
- **Health and Apple Health** — iPhone-side HealthKit import/write controls and provenance.
- **Settings** — pairing, profile, sources, behavior, diagnostics, backup/restore, and privacy controls.
- **Widgets and Live Activities** — bounded snapshots for the Home Screen, Lock Screen, and Dynamic Island.

## Local-first behavior

- Strap and imported data are stored on the device.
- Analytics run locally.
- Backups are user-initiated files; treat them as sensitive health data.
- The optional AI Coach is the only product surface designed to call a network provider, and only after the user configures and invokes it.

## Hardware and data sources

The app contains protocol support for WHOOP 4 and WHOOP 5/MG paths, plus import and standard-heart-rate integrations documented elsewhere in this repository. Capability depends on the exact device, firmware, permissions, and physical test coverage; unsupported data is shown as unavailable rather than fabricated.

Apple Health is an iPhone-side data source. It does not require or imply a NOOP watchOS companion app.

## More detail

- [Architecture](ARCHITECTURE.md)
- [Analytics](ANALYTICS.md)
- [Build and test](BUILD.md)
- [iPhone install/build](IOS.md)
- [Privacy and security](PRIVACY_SECURITY.md)
- [Protocol notes](PROTOCOL.md)
- [Device support roadmap](DEVICE_SUPPORT_ROADMAP.md)
