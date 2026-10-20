# Noop notifications implementation plan

> For agentic workers: use a task-based implementation workflow with independent review. Follow current repository instructions. Each task below ends with a testable result.

**Goal:** Add useful local notifications with correct data, controlled frequency, and direct routes to the relevant result.

**Architecture:** Existing canonical data feeds a pure policy. One coordinator owns local notification submission and cancellation. A small SQLite ledger records event identity and outcomes.

**Tech stack:** Swift, SwiftUI, UserNotifications, existing StrandAnalytics and WhoopStore packages, GRDB, and current iOS lifecycle hooks.

**Spec:** `PRODUCT_SPEC.md`. Read `REPO_AND_WHOOP_EVIDENCE.md` before choosing the implementation base.

## Global constraints

- Recheck latest main and open PR #62/#63. The reviewed base was `00eadc67c23fee97fd064f1aeb6d79b7a7f2e537`.
- Recovery-dependent new pushes require the reviewed repair from #62 or an equivalent tested fix, plus current repaired data.
- Preserve existing alarm behavior, canonical sources, imported-data ownership, and user settings.
- New push groups start off for existing installations. Breathe and Hydrate require explicit selection.
- Use the spec's proposed proactive limits: 2 per local day, 10 per rolling 7 days, 3 hours apart.
- Explicitly selected reminders retain their own schedule. Proactive advice yields within 30 minutes of those reminders.
- New proactive quiet hours default to 21:00–08:00 local. A selected reminder time grants a scoped exception.
- Use local deterministic eligibility. Do not add APNs, a background polling loop, or model-based send decisions.
- Keep the current Training Load UI. Defer split-load alerts until their measurement contract exists.
- Count submission separately from presentation. Never log `delivered` just because `add` succeeded.

## Review focus

| Failure class | Required behavior | Owning task |
| --- | --- | --- |
| Same evidence arrives twice, including after a restart | One occurrence claim; no duplicate notice. | 1 and 2 |
| Yesterday's score appears in today's UI | Preserve display behavior; suppress a new current-day claim. | 1 and 4 |
| Timezone or DST changes a saved schedule | Correct local occurrence with no extra or obsolete request. | 3 |
| The user opens a notice after its data changes | Open the correct record and show current status. | 3 |
| Permission, source, or category changes during submission | Revalidate, cancel obsolete work, and keep the ledger accurate. | 2 and 3 |

## Task 1. Build pure decisions from canonical facts

**Create:**

- `Packages/StrandAnalytics/Sources/StrandAnalytics/NotificationModels.swift`
- `Packages/StrandAnalytics/Sources/StrandAnalytics/NotificationPolicy.swift`
- `Packages/StrandAnalytics/Sources/StrandAnalytics/NotificationRules.swift`
- `Packages/StrandAnalytics/Tests/StrandAnalyticsTests/NotificationPolicyTests.swift`

**Proposed interfaces:**

```swift
public enum NotificationRuleEvaluator {
    public static func candidates(from facts: NotificationFacts) -> [NotificationCandidate]
}

public enum NotificationPolicy {
    public static func evaluate(
        candidates: [NotificationCandidate],
        preferences: NotificationPreferencesSnapshot,
        context: NotificationRuntimeContext,
        history: NotificationHistorySnapshot,
        now: Date
    ) -> NotificationEvaluation
}
```

These signatures define the intended boundary. Codex must implement and compile them in the current package layout.

`NotificationFacts` contains typed optional evidence with source, metric day, observation time, finality, and model version. `NotificationEvaluation` contains selected candidates and rejected candidates with reason codes. Keep display copy downstream of eligibility. An unresolved dependency must return no enabled push candidate.

- [ ] Write cases for missing versus zero values, nonfinite values, stale carries, source switches, model changes, and historical replay.
- [ ] Run `swift test --package-path Packages/StrandAnalytics --filter NotificationPolicyTests`; record the initial failure.
- [ ] Implement the small launch rule set, coalescing, stable tie breaks, expiry, and the exact policy limits.
- [ ] Run the focused tests; prove one selected message for each collision fixture and no stale candidates.
- [ ] Review the patch and commit this isolated task.

