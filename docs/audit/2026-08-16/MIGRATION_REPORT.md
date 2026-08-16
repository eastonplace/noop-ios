# Migration report

No device-removal migration was executed in this branch.

Preserved:

- WHOOP 4, WHOOP 5, and WHOOP MG device identity and protocol paths.
- Standard live-HR code used by WHOOP.
- Apple Health import and HealthKit bridge behavior.
- Existing legacy source kinds, readable data, export paths, and compatibility schemas.
- Package and persistence compatibility, including current `WhoopStore` migrations.

Not changed:

- Runtime drivers for Oura, Xiaomi/Huami, FTMS, generic HR, Apple Watch live source, or Garmin broadcast.
- Package dependencies.
- Database schema or migration versions.
- Existing raw-to-derived skin-temperature formulas and conflict behavior.

The proposed WHOOP-only series remains staged: freeze new non-WHOOP enrollment, remove runtime drivers after a migration proof, and remove package/schema compatibility last. The branch does not claim that series is complete.
