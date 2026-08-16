# WHOOP-only migration manifest

This manifest is a candidate plan, not an executed deletion.

## Preserve

- WHOOP 4, WHOOP 5, and WHOOP MG enrollment, identity, secure session, live HR, and history.
- Standard live-HR support used by WHOOP.
- Apple Health import unless a later product decision explicitly removes it.
- Old data reads, exports, restore paths, raw rows, and schema compatibility during migration.

## Staged order

1. Stop new non-WHOOP enrollment at the UI and registry boundary.
2. Verify existing non-WHOOP data remains readable and exportable.
3. Remove runtime drivers only after device and migration tests pass.
4. Remove package dependencies and schema compatibility last.
5. Delete legacy data only through an explicit, recoverable product decision.

## Candidates requiring evidence

- Oura live source.
- Huami/Xiaomi source and import paths.
- FTMS source.
- Generic HR source.
- Apple Watch live source.
- Garmin broadcast.

No candidate was deleted in this branch. `DELETE_MANIFEST_CANDIDATES.md` remains a review input, not authorization to remove code or data.
