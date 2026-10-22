# Four-feature verification record

## Scope

This change implements the four approved additions on `main` at
`6f49d855d6f747103f4dc2a60949cb933445c3c0`:

| Feature | App entry point | Persistence |
| --- | --- | --- |
| Adaptive daily training target | Today, below the daily scores; Preview opens the plan controls | Reads the current canonical snapshot and completed-day history. Preview does not write metrics. |
| Smart progressive overload | Saved Lift routine preview, including quick-start routes | Explicit acceptance changes the active session. Saved routines and completed history remain intact. |
| Voice Journal | Journal, Write or dictate an entry | Reviewed answers commit together to the existing global `noop-journal` namespace. |
| Smarter workout detection | Existing workout suggestion card | Confirmed type and exact detected interval save to the captured raw source, with ownership and overlap checks. |

The training-mix feature belongs to the separate Claude work. This branch has no
dependency on PR70 or another open feature/reliability branch. No database migration,
remote service, BLE sampling change, or production deployment is required.

## Local evidence

| Check | Result before publication | Scope and limitation |
| --- | --- | --- |
| Focused source audits | 12 passed | Existing repository source, UI, workout, accessibility, privacy, string, project, and test hygiene audits. |
| Daily target tests | 18 passed | Exact target, training-load, and recovery-forecast sources. A portable harness supplies only the existing eight-hour default Sleep Need constant. |
| Lift progression tests | 37 passed | Exact progression engine and model sources. App storage and SwiftUI need native CI. |
| Journal parser and editable values | 22 passed | 19 parser cases and 3 editable-value cases against the production sources. |
| Workout classifier and card state | 37 passed | 15 classifier cases, 6 card-state cases, and 16 existing detector/trace regressions. |
| Journal and workout transactions | Passed | Real GRDB and SQLite with snapshot support, exact production transaction extensions, and a small actor/schema scaffold. This is not production migration validation. |
| Swift source syntax | Passed | Apple-target syntax parsing of every changed/new Swift file. This does not type-check against the Apple SDK. |
| Patch whitespace | Passed | `git diff --check`. |

The host is Linux. A full store build reaches an existing `CryptoKit` import that is
unavailable there. The transaction harness preserves real database behavior without
changing the app's dependencies or weakening its Apple code. No local result is a
claim that the iOS app builds or renders correctly.

Native repository, Lift application, dictation, and review tests are included for the
macOS workflow. Its existing gates build the app and extensions, run NOOPiOSTests,
exercise selected UI regressions, and test the retained Swift packages. Record the
latest GitHub run in the PR before review is complete.

## Review corrections

Independent review found two issues during implementation:

- Workout writes needed a durable source-owner/lifecycle check inside the same
  transaction as overlap suppression and insertion. A MainActor check alone cannot
  protect a queued write after a source is purged or replaced.
- Journal answer controls remained editable while Save was running. They now disable
  with the existing saving state, so the visible answers cannot change after the
  transaction captures the values.

The workout card's state tests also caught an empty-refresh race during a pending or
failed save. The card now retains the selected type and retry state until the save
completes or its ownership changes.

## Data and model decisions

- Daily targets need seven measured Strain days in the preceding fourteen days,
  including yesterday. Missing observations do not become zeroes. The current day
  cannot change the historical baseline. All targets and recovery previews are
  estimates; the UI explains the inputs and calculation policy.
- Progression requires suitable completed sets and explicit effort ratings. It uses
  equipment-specific increments, bounds increases, and revalidates the reviewed
  routine and storage state before starting a session.
- Dictation requires on-device recognition and explicit microphone use. Unsupported
  recognition leaves typing available. Unmatched statements remain visible, and only
  included, reviewed catalog answers can save.
- Journal Save admits immutable values for the reviewed day in a global namespace.
  Source/day/catalog changes before admission reject Save. After admission, database
  identity and exact-row comparison protect the transaction; a later UI/source change
  cannot turn a successful commit into a reported failure.
- Workout type suggestions show evidence. Heart rate alone cannot confidently name a
  sport. Personal history produces only a cautious possible label after repeated,
  source-local user confirmations. The user can change the label before saving.

## Review and release checks

The PR stays unmerged. Review Apple CI on the latest commit before merging. A physical
iPhone check is still needed for microphone permission, on-device Speech availability,
interruption behavior, and the final screen layout. Keep feature 1 and the other open
branches separate when resolving later integration conflicts.
