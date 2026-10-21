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
3. **Write the What's New entry**: add a `.fork("<version>", "<short title>", "<Month Year>", [...])` at the top
   of `AppChangelog.releases` (`Strand/System/AppChangelog.swift`) with 3–9 `Feature(symbol, tint, title, detail)`
   rows. This is a showcase, not a changelog: titles are 2–4 words, details are one short line (under ~60
   characters) on what changed for the person. An SF Symbol and a tint per row. No PR numbers, file names or
   jargon. Look at the 1.7.0 entry and match it.
4. **Update the fallback**: the literal in `AppChangelog.currentVersion` matches the new version.
5. **Mirror it** in `CHANGELOG.md` under a `## <version>` heading.
6. **Tag the release** after merge: `gh release create v<version> --repo eastonplace/noop-ios --generate-notes`.
   Settings → About → Check for updates reads the latest release from this repository.

The What's New screen opens by itself the first time the app runs a new version (the stored last-seen
version differs from the running one), so a version bump is what shows it. It is always reachable from
Settings → About → What's new.

**Enforced in CI.** `Tools/qa/whats_new_release_audit.py` runs in the `source-audits` job and fails a PR when the
newest What's New entry doesn't match `MARKETING_VERSION`, the fallback literal is stale, or app source changed
without raising both `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` above `main`'s.

## Credits

Settings → About credits Easton Place as the builder and owner of the design and direction. Keep the
"Background formulas built on" attributions (my-whoop, goose, NoopApp/noop) intact.
