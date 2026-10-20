# Noop notification plan and 540-case catalog

Prepared October 20, 2026 for Easton Place and `eastonplace/noop-ios`.

**Recommendation:** Build one shared local notification policy, then release eight useful groups. The 540-case catalog supplies future context and variations. Each selected message must pass data, consent, timing, relevance, privacy, and repeat checks.

## Start here

| File | Purpose |
| --- | --- |
| `Noop_Notification_Plan.pdf` | Six-page visual overview of the recommendation, evidence, rollout, and limits. |
| `Noop_Notification_Catalog_540.xlsx` | Filterable workbook with every scenario and family. |
| `CODEX_PROMPT.md` | Ready-to-paste implementation instruction. Attach this folder with it. |
| `docs/PRODUCT_SPEC.md` | Full product and architecture specification. |
| `docs/IMPLEMENTATION_PLAN.md` | Five concrete tasks, proposed files, tests, and PR expectations. |
| `docs/REPO_AND_WHOOP_EVIDENCE.md` | Pinned repo findings and official WHOOP and Apple sources. |
| `docs/CATALOG_GUIDE.md` | Fields, interpretation, release mapping, and query examples. |
| `catalog/FAMILY_INDEX.md` | 54-family index and scenario ranges. |
| `catalog/notification_catalog.json` | Complete machine-readable 540-case catalog. |
| `catalog/notification_catalog.csv` | Flat export for other spreadsheet or analysis tools. |
| `notification_policy.json` | Proposed defaults, lane separation, freshness, and privacy rules. |
| `docs/QA_MATRIX.md` | 96 separate failure and platform cases. |
| `validation/validate_catalog.py` | Reproducible design-inventory validator. |
| `validation/VALIDATION_REPORT.json` | Executed catalog-check results and channel counts. |

## What the count means

There are 540 positive user-visible possibilities, arranged as 54 families with ten scenarios each. The catalog labels local notifications, in-app cards, and digest items separately. They are not all enabled, and they are not 540 independent posting jobs. An eligible event can match several variants and still produce one selected message.

The separate failure matrix is excluded from the 540. The count also excludes generic silence cases and wording-only permutations. Example measurements and times are fictional fixtures. All new thresholds and attention limits are proposed Noop product settings unless explicitly identified as an existing rule.

## First release

Morning summary, wind-down, scheduled workout, workout result, canonical strain target, charging before recording, weekly review, and journal check-in. Recovery-dependent choices wait for the reviewed recovery repair and valid current data. Keep later habits optional. Future load splits and unsupported data features remain Deferred.

## Evidence and verification

This is a research and design handoff. Repository work was read-only. No app code was changed, no PR was merged, and no iOS build or physical-device notification test was performed. The package includes executed structural catalog checks and rendered artifact review. Those checks are different from the future app checks in the implementation plan.

The repository and public-source findings are pinned to the evidence snapshot. Codex must recheck the latest main and open PRs before implementation. A WHOOP phone notification, a strap vibration, and an in-app warning are identified separately where the sources allow it.
