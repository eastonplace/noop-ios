# Four approved NOOP features

User authorization: implement the second through fifth features from the next-feature proposal, open one PR, push it, and leave it unmerged. The first feature, aerobic/anaerobic/strength training mix, belongs to Claude's parallel work and is excluded.

Base: `main` at `6f49d855d6f747103f4dc2a60949cb933445c3c0`.

## Daily training target

Add a Today section and an interactive preview that fit the existing Paper design. A transparent, bounded heuristic uses current-day Recovery, current-day sleep duration against a recent canonical Sleep Need, and completed prior days of canonical NOOP V2 daily Strain. The range describes the total day's Strain on the existing display scale. The current partial day never enters the historical baseline. Missing days remain missing, including measured zero days as real observations.

Require seven observed days in the preceding fourteen days, including yesterday. Reject invalid, duplicate, future, stale, or differently owned inputs. Show a useful missing-data state without a fabricated target. Recovery, short sleep, and excess recent load can lower the range. A preview reuses TrainingLoadEngine.step and RecoveryForecaster; it does not write observed metrics. It cannot simulate a daily total below current measured Strain. Display estimates and uncertainty as such, without a medical claim or a precise duration-to-Strain conversion.

The adapter reads a bounded 56-day transaction, pins the repository/database/source/day/time-zone context, and rejects an obsolete completion. The UI reads cached history on existing repository revisions. No new BLE sampling or recurring network request is required.

## Smart progressive overload

Extend the saved Lift routine preview. Use actual completed, non-warmup work sets for the same routine exercise, with explicitly rated effort required before increasing load. Honor equipment and display units. Missing, old, ambiguous, bodyweight, and timed histories produce conservative results. A review explains each change to weights, reps, or sets. Applying affects this session only and leaves the saved routine and history unchanged.

Optional planned-weight storage remains backward compatible. Revalidate the reviewed routine, history, equipment, unit system, and active store immediately before starting. An existing active workout cannot be replaced. All saved-routine start routes reach this preview.

## Voice journal

Add typed or explicitly started on-device dictation to the existing Journal. Recognition remains independent of the Coach language model. Parse bounded text against the actual visible journal catalog. Only explicit yes/no statements and quantities with compatible units can become entries. Missing answers stay missing. Unsupported or ambiguous text remains visible.

The user reviews, edits, or removes proposed answers before saving. Show current answers where a write would replace one. Compare reviewed native values and commit the batch in one SQLite transaction. Reject source/day/catalog changes before accepting Save. Admission pins the reviewed day and values in the global journal namespace; a later source change does not undo a successful commit. A native-answer conflict, database replacement, or write failure leaves the whole batch unsaved. Disable editable answers while saving. Preserve imported answers and notes. Cancelled or obsolete recognition callbacks cannot update a closed or replaced editor.

## Smarter workout detection

Extend the existing Save/Dismiss suggestion card. Keep AutoWorkoutDetector's interval semantics. Source-local step movement and sustained activity classifications may support walking/running labels. Confirmed manual history can supply a cautious possible type only after repeated consistent observations. Heart rate alone cannot confidently identify cycling or strength.

Show the label, confidence, and evidence, and allow the user to change the type. Save exact detected interval boundaries to the existing workout store under the captured source. Recheck ownership and overlap before writing. Display errors and keep the review visible after failure. Preserve durable dismissal and overlap suppression.

## Integration and verification

Use current UI components, repositories, source guards, and persistence owners. Keep PR70 and all other open branches untouched. No deployment or merge is authorized by this task.

Each feature needs logic tests for its edge cases and native tests for repository/coordinator behavior. Run focused source audits and exact-source portable Swift tests locally. GitHub's macOS workflow provides the native build and tests; local Swift syntax checks do not prove Apple SDK compilation. Challenge the completed patch with an independent reviewer before reporting the result.
