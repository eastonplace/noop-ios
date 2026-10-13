# T133 — Full-app design-system re-shoot gate

## Runtime

- Clone: `~/Code/noop-completion`
- Branch: `reskin/paper-ui`
- Simulator: iPhone 17 Pro Max (`602CD04D-E0CD-4A41-986C-74427759C06A`)
- Launch: `--demo-seed --demo-screen <route> -theme.appearance <light|dark>`
- Build: `NOOPiOS` Debug from T132 (`841a845f`)

## Evidence

- [Light contact sheet](qa/t133/contact-light.jpg)
- [Dark contact sheet](qa/t133/contact-dark.jpg)
- [Light capture tree](qa/t133/light/)
- [Dark capture tree](qa/t133/dark/)
- 75 deterministic routes/states per appearance; 150 screenshots total.
- Every capture is 1320×2868. The size audit found zero missing or suspiciously
  small images.
- All 12 onboarding steps are independently represented in both appearances.

## Deadness check

The T131/T132 rebase is visibly present beyond Settings:

- Real card shadows and the stronger surface hierarchy carry through Today,
  Trends, Sleep, Workouts, detail screens, utilities, and onboarding.
- The 34/28/22/17/13/11 type scale and 56-point row/control rhythm are visible
  across data-heavy and settings-style surfaces without washed light-mode ink.
- Selection chrome is black across segmented controls and native switches;
  semantic color remains in status fills/glyphs rather than value text.
- The 76-point navigation treatment and black primary actions remain consistent
  in both appearances.
- WHOOP metric colors remain isolated to data graphics; journal purple was not
  introduced into the data surfaces during the component sweep.

Per the approved T133 amendment, the external reviewer holds the two canonical
boards in context and performs the board comparison at this gate. The PNG files
remain required in `references/` before T139.

## Validation

- StrandDesign: 43 tests passed, 0 failures (T132 verification baseline).
- Fresh `NOOPiOS` simulator build after the final component cleanup: succeeded.
- `git diff --check`: clean before commit.
- T134 was not started; this commit contains evidence and task-ledger changes
  only.
