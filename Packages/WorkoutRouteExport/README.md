# Workout route export

Dependency-free Swift encoders for GPX 1.1 and FIT 2.0 activity files. Run `swift test --package-path Packages/WorkoutRouteExport` from the repository root.

`RouteExporter.render(_:segments:name:sport:)` accepts the original GPS points, with Unix timestamps in milliseconds and optional horizontal accuracy in metres. It rejects empty routes, invalid coordinates/accuracy, and timestamps that do not increase across the complete route. At least one segment must contain two points. Each segment represents an uninterrupted recorded portion.

GPX writes a separate `trkseg` for each portion, preserving millisecond timestamps. Horizontal accuracy uses a NOOP extension in metres; it is never mislabeled as GPX's dimensionless `hdop`. Unmeasured elevation and physiology are omitted. Names and sport labels are escaped as XML 1.0 text.

FIT writes `file_id`, `device_info`, `record`, timer `event`, `lap`, `session`, and `activity` messages, a 14-byte header, and both CRCs. Start/stop events preserve recording gaps. Cumulative GPS distance excludes the gaps. Elapsed time spans the measured recording, while timer time covers only the measured segments. FIT record timestamps have one-second resolution; GPX is the option for millisecond timestamps. FIT's numeric limits cause a descriptive error, rather than clamping dates, duration, or distance. Heart-rate and calorie summaries are not included.

The native app stores measurement segments alongside its existing route polylines and includes them in the existing route backup/deletion lifecycle. Coordinate-only legacy routes remain drawable but do not acquire synthetic timestamps or accuracy. After recovering an older active session, only newly measured portions are eligible for export. Both workout detail's ShareLink and the “Export Workout Route” Shortcuts action use the same export service. The action returns the latest eligible saved route and offers a GPX/FIT choice. It is available in the Shortcuts action catalog; the existing ten top-level App Shortcut registrations are preserved.

Tests parse GPX as XML, decode FIT message definitions independently, verify both CRCs with a separate bitwise implementation, verify the CRC-16/ARC check vector, and cover pause distance, missing accuracy, dateline coordinates, ordering, malformed values, and format bounds. Native tests additionally cover route persistence, v2 active-journal migration/rollback, legacy snapshots, and recorder pause/recovery behavior.

Format references:

- [GPX 1.1 schema](https://www.topografix.com/GPX/1/1/gpx.xsd)
- [Garmin FIT activity file structure](https://developer.garmin.com/fit/articles/file-types/activity.html)
- [Garmin FIT protocol](https://developer.garmin.com/fit/protocol/)

The generated paused-route test fixture was also checked with Garmin's FIT Python SDK 21.218.0: its integrity check passes and it decodes the complete activity without errors. That SDK is a separate validation tool and is not included as a runtime or package dependency.
