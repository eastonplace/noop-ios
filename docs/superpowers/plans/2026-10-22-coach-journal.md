# Coach Journal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox syntax.

**Goal:** Build the approved Journal widget, capture review, daily notes and mood, and evidence cards inside iPhone Coach.

**Architecture:** Extend the existing reviewed Journal transaction and composer from PR #72. Keep the transcript value-fed and load bounded Journal snapshots outside it. Build insight cards from deterministic scoped record reads.

**Tech Stack:** Swift, SwiftUI, StrandAnalytics, WhoopStore/GRDB, existing local Foundation Models Coach.

**Spec:** `docs/superpowers/specs/2026-10-22-coach-journal.md`

## Global Constraints

- Base: PR #72 at `2823613b22ed099244627fac78db69a06310c964`.
- Open a new draft PR against PR #72's branch. Leave it open and unmerged.
- Preserve `noop-journal` answers, canonical keys, imports, and per-answer notes.
- Use `noop-mood` / `mood` for mood values 1 through 5. A missing mood remains absent.
- Day note maximum: 8,000 UTF-8 bytes; no NUL. No new remote service or model writes.
- Coach record reads require consent. Explicit manual journal entry is independent of model availability.
- Local Linux checks do not prove an Apple SDK build or physical-device dictation.

## Review Focus

- Source/database replacement during review: reject a stale save without losing the draft.
- Midnight and timezone changes: keep a captured wake-day key; do not redirect a queued save.
- Concurrent note/mood/answer changes: compare exact rows and roll back the whole transaction.
- Native/imported overlaps and capped reads: prevent biased association values and disclose exclusions.
- Preview, consent-off, unavailable-model states: no hidden personal reads or writes.

### Task 1: Atomic daily details

Files: WhoopStore migration, registry, reviewed-journal transaction and tests;
`Strand/Data/Repository+JournalEntry.swift` and focused repository tests.

Interfaces: `JournalEntryDayDetails(note: String, mood: Int?)`;
`reviewJournalEntry(..., includeDayDetails: Bool = false)`;
`saveJournalEntry(..., dayDetails: JournalEntryDayDetails? = nil)`;
`journalDayDetails(day:sourceContext:) async throws`.

- [x] Add failing roundtrip, conflict, bounds, notes-only, mood-only, and rollback tests.
- [x] Add native daily note storage and extend the reviewed transaction with exact comparisons.
- [x] Run real-GRDB transaction tests and repository tests where the platform permits.

### Task 2: Entry review

Files: `Strand/Screens/JournalEntryComposer.swift`, focused draft helper and tests.

Interfaces: `JournalEntryPresentation(day:sourceIdentity:initialText:initialSuggestions:)`.
Consume Task 1 APIs. Original callers retain default seed values.

- [x] Add tests for unchanged seed proposals, edited input, note append limits, and explicit detail inclusion.
- [x] Add visible note/mood review and preserve all existing context and saving locks.
- [x] Verify no capture, parsing, or sheet presentation writes data.

### Task 3: Association cards

Files: StrandAnalytics helper/tests, LocalCoachCards/DataService/CardViews,
CoachChatParts, focused app tests. Parent wires Ask Coach in transcript.

- [x] Test same-day matching, explicit-no controls, native override, ambiguity, missing recovery, numeric habits and read caps.
- [x] Produce shared typed analysis for tool text and cards; support Codable/export.
- [x] Run portable helper tests and add source/consent regression tests for native CI.

### Task 4: Widget and routing

Files: new `CoachJournalWidget.swift`, `CoachJournalSession.swift`,
`CoachJournalSheet.swift`, `Repository+CoachJournal.swift`,
LocalCoachView, CoachWelcomeView, CoachConversationView and focused tests.

- [x] Test stale snapshot and request identity rejection, day selection, explicit draft behavior and source fencing.
- [x] Add a value-fed widget, full Journal sheet, explicit Journal composer mode and confirmation handoff.
- [x] Refresh on journal edits and clear visible values immediately when consent/source changes.

### Task 5: Verification and publication

- [x] Run source audits, focused tests, Swift syntax checks and diff checks.
- [x] Independent reviewers inspect storage, UI and whole-branch integration; fix confirmed findings.
- [ ] Push only the task branch, open a stacked draft PR, inspect native CI, and report remaining device checks.

## Execution decisions

The approved user request authorizes implementation and a new unmerged PR.
Independent file ownership permits parallel work; shared interfaces above pin
the integration. No existing feature branch is mutated. A later merge/rebase
must carry PR #72 first or retarget after that dependency lands.
