# Research 008 — Design Lab Adoption Decisions

## D1 — Token authority

- **Decision:** Product tokens win. Every ported component re-binds `LabPalette.*` →
  `StrandPalette.*`, `LabType.*` → `StrandFont.*`, `LabMotion.*` → `StrandMotion.*`
  (mapping in D6). Lab hex values are never copied into the app.
- **Rationale:** The lab intentionally used a stand-in palette; `StrandPalette` is the
  shipped Paper ruling (dark-mode adaptive, strain accent locked).
- **Alternative:** Import LabPalette as a second token set — rejected; two palettes is
  how drift starts.

## D2 — Promote vs upgrade vs skip (component disposition)

- **Decision:** Three dispositions, fixed per component in data-model.md:
  1. **Promote** (no equivalent): ValueToken, MicroBadge, MicroStatusDot, ProgressDots,
     MicroIconButton, PaperSearchField, PaperToast.
  2. **Upgrade in place** (equivalent exists): SegmentedPillControl (sliding thumb),
     StatePill/StatusBadge (pulse option). `PipBar`, `StatTile`, `Hypnogram`,
     `TypicalRangeBar/Row`, `ZoneBars`, `SplitsTable`, `NoteCard`, `SettingsRow`,
     `DeviceRow`, `SectionHeader`, `SourceBadge`, `CountUpText`, `TrendChart`,
     `StressTimelineBar` are already canonical — lab parity confirmed, no change.
  3. **Skip** (lab-only fixtures): the lab hypnogram (product `Hypnogram` is richer:
     hover, smoothing, time axis), LabCard (product `NoopCard`/`PaperCard` rule),
     `NoopWordmark` (landed in spec 004), Score/Strain dials (product `RecoveryRing`/
     `StrainGauge`/`BevelGauge` rule), Route/BreathOrb/Rhythm specimens (product has
     real implementations).
- **Rationale:** The lab prototypes grammar; where the product already embodies the
  grammar with more capability, adoption means *verify parity*, not replace.

## D3 — Sleep decomposition source of truth

- **Decision:** `SleepView`'s existing structures (stage rows with `selectedStage`,
  window strip, stages-vs-typical with LiquidTube+DiagonalHatch, StatTile grid, debt
  ledger) are retained; the lab contributes metrics polish, the pip-rail on breakdown
  rows, dim-others hypnogram treatment, and the ledger stagger reveal.
- **Rationale:** The lab's sleep suite was distilled *from* SleepView this cycle; the
  product carries the real interactions (wake edit, naps, why-popovers) the lab never
  modeled. Porting fixtures backwards would delete capability.
- **Alternative:** Rebuild SleepView sections from lab code — rejected (regression
  risk to nap/edit/undo flows for zero user value).

## D4 — Stress totals rail

- **Decision:** `StressTotalsBar` moves from per-band LiquidTube fills to the
  canonical `PipBar` rail, per the approved lab band-split. LiquidTube remains the
  signature elsewhere (Today grid, recovery contributors, stage-vs-typical).
- **Rationale:** Easton approved the pip-rail band split in lab QA; it reads durations
  better at small heights and cuts three static Canvas instances.
- **Alternative:** Keep LiquidTube — rejected by the approved direction; revisit only
  if the screenshot gate shows worse legibility.

## D5 — Toast vs existing banners

- **Decision:** One `PaperToast` in StrandDesign; the Sleep undo banner and operation
  confirmations adopt it. Engine semantics (undo window length, `sleepUndoTask`
  cancellation, retry state machines) are untouched — only presentation swaps.
- **Rationale:** Three ad-hoc transient banners exist today with different timings and
  no VoiceOver announcements; the lab standardized dwell (2.4 s), entry (rise 12 pt +
  fade), exit (fade), and reachable action.
- **Alternative:** SwiftUI `.alert`/system banners — rejected; not Paper, and alerts
  interrupt.

## D6 — Motion token mapping

- **Decision:** `LabMotion.press → StrandMotion` press/spring equivalent;
  `LabMotion.value → StrandMotion` value spring; `LabMotion.reveal → StrandMotion`
  reveal/soft spring. Exact assignments happen in Phase 1 by inspecting
  `StrandMotion`'s existing cases; if a case is missing, it is **added to
  StrandMotion** with the lab's curve (spring response/damping copied verbatim), never
  inlined at call sites.
- **Rationale:** Screens must reference named tokens so motion stays tunable in one
  place; the lab's curves (0.26/0.82 press, 0.48/0.86 value, 0.62/0.88 reveal) are the
  approved feel.

