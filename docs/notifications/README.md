# Notifications implementation

This change implements the first release from the approved notification plan. The original 540-case catalog remains a design backlog. Production uses a small set of deterministic rules and one delivery coordinator.

## User controls

**Settings → Notifications** owns phone permission status, category choices, selected schedules, quiet hours, preview privacy, a proactive pause switch and an optional Essentials selection. It links to the existing wrist controls and wake-alarm editor. Existing battery, prediction, illness and wind-down preferences keep their original persisted keys. New categories start off.

The initial release supports:

| Group | Behavior |
| --- | --- |
| Wind-down | Generic reminder calculated from the canonical Sleep Need plan, chosen wake time and lead. Daily or weekday calendar recurrence. |
| Planned workout | Generic reminder for a saved Lift plan with an explicitly chosen time. Date-only legacy plans need a time saved before they qualify. |
| Completed workout | Current, locally completed sessions only, after canonical strain has settled. No imported or historical-session replay. |
| Device charging | Existing low, predictive-runtime and full-charge choices, with durable per-device charging episodes. |
| Weekly review | Chosen weekly reminder opening the latest completed Monday-Sunday review period. |
| Journal | Chosen weekdays and time, opening the exact journal date. A completed entry is skipped when the app reconciles the schedule. |
| Morning summary | Choice is saved; delivery awaits the separate recovery repair and a qualified canonical-data adapter. |
| Daily strain target / health patterns | Choices are saved; delivery awaits the separate recovery repair and qualified current inputs. |

The recovery gate is explicit in `NotificationFactBuilder`. Merging recovery PR #62 alone must not activate these groups: the adapter, qualification tests and gate must be reviewed together in a later change. PR #63 remains independent.

Journal and workout reminders are prepared seven days ahead and replenished during normal app execution. Wind-down and weekly reminders repeat through the OS. iOS cannot rerun app eligibility at the moment a local request is displayed, so future copy stays generic and changed/completed schedules are cancelled when the app observes them.

## Delivery contract

- Proactive notices have a limit of 2 per local calendar day, 10 per rolling seven days and a minimum three-hour gap. They yield within 30 minutes of a chosen reminder.
- Proactive quiet hours default to 21:00–08:00. A deliberately selected reminder time is a scoped exception.
- New routine notices use normal interruption priority and no sound. Existing alarm/session behavior retains its independent owner.
- Health-detail previews default off. Future reminders contain no predicted score or sensitive journal answer.
- Occurrence identity, shared attention identity and the budget reservation are claimed atomically in SQLite. A source revision cannot create another occurrence for the same event.
- A successful OS `add` is recorded as submitted, not delivered. Unknown outcomes retain a conservative claim; known failures have at most one retry.
- Source changes, disabled categories, expired records and removed plans are reconciled with requests owned by this coordinator. Unrelated alarm requests remain owned by their existing code.
- Taps carry typed record IDs, wait for onboarding/source/session readiness, and open read-only destinations. A tap cannot start or complete a workout.

`Preview new advice without sending` records eligible new advice locally. The proactive pause switch leaves explicitly chosen schedules and wake alarms available.

## Implementation map

| Area | Main paths |
| --- | --- |
| Pure eligibility, coalescing and reason codes | `Packages/StrandAnalytics/Sources/StrandAnalytics/Notification{Models,Policy,Rules}.swift` |
| Durable claim/audit/episode state | `Packages/WhoopStore/Sources/WhoopStore/NotificationDecision{Migration,Store}.swift` |
| Preferences and unified UI | `Strand/Data/NotificationPreferences.swift`, `Strand/Screens/NotificationSettingsView.swift` |
| Canonical facts, delivery and schedules | `Strand/System/Notification{FactBuilder,Coordinator,SchedulePlanner}.swift` |
| Notification responses and routes | `Strand/System/NotificationPresenter.swift`, `Strand/App/NavRouter.swift`, `StrandiOS/App/RootTabView.swift` |
| Lift plan timing and completion integration | `Packages/ReceiptLiftFeature`, `Strand/Data/NoopReceiptLiftIntegration.swift` |

Migration `v61-notification-decisions` is independent of the recovery branch's `v60` migration. Compact identity tombstones and active recurring requests outlive the 30-day decision/audit retention so old events cannot replay and future requests remain cancellable.

## Validation and review

The temporary Linux Swift 6.3.3 harnesses compiled the exact new policy sources and the exact ledger/migration sources. The ledger harness uses real SQLite and pinned GRDB with a minimal store wrapper; it does not replace the full production migration suite.

- Policy harness: 13 tests passed.
- SQLite ledger harness: 20 tests passed, including separate writer connections, disk reopen, unknown submission outcomes, bounded retry, retention, local-calendar budgets and migration ordering. A repeated-reconciliation regression was reproduced and fixed before the final run.
- A pure Foundation schedule harness verified DST spring/fall resolution and skipping date-only or completed plans.
- All 12 required source audits passed. Swift syntax parsing has passed for the changed implementation areas. Parsing does not establish Apple SDK type checking.

The existing GitHub workflows run the real retained packages, Xcode app build and iOS unit tests on the pushed PR. Their current status is recorded in the PR description. Linux cannot run Xcode, render SwiftUI screenshots or exercise device notification behavior.

Before merge, review the hosted Apple checks and manually verify normal/large-text Settings, lock-screen privacy, Focus behavior, cold-launch taps, permission revocation, timezone travel, reconnects and a real Lift completion. Physical-device checks and rendered UI screenshots are not claimed by this implementation report.

## Design references

- [Product specification](PRODUCT_SPEC.md)
- [Original implementation plan](IMPLEMENTATION_PLAN.md)
- [Repository and WHOOP research evidence](REPO_AND_WHOOP_EVIDENCE.md)
- [Launch catalog-family mapping](launch-rule-map.json)
