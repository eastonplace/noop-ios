This is the specialist evidence snapshot before delivery. The [combined report](README.md) is authoritative for release status. Scratch paths record the original execution environment.

# NOOP 2.0 — UI, Coach, notification and historical-view audit

Audit date: 2026-10-23. Checkout: `/workspace/scratch/fc582a8e42a6/noop-ios`, branch `audit/noop-2-release-hardening-20261023`. Baseline: `a7ade2598d439d33cd20816d69ccc991b29322fc`. Intended release-hardening output is PR78. Parent agent owns the final PR, release bookkeeping and native CI.

This work began as read-only investigation. The parent explicitly authorized the two Coach fixes below after reviewing their call paths. No Coach prompt, template or instruction wording was changed. No UI redesign, visual restyling, live device access, real model call, real credential read, personal health-data access, push or PR operation was performed by this agent.

## Confirmed findings and implemented fixes

### UI-1 — Cloud Coach mixes request ownership across asynchronous context loading

**Severity: P1.** The real UI exposes disconnect, provider setup and consent controls while an earlier request can still be awaiting local context. A saved cloud credential can be attached to a newly selected Custom destination; revoked personal context can still be transmitted; previously generated personal replies can be included in the next supposedly non-personal request. A separate concurrency consequence lets overlapping requests append duplicate questions and lets an obsolete completion clear the current request's busy state.

**Baseline locations and root cause:**

- `Strand/AI/AICoach.swift:468–501`: `send` resolves the key before `await buildFullContext()`, but dispatch later reads mutable provider/model/prompt. There is no engine-level `sending` admission guard or request identity.
- `Strand/AI/AICoach.swift:504–534`: proactive brief generation has the same suspension/ownership problem.
- `Strand/AI/AICoach.swift:631–640`: `callProvider` selects the live `provider.client`, `model` and `systemPrompt`, even when the key and context belong to an earlier configuration.
- `Strand/AI/AICoach.swift:667` and the `wireMessages` path: visible messages are also outbound history; consent/source changes do not revoke that history.
- `Strand/AI/AICoach.swift:403–449`: model refresh already protects a direct provider switch, but not a same-provider server/key/configuration change or an A→B→A generation change.
- `Strand/AI/Providers/Custom.swift:59,81–111`: a compatibility retry and model discovery read the current UserDefaults endpoint instead of retaining the server selected for the original client/request.

**Reachable UI:** `StrandiOS/Coach/LocalCoachLibraryViews.swift:305` opens cloud Coach. `Strand/Screens/CoachView.swift` exposes disconnect in the toolbar, the data consent toggle, and provider/server setup. These actions can happen while context awaits finish. No malicious input or unusual hardware timing is necessary.

**Deterministic reproduction:** park `buildFullContext` on a continuation after `send` captures its key; change provider from OpenAI to Custom and set a replacement URL; release the continuation. The original code sends to the replacement server with the old key. Equivalent tests revoke either consent, clear the key, disconnect a brief, invalidate/reopen source context, cancel the caller, change model A→B→A, overlap sends, or let an older request finish during a newer one. A real CustomClient/URLSession mock returns an unsupported-parameter 400 and changes defaults before retry, demonstrating the destination retargeting directly.

**Fix:** request configuration captures provider, model, normalized Custom URL/client, credential and owner, both consents, repository source/epoch and prompt before any suspension. Configuration changes increment a generation and cancel owned work. Every request validates identity/configuration/source/cancellation before transmission and before publishing a reply/error. The shared HTTP helper repeats this admission check before each attempt, including compatibility retries. Busy-state completion is owned by one request ID. Re-entrant sends are rejected. Visible history is retained, while outbound history is cleared on privacy/provider/source ownership changes. CustomClient retains immutable chat and model endpoints derived from one captured base URL. Stale model-list results/errors are discarded for configuration changes, not just provider changes.

**Current implementation:** `AICoach.swift:548` (`send`), `579` (brief), `600–679` (source/configuration/task ownership), `785` (captured dispatch), `824` (outbound history). The credential dependency is a narrow production-default wrapper around the existing Keychain implementation and permits tests to supply synthetic keys. The context override remains DEBUG-only.

