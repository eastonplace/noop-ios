# 002 References

The approved concept images live in `../../001-concept-ui-reskin/references/` (five
canonical sheets — see that folder's README for the manifest and usage rules). They
remain the visual target for this spec; do not duplicate them here.

This folder also holds `whoop-brand-guidelines.pdf` — the official WHOOP Brand & Design
Guidelines (source: developer.whoop.com). Its "Color Palette" pages are the authority
behind spec C13 (recovery bands #16EC06/#FFDE00/#FF0026 at 67/34 boundaries, Recovery
Blue #67AEE6 for non-valuated data, Strain #0093E7, Sleep #7BA1BB, Teal #00F19F).
C13 defines the light-mode adaptations; the PDF hexes are the dark-mode values.

This spec adds one more evidence source: `../fidelity.md`, the screen-by-screen audit of the
first implementation pass against those sheets (scored 2026-07-10 from the pass-1 QA
screenshots). Re-score it in T55.

QA output layout for this spec (C11):
- `../qa/baseline/` — pass-1 screenshots consolidated from the stray repo-root `qa/`
  folder + fresh current-state captures (T31)
- `../qa/T##-<screen>.png` — per-task verification shots
- `../qa/after/` — final full set for the contact sheet (T55)
