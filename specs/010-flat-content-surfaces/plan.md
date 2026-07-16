# Plan 010 — iOS Flat Content Surfaces

1. Freeze the post-routing working tree and inventory shared plus bespoke card sites.
2. Add `StrandPalette.appCanvas`, an app-scoped content-surface environment, and the
   public `ContentSection` container. Default remains bounded; only the iOS app opts in.
3. Flatten Today as the composition reference, then primary product screens, then
   utility/lifecycle screens. Preserve bounded controls and overlays.
4. Re-run the inventory, remove obsolete iOS-only chrome, and verify the frozen-file
   boundary.
5. Run package tests, regenerate/build all targets from a `/tmp` mirror if needed, and
   visually QA iPhone Pro/Pro Max plus iPad in light/dark and accessibility variants.

No data model or persistence migration exists. Each phase is presentation-only and can
be reverted independently.