**Tests:** `StrandiOSTests/AICoachRequestOwnershipTests.swift`, now 20 deterministic production-engine/provider cases. The original 16-case baseline run fails 15 cases with 21 expected assertions; the positive path passes. All 10 existing model-refresh/model-parser cases also pass on that baseline. The final fixed run, including the four retry-boundary tests below, passes **30/30** (20 new cases plus 10 existing cases).

**Independent-review follow-up, P2:** the first ownership fix still checked only before and after the entire provider `send`. Both OpenAI and Custom perform a second HTTP attempt after a parameter-compatibility 400 (`Providers/OpenAI.swift:18–24`, `Providers/Custom.swift:30–36`). If the source fence closed/reopened while the first HTTP request was in flight, that retry retransmitted the retired source payload before the eventual reply was discarded. The independent reviewer reproduced this in the real-engine/provider harness. The adopted test plus an OpenAI equivalent both failed with **2 requests instead of 1**; stable-source retry controls passed. `AIProvider.swift:128–141` now checks a task-scoped, main-actor ownership closure before every `session.data` call and checks cancellation again after the actor hop. `AICoach.swift:785–798` scopes that closure to its exact request for the duration of provider dispatch. No provider protocol or retry payload change is required. All four new tests pass after the fix. This prevents later attempts from using retired ownership; it cannot revoke bytes already transmitted by an earlier valid attempt.

### UI-2 — Weekly local Coach insight cache and task lifetime are not owned by their source

**Severity: P2.** A same-week insight can describe records from an earlier database after restore/source replacement. On the same local day the cache suppresses regeneration. The same weekly task also has an unowned defer: after clear/restart, a cancelled older task can clear the newer task's admission handle, permitting another overlapping generation. A consent off/on transition can revive an earlier completion because weekly work is not invalidated by the engine's ordinary consent path.

**Baseline locations and root cause:**

- `Packages/StrandAnalytics/Sources/StrandAnalytics/WeeklyCoachInsightStore.swift:8–16,54–60,83–90`: persisted insight contains only week/text/generated date; cache freshness compares week/day only.
- `Strand/Screens/TrendsView+WeeklyReview.swift:198–201`: any matching-week cache is displayed, without a database/source owner.
- `StrandiOS/Coach/LocalCoachEngine.swift:367–404`: weekly task has no request ID; its unconditional `defer { weeklyInsightTask = nil }` can release another task's slot. The existing direct source-match guard does reject an ordinary A→B response; that already-solved case was explicitly retained as a positive regression.
- `StrandiOS/Coach/LocalCoachEngine.swift:944–976,1003–1027`: ordinary conversation consent/source reconciliation clears ordinary history and daily publication, but does not cancel/clear weekly insight.
- `StrandiOS/App/RootTabView.swift:375–381`: weekly invalidation is attached to physical lineage changes only. Database-scope changes route pending Coach requests but do not clear weekly cache. `Repository.quiesceStoreForRestore`/`reopenStoreAfterRestore` change database scope while retaining the physical lineage.

**Deterministic reproduction:** seed a cache for database A/current week/current day, change the engine source scope to database B, and run actual source reconciliation: baseline retains A's cache. A fresh engine for B also skips generation because freshness only checks day/week. For task ownership, suspend completion A, clear, suspend completion B, finish A, then retry after the throttle interval: baseline admits a third model call while B is running. An off/on consent transition and a fence that closes/reopens during a suspended read also produce stale baseline publication.

**Fix:** persist an optional source ID with weekly insights; legacy entries remain decodable but production freshness/display require the current owner. LocalCoachEngine clears weekly work/cache at the same source/database reconciliation boundary as its other state and when personal access is revoked. A unique weekly task ID owns post-await validation and defer cleanup. Exact captured scope, including fence state, is rechecked. Caller cancellation propagates to the owned task. The saved timestamp uses the method's injected `now`, keeping freshness deterministic. Trends filters cache by current source and fence before reading its text; its appearance and valid-source content remain unchanged.

**Current implementation:** `LocalCoachEngine.swift:368–427,956–962,1018–1043`, `WeeklyCoachInsightStore.swift:8–21,57–64,86–94`, `TrendsView.swift:30–34`, `TrendsView+WeeklyReview.swift:198–201`.