## D7 — iOS 16 floor vs lab's iOS 17 APIs

- **Decision:** `sensoryFeedback(_:trigger:)` and `contentTransition(.numericText)`
  are wrapped: `#available(iOS 17, *)` uses them; below, haptics route through the
  existing `StrandHaptic` helper and numeric transitions fall back to opacity.
  Implemented once as private helpers inside the promoted components.
- **Rationale:** StrandDesign is shared with macOS and the app floor is iOS 16
  (spec-004 context); promotions must not raise the floor.
- **Alternative:** Raise the deployment target — out of scope; a separate product
  decision.

## D8 — Duplicate convergence inventory (Phase 0 seeds this; audit is executable)

Phase 0 audit against paper-reskin HEAD `44d36bd`:

| Family | Current sites | Replacing atom / verdict |
|---|---|---|
| Status | `LiveView:187-204,660`; `TodayView:98-101,1785-1786,4558-4563`; `AutomationsView:509-526` | `StatePill` for the connection pill; `MicroStatusDot` for the dots. Keep existing button shells. |
| Badges | `TodayView:2211-2227`; `CoupledView:240-250,1288-1295`; `ChargeBreakdownFormat:249-254`; `WorkoutsView:609-615,668-673,1448-1453`; `WeeklyDigestView:290-304`; `InsightsHubView:103-110`; `NotificationSettingsView:191-200` | `MicroBadge`, retaining the surrounding Button/Menu semantics where present. |
| Existing status exception | `ChargeBreakdownFormat:157-181` | Delete `ConfidenceTierChip`; use existing `ScoreStatePill`/`StatePill`. |
| Values | `LiveView:650-666,716-727,855-866,910-928`; `CoupledView:341-350`; `WorkoutsView:902-925,1038-1048`; `WorkoutDetailView:238-250,431-440` | `ValueToken`; keep truthful units and compose status separately. |
| Search | `WorkoutsView:424-453`; `MarkerEditorView:104-119`; `ManualWorkoutSheet:603-612`; `JournalLogCard:1262-1269` | `PaperSearchField`, preserving each site's sizing and binding behavior. |
| Segmented | `OnboardingWizard:702-707,720-724`; `CoachView:228-234`; `SettingsView:300-305,310-316,431-437,713-718,726-732,763-769,776-782,788-793` | Upgraded `SegmentedPillControl`. Stress and TrendsReport already use it. |
| Transient | `SleepView:104-110,142,251-267,289-323,2555,2569-2575,2608`; `BackupSyncView:17-19,62-64,161-225`; `DataSourcesView:88-90,154-294`; `WorkoutsView:281-317` | `PaperToast` for transient success/undo; persistent operation treatment with Retry for failures. Sleep undo needs configurable 7 s dwell; the component default remains 2.4 s. |

Verified exclusions: `DevicesView` already uses canonical `StatePill`; its battery
tube remains determinate progress. `OnboardingWizard`'s `ThreadProgress` is
determinate and is not replaced by `ProgressDots`. TermsGate/AddDeviceWizard have no
step indicator, and there is no Explore search at this HEAD, so T036 must not invent
them. `LiveWorkoutView` is excluded by the workout-coordinator invariant. Chart
legends and interactive filter pills are not status badges.

Audit command of record (results pasted into tasks.md evidence):
`grep -rn "Capsule().fill" Strand/Screens StrandiOS --include=*.swift` plus
per-family greps named in tasks T002.

## D9 — Evidence and device gates

- **Decision:** Primary device `NOOP-Paper-iPhone16Pro-QA` (00522DAA-…); secondary
  layout pass on iPhone 17 Pro Max (602CD04D-…). Evidence root
  `outputs/2026-07-14/design-lab-adoption/qa/`. Fixture seeding uses the existing
  simulator seed mechanism from spec 004 — no new fixture code, no fabricated data in
  product code paths.
- **Rationale:** Matches the Paper-reskin QA convention; the dedicated QA simulator
  keeps appearance/type settings stable between phases.

## D10 — Numbering and concurrency

- **Decision:** This package is 008. Phase 0 verified that the live paper-reskin base
  `44d36bd` already includes specs 005–007. Spec 005 touched `TrendsView`; spec 006
  touched `SleepView` and `TrendsView`; spec 007 touched none of the Sleep/Stress/
  Trends triad but added the Quick Add search now listed in D8. Current file hashes
  match the verified T139 snapshot, so no rebase or coordination blocker remains.
