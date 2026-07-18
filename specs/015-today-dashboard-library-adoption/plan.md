# Implementation Plan

1. Promote narrow-input Today hero, health tile, catalog-row, workout-row, and header-chrome primitives into `StrandDesign`.
2. Normalize dashboard preferences to 1–9 eligible cards, rebuild the editor, replace Today's fixed monitor, and remove the lower duplicate section.
3. Add a day-focused workouts view fed by repository workout rows/HR buckets and route only Today's glance to it.
4. Add leaf-observing iPhone app chrome to `ScreenScaffold`, route its actions centrally, and opt focused flows out.
5. Add pure mapping/persistence tests, run package/app/store suites, signed-build and install in place, then visually QA with iPhone Mirroring.

## Architecture decisions

- `StrandDesign` owns visual components and value models only; the app owns repository access, persistence, and navigation.
- Header state observation remains inside a leaf component so strap updates do not invalidate entire screens.
- Existing `WorkoutsView` and `WorkoutDetailView` stay canonical for management and rich workout details.
- The new Today workouts page is a read-only day projection and lazy-loads row traces.
- Existing page titles/back controls remain below pinned chrome.