**Tests:** `StrandiOSTests/LocalCoachWeeklyInsightOwnershipTests.swift`, 8 deterministic app-target cases. A focused Linux harness compiles exact production weekly/source/consent methods with actual models/cache/date math; unrelated UIKit/conversation/persistence shell dependencies are stubbed. Baseline: 6 cases fail with 10 expected assertions, and 2 already-correct controls pass. Fixed: **8/8 pass**. This is method-level execution evidence; full LocalCoachEngine/native app compilation is still a native CI requirement.

## Prompt and instruction preservation

`/tmp/noop-ui-coach-harness/check_ai_literals.py` lexes Swift string literals, including multiline/raw strings, comments and nested interpolation. It compares every original literal token against the baseline in all **32** files under `Strand/AI` and `StrandiOS/Coach`. Result: every original literal is retained **byte-for-byte**, including all prompts, instructions, context strings, UI copy and payload keys. Only two new endpoint path literals (`/chat/completions`, `/models`) appear in Custom.swift. The proof includes per-file literal counts and SHA-256 fingerprints in `prompt-literal-proof.json`.

The durable checker and proof are also included in `docs/qa/noop-2-release-hardening/check-coach-literals.py` and `coach-prompt-literal-proof.json`. Exact command from the repository root: `python3 docs/qa/noop-2-release-hardening/check-coach-literals.py .`. `coach-validation.json` records the test counts, scopes and native gates.

The weekly prompt at baseline `LocalCoachEngine.swift:393` and weekly instructions at `416` are unchanged. The cloud default prompt, no-consent note, brief instruction and all context templates are unchanged. This check is stronger than comparing only the named prompt constants.

## Broader audit conclusions

### Notifications and permissions — existing protections retained

The reviewed notification code already moves UNUserNotificationCenter IPC onto a serial queue, preserves categories, serializes durable occurrence claims, retains submitting markers for uncertain platform results, bounds known-failure retries and cleans up accepted/uncertain submissions after source/permission/privacy changes. Removal finishes against the captured old database instead of accidentally withdrawing a replacement source's ledger. Initial observer/category migration is one retained task, and schedule generations reject superseded work.

Journal reminders are occurrence-specific seven-day one-shots, so a completed day can be withdrawn; repeating wind-down/weekly reminders carry generic copy. Schedule changes and civil-time notifications rebuild schedules. Battery observations have physical-device episode identity, measured recovery hysteresis, and retained confirmed-charging cancellation across unknown packets. Permission denial does not consume the durable notification claim. WindDownNudge's asynchronous enable path owns a generation and reports denied/off outcomes rather than persisting an apparently enabled but unschedulable toggle.

No additional confirmed notification correctness defect emerged from this pass. Existing app tests specifically cover these races; they were reviewed/indexed, not newly executed on Linux by this agent. Health-pattern/morning/target phone notices remain behind the pre-existing qualified-input gate; this audit did not bypass that dependency or enable new notification behavior.

### Charts, history, invalidation and main-thread work

- Trends has immutable loaded/screen snapshot identities, bounded range/week offsets, explicit civil-time identity, latest-wins terminal state and an off-main snapshot builder. Result publication compares request, data revision, range/week and civil context. It already avoids decoding the weekly cache on every render.
- FullDayChartView already reads SQL-bucketed series at a target of 600 points and separates gesture movement from settled-window queries. Zone totals use a fixed-resolution day read and retain their day identity. These are existing optimizations, not new work attributed to this audit.
- MetricExplorer publishes the primary series first, guards subsequent results by revision/cancellation, then loads comparison series. Its correlation cache is invalidated for each load. Binary-search slice boundaries and precomputed date numbers are already present.
- Workout detail already resolves the tapped time window before broad comparison history, avoids HR reconciliation for the secondary comparison read and checks cancellation before publishing its expensive zone timeline. Heart-rate series rejects non-finite sample values; curve geometry and rail-label placement are still recomputed during view updates, but no measured runtime evidence supports changing them here.
- Today day-scoped loads already capture revision/day/presentation identity and gate the final commit; stress paths use explicit source/read identities. Historical data cache behavior and UI value invalidation were examined separately from live-workout hot-path work owned by the parent.
- Local Coach ordinary conversation persistence already has source-separated storage, serialized/coalesced writes, hydration ownership, protected-data retry, bounded file size, delayed-publication guards and a finite background flush lease. The weekly path was the exception fixed above.
- AppModel's performance lifecycle adapter already forwards through one existing lifecycle/migration owner. Realtime leases are token owned. NavRouter queues cold notification taps, waits for repository/lift-source readiness and defers routes behind active workout/onboarding blockers without starting a workout from a notification.
- Lift illustration loading is already detached/coalesced and count/cost bounded. Profile avatar decoding is small, bounded input; without native profiling, adding another cache would be speculative.

