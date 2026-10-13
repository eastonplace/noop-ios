# Specification 011 — Component Library Production Adoption

## Goal

Promote the finalized NOOP Design Lab components into `StrandDesign` and use them in
the production iPhone app without changing scoring, persistence, repositories, or the
approved rich Stress and Sleep destinations.

## User-visible contract

- Every iPhone screen uses one consistent NOOP navigation/header system.
- The full inline header is visible at rest; a compact pinned header replaces it only
  after the inline header scrolls away. A title/date is never shown twice.
- Today uses the accepted score rings, live Heart Rate module, and Stress module.
- Recovery, Strain, Trends, and Heart Rate detail use the accepted library designs.
- Unique production metrics, controls, drill-ins, annotations, and exports remain
  reachable even when the fixture specimen did not include them.
- Empty, calibrating, partial, offline, and permission-denied states remain honest.

## Boundaries

- Canonical source: `projects/Noop`. The Design Lab is a fixture/showcase host.
- No fixture or demo data may be linked into a production target.
- Stress routes to the rich `StressView`; Sleep routes to the rich `SleepView`.
- iPhone is the QA target. iPad/watch visual QA is deferred unless requested.
- macOS/watch/widgets must not inherit an unintended visual redesign.

## Acceptance

- One production component implementation is rendered by both NOOP and the Design Lab.
- No unique old metric/tool is silently removed.
- Existing routes and stored values are unchanged.
- Release scrolling, live HR updates, and charts show no material regression.
- The signed app installs in place and launches on Easton's connected iPhone.
