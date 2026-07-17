# Plan 011 — Component Library Production Adoption

1. Freeze the non-versioned Design Lab handoff and inventory data/route parity.
2. Promote fixture-free components and value models to `StrandDesign`; make the lab
   consume those production components.
3. make `ScreenScaffold` the sole iPhone header owner with threshold-gated compact
   chrome and remove duplicate inline/scaffold labels.
4. Adopt Today rings, Stress, and live HR using bounded real-data adapters.
5. Adopt Recovery, Strain, Heart Rate detail, and Trends V2 while preserving every
   unique production metric, action, annotation, and export.
6. Run unit/build/route/visual/performance parity checks, install in place, then merge.

Business logic remains in the existing repositories and engines. SwiftUI components
receive small immutable display models and actions; they never query storage or create
fallback health values.