No Instruments, simulator interaction, memgraph, physical device or frame-time profiling was possible in this Linux audit. No numeric performance improvement is claimed for UI/chart work. No unmeasured caching/refactor optimization was added.

## Suspected issues retained for follow-up, not included as confirmed fixes

1. **SleepView late loader completion:** around `SleepView.swift:358–388`, cancellation is checked after sleep-history load, but subsequent invalid-session/habitual-midpoint/motion awaits assign state and rebuild using current `dataKey` without a final captured-generation check. A slow old task may commit after a replacement task. The actual view lifecycle needs a deterministic suspended-read/native test before this is promoted to a confirmed fix. The data agent owns sleep edit/delete/undo fixes; no overlapping changes were made here.
2. **Deep Timeline initial landing:** `FullDayChartView.swift:520–529` marks its one-time landing before awaiting latest-data lookup, then can assign `dayStart` without verifying that the person has not stepped to another day while waiting. Native suspended lookup + manual navigation is the relevant reproduction. No redesign or speculative fix was made.
3. **Chart/correlation render work:** body-driven maps/reductions in bounded timelines and larger MetricExplorer correlation processing warrant profiling only if a measured hitch identifies them. Cost, user impact and device behavior have not been demonstrated; no severity or optimization claim is assigned.
4. **Settings avatar picker completion:** focused inspection found unowned async photo loading; rapid replace/remove may be able to overwrite a newer selection. No native reproduction was performed and this cosmetic-adjacent path was not changed.

## Cross-domain coordination

The data agent received the exact sleep-edit call chain: editor creation carries immutable detected start and effective displayed bed time separately; save at `SleepView.swift:402–404` originally passed detected start/current wake/stored stages only, while delete uses detected identity. This corroborates the data agent's canonical-row ownership and repeated-clip findings. That agent owns the repository fixes and the authorized narrow SleepView undo feedback/identity follow-up. This agent did not modify SleepView or repository source.

## Verification artifacts and limits

Preserved evidence: `/workspace/scratch/fc582a8e42a6/coach-audit-evidence`, with an equivalent `.tar.gz` archive. Original working harnesses are `/tmp/noop-ui-coach-harness` and `/tmp/noop-ui-weekly-harness`. Each contains a README explaining exact extraction/stubs, baseline source/test snapshots, actual current test source, the sync script and red/green logs. Cloud original-baseline results are `red-all.log` (26 cases), retry-boundary red results are `retry-red.log` (4 cases, 2 failures), and final fixed results are `green-all.log` (30 cases, no failures). Weekly results are `red.log` and `green.log` (8 cases). Both were compiled/run with Swift 6.4.1, unique scratch directories, explicit shared module/cache directories, and synthetic inputs only. The shell used pipefail for final runs, so red exit codes are nonzero and green exit codes are zero. Scoped `git diff --check` and the 32-file literal proof also passed after the retry fix.

Native CI still needs to compile the complete iOS target and run `AICoachRequestOwnershipTests`, `AICoachRefreshModelsRaceTests`, `AIProviderModelListTests`, `AICoachPromptAndStressTests`, `AICoachPortTests`, `LocalCoachWeeklyInsightOwnershipTests`, `LocalCoachEngineTests`, and existing `WeeklyDigestTests`. Native UI/runtime behavior is not implied by the Linux method harnesses.

## Reviewed-file manifest

“Full logic review” means the relevant source file's executable behavior was read, not a claim of exhaustive formal verification. “Focused” lists the portions/call paths inspected. “Index” means pattern/test-name inspection only and is not counted as complete code review. The 32-file literal-preservation inventory is separate and does not imply complete logic review of every Coach UI file.

### Policy, cloud Coach and local Coach