## Task 2. Add durable claims and the delivery coordinator

**Create:**

- `Packages/WhoopStore/Sources/WhoopStore/NotificationDecisionStore.swift`
- `Packages/WhoopStore/Tests/WhoopStoreTests/NotificationDecisionStoreTests.swift`
- `Strand/System/NotificationCoordinator.swift`
- `Strand/System/NotificationFactBuilder.swift`
- `StrandiOSTests/NotificationCoordinatorTests.swift`

**Modify:** the existing WhoopStore migration registration at its current next migration number. Inspect it first. Do not reuse v59 or the v60 from draft #62.

**Proposed interfaces:**

```swift
public func claim(_ reservation: NotificationReservation) async throws -> ClaimResult
public func recordSubmission(_ occurrenceID: String, requestID: String, at: Date) async throws
public func recordFailure(_ occurrenceID: String, reason: String, at: Date) async throws
public func withdraw(_ occurrenceID: String, at: Date) async throws

@MainActor
func process(_ facts: NotificationFacts, reason: NotificationEvaluationReason) async
```

The store methods belong to `NotificationDecisionStore`. `process` belongs to `NotificationCoordinator`. Inject a clock, notification-center adapter, and preferences provider. Family claims, shared cross-family attention keys, and budget reservations must share a transaction. Use a stable request identifier derived from the occurrence, not a random value on each retry. Keep database generation separate from stable event identity.

- [ ] Add tests for simultaneous and sequential cross-family callbacks, restart before/after submission, failed adds, dismissed notices with unknown submission outcomes, and independent paired devices.
- [ ] Run focused store tests and coordinator tests; record the failures before implementation.
- [ ] Implement the ledger, bounded retries, pending-state reconciliation, and a 30-day metadata retention policy.
- [ ] Verify that `add` success records submitted, known failure releases a reservation, uncertain outcomes do not trigger blind retries, and one shared event cannot consume two slots.
- [ ] Review migration compatibility with #62 and commit the task.

## Task 3. Make settings, schedules, and taps reliable

**Create:**

- `Strand/Data/NotificationPreferences.swift`
- `StrandiOSTests/NotificationRoutingTests.swift`
- `StrandiOSTests/NotificationScheduleTests.swift`
- `StrandiOSTests/NotificationPreferenceMigrationTests.swift`

**Modify:**

- `Strand/System/NotificationPresenter.swift`
- `Strand/System/WindDownNudge.swift`
- `Strand/App/NavRouter.swift`
- `Strand/Screens/AutomationsView.swift`
- `Strand/Screens/SettingsRouteCatalog.swift`
- `StrandiOS/App/StrandiOSApp.swift`
- `StrandiOS/App/SmartAlarmRuntimeController.swift` only at the reviewed notification boundary

Find the current root route consumer before editing it. Coordinate settings work with draft #63. Keep the active-workout and onboarding guards.

**Proposed interfaces:**

```swift
struct NotificationRoutePayload: Codable, Equatable, Sendable {
    let version: Int
    let occurrenceID: String
    let destination: NotificationDestination
}

@MainActor
func handleNotificationResponse(_ payload: NotificationRoutePayload)

@MainActor
func reconcileSchedules(reason: ScheduleReconciliationReason) async
```

Routes carry stable day, workout, or device identifiers. Serialize only supported destinations. Actions use typed IDs. A tap never starts exercise or changes a plan. Snooze keeps the original expiry and is unavailable after it.

Expiry governs app eligibility and submission, not a guaranteed OS presentation deadline. Pre-scheduled requests use generic copy and cancel when changed state is observed. Resolve one-shot DST occurrences by the spec's explicit policy; test OS repeating calendar behavior separately. Treat 24 pending routine requests as a management target and never silently drop selected reminders to meet it.

