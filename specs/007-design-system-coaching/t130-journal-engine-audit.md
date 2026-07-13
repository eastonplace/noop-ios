# T130 Journal Engine Audit

Status: **APPROVED — T131/T132 AUTHORIZED**
Baseline: `pre-007` → `a80a83ced85b111c48118c07c757450e8d528ec0`  
Scope: code and storage audit only; no schema, engine, navigation, or UI changes.

## Gate input status

| Required T130 input | Result |
|---|---|
| Annotated `pre-007` tag | PASS — created at `a80a83ce` and pushed to `private-noop-report` |
| `references/component-library.png` | **BLOCKED — absent locally and on the fetched remote branch** |
| `references/coaching-sheet.png` | **BLOCKED — absent locally and on the fetched remote branch** |
| Standalone `plan.md` / `tasks.md` | Not present; the G1–G6 rulings and T130–T139 list embedded in `spec.md` are the only available execution contract |

The engine audit below uses G3/G4's explicit product requirements. T131 must not start until both canonical boards are present and externally reviewed with this proposal.

## Existing engine inventory

| Capability | Current source of truth | Persistence / identity | Engine effect | T130 verdict |
|---|---|---|---|---|
| Starter behaviors | `JournalCatalogStore.starterQuestions` | Ten verbatim canonical question strings | Canonical string is the association join key | KEEP unchanged |
| Imported behaviors | `Repository.importedJournalEntries()` + `JournalCatalogStore.resolvedItems` | Imported question spelling leads the catalog merge | Joins imported and native days under the same question | KEEP unchanged |
| Custom behaviors | `JournalCatalogStore.items` | JSON blob `journal.catalog.v2` in `UserDefaults` | Custom canonical becomes a normal behavior key | KEEP; settings storage should move forward additively, not rewrite keys |
| Rename / group / kind / order / hide | `JournalCatalogItem` | Display metadata in `journal.catalog.v2`; `canonical` never changes | Presentation-only except kind enables numeric logging | KEEP semantics; behavior-set preferences can reference canonical keys |
| Boolean answer | `Repository.saveJournalAnswer` | Existing `journal` row keyed by `(deviceId, day, question)` under `noop-journal` | `answeredYes == true` contributes an occurrence day | KEEP byte-for-byte contract |
| Clear answer | `Repository.clearJournalAnswer` | Deletes only the `noop-journal` natural key | Imported rows cannot be deleted | KEEP |
| Numeric answer | `Repository.saveJournalNumeric` | Existing nullable `journal.numericValue`; also writes `answeredYes=true` | Boolean associations remain intact; numeric series is additive | REUSE for quantity-capable single behaviors |
| Imported/native merge | `Repository.mergeJournal` | Native wins only on identical `(day, question)` | Same merged sequence feeds Insights and coaching-adjacent consumers | KEEP and pin with integration test |
| Mood | `MoodStore` / `Repository.saveMood` | Existing metric series under `noop-mood`, key `mood`, range 1...5 | Separate from behavior associations | REUSE as optional check-in context; do not fold into journal booleans |
| Association input shaping | `InsightsView.load` and `InsightsHubViewModel.load` | `[question: Set<day>]` built only from merged rows where `answeredYes` | Passed to `EffectRanker` against Recovery/HRV/Sleep/RHR outcomes | KEEP; same fixture must produce identical ranked output before/after G3 |
| Dose response | `InsightsHubViewModel` | Explicit dose rows under `noop-journal-dose`; missing explicit dose falls back to 1 for logged Yes days | `DoseResponseEngine` for existing dosed behaviors | REUSE where compatible; do not create a second quantity truth |
| Day attribution | `JournalLogCard.dayKey` | Local wake-day convention; Today/Yesterday/Tomorrow offsets | Aligns native logs with WHOOP export cycles | KEEP |
| Existing entry points | FAB Quick Actions, Insights Journal chip, debug routes | All currently open `InsightsView(focusedJournal: true)` | No engine change | T134 rewires destinations only to Coaching Root |

