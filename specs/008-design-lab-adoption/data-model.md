# Data Model 008 — Design Lab Adoption

This spec adds **no persistence**. No Repository/GRDB schema change, no new stored
keys, no widget/Live Activity payload change. Everything below is presentation state
and the component inventory model.

## Component Disposition Inventory

Dispositions per research D2. "Source" = lab file of record; "Target" = product home.

| Component | Disposition | Source (lab) | Target (product) |
|---|---|---|---|
| ValueToken (MicroValueToken) | Promote | ScopedMicroComponents.swift | StrandDesign/ValueToken.swift |
| MicroBadge | Promote | ScopedMicroComponents.swift | StrandDesign/MicroPrimitives.swift |
| MicroStatusDot | Promote | ScopedMicroComponents.swift | StrandDesign/MicroPrimitives.swift |
| ProgressDots (MicroProgressDots) | Promote | ScopedMicroComponents.swift | StrandDesign/MicroPrimitives.swift |
| MicroIconButton | Promote | ScopedMicroComponents.swift | StrandDesign/MicroPrimitives.swift |
| PaperSearchField (LabSearchField) | Promote | LabComponents.swift | StrandDesign/PaperSearchField.swift |
| PaperToast (ToastSpecimen) | Promote | ExpandedComponents.swift | StrandDesign/PaperToast.swift |
| SegmentedPillControl thumb+haptic | Upgrade | SegmentSelectorSpecimen | existing SegmentedPillControl |
| StatePill/StatusBadge pulse | Upgrade | StatusPill | existing StatePill/StatusBadge |
| PipBar | Parity (no change) | LabPipBar | existing PipBar |
| StatTile spark/delta | Parity | MetricTile | existing StatTile |
| Hypnogram | Parity + dim-others option | SleepArchitectureSpecimen | existing Hypnogram |
| Stage breakdown row | Adopt metrics/motion in place | SleepArchitectureSpecimen | SleepView.stageBreakdownRow |
| Sleep window strip | Parity | SleepWindowSpecimen | SleepView.paperSleepWindow |
| Stages vs typical row | Parity | SleepStageVsTypicalSpecimen | SleepView.stageRow |
| Debt ledger stagger | Adopt motion | SleepDebtLedgerSpecimen | SleepView.debtDeltaBars |
| Stress load line reveal/peak/legend | Adopt in place | StressLoadLineSpecimen | StressView.daytimeSection / DaytimeLoadLine |
| Stress band split rail | Replace fill style | StressBandSplitSpecimen | StressTotalsBar |
| Hourly strip opacity treatment | Adopt | StressHourStripSpecimen | StressTimelineBar |
| Marker tiles delta tint | Parity | StressMarkerTilesSpecimen | StressView.markerTile |
| Breathe nudge | Parity | StressNudgeSpecimen | StressView.sustainedBreatheCard |
| Trend summary rows | Promote pattern (app target) | TrendMetricRowSpecimen | TrendsView (new private view) |
| Day navigator numericText | Adopt | DayNavigatorSpecimen | DayNavBar call sites |
| Wizard/operation/live-vital/empty/skeleton | Parity | Expanded specimens | existing screens |
| LabCard, lab hypnogram fixture, dials, wordmark, route/breath/rhythm | Skip | — | — |

## Presentation State (new or modified)

### PaperToast

| Field | Type | Rule |
|---|---|---|
| `message` | LocalizedStringKey | required |
| `actionTitle` / `action` | optional | action tappable for full dwell |
| `isPresented` | Binding<Bool> | owner-controlled; toast never self-presents |
| dwell | 2.4 s constant | restart on re-present; cancel on disappear |

State machine: hidden → presenting(rise+fade in) → dwelling(2.4 s) → dismissing(fade)
→ hidden. Re-trigger during any state restarts dwell without stacking. Reduce Motion:
opacity-only in/out.

### SegmentedPillControl (upgraded)

| Field | Type | Rule |
|---|---|---|
| `selection` | Binding<T: Hashable> | unchanged public API |
| thumb | matchedGeometryEffect | one namespace per control instance |
| haptic | selection | iOS 17 `sensoryFeedback`; else `StrandHaptic` (D7) |

### StatePill / StatusBadge pulse

| Field | Type | Rule |
|---|---|---|
| `pulsing` | Bool (default false) | ring pulse 1.25–1.5 s; removed under Reduce Motion; only for live states |

### Sleep additions (SleepView-local, no model change)

- `selectedStage: SleepStage?` — exists; now also drives hypnogram dim-others overlay
  (segment opacity 1.0 selected-stage / 0.18 others when non-nil).
- Ledger `revealed: Bool` — appear-once flag; per-bar delay `index * 0.02 s`, capped
  at 14 bars (existing ledger cap).

### Stress additions (StressView-local, no model change)

- Load line `reveal: Bool` — trim 0→1 over 0.85 s ease-out on first appear only.
- Peak annotation derives exclusively from `day.peak` (hour + level); absent peak →
  no annotation view.
- Band legend constants: 0–1 / 1–2 / 2–3 labeled with `StressRamp.calm/steady/tense`.

### Trends summary rows (TrendsView-local)

| Field | Type | Rule |
|---|---|---|
| series | `[TrendPoint]` per metric | the exact array charted — single derivation |
| latest | last point value | formatted with the metric's existing formatter |
| delta | latest − previous period aggregate | signed; tint positive/negative by the metric's existing good-direction rule |
| spark | last ≤ 7 points | downsampled from the same series |

## Invariants

- No component in this inventory reads Repository, AppModel, or BLE state directly
  from within StrandDesign.
- `selectedStage`, `reveal`, `revealed`, toast presentation are view-local `@State` —
  never persisted, never in AppModel.
- Engine outputs consumed by adoption sites (SleepModel fields, DaytimeStress.Result,
  StressTotals, TrendPoint series) are byte-identical before and after adoption; the
  fixture-diff test in tasks T031 asserts this.