| File | Coverage |
|---|---|
| `AGENTS.md` | Full repository instructions |
| `docs/CONTRIBUTING.md` | Full contribution/release/test instructions |
| `CONTRIBUTING.md` | Full contribution instructions |
| `project.yml` | App/test source inclusion and Swift 6/warnings settings |
| `Strand/AI/AICoach.swift` | Full logic review, ownership fix and test seams |
| `Strand/AI/AIProvider.swift` | Full logic review, provider contracts/shared transport |
| `Strand/AI/Providers/Custom.swift` | Full logic review and endpoint snapshot fix |
| `Strand/AI/Providers/OpenAI.swift` | Full provider logic review |
| `Strand/AI/Providers/Anthropic.swift` | Full provider logic review |
| `Strand/AI/Providers/Gemini.swift` | Full provider logic review |
| `Strand/Screens/CoachView.swift` | Focused setup, consent, disconnect, send/task and transcript paths |
| `StrandiOS/Coach/LocalCoachEngine.swift` | Full state/async/persistence logic review; prompt literals read only |
| `StrandiOS/Coach/LocalCoachModels.swift` | Full model/data-shape review |
| `StrandiOS/Coach/LocalCoachPersistence.swift` | Full persistence ownership/IO review |
| `StrandiOS/Coach/LocalCoachDataService.swift` | Focused source/read fencing and query contracts |
| `StrandiOS/Coach/LocalCoachView.swift` | Focused lifecycle, input preparation and cancellation |
| `StrandiOS/Coach/CoachConversationView.swift` | Focused transcript rendering/scroll/feedback state |
| `StrandiOS/Coach/LocalCoachLibraryViews.swift` | Focused cloud-Coach navigation call site |
| `Packages/StrandAnalytics/Sources/StrandAnalytics/WeeklyCoachInsightStore.swift` | Full review and durable owner fix |
| `Packages/StrandAnalytics/Sources/StrandAnalytics/WeeklyDigest.swift` | Focused Monday/civil-date helpers and insight call contracts |

### UI, historical views, app state and lifecycle

| File | Coverage |
|---|---|
| `Strand/Screens/TrendsView.swift` | Full loader/task/snapshot/cache ownership review |
| `Strand/Screens/TrendsView+WeeklyReview.swift` | Focused 1–235, weekly rendering/cache selection and bounded mover processing |
| `Strand/Screens/TrendsView+SelectedRange.swift` | Index of task/compute paths; snapshot consumption |
| `Strand/Screens/TrendsSnapshotModels.swift` | Index of cancellation and transforms; no full logic-review claim |
| `Strand/Screens/FullDayChartView.swift` | Full loader, render, gesture, annotation and initial-navigation review |
| `Strand/Screens/MetricExplorerView.swift` | Focused state, body transforms, primary loader and correlation pipeline (735–949) |
| `Strand/Screens/SleepView.swift` | Focused loader 310–388, edit/delete/undo 391–575, main/nap edit construction, cached Night model and WakeEdit representation |
| `Strand/Screens/StrapComparisonCard.swift` | Full core loader/source binding and bounded history review |
| `Strand/Screens/WorkoutHeartRateCurve.swift` | Full render/geometry/scrub identity review |
| `Strand/Screens/WorkoutDetailModel.swift` | Full pure presentation/series/elapsed-rule review |
| `Strand/Screens/WorkoutHistoryChart.swift` | Focused full chart/grouping path; UI prose not exhaustively audited |
| `Strand/Screens/WorkoutDetailView.swift` | Focused 165–257 loader/secondary-history/zone work; route export task index |
| `Strand/Screens/WorkoutSummaryView.swift` | Task/load and presentation index only |
| `Strand/Screens/WorkoutsHubModel.swift` | Transform/reduction index only |
| `Strand/Screens/TodayView.swift` | Focused lifecycle/task identities, day-scoped commit/cache guards, history-wide loader and stress-ribbon ownership; not all 5k+ view lines |
| `Strand/Screens/StressView.swift` | Focused 148–205 source/read/terminal-state ownership; compute index elsewhere |
| `Strand/Screens/HealthView.swift` | Refresh/task index only |
| `Strand/Screens/LiftExerciseComponents.swift` | Full illustration IO/coalescing/cache review |
| `Strand/Screens/ProfileAvatarView.swift` | Full bounded image render review |
| `Strand/Screens/SettingsView.swift` | Focused avatar selection/removal paths near 370–400 and 875–900 |
| `Strand/Screens/BreathingView.swift` | Timer/input/lifecycle index and stop-on-disappear path |
| `Strand/Screens/BiofeedbackController.swift` | Timer/work-item lifetime and stop/cancel index; no hardware operations |
| `Strand/App/LatestWinsLoadState.swift` | Full request/terminal ownership review |
| `Strand/App/NavRouter.swift` | Full navigation/notification queue/blocker/visibility review |
| `Strand/App/AppModel+PerformanceLifecycle.swift` | Full migration forwarding and realtime lease ownership review |
| `StrandiOS/App/RootTabView.swift` | Focused routing/lifecycle/source observers 320–395 and notification/Coach route readiness |
| `StrandiOS/App/StrandiOSApp.swift` | Environment/lifecycle wiring index only |
| `Strand/Data/Repository.swift` | Focused source/database identity, fence epoch, restore boundary, sleep edit/delete calls and history-loader contracts; full data audit delegated |