## Existing behaviors

The built-in catalog currently contains ten canonical behaviors:

1. Did you drink any alcohol?
2. Did you have caffeine late in the day?
3. Did you view a screen in bed?
4. Did you eat close to bedtime?
5. Did you feel stressed?
6. Did you use a sauna?
7. Did you share your bed?
8. Did you feel sick or ill?
9. Did you take magnesium?
10. Did you read before bed?

Existing display groups are Nutrition, Supplements, Lifestyle, Health, Behaviour, and Other. G3's Sleep setup / Fuel / Training & activity / Recovery & stress / Supplements & medication groups therefore require a new presentation/preference taxonomy; they must not mutate stored canonical questions or historical rows.

## G3 gap matrix

| Coaching-sheet need | Exists now | Gap / additive requirement |
|---|---|---|
| Coaching Root progress and `N of M logged` | Answers can be counted for a day | New presentation model only; denominator comes from active behavior set |
| Continue Check-In | Existing focused Journal route | New Coaching Root and Check-In navigation; keep old `JournalLogCard` as quick path |
| Repeat yesterday | Read/write primitives exist | New transaction/helper that copies selected native answers and quantities to today's natural keys; imported rows remain immutable |
| Shortcuts and stacks | No stack model | New stack definitions, stack items, and stack-use log |
| Quick Add grid | Custom add exists; no quick-add preferences | New per-behavior quick-add flag/order and search/category presentation |
| Recent Entries | Journal range reads exist | Derive from existing native journal rows plus stack-use rows; honest empty state needs no schema |
| Collapsible check-in groups | Existing six groups and collapsed state | New coaching group mapping/order; presentation preference only |
| Boolean toggles | Existing tri-state Yes/No | Reuse exact save/clear functions; UI may present active/inactive without changing stored bool semantics |
| Steppers / quantity counters | Numeric journal and dose rows exist | Store quantity metadata without replacing boolean occurrence; unify with existing numeric/dose path per behavior |
| Behavior set selection | No set entity | New behavior-set and membership tables |
| ACTIVE and QUICK ADD columns | Hidden/custom metadata only | New membership preference fields; do not overload `hidden` |
| Drag reorder | `sortIndex` exists globally | Set-specific membership order required; preserve catalog order for legacy view |
| Stack detail, doses, notes, last used | No stack entity | New stack, stack-item, and stack-use tables |
| Relaunch persistence | Journal/mood already durable | New entities must use the same SQLite store/migrator, not new `UserDefaults` islands |
| Associations unchanged | Existing unit coverage pins pieces | Add an integration fixture around log → merge → `EffectRanker` output equality |

## Proposed additive schema

Names are provisional for external review; all tables are new and existing `journal` rows are untouched.

### `coachingBehaviorSet`

| Column | Type / rule |
|---|---|
| `id` | TEXT primary key (stable UUID string) |
| `name` | TEXT not null |
| `isActive` | INTEGER not null, one active set enforced by repository transaction |
| `createdAt` / `updatedAt` | INTEGER not null Unix seconds |

### `coachingBehaviorMembership`

| Column | Type / rule |
|---|---|
| `setId` | TEXT not null, references behavior set |
| `canonicalQuestion` | TEXT not null; exact existing journal/engine key |
| `coachingGroup` | TEXT not null; new G3 display taxonomy |
| `sortIndex` | INTEGER not null |
| `isActive` | INTEGER not null |
| `isQuickAdd` | INTEGER not null |
| Primary key | `(setId, canonicalQuestion)` |

This table references catalog canonicals; it never renames or copies them. Imported-only questions may be materialized into membership without rewriting imported history.

### `coachingQuantityMetadata`

| Column | Type / rule |
|---|---|
| `deviceId` | TEXT not null; normally `noop-journal` |
| `day` | TEXT not null |
| `canonicalQuestion` | TEXT not null |
| `quantity` | REAL not null |
| `unit` | TEXT nullable |
| `source` | TEXT not null (`checkIn`, `quickAdd`, `stack`) |
| Primary key | `(deviceId, day, canonicalQuestion)` |

