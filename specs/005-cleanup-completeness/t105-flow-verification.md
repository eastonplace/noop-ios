# T105 record and inspect verification

Runtime: iPhone 17 Pro Max, `--demo-seed`.

## Before relocation

- T104 Live rendered the original Session controls: Start workout, Refresh, and HRV reading.
- Source trace confirmed their production actions were `showStartSport = true`,
  `model.getBattery()`, and `showHRVSnapshot = true` respectively.
- Simulator CoreBluetooth is unavailable, so the original buttons correctly rendered disabled; the
  existing `preworkout` and `liveworkout` demo routes confirmed the current workout destination.

## After relocation

- Record workout opened the current Paper pre-workout sheet, Start Other created an active workout,
  and the current `LiveWorkoutView` opened with a running timer and Finish control.
- Finish ended the workout and returned to Test Centre with Record workout available again.
- Inspect HRV opened `HRVSnapshotView`; its close control and disconnected-state guidance rendered.
- Refresh strap still calls `model.getBattery()` and the Stream Log still exposes Copy and Save.
- The simulator-only `--demo-seed` allowance enables these destinations for QA; Release keeps the
  original bonded-strap gate.

Evidence: [Test Centre full page and interactions](qa/t105-testcentre/),
[clean Live screen](qa/t105-live/).
