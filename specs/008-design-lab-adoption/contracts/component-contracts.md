# Component Contracts 008 — Promoted / Upgraded StrandDesign Atoms

All promoted components: `public`, visual-only, `StrandPalette`/`StrandFont`/
`StrandMotion` tokens only, `#Preview` required, no Repository/AppModel/BLE access,
localized-string parameters (`LocalizedStringKey` where user-visible), Reduce Motion
honored internally so call sites need no extra handling.

## PaperToast

```swift
public struct PaperToast: View {
    public init(
        _ message: LocalizedStringKey,
        systemImage: String = "checkmark.circle.fill",
        tint: Color = StrandPalette.statusPositive,
        actionTitle: LocalizedStringKey? = nil,
        action: (() -> Void)? = nil
    )
}

public extension View {
    /// Presents `toast` low over content while `isPresented` is true; auto-dismisses
    /// after 2.4 s. Re-setting true restarts the dwell. Cancelled on disappear.
    func paperToast(isPresented: Binding<Bool>, @ViewBuilder toast: () -> PaperToast) -> some View
}
```

**Guarantees**

- Entry: rise 12 pt + fade with the reveal token; exit: 0.22 s fade. Reduce Motion:
  opacity only, identical dwell.
- Action button remains hittable (≥ 44 pt) through the whole dwell; tapping the action
  dismisses immediately after invoking it.
- Posts a VoiceOver announcement of `message` on present;
  `.accessibilityAddTraits(.updatesFrequently)` on the container.
- Never stacks: one toast per owner; re-present replaces content and restarts dwell.
- Owner controls `isPresented`; the modifier flips it false on auto-dismiss.

## ValueToken

```swift
public struct ValueToken: View {
    public init(_ label: LocalizedStringKey, value: String,
                tint: Color = StrandPalette.textPrimary)
}
```

- Fixed height 42 pt, monospaced value with `contentTransition(.numericText())`
  (iOS 17+, opacity fallback), uppercase micro label.
- Combined accessibility element: "\(label), \(value)".

## MicroPrimitives (one file)

```swift
public struct MicroBadge: View {
    public init(_ title: LocalizedStringKey, systemImage: String? = nil,
                tint: Color = StrandPalette.textPrimary)
}
public struct MicroStatusDot: View {
    public init(color: Color, isActive: Bool = false)   // pulse only when isActive
}
public struct ProgressDots: View {
    public init(count: Int, current: Int, tint: Color = StrandPalette.accent)
}
public struct MicroIconButton: View {
    public init(systemImage: String, label: LocalizedStringKey,
                isSelected: Bool = false, action: @escaping () -> Void)
}
```

**Guarantees**

- MicroStatusDot pulse: 1.25 s ease-out repeat, removed entirely under Reduce Motion;
  animation lives inside the dot (leaf view — safe next to realtime values).
- ProgressDots: active dot 22×7 capsule, inactive 7×7; announces
  "Step current+1 of count"; never used for determinate progress (that's PipBar).
- MicroIconButton: 42 pt minimum target, `.isSelected` trait when selected,
  press-scale via the package button style.

## PaperSearchField

```swift
public struct PaperSearchField: View {
    public init(_ placeholder: LocalizedStringKey, text: Binding<String>,
                height: CGFloat = 48, cornerRadius: CGFloat = 15)
}
```

- Magnifier leading, clear button appears only when non-empty ("Clear search" label).
- No search execution logic — owner filters; field is presentation + binding only.

## SegmentedPillControl (upgrade — API preserved)

Existing `public struct SegmentedPillControl<T: Hashable>` keeps its initializer.
Added behavior:

- Selected background becomes a single matched-geometry thumb (one `@Namespace` per
  instance) sliding with the press/snappy token; Reduce Motion: no slide, instant.
- Selection change fires a selection haptic (D7 fallback path below iOS 17).
- Each segment exposes `.isSelected` trait; control is a single accessibility
  container with adjustable semantics preserved if already present.

## StatePill / StatusBadge (upgrade — API additive)

```swift
StatePill(_ title:, tone:, showsDot:, pulsing: Bool = false)   // new param, default off
```

- Pulse ring identical to MicroStatusDot spec; compile-time default keeps every
  existing call site's behavior unchanged.
- Rule of use (enforced in review, not code): `pulsing: true` only for live sensor /
  in-progress states, never for static status.

## Adoption-Site Contracts (app target)

- **Sleep stage rows:** keep `(stage, minutes, total, selectedStage)` inputs and tap
  toggle; rail is `PipBar(value: fraction*100, segments: 20, tint: stageColor,
  height: 8)`; row background/dim states per lab (selected 0.13 tint fill, others 0.5
  opacity). VoiceOver label format unchanged.
- **Hypnogram dim-others:** new optional `highlightedStage: SleepStage?` parameter on
  the existing `Hypnogram` (default nil = current behavior); non-nil dims non-matching
  intervals to 0.18 opacity with the fade token. Hover/axis/smoothing untouched.
- **StressTotalsBar:** same `StressTotals` input; rows become label + duration +
  `PipBar(fraction:)` tinted per band; zero-total renders empty rails.
- **Trend summary row (private to TrendsView):** input `(title, series: [TrendPoint],
  formatter, goodDirection)`; renders dot/name/spark/latest/delta; MUST assert
  `series === charted series` by construction (single source array).

## Compatibility

- All upgrades are API-preserving or parameter-additive with defaults → macOS target
  compiles with zero call-site edits.
- No promoted component may gain an engine dependency later without a new spec; this
  contract is the package boundary of record.
