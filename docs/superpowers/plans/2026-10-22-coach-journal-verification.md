# Coach Journal verification

Date: 2026-10-22.

Base: `2823613b22ed099244627fac78db69a06310c964`, the head of draft PR #72.
This feature is stacked on PR #72 and must remain unmerged for review.

## Implemented scope

- A value-fed Journal widget in Coach with explicit Yes/No drafts, review, and discard.
- A full Journal sheet with a civil wake-day selector and the existing catalog controls.
- An explicit Journal composer mode for typed or on-device dictated input. Capture does not require the Coach model.
- Separate daily note storage and existing mood storage, saved with reviewed answers in one transaction.
- Deterministic journal/recovery cards with counts, date windows, sources, missing-data states, and Ask Coach.

Automatic personal reads require Coach permission. Manual Journal access is an explicit local action.
Previews cannot read or write personal journal records. Daily notes and per-answer notes are excluded from the association tool.

## Fresh local checks

| Check | Result |
| --- | --- |
| Widget draft policy | 7 tests passed |
| Session, date, source and consent policy | 13 tests passed |
| Composer, editable values and parser | 50 tests passed |
| Association analysis and card/export models | 22 tests passed |
| Real GRDB/SQLite transaction and repository-review harness | 38 tests passed |
| Total focused tests | 130 passed, zero failures |
| Existing focused source audits | All 12 passed |
| Swift frontend Apple-target parsing | All 45 changed Swift files passed |
| Diff whitespace check | Passed |

The source audit scanned 1,272 Swift files and reported no architecture warning.
The hygiene audit retained the existing version/changelog warning: marketing version 9.0.1 versus changelog 7.9.0.
Its 13 regression tests also passed. The existing trends-audit Python escape warning remains unchanged.

Two hygiene checks first lacked permission to create temporary fixtures. Approved reruns passed.
Swift package commands use `-j 1`; the compiler rejects the combined `-j1` spelling before compilation.

## Review findings closed

- Retained authored note/mood values across narrative edits, failed saves, and re-review. A new review still requires explicit inclusion.
- Kept invalidated-context drafts visible and copyable under their original wake day while preventing a save into a different context.
- Changed Discard to remove draft overrides, so a later saved answer cannot be overridden by a copied old snapshot.
- Replaced the 200-total-row association cap with a bounded 4,096-row read plus one overflow sentinel per source, with at most eight sources.
- Withheld counts and effects on overflow; allowed complete reads at the exact limit. Tests cover a normal four-habit, 90-day journal.
- Paused reads when either host is inactive and preserved same-context drafts through pause/resume.
- Cleared stale in-memory catalog deltas after the stored catalog key is removed, without recreating that key.

Independent final source review found no remaining confirmed blocker. This does not establish an Apple SDK build.

## Harness fidelity and reproduction

The portable runs use Swift 6.3.3. Production helper and transaction files are compiled directly or symlinked into isolated harnesses.
The database harness uses real GRDB/SQLite with lightweight Repository/WhoopStore host scaffolds.
The card harness mechanically exposes pure production card/export code and supplies unrelated date/localization stand-ins.
All tests are also committed in their native app or package test target for Apple CI.

Standalone policy tests can be compiled from this checkout:

```sh
swiftc -D COACH_JOURNAL_STANDALONE_TESTS \
  StrandiOS/Coach/CoachJournalWidget.swift \
  StrandiOSTests/CoachJournalWidgetTests.swift \
  -o /tmp/noop-coach-journal-widget-tests
/tmp/noop-coach-journal-widget-tests

swiftc -D COACH_JOURNAL_SESSION_STANDALONE_TESTS \
  StrandiOS/Coach/CoachJournalSession.swift \
  StrandiOSTests/CoachJournalSessionTests.swift \
  -o /tmp/noop-coach-journal-session-tests
/tmp/noop-coach-journal-session-tests
```

The transient harnesses used for this run are `/tmp/noop-journal-composer.CAaPUo`,
`/tmp/noop-coach-association-verification-20261022`, and `/tmp/noop-journal-day-details.m0BQDb`.
Their successful build path uses `swift build --build-tests -j 1 -Xswiftc -disable-batch-mode`,
followed by direct execution of the generated XCTest binary. The database build also supplies the existing SQLite headers and library.
Earlier SwiftPM child launches intermittently failed in this environment's process monitor; direct XCTest runs completed successfully.

## Native verification still required

This Linux environment has no Xcode or Apple SDK. The full package attempt stopped at the existing Apple-only `CryptoKit` import.
The focused results do not establish a complete app build, full package pass, or rendered SwiftUI behavior.

The existing pull-request workflows should generate the Xcode project, build the app and extensions, run app tests, and run package suites.
Native-only snapshot, catalog/session lifecycle, and consent tests are included but were not executed locally.
Inspect the PR checks for the exact published commit before marking it ready.

A physical iPhone check remains required for microphone permission, on-device Speech availability, interruption handling,
VoiceOver, large text, and the final keyboard/sheet layout. No deployment or merge is part of this change.
