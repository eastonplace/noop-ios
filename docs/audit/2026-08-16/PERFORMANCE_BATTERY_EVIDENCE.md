# Performance and battery evidence

## Measured

- Existing WHOOP history-ingest performance gate passed in `WhoopProtocol`: 35 frames, p50 3.427 ms, p95 3.598 ms, max 3.732 ms.
- Simulator build and test completed without compiler warnings or errors.

## Preserved policy

- Continuous HRV remains opt-in.
- Low-battery policy remains unchanged.
- One WHOOP BLE owner remains in place.
- Current-day refresh remains separate from full-history work.
- No new observable-owner split was introduced without measurement.

## Not measured

The following requested evidence requires a physical device and was not available:

- Foreground energy and wakeup cost.
- Overnight background delivery and wakeups.
- Reconnect radio/thermal behavior.
- History catch-up energy and duration.
- Widget publication latency and App Group durability on the installed app.

These are open qualification gates, not inferred passes.
