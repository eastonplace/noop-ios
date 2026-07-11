# T108 dead-control gate

Build: `NOOPiOS`, Debug iPhone Simulator, iPhone 17 Pro Max, `--demo-seed` — PASS.

## Dead control

- The Recovery recommendation still pushes the same scoring guide destination: [entry proof](qa/t108-scoring-guide/recovery-entry.png).
- Its constructor no longer supplies an empty callback. `ScoringGuideView.close()` invokes an explicit callback for sheet hosts and otherwise calls the environment `dismiss()` for navigation pushes.
- Both visible exit controls (header Close and footer Got it) call that shared function: [guide proof](qa/t108-scoring-guide/page-1.png).
- Internal guide anchors and user-facing copy now consistently use Recovery / Strain / Sleep. No stale 0–100 Strain teaching copy remains; Strain is described and illustrated on 0–21.
- The former comment claiming Android mirrors the `charge` / `effort` / `rest` identifiers is stale after this Apple rename. Android synchronization is out of scope.

## Honesty carry-alongs

- Trends scaffold overline and Week in Review card both render from `weekOffsetLabel`: [Last week proof](qa/t108-carry-alongs/trends-last-week.png).
- Health Monitor reads the same published `AppModel.healthAlert` state as `HealthAlertBanner`; when the seeded engine alert fires it says “Metrics outside your range”: [alert-state proof](qa/t108-carry-alongs/today-alert-caption.png).
- No scoring, alert, baseline, or weekly-digest math changed.
