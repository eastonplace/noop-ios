# NOOP project rules

## Project tracking

- Treat GitHub as the canonical operational record for NOOP product work. Use Obsidian for durable context, not as a substitute for current issue, branch, pull request, or release state.
- Track every non-trivial bug, feature, investigation, release gate, and follow-up in a GitHub issue.
- Before starting work, search for an existing issue. Reuse it when the scope matches.
- Keep investigation evidence, decisions, blockers, and verification results on the issue as work progresses.
- If work discovers materially new scope, open or link a separate issue before broadening the change.
- Use one focused branch and pull request per issue or tightly related issue set.
- Link pull requests to their issue. Do not close an issue until the requested behavior is verified.
- Do not push directly to `main` for normal product work.

## Change flow

- Start from current `main` unless the tracked issue explicitly requires another base.
- Keep pull requests draft while implementation or required QA is incomplete.
- Separate code-complete, simulator-tested, physical-device-tested, merged, installed, and released states.
- Record the exact tested SHA in the pull request before merge.
- Treat GitHub Actions as evidence only when jobs actually ran. A zero-step, billing, runner, or other infrastructure failure is not a source, build, or test result.
- Merge only after the issue's required gates pass and Easton explicitly authorizes the merge when that gate applies.

## NOOP safety

- `project.yml` is XcodeGen truth. Run `/opt/homebrew/bin/xcodegen generate` after project membership changes.
- Phone and Release builds use real user data. Never uninstall, reset, reseed, or replace the production app container unless Easton explicitly approves it.
- Keep demo data limited to Debug, Simulator, or explicit test modes.
- Treat draft pull request, merge, physical iPhone install, and release as separate authorization gates.
- Do not hide BLE or protocol failures or manufacture successful synchronization state. Repair state ownership and completion paths at the source.
- Preserve raw diagnostic evidence needed to recover user data before acknowledging destructive protocol steps.
- Use a clean isolated checkout when the iCloud checkout is dirty, damaged, or missing Git objects.

## Verification

- Read the tracked issue, relevant code, and current GitHub state before editing.
- Keep changes focused on the tracked scope and preserve unrelated user work.
- Verify in proportion to risk with the relevant package tests, XcodeGen, iOS tests, source audits, simulator UI checks, and physical-device proof.
- For BLE, HealthKit, background execution, alarms, data migration, or persistence changes, require physical-device evidence before calling the behavior qualified when the issue depends on hardware/runtime state.
- Report verified, partial, blocked, and unverified work separately.
