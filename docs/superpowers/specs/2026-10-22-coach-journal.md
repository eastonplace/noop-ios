# Journal inside Coach

The user approved the in-chat Journal and Coach mockup and requested an open,
unmerged pull request implementing it. This change extends PR #72's reviewed
Voice Journal rather than creating a second capture or storage path.

## Approved experience

- Show a compact Journal widget in Coach, using the existing dark palette and
  purple Journal accent. Offer explicit Yes and No answers. Unanswered stays
  distinct from No. Edits remain drafts until review and confirmation.
- Keep the full existing journal catalog available in a sheet. Include a visible
  wake-day selector. Statements describe the day and night leading into that
  morning; never infer a different save date from conversational text.
- Provide a Journal mode in the Coach composer. Typed or explicitly dictated
  text goes to editable review before persistence. Ordinary Coach questions
  continue to use the local model. Journal capture works without that model.
- Support a day note and optional mood using one confirmed transaction with
  reviewed answers. Preserve existing per-answer notes and imported records.
- Show real journal/recovery association cards with date windows, explicit
  group counts, missing-data and source information, and an Ask Coach action.
  Describe associations only. Never use mockup values in production.

## Boundaries

Local records remain local. Coach personal-record consent applies to automatic
reads and insight tools. A deliberate Journal action can open manual controls
without enabling the model's personal-record access. Dictation stays on device.
Source, database, catalog and civil-day changes invalidate stale reviews.
No Bluetooth changes, cloud services, production deployment, or merge.

## Acceptance

An empty day shows unanswered controls. A quick answer does not write until Save.
A typed entry can be reviewed, changed, cancelled, or saved. Notes-only and
mood-only saves work and conflicts leave the draft intact. An explicit No is the
only control group for associations. Missing or truncated observations never
become a confident numerical result. Manual capture remains available when the
model is unavailable. Previews cannot read or write personal journal records.

The new Coach quick controls require review. The full Journal sheet retains the
existing direct-save controls and their established behavior.
