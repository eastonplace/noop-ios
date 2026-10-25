# WHOOP 4 background sync and battery refresh

Target: 2.0.4 build 256, stacked after PR82 at d513c7b826e566ebfc8f99fb887a28abb03a1d3b. The installed 2.0.2 source is 823a329ea870650812f4399e80b26e0ba672ee17. PR82's intervening product changes concern Sleep presentation.

## Findings and changes

| Finding | Reproduction | Correction |
| --- | --- | --- |
| A caught-up connection loses its OS history request | A ready eligible WHOOP 4 with no existing debt returns `cancel` instead of its existing periodic deadline | Keep a discretionary maintenance request for the current preferred ready WHOOP 4. Reuse existing power and empty-result floors. |
| An old connection range can clear real pending history | A productive capped or interrupted pass moves beyond the old range and clears durable debt | Clear debt only after a completed tail supplies no fresh sensor receipts. Productive stops retain debt for later bounded attempts. |
| Live WHOOP 4 battery events do not refresh percent | A protocol-valid synthetic 50.5% event leaves the displayed value at 80%; zero also stays ignored | Admit current owned proprietary battery events in the normal and offload routes. Publish charging before percentage so power admission sees the same observation. |
| Explicit Disconnect leaves automatic work queued | A manager with stored debt still reports a scheduled request after Disconnect | Cancel automatic planning immediately while retaining stored debt. Reconnect can resume it. |

Battery admission requires a current connected and bonded physical WHOOP 4 source, explicit envelope and CRC validity, a complete protected payload, a finite percentage from 0 through 100, and a positive raw event timestamp within 45 seconds of callback wall time. Events older than the last accepted observation cannot overwrite a newer command reading. Approximate historical clock mapping is never used to make replay appear fresh. A new owner gets its own observation ordering. The WHOOP 4 standard 2A19 stub remains excluded; WHOOP 5/MG retains its existing source.

An initial command read now waits for the existing connect-settled signal, which requires the command notification confirmation. It skips an active offload; current battery events and the normal poll remain available. Automatic WHOOP 4 polling uses the same refresh path as manual refresh. The empty command body was not diagnosed as a defect: upstream documents both empty and `00` bodies.

Background scheduling follows the successful attempt's absolute deadline and refreshes on power/readiness changes. Intentional stops, reconnect pauses and known future-dated strap ranges cancel automatic planning. Existing radio budgets, secure transport admission, source ownership, active-session deferral and cancellation remain in place.

## Upstream and platform comparison

Current RyanBR reference: [6d750391bda65b99d0d74ef8a0acce2d7188636e](https://github.com/ryanbr/noop/commit/6d750391bda65b99d0d74ef8a0acce2d7188636e), October 25, 2026.

- [Its battery event sink](https://github.com/ryanbr/noop/blob/6d750391bda65b99d0d74ef8a0acce2d7188636e/Strand/BLE/FrameRouter.swift#L471-L490) uses the proprietary event percentage. The local adaptation adds explicit ownership, integrity, range and freshness admission. The upstream change's [original PR1226](https://github.com/ryanbr/noop/pull/1226) still requested physical strap validation.
- [Its command contract](https://github.com/ryanbr/noop/blob/6d750391bda65b99d0d74ef8a0acce2d7188636e/docs/PROTOCOL_COMMANDS.md#L245-L256) records both battery request bodies. Payload normalization is consistency, not hardware proof of the reported defect.
- Existing local immediate background reconnect handoff and locked-store protection already implement the relevant upstream patterns. No replacement of those paths was needed.
- Upstream's stale-battery background scheduler reads a saved value to issue a warning. It does not obtain a new battery reading, so it was not imported as a refresh fix.
- [Apple's Core Bluetooth background guide](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html) describes bounded event wakes and state restoration. Background capability and a submitted request do not guarantee uninterrupted execution or a fixed wake time.

## Verification

The initial native regression run exercised 16 cases. Its expected failures reproduced debt-only cancellation, stale-range debt clearing and ignored battery observations. A separate native regression reproduced queued work after explicit Disconnect. A focused harness using the production scheduling policy reproduced future-clock maintenance eligibility before the final guard.

The initial corrected native batch passed 141 cases. After independent review tightened clock exclusion and initial battery-read placement, 88 affected native cases passed. Battery event and retention code was unchanged by those final review corrections. Coverage includes source/family rejection, invalid CRC and payload bounds, old/future/zero timestamps, invalid percentage, command/event ordering, offload routing, power floors, due-launch admission, cancellation and restoration controls.

Source, HealthKit sync, WHOOP UI and release audits passed. The protected CI lane and remote checks apply to the final PR head. No pending-check merge exception is granted.

## Qualification boundary

The earlier phone inspection showed overnight data incomplete while foreground catch-up advanced. It did not establish the exact iOS suspension or connection state during the reported night. These are reproduced software defects that can contribute to the symptoms; they are not a completed physical overnight test.

No phone installation, live strap command, reset, re-pair, database change or new data export was performed for this follow-up. Fresh physical battery readings, locked overnight sync continuity, and power/watchdog behavior still need device qualification before claiming that the reported runtime symptoms are resolved. No release tag or publication is authorized here.
