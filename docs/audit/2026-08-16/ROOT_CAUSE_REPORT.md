# Root-cause report

## Stress

`StressView` previously entered its loaded branch only when the daily model was non-nil. A valid intraday result without a daily model therefore fell through to an empty state. The analytics formulas were not the cause. The repair adds `StressPresentation` and an explicit mode so combined, intraday-only, daily-only, baseline-calibration, and empty states are distinct. `TodayView` now uses the same mode semantics.

Failure, cancellation, stale-owner, and retry behavior remain owned by `LatestWinsLoadState`; the focused retry test confirms a failed request can become a new owner.

## Home skin temperature

Home previously assembled display values through paths that did not carry one dated identity through both the tile and rail. The new resolver selects the newest valid recent daily value on or before the target day, carries day, age, source identity, and freshness, and keeps absolute and deviation trails separate. It uses the existing source precedence and does not change conversion, baseline, wear tolerance, sample minimum, or conflict rules.

The current phone database/log trace was not available. The first failed raw-to-nightly pipeline stage is therefore not identified, and no pipeline change was made.

## Widgets

The source has a verified sink contract that requires an active matching epoch/context token before publication. Static inspection shows a conditional gap: a valid projection with a missing or corrupt token and no pending transition can remain without a verified sink. The installed app’s actual token, App Group state, and launch logs were not available in this run, so the gap is not proven on the current phone.

The branch adds a pure, idempotent policy seam and tests for keep, wait, clear-closed, missing, and mismatched states. It does not wire a launch repair into `AppModel` without the required device evidence.

## Settings

Settings and More had row arrays but no shared searchable catalog. The new catalog supplies stable row IDs, route IDs, section IDs, breadcrumbs, titles, subtitles, and keywords. Existing row actions and stored keys remain unchanged. Filtering is added to both surfaces.

The larger destination enum/router and physical file split are not included in this slice because the current request’s evidence gates do not prove a behavior-safe migration of the full Settings file.

## WHOOP-only scope

The audit did not find evidence sufficient to remove non-WHOOP runtime sources, packages, or schema compatibility in this pass. WHOOP 4, 5, and MG support, standard WHOOP live-HR code, Apple Health import, legacy reads, export, and migration compatibility remain preserved. Removal is staged as a separate future series.
