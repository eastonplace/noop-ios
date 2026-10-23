# Five NOOP feature additions

## Scope and lineage

This branch implements the five features Easton selected after the Ryan BR comparison:
personal stress baseline, Coach Brief widget, improved step filtering, routine spreadsheet
import, and GPS route export. It starts from NOOP main
`6f49d855d6f747103f4dc2a60949cb933445c3c0`. Upstream behavior was reviewed at Ryan BR
`8e4b0c16e7640607600fa6bde5424095eba6034e`.

The additions use NOOP's existing iPhone UI, local Repository/SQLite, ReceiptLift store,
Coach consent rules, verified widget publication, and route persistence. There is no
new server service, cloud account, feature-specific database schema bump, or runtime
third-party dependency. Integration retains the shared 2.0.0 staging version and advances
the build to 245; phone installs and release publication remain on hold. Raw strap records and completed Strength sessions are
not rewritten by these features.

## Feature walkthrough

### Personal Stress Baseline

Open **Stress → Your normal → Compare to my normal**. It is off by default.
The reference uses the previous 30 complete local calendar days, excluding today,
with covered waking-hour HR means, a low-percentile daily reference, and the existing
baseline fold. Four usable days permit a provisional reference; 14 establish it.
Missing history, stale history, and read failures have explicit fallback states.

The setting changes the hourly ribbon in Stress and Today. It does not redefine the
stored daily stress score or silently change background widget metrics. This is an
HR-only comparison; activity can also raise it. It is not a time-of-day percentage
comparison or a medical stress measurement.

History is reduced by bounded SQL summaries off the main actor. Active/canonical source
precedence, cancellation, database replacement, source changes, and local calendar/DST
boundaries are checked before publication.

### Coach Brief widget

Add **NOOP Coach Brief** from the iOS widget gallery (small or medium). Complete a
morning or evening brief in Coach with local personal-data consent enabled. The widget
shows the completed prose, generation time, and available verified metrics captured
with that brief; tapping it opens Coach.

The extension does not invoke AI, Bluetooth, network requests, or the health database.
Partial/interrupted responses and weekly/activity summaries cannot replace the daily
brief. Consent revocation, source transitions, relevant history edits, and the app's
04:00 logical-day rollover clear or suppress it. An empty widget asks the user to open
Coach. It depends on the app's existing on-device Coach availability.

### Step filtering and derived history

The shared counter now checks walking/running classifications when present, rejects
implausible tick rates and resets, and handles duplicate or conflicting timestamps
deterministically. Entirely unclassified legacy windows retain their counter estimate.
Sleep-aware totals exclude isolated movement while preserving explicit awake stages
and sustained gait. Existing per-user calibration and civil/physiological day boundaries
remain in use.

Daily and cycle totals use the same filtering. Manual workout counts reuse the class
and rate kernel. The newest-first scan reuses a completed successor night's sleep
context from the same source for late-evening calendar steps, without staging it again
or changing its sleep attribution. Explicit awake spans survive overlapping sleep
records, and the Strain detail uses the batch's exclusive cycle end. Step diagnostics
use the same filtered total and state how many ticks sleep filtering excluded.
Derived-analysis cache version advances to `cache-v6`, and the bounded,
resumable history rescore/settlement moves to fresh `v5` identities. The repair rederives
stored step totals and their Strain V2 contribution through the existing pipeline;
raw recordings, edited sleep, and logged lifts retain their existing ownership rules.

### Strength routine import

Open **Lift → Routines → Import routines**. A CSV template is available in the import
sheet. Choose a CSV or XLSX file, review all routines and validation messages, allow
any explicitly listed new custom exercises, then confirm.

Parsing/preview does not save. Confirmation uses the current ReceiptLift schema and
atomic persistence callback. Imported routines receive fresh IDs and collision-safe
names; existing routines are not replaced. Known exercises match on exact normalized
names; unfamiliar ones require consent. Sets, reps, rest and target effort map into
the existing plan fields. Planned loads are preserved visibly in exercise notes because
the current plan model has no dedicated planned-load field. Completed workouts and
Strength Strain calculations are unchanged.

