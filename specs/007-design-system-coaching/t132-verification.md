# T132 Component Rebase Verification

Status: **COMPLETE — T133 remains the visual gate**

## Canonical component changes

- Buttons now use the G1 56pt height and 22pt radius for primary, secondary, tertiary, and destructive roles.
- iPhone switches use black selected chrome through the shared UIKit appearance; legacy explicit blue/green component tints were mechanically rebased to ink.
- Settings rows retain the canonical 56pt height, use ink control tint, and now expose an explicit destructive-red role.
- Status badges now cover Connected, Queued, Not connected, Success, Blocked, and Live in addition to existing compatibility states. Meaning remains in dot/fill/glyph while text stays ink per G2.
- The segmented picker uses scheme-invariant ink selection with on-ink text.
- The bottom navigation is 76pt with the existing black FAB and ink selected states.
- Banners/notes now cover warning, success, error, information, and privacy, with optional dismiss controls.
- Added shared icon-button, inline-alert-row, notification-badge, tiny-metric-badge, compact-form-field, and dropdown primitives.
- Native SwiftUI `Menu`, confirmation dialogs, action sheets, sheet handles, and reorder interactions remain the behavior/accessibility authority; their surrounding rows/buttons now inherit the canonical tokens.

## T126a absorption

No standalone T126a artifact or commit exists in the fetched branch. The pending component-family carry-over named by spec 007 is absorbed here through the app-wide control-tint sweep, ink segmented selection, canonical button geometry, visible cards, semantic feedback components, and 76pt navigation. No F3/F4 data-color or no-color-text behavior was reverted.

## Verification

- `swift test` in `Packages/StrandDesign`: 43 tests, 0 failures.
- `NOOPiOS` simulator build on iPhone 17 Pro Max: succeeded, 0 errors.
- `git diff --check`: clean after the recorded T130 status whitespace fix.
- No data, scoring, journal, persistence, or navigation logic changed.

T133 owns the full-app light/dark re-shoot and deadness comparison. It is hard-blocked until both canonical PNG boards are present under `references/`.
