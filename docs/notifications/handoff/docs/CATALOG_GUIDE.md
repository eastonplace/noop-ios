# How to use the catalog

## One family, several useful variants

The catalog has 540 positive scenarios in 54 families. Each family has ten distinct situations. A situation changes a condition, action, timing, or destination. It does not create another independent posting loop.

For example, a saved workout can also contain a strength record and cross the day's strain target. That can match multiple rows. The coordinator should select or combine the most useful facts into one notification for the stable workout occurrence. If the person is already viewing its result, an in-app update is enough.

The 96 failure and platform cases are a separate inventory. They do not contribute to the 540 count.

## Delivery modes

| Value | Meaning |
| --- | --- |
| `local_notification` | A possible phone notification after opt-in and all policy gates. It can use a selected reminder time or fresh data, depending on the case. |
| `in_app` | A card, explanation, or status shown inside the app at the relevant time. It creates no phone interruption. |
| `digest` | An item in a combined review. Ten digest items still belong to one review, not ten phone notifications. |

An `in_app_only` family never produces a phone notification. P1 is first-release priority, P2 is the next optional expansion, and P3 is a later carefully reviewed expansion. Deferred means a named data, storage, or validation dependency prevents implementation as an enabled feature. These labels are proposed product decisions.

## Rule precedence

User consent, platform permissions, privacy, source validity, and explicit dependencies apply before a scenario can match. The stricter global or scenario-specific freshness and expiry wins. A family TTL is an upper bound; a scenario deadline can end earlier.

The proactive attention budget applies to proactive phone notifications. It does not cap in-app cards or digest contents. Those still need relevance, visibility, dismissal, and duplicate checks. Explicitly chosen reminder times keep their schedule and a scoped quiet-hour exception. A general quiet-hours or budget phrase in a scenario must be interpreted under these lane rules.

Current data means more than a newly read database row. Check the observation's metric day, source, model, finality, and coverage. Repaired historical data does not create a fresh event. Database generation is a freshness token, separate from stable occurrence identity.

## First-release mapping

| Launch group | Starting families | What to ship first |
| --- | --- | --- |
| Morning summary | SLP09 and REC01 | One completed-night/current-day summary. Recovery-dependent text waits for the reviewed repair. |
| Wind-down | SLP02; selected SLP01 planning context | Preserve the person's selected time and refresh the schedule when the current plan changes. |
| Scheduled workout | WT03 | Saved Lift schedule reminders with exact user-selected timing and current schedule revision. |
| Workout summary | WT01 and WT05 | A new saved workout or lifting receipt, combined when they are the same session. |
| Daily strain target | WT18 | One first supported crossing using canonical displayed strain and valid current target inputs. |
| Charge before recording | HC13 | One device-specific charging action, coalescing battery percentage and runtime evidence. |
| Weekly review | WT10 | A chosen review of the completed week; other sleep, recovery, and habit digest families can join later. |
| Journal check-in | HC01 | A selected check-in that cancels when its relevant saved entry is complete. |

SLP03, SLP13, HC15, and HC16 also provide useful maintenance cases for existing alarm and data behavior. Implement their necessary foundation fixes without turning every technical status into a push. P2 preparation insights in WT04 are expansion work, not required for the first scheduled-workout reminder.

## Fields Codex should use

| Field | Interpretation |
| --- | --- |
| `id` | Stable scenario reference for implementation mapping and acceptance tests. |
| `family_id` | Group that owns common data, cooldown, expiry, and dedupe semantics. |
| `trigger` | Eligibility condition expressed in plain language. Convert the chosen cases into typed, tested Swift logic. |
| `context` | The user decision that makes this case worth showing. |
| `title`, `body_template` | Detailed copy, intended for the destination and separately permitted health previews. |
| `example_values`, `rendered_body` | Fictional fixtures for review. They are not user health data. |
| `public_title`, `public_body` | Generic preview text. The app can improve its action specificity without revealing health or sensitive journal facts. |
| `detailed_copy_requires_field_level_privacy_check` | The detailed template is not a blanket permission to expose all of its contents. Sensitive journal context stays inside the app. |
| `action_label`, `destination` | Proposed action and typed route. A route must be implemented and resolve the correct stable record ID. |
| `delivery_window` | Useful time to show the case. Revalidate data-dependent copy at actual evaluation. |
| `priority` | Tie-breaking input after eligibility. It cannot override consent or expiry. |
| `suppression` | Scenario-specific reasons to stay silent, in addition to the global policy. |
| `acceptance` | Positive Given/When/Then specification. It is not an executed app test. |
| `required_data`, `dependencies` | Inputs and implementation gates inherited from the family. |
| `existing_code`, `source_urls` | Observed integration points or reference behavior. A source link does not validate a new product threshold. |

`readiness=existing_data_new_rule` means useful underlying data exists. The notification rule and any named adapter or derived comparison still need implementation. `upstream_port` means the behavior has a reference implementation in upstream. `pr62_dependency` requires the reviewed recovery repair and valid repaired results. `new_data_dependency` requires a new input or capability and stays Deferred.

## Query a small part at a time

Use Python's standard library from the handoff root:

```python
import json
from pathlib import Path

catalog = json.loads(Path('catalog/notification_catalog.json').read_text())
chosen = {'SLP09', 'REC01', 'WT01', 'WT05'}
families = [f for f in catalog['families'] if f['family_id'] in chosen]
cases = [s for s in catalog['scenarios'] if s['family_id'] in chosen]
print(json.dumps({'families': families, 'scenarios': cases}, indent=2))
```

For spreadsheet review, use the Catalog filters for Domain, Phase, Delivery, or Data readiness. The Families sheet shows common inputs and gates. The Overview counts are formulas linked to the underlying rows.

## Verification boundary

Run `python3 validation/validate_catalog.py` after changing the catalog. It checks structure, identifier counts, field limits, placeholders, routes, exact duplicate triggers, and the separate failure inventory. Human review is still required for meaningful distinctions, supported input assumptions, and product judgment.

The catalog validator does not compile Swift, exercise UserNotifications, or establish that an alert reached a phone. The implementation plan defines those separate checks. Keep unverified device conditions explicit in the eventual draft PR.