- [ ] Write tests for cold launch, removed records, hidden tools, active sessions, provisional permission, and all current preference migrations.
- [ ] Add DST spring/fall, Sunday/Monday wind-down, timezone travel, schedule-edit, and disable-after-enqueue cases.
- [ ] Implement typed routing, private previews, foreground policy, scoped actions, and lifecycle schedule reconciliation.
- [ ] Build the app and run these tests on an installed simulator. Confirm obsolete identifiers disappear and future alarms remain.
- [ ] Review normal and large-text Settings screens, then commit.

## Task 4. Migrate existing alerts and add the launch rules

**Modify existing producers:**

- `Strand/System/BatteryNotifier.swift`
- `Strand/System/IllnessNotifier.swift`
- `Strand/System/WindDownNudge.swift`
- `Strand/App/AppModel.swift`
- `Strand/Data/Repository.swift` at canonical commit/publication seams
- `StrandiOS/App/AppModel+iOS.swift` and existing lifecycle completion hooks as needed

**Reference upstream behavior:** `StrainTargetNotifier.swift`, `BatteryNotifier.swift`, Android `ScheduledReportNotifier.kt`, and Android `IllnessAlertNotifier.kt`. Read pinned files listed in the evidence report. Do not merge all upstream code or restore unrelated platform UI.

**Create tests:** `NotificationFactBuilderTests`, `NotificationProducerMigrationTests`, `NotificationLaunchRuleTests`, and a catalog-to-rule mapping fixture. Use the repository's existing test target conventions.

- [ ] Map the eight launch groups to catalog families and exact current producers; mark every dependency in a checked-in mapping.
- [ ] Add tests for battery coalescing, persisted health episodes, sleep-episode dedupe, settled workout summaries, and target units.
- [ ] Route existing producers through the coordinator and implement only the selected launch groups.
- [ ] Verify that imported or repaired old sessions create no fresh push; check that #62-dependent rules remain gated until current data is valid.
- [ ] Remove obsolete duplicate posting code, review the diff, and commit.

Preserve canonical displayed strain. Do not sum workout scores to invent daily strain. Keep the 7/42 Training Load ratio separate from the 7/28 Readiness ratio. Reuse the fork's current Sleep Need V2 planner instead of upstream's fixed need.

## Task 5. Qualify behavior and open a draft PR

**Create:** a concise implementation report with commands, exact heads, and unverified device conditions. Add screenshots of notification settings and each launch destination at normal and accessibility sizes.

The catalog's 540 entries are product cases. They are not 540 existing production rules. Implement focused behavior tests for the selected families and the shared policy. Run catalog validation to check the design files separately.

Repository evidence (2026-10-20): the recovered original 540-row catalog, separate failure matrix and artifact validation are retained under `handoff/`. Run the retained catalog validator for design-library checks. `SOURCE_COVERAGE.md` records the bounded first-release source audit; it does not replace design validation or Apple execution gates.

- [ ] Run the changed package suites and the project's required source audits.
- [ ] Generate the Xcode project with `xcodegen generate`; build and test scheme `NOOPiOS` on an installed simulator.
- [ ] Test real-device notification permission, lock state, background delay, Focus, time changes, and strap reconnect when available.
- [ ] Record every command and observed result. Mark physical-device checks as not run if no device is available.
- [ ] Open one detailed draft PR with screenshots, remaining gates, and a rollback switch. Leave merge and installation for review.

### Build commands

The current README uses XcodeGen and scheme `NOOPiOS`. Select an installed simulator with `xcrun simctl list devices available`; do not assume a fixed model exists.

```bash
swift test --package-path Packages/StrandAnalytics
swift test --package-path Packages/WhoopStore
xcodegen generate
xcodebuild -scheme NOOPiOS -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

For tests, supply the verified simulator ID to `-destination 'platform=iOS Simulator,id=<verified-id>'`. Run the project's current required checks after inspecting its instructions. This handoff did not execute these app commands.

## Later work

Use P2 and P3 catalog families as a reviewed backlog. Keep optional habits, repeated patterns, and coaching commitments off until selected and supported. Deferred rows must wait for their explicit data and route dependencies. An aerobic/anaerobic alert cannot pass solely because a workout was labeled Strength or contained high heart rates.