### Notifications

| File | Coverage |
|---|---|
| `Strand/System/NotificationCoordinator.swift` | Full 1–735 delivery, IPC, ledger, scheduling and cancellation review |
| `Strand/System/NotificationSchedulePlanner.swift` | Full scheduling/expiry/day arithmetic review |
| `Strand/System/NotificationJournalEligibility.swift` | Full completion/eligibility review |
| `Strand/System/NotificationPresenter.swift` | Full foreground/tap/action routing review |
| `Strand/System/NotificationFactBuilder.swift` | Full qualified-input and canonical-workout gate review |
| `Strand/System/BatteryNotifier.swift` | Full observation/episode/rearm/withdrawal review |
| `Strand/System/IllnessNotifier.swift` | Full explicit-disabled phone producer review |
| `Strand/System/WindDownNudge.swift` | Full permission-generation and civil-time scheduling review |
| `Strand/Data/NotificationPreferences.swift` | Full settings/migration/revision/validation review |
| `Strand/Screens/NotificationSettingsView.swift` | Full permission UI and schedule/control wiring review |

### Tests

| File/group | Coverage |
|---|---|
| `StrandiOSTests/AICoachRequestOwnershipTests.swift` | Authored, full review, production-engine red/green execution |
| `StrandiOSTests/LocalCoachWeeklyInsightOwnershipTests.swift` | Authored, full review, production-method red/green execution |
| `StrandiOSTests/AICoachRefreshModelsRaceTests.swift` | Full review and baseline/fixed harness execution |
| `StrandiOSTests/AIProviderModelListTests.swift` | Full review and baseline/fixed harness execution |
| `StrandiOSTests/AICoachPortTests.swift` | Full reviewed tests; native execution pending |
| `StrandiOSTests/AICoachPromptAndStressTests.swift` | Test-case index and prompt/stress contract review; native execution pending |
| `StrandiOSTests/LocalCoachEngineTests.swift` | Focused consent/source, tool budget, persistence/hydration and daily-widget cases plus helper seams; not full-file execution |
| `StrandiOSTests/LocalCoachDataTests.swift` | Test-case index only |
| `StrandiOSTests/CoachEvidenceIntegrationTests.swift` | Source/evidence test index only |
| `StrandiOSTests/PerformanceLifecycleOwnershipTests.swift` | Full review |
| `Packages/StrandAnalytics/Tests/StrandAnalyticsTests/WeeklyDigestTests.swift` | Existing cache tests 425–475 and date/test index |
| `StrandiOSTests/NotificationCoordinatorTests.swift` | Focused race-test names/contracts for permission, old-store cleanup, claims, source and initialization |
| `StrandiOSTests/NotificationProducerMigrationTests.swift` | Focused charging/snooze/observation race test index |
| `StrandiOSTests/NotificationPreferencesTests.swift` | Validation/migration test index |
| `StrandiOSTests/NotificationRoutingTests.swift` | Source/readiness/date routing test index |
| `StrandiOSTests/NotificationScheduleTests.swift` | DST/repeated-minute/expiry/identity test index |
| `StrandiOSTests/NotificationJournalEligibilityTests.swift` | Completion and withdrawal test index |
| `StrandiOSTests/NotificationFactBuilderTests.swift` | Canonical/finiteness test index |
| `StrandiOSTests/WindDownPerDayOverrideTests.swift` | Per-day/wrap/clamp test index |
| `StrandiOSTests/BatteryAlertPolicyTests.swift` | Hysteresis/rearm/charging test index |

Additional Battery* test filenames appeared in the search inventory; they were not substantively reviewed and are not represented as audited logic.
