# AGENTS.md

Rules for anyone (human or agent) changing this repository. This app is Easton Place's iPhone fork of the
open-source NOOP, forked at upstream 9.0.1 in July 2026. Its own version history restarts at 1.0.0.

## Versions and releases

Every PR that changes what a user sees or how the app behaves ships a version bump and a What's New entry.

1. **Pick the version** (semver on `MARKETING_VERSION` in `project.yml`):
   - **Minor** (`1.7.0` → `1.8.0`): any user-visible feature, redesign, or behaviour change.
   - **Patch** (`1.7.0` → `1.7.1`): fixes only, nothing new to learn.
   - **Major**: a deliberate reset of the product, only on Easton's say-so.
   - One version per merged PR. If two PRs are open at once, the second to merge rebases and takes the next number.
2. **Bump the build**: raise `CURRENT_PROJECT_VERSION` in `project.yml` by one on every bump.
3. **Write the What's New entry**: add a `Release` at the top of `AppChangelog.releases`
   (`Strand/System/AppChangelog.swift`) with the same version, a short title, the month, and 2–9 items.
   Items are user-facing: `**Bold lead-in.**` then one or two plain sentences on what changed for the person.
   No PR numbers, file names or internal jargon.
4. **Update the fallback**: the literal in `AppChangelog.currentVersion` matches the new version.
5. **Mirror it** in `CHANGELOG.md` under a `## <version>` heading.
6. **Tag the release** after merge: `gh release create v<version> --repo eastonplace/noop-ios --generate-notes`.
   Settings → About → Check for updates reads the latest release from this repository.

The What's New sheet opens by itself once after an update (the stored last-seen version differs from the
running one) and is always reachable from Settings → About → What's new.

## Credits

Settings → About credits Easton Place as the builder and owner of the design and direction. Keep the
"Background formulas built on" attributions (my-whoop, goose, NoopApp/noop) intact.
