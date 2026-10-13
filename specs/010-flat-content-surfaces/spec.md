# Spec 010 — iOS Flat Content Surfaces

## Goal

Replace ordinary rounded content cards throughout the NOOP iPhone/iPad app with a
continuous white (`#FFFFFF`) / near-black (`#0B0D10`) canvas. Preserve hierarchy with
spacing, typography, data colour, and hairline dividers. Navigation, data, scoring,
persistence, HealthKit, BLE, widgets, macOS, watchOS, and the Design Lab are frozen.

## Requirements

- The iOS app root opts into a flat-content environment; package consumers default to
  the existing bounded card presentation.
- Dashboard, chart, metric, history, explanatory, list-group, and settings-group
  containers render without fill, radius, border, or shadow on iOS.
- Buttons, fields, toggles, pills, badges, alerts, sheets, popovers, tooltips, and
  destructive confirmations retain explicit boundaries.
- Flat tappable rows retain Button/NavigationLink semantics, press feedback, chevrons,
  and a 44-point minimum target.
- Shared macOS/watchOS/widget rendering is unchanged.
- Existing routes and displayed values are byte-for-byte outside presentation code.
- The shared iOS header removes obsolete card-era top spacing and Today's device status
  shows the real connected-strap battery percentage when available.

## Acceptance

Every audited content-card site has a disposition; iPhone/iPad screenshots show one
continuous canvas in both appearances; all package/app targets compile; package tests
pass; no engine, repository, navigation, persistence, or mock-data file changes enter
the migration diff.
