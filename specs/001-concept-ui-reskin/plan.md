# Plan 001 — Concept UI Reskin: Technical Approach

> Read `spec.md` first (WHAT + acceptance criteria). This file is the HOW. Ordered,
> executable tasks are in `tasks.md`.

**Goal:** Implement the "Paper" light reskin across the iOS app with minimum blast
radius, by exploiting the codebase's existing single-choke-point theming.

**Architecture:** Token-first. `Packages/StrandDesign` already routes every color
through `StrandPalette` (with a `Color(light:dark:)` dynamic provider built exactly for
theme swaps — see the comment in `Palette.swift`: "only the token definitions change,
never the call sites") and every font through `StrandFont` (single `family` constant).
Phase 1 rewrites tokens; Phase 2 rebuilds the ~15 shared primitives; Phases 3–7 restyle
screens in dependency order; Phase 8 is a sweep + QA. Screens are shared with macOS —
macOS inherits the new look for free and that is accepted in the spec.

**Tech stack:** SwiftUI, XcodeGen (`project.yml` → `Strand.xcodeproj`), Swift Package
`StrandDesign`, iOS 16 floor (per Typography comments), scheme `NOOPiOS` (verify with
`xcodebuild -list` — target names in `project.yml`: `NOOPiOS`, `NOOPiOSWidgets`,
`NOOPWatch`, `Strand`, `StrandTests`).

## Global constraints

- **Visual reskin only** — zero changes to scoring, data, BLE, import, navigation
  graph, or feature logic (spec §Non-goals, R2, R4).
- Pillar scores 0–100, Stress 0–3, workout effort = existing metric untouched (R2).
- Pillar colors: Charge green / Effort purple / Rest blue / Stress amber (R3).
- Tabs: Today · Trends · Sleep · More + black FAB (R1).
- Light theme is the pixel target; dark is derived per spec §2.2 (R6).
- watchOS, Android, widgets, onboarding layout: out of scope (spec §1).
- iOS 16 deployment floor — no iOS 17+-only API without fallback.
- All new user-facing strings registered in `Localizable.xcstrings`.
- Surgical diffs: match existing file style, comment density, and the repo's
  issue-reference comment convention. Don't reformat untouched code.
- **Required reading before Phase 1** (Codex skills, installed at `~/.codex/skills/`):
  read `swiftui-expert-skill/SKILL.md` **and its `references/latest-apis.md`** (the
  skill's own operating rules require it), `swift-concurrency/SKILL.md`, and
  `swift-testing-expert/SKILL.md`. Apply them throughout. When a build breaks or is
  slow, reach for the Xcode skills in the same folder: `xcode-build-fixer`,
  `xcode-build-orchestrator`, `xcode-compilation-analyzer`, `xcode-project-analyzer`,
  `spm-build-analysis`. Note: this app's floor is iOS 16 — the SwiftUI skill's
  iOS 26 / Liquid Glass material is explicitly NOT wanted here (we are *removing* a
  liquid look); take its state-management, view-composition, and performance guidance.
- **No modifications before the T00 safety gate passes** (see below).

## Safety & rollback (T00 — hard gate)

Decision: **branch + tag + remote push is the primary safety net; a one-time compressed
snapshot outside iCloud is the belt-and-suspenders.** A plain folder copy of the repo
inside iCloud Drive is NOT acceptable as the backup — iCloud sync corrupts/evicts `.git`
internals and doubles sync churn; the snapshot must be a tarball on local disk.

Before touching any file:

1. **Clean tree.** Commit the spec kit (`specs/`) and any pre-existing modified files
   as a `wip:` commit (or stash them) so the starting point is a single reproducible
   commit. `git status --porcelain` must be empty afterwards.
2. **Tag the starting point:** `git tag pre-paper-reskin` on that commit.
3. **Branch:** `git checkout -b reskin/paper-ui`. ALL work happens here. Never commit
   to `main`; never force-push anything.
4. **Push the safety net:** push `main`, the tag, and (continuously, after each task
   commit) `reskin/paper-ui` to the **`private-noop-report`** remote
   (`github.com/eastonplace-ai/noop` — Easton's). Do NOT push to `origin`
   (`github.com/NoopApp/noop`) without Easton's say-so.
5. **Local snapshot outside iCloud:**
   `mkdir -p ~/Backups && tar czf ~/Backups/noop-pre-reskin-$(date +%Y%m%d).tgz --exclude='Noop/build' --exclude='Noop/.git/objects/pack/tmp*' -C "$HOME/Library/Mobile Documents/com~apple~CloudDocs/Vibe Coding Projects/projects" Noop`
   — verify the tarball exists and is >10 MB before proceeding. This covers untracked
   files that git can't restore.

**Rollback recipes** (cite these in the PR description):
- Abandon everything, keep history: `git checkout main` (branch simply not merged).
- Nuke the branch state back to start: `git reset --hard pre-paper-reskin` (on the
  branch).
- Catastrophic / untracked-file damage: restore the tarball —
  `tar xzf ~/Backups/noop-pre-reskin-<date>.tgz -C /tmp/noop-restore` and copy back
  what's needed.
- Partial revert after merge: `git revert` the reskin commits (they're one-per-task,
  so per-screen reverts are clean).

## Why token-first (and what it doesn't buy)

Rewriting `StrandPalette`/`StrandFont` instantly flips ~80% of the app to the new
palette because call sites reference semantic tokens. What it does NOT fix:

1. **Structural styling** — the floating glass tab bar, gold FAB, glow rings, bevel
   gauges, liquid backgrounds are *shapes and effects*, not just colors. These are
   Phase 2 component rebuilds.
2. **Dark-canvas assumptions** — screens built dark-first may hardcode
   `onDarkPrimary`-style tokens, white text, or dark imagery. The Phase 8 sweep greps
   for these (`onDark`, `gold`, `titanium`, `glow`, `scenic`, `.white`, `.black`
   literals in `Strand/Screens` + `Strand/Liquid`).
3. **Layout deltas vs the concepts** — some screens need real layout edits (Today trio
   vs current dashboard cards, Live console layout, run flow). Phases 3–7.

## Token migration strategy

Keep the existing token *names* where semantics match (`surfaceBase` → canvas value,
`surfaceRaised` → card, `hairline`, `textPrimary/Secondary/Tertiary`, `accent` → ink)
so call sites keep compiling, and add the new pillar/semantic tokens from spec §2.1
(`chargeAccent`, `effortAccent`, `restAccent`, `stressAccent`, `liveRed`, `success`,
`warning`, `destructive`, `link`, zone + sleep-stage ramps, tints). Map old worlds:
`recovery0xx` ramp → charge greens, `strain0xx` → effort purples. `gold*`/`titanium*`/
`scenic*`/`glow*` tokens: leave defined (other targets may reference them) but ensure no
iOS screen renders them (spec AC-2). Delete only what provably has no references
(`grep -rn "goldGradient" Strand StrandiOS Packages NOOPWatch`).

**Decision needed at execution time:** if `accent` is used both as "brand gold" and
"interactive tint", split it into `ink` (actions) vs data accents before Phase 3 —
check call sites with `grep -rn "StrandPalette.accent" | wc -l` and triage.

## Phases (details + steps in tasks.md)

| Phase | Tasks | Delivers |
|---|---|---|
| 0 Gate + baseline | T00–T01 | Safety gate passed (skills read, tag + branch + remote push + tarball snapshot), reference images verified, before-screenshots of all 27 spec screens, scheme/build sanity |
| 1 Tokens | T02–T03 | New palette (light+dark) + SF Pro typography; app builds and already looks ~paper |
| 2 Primitives | T04–T08 | PaperCard, ScoreRing, buttons, badges, rows, notes, charts restyle, header, tab bar + FAB + Quick Actions |
| 3 Core tabs | T09–T12 | Today, Trends, Sleep, More list |
| 4 Pillar details | T13–T14 | Charge/Effort/Rest/Stress detail screens |
| 5 Live + workouts | T15–T18 | Live console, Workouts, run flow (pre/live/paused/summary) |
| 6 Management | T19–T22 | Devices, Add Device, Data Sources, Backup, Settings, Support |
| 7 Labs | T23–T26 | Insights, Lab Book, Rhythm + consent, Automations, Alarms, Test Centre |
| 8 Sweep + QA | T27–T29 | R8 screen sweep, dark mode, Dynamic Type/device matrix, contact sheet |

Order rationale: primitives before screens (every screen consumes them); Today first
among screens (highest-traffic, exercises the most primitives, fastest feedback);
run flow after Workouts (shares components); sweep last (token fallout is only visible
once real screens are done).

## Verification workflow (every task)

1. `xcodegen generate` (only if `project.yml` changed).
2. Build: `xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -destination
   'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -20` — expect
   `BUILD SUCCEEDED`.
3. Run in simulator, navigate to the task's screen, screenshot:
   `xcrun simctl io booted screenshot specs/001-concept-ui-reskin/qa/<task>-<screen>.png`.
4. Compare against the matching crop in `references/sheet-N.png` — check layout order,
   spacing rhythm, colors (sample hexes from the screenshot if unsure), typography
   hierarchy, badge/button shapes.
5. Package tests when `StrandDesign` changed: `swift test --package-path
   Packages/StrandDesign`.
6. Commit per task: `git commit -m "reskin(T##): <screen/component>"` on branch
   `reskin/paper-ui` (created in T00; never commit to `main`), then push the branch to
   `private-noop-report` so the remote always mirrors the last good task.

Simulator note: demo/seed data exists (`Strand/Data/AppleDemoSeeder.swift`) — use it so
screens have data to render; document in the PR how QA screenshots were seeded.

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| macOS renders regress (shared views/tokens) | Accepted per spec §1; smoke-build macOS `Strand` scheme at Phase 8, log breakage as follow-up, don't fix here |
| Widgets/watch pick up token changes unexpectedly | Watch resolves dark-hex path (`Palette.swift` watchOS branch) — verify unchanged; build `NOOPiOSWidgets` + `NOOPWatch` at Phase 8 |
| `accent` token dual-use (brand vs interactive) | Triage call sites in T02 before rewriting |
| S20–S26 file mapping uncertain (pillar hosts, run UI) | T13/T16 start with a locate step; spec §5 lists candidates |
| Old scale/copy leaks ("strain", 0–21 numbers in UI strings) | R2; grep UI strings for "strain" during relevant tasks |
| Contrast failures from warm grays | AC-3 check per screen; darken `textTertiary` if it fails, update spec value |
| 4,728-line `TodayView.swift` | T09 may split extracted subviews into sibling files — allowed by repo conventions ("if a file you're modifying has grown unwieldy"), but keep the split mechanical, no logic changes |
| Concept ↔ feature mismatch (routes, sleep marks) | Visuals-only rule: restyle what exists, never build backing features (spec S24 note) |

## Decision log

| # | Decision | Why |
|---|---|---|
| D1 | Token-first, keep old token names where semantics match | Minimum diff; call sites untouched per Palette design |
| D2 | SF Pro replaces Helvetica Neue (R9) | Concepts render the native grotesque; single-constant change; Easton can veto → skip T03 step 2 |
| D3 | Liquid Today retired, concept Today lives in `TodayView` (R7) | One Today; toggle removal is small; Liquid files left compiling for follow-up deletion |
| D4 | Gold/titanium tokens defined-but-unrendered rather than deleted | Cross-target references; deletion is cheap follow-up once proven unused |
| D5 | Dark theme derived, checked not pixel-matched (R6) | No dark concepts exist; spec §2.2 fixes values so it's still deterministic |
| D6 | QA screenshots under `specs/001-concept-ui-reskin/qa/` (gitignored if large) | Keeps evidence next to spec for review |
