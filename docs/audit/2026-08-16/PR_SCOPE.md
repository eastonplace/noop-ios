# Pull-request scope

This is a new draft PR from `codex/noop-audit-p0-settings-whoop-20260816` to `main`. It is not merged.

Commits are separated by scope:

1. `a4195e6e` — `feat: repair stress and home metric presentation`
2. `79bd8504` — `feat: add searchable Settings and More catalog`
3. `dbe45e72` — `test: specify verified sink bootstrap policy`
4. Documentation and evidence package — added after the tested source SHA.

The first commit contains Stress and Home changes only. The Settings catalog is separate. The widget work is a policy seam and focused tests only because installed-state evidence is missing. No WHOOP-only deletion is mixed into the correctness commits.

The tested source SHA is `dbe45e72f1fbd7e34d28012cb6294d1fed13ec79`. The final PR head will also contain documentation and the evidence archive; those documentation-only commits do not change tested source.