Repository writes must pair a positive quantity with the existing journal upsert using `answeredYes=true`; clearing the occurrence clears only native quantity metadata and the matching native journal row. Before implementation, T137/T138 must resolve whether this table can be avoided by extending the already-existing `journal.numericValue` + `noop-journal-dose` contract. One quantity truth is preferred; duplicate quantity stores are forbidden.

### `coachingStack`

| Column | Type / rule |
|---|---|
| `id` | TEXT primary key |
| `name` | TEXT not null |
| `description` | TEXT nullable |
| `scheduleLabel` | TEXT nullable presentation metadata |
| `isActive` | INTEGER not null |
| `notes` | TEXT nullable |
| `sortIndex` | INTEGER not null |

### `coachingStackItem`

| Column | Type / rule |
|---|---|
| `stackId` | TEXT not null |
| `canonicalQuestion` | TEXT not null; exact engine key |
| `dose` | REAL nullable |
| `unit` | TEXT nullable |
| `sortIndex` | INTEGER not null |
| Primary key | `(stackId, canonicalQuestion)` |

### `coachingStackUse`

| Column | Type / rule |
|---|---|
| `id` | TEXT primary key |
| `stackId` | TEXT not null |
| `day` | TEXT not null |
| `loggedAt` | INTEGER not null |
| `notes` | TEXT nullable |
| `skipped` | INTEGER not null |

Logging a stack use is additive provenance. Each checked item must also write through the existing journal API under its canonical key so What Moves You sees the same boolean input it would receive from a manual Yes answer.

## Explicit non-changes

- No migration or rewrite of existing `journal` rows.
- No change to the `(deviceId, day, question)` natural key.
- No change to native-over-imported merge precedence.
- No localization or replacement of canonical question strings.
- No change to `answeredYes` filtering before `EffectRanker`.
- No new scoring, recovery, sleep, strain, or stress math.
- No tab-bar changes.
- No removal of `JournalLogCard`, numeric logging, mood, custom questions, or dose-response behavior.

## Required T138 integration oracles

1. Seed imported and native rows with one collision; assert the merged journal is unchanged after coaching metadata is added.
2. Log a boolean through Check-In; persist, recreate the repository, and assert the same canonical/day/answer returns.
3. Log a positive quantity; assert quantity round-trip and `answeredYes == true` for the existing engine input.
4. Log a stack with two checked items; assert two existing journal occurrences plus one stack-use provenance row.
5. Run the same behavior/outcome fixture through `EffectRanker` before and after coaching metadata; assert identical ranked effects, lags, means, sample counts, confidence, and ordering.
6. Clear a native coaching answer; assert the imported row with the same day/question remains readable.

## Gate decision requested

External review should approve or revise:

1. The behavior-set/membership split and set-specific order.
2. Whether quantity metadata reuses `journal.numericValue` + the existing dose source exclusively, or needs a new provenance table.
3. Stack logging semantics: checked stack items write existing journal occurrences; the stack-use row is provenance only.
4. The rule that G3 groups are presentation metadata and never alter canonical behavior identity.
5. The missing-board blocker: both canonical PNGs must land under `references/` before T131.

The T130 stop was observed; T131/T132 began only after the external approval below.

## External-review rulings

- Set/membership split approved.
- `coachingQuantityMetadata` rejected. T137 must extend the existing
  `journal.numericValue` + `noop-journal-dose` contract exclusively; stack-use carries provenance.
- Stack items write real journal occurrences through the existing API; stack-use is provenance only.
- Coaching groups are presentation metadata; canonical strings remain immutable.
- G1 transcription authorizes T131/T132 without the PNGs. T133/T139 remain hard-blocked until both
  boards land under `references/`.
- All six T138 integration oracles are approved.