File size, expansion, row and cell counts are bounded. Unsupported formulas, malformed
values and invalid workbooks produce errors. Request ownership prevents an older file
read from replacing a newer preview; source changes and active workouts block a stale save.

### GPS route export

Open a saved workout with timestamped GPS measurements and choose **Export route** to
share GPX or FIT through the native share sheet. **Export Workout Route** is also a
discoverable Shortcuts action for the latest exportable saved route. Existing Siri
shortcut phrases are retained.

New recordings preserve measured timestamps, available horizontal accuracy, and segment
breaks across pause, resume and relaunch. GPX and FIT use those measurements. FIT exports
route/distance/timer information without an invented heart-rate or calorie summary.

Older polyline-only routes remain viewable and restorable. They cannot be given real
timestamps retroactively, so they are not offered as full measured exports. Active
workout journal decoding remains backward compatible; any legacy portion of a resumed
workout is distinguished from newly measured portions.

## Verification and review

Local portable checks use Swift 6.4.1. The full iPhone app and Apple-only package graph
require macOS/Xcode CI; a Linux source parse is not a native build.

- The full `NoopPhase34Core` package suite passes (28 tests), including seven new brief
  payload tests for source/epoch/day/expiry isolation, malformed versions, Unicode bounds,
  missing metrics and non-finite values.
- Focused exact-source stress analytics tests pass (44 tests). A real GRDB/SQLite
  harness also passes all six exact-source history-query tests, including a regression
  that reproduced the first native CI run's SQL-fragment interpolation failure before
  its correction. Full store integration and iOS view ownership run in native CI.
- The focused routine parser suite passes (14 tests), including CSV and real XLSX
  paths. ReceiptLift persistence/source/preview tests are committed for iOS CI.
- The GPS writer package passes (10 tests); the exact-source persistence/service harness
  passes (9 tests). Garmin's FIT SDK independently recognizes and decodes the fixture
  with valid integrity checks and pause-aware distance/timer values.
- The focused exact-source step and scan-cache suite passes (37 tests), covering
  classifications, rate bounds, wraps, duplicate conflicts, invalid counters, sleep
  movement, overlapping awake spans, sustained bouts and successor-sleep cache
  invalidation. Native daily/cycle, diagnostic-parity and repair integration tests
  are included for macOS/iOS CI; they were not executed in the Linux harness.
- The complete exact-source day-boundary test file passes (17 tests). Its DST fixture
  includes sustained boundary-hour walking so the wrong-offset regression remains
  observable after isolated sleep movement is correctly filtered.
- All 12 existing static audit commands pass, including UI conventions, accessibility,
  privacy, HealthKit, workout persistence, and project hygiene.

The temporary component harnesses compile the repository's exact source and tests while
excluding unrelated Apple-only modules; they are not substitutes for the complete
macOS package or iOS suites. Native build/test results belong to the PR checks. The
new GPS package is discovered by the protected package plan and receives one authoritative
host test job. The app and tests also compile against it.

Historical pre-integration evidence: the native rerun at `8c8b11d7` compiled the full iPhone app and extensions, passed all
12 source audits, and passed all nine retained Swift package suites. This includes the
complete 641-test WhoopStore and 1,536-test StrandAnalytics suites after the SQL and
DST-fixture corrections.

That run found one iOS test compilation error: the GPS persistence test's teardown
captured a non-Sendable `UserDefaults` instance in XCTest's main-actor closure. The
cleanup now constructs its own suite instance from the suite name, avoiding that
cross-actor capture. The iOS test suite must pass the follow-up native rerun; native
UI and device interaction checks remain separate review gates.

## Integration with current main

PR70 is integrated with main `a2194ec6348e97324edebad2a22b2e667c287acb`, which includes
PR68, PR71, PR76, PR72 and PR75. Their source ownership, GPS sport filtering, Coach
hydration and Journal, reviewed Lift progression, persistence workers, analysis cache
witnesses and change-aware CI are retained. The shared 2.0.0 entry accumulates this
work with the prior batch. PR73 and PR74 remain separate and unmerged.

The portable and native results above describe earlier branch heads. Final integration
qualification must be read from the exact current PR head's checks; local component
evidence does not replace those required checks. Physical GPS/strap behavior remains
a later device-validation gate and is not implied by a source merge.
