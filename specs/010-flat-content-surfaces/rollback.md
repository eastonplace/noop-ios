# Rollback 010 — iOS Flat Content Surfaces

- Revert screen migrations in reverse order: utility → primary → Today → foundation.
- The environment defaults to bounded cards, so removing the iOS root opt-in restores
  legacy presentation without a data migration.
- Abort and revert the active phase for navigation/data drift, lost control boundaries,
  inaccessible tap targets, chart contrast loss, a non-iOS visual change, or a target
  build failure.
- Preserve Fable's routing diff and the pre-existing Stress/Sleep component work during
  every partial rollback.
