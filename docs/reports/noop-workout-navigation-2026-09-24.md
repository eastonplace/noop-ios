# NOOP workout navigation correction

The initial integration retained Lift Receipt's standalone Today/History/Progress/Schedule bottom bar. This correction removes it from the embedded feature.

- NOOP's existing Start a Workout screen now offers Lift weights, in both the Workouts route and quick workout action.
- Lift weights opens a routine picker with all five imported routines, an open workout option, settings, and active-session resume.
- NOOP's Workouts screen owns Lift history, Lift progress and Manage routines destinations.
- Finishing a lift displays its completed summary and links to workout history. The completed session also appears in NOOP's ordinary recent workout list.
- Catalog, photos, metadata, supersets, logging, scheduling, exports and source-scoped persistence are retained. Removed padding reserved for the old bottom bar.

Validation: full NOOPiOS tests passed (591 XCTest cases, 1 skipped, 0 failures; 118 Swift Testing cases with 3 known inherited photo issues). All nine source audits passed. A final contrast-only adjustment then passed a full app build.

On the full NOOP app in the iOS 27 iPhone simulator in Device Hub, followed Workouts > Start a workout > Lift weights > Upper A > Start workout; logged a set; finished the workout; opened the completed summary and history; closed back to Workouts; opened Lift progress. No nested bottom bar appears. The DEBUG simulator QA route now starts at the real Workouts screen instead of opening Lift directly.

Screenshots and logs are preserved at outputs/noop/2026-09-24-workout-flow in the shared workspace. Physical iPhone installation and live HealthKit/strap checks remain pending.
