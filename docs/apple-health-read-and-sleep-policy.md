# Apple Health read and sleep policy

## Permission flow

- `healthKit.permissionRequestCompleted.v1` records completion of a permission request. It does not record or imply a read grant.
- A completed flow permits read attempts after relaunch, including read-only, partial, and subsequently revoked access. HealthKit can return empty results or an error. A read error retains the pending sync window for retry.
- A pre-flag install can resume when HealthKit reports that the legacy core permission request is unnecessary. This is a nonprompting request-status check. Write authorization does not determine read eligibility.
- Only the explicit permission action requests authorization. Lifecycle and background refresh do not request new types. Every write retains its existing per-type sharing authorization check.

## Empty reads and deletion evidence

Live import preserves missing daily fields, metric points, and workouts. An empty result cannot establish that a user deleted data or that reads remain granted.

A tombstone proves one object was removed. It does not prove a multi-object daily aggregate is empty, and the object index does not retain complete contributor/value provenance. Guarded live sync therefore retains missing daily fields and metric points even after known tombstones. Visible values, including numeric zero, still replace the prior value.

Known external workout tombstones carry their indexed timestamps in the durable sync journal, but the index does not map a UUID to a committed projected workout key. Even one indexed object and one banked row with identical timestamps can represent different workouts: the indexed object may never have projected, while the banked row came from XML. Guarded live sync therefore retains missing workout rows too. Timestamp and cardinality matches do not authorize removal. NOOP-owned export tombstones do not authorize inbound removal. An unknown UUID still causes the existing conservative historical requery, but cannot authorize clearing the history. Existing journals decode with no deletion evidence. No schema migration is required. Explicit authoritative replacement callers outside guarded live sync retain their existing replacement contract.

This policy does not delete raw evidence, `sleepSession` rows, or another source's data.

## Shared sleep reduction

XML and live HealthKit use `AppleSleepEpisodeReducer`:

1. Keep source, stage, identity, absolute start/end instants, and end offset until overlap resolution. Reject nonfinite, nonpositive, and over-24-hour individual intervals from projections. Keep the original input evidence.
2. Group overlapping intervals and gaps of at most 30 minutes into one episode. A gap contributes no sleep minutes. Separate naps remain separate episodes; daily totals include episodes with the same wake day.
3. Count each sleep instant once. Detailed core/deep/REM and awake evidence take priority over unspecified summaries. When detailed sources disagree, prefer the source with the most unioned detailed coverage in the episode, then stable source name and bundle identity. Stable interval/stage/identity ordering resolves remaining ties. This order does not claim that one sensor is more accurate.
4. Count in-bed envelopes as a separate interval union that cannot join separate sleep episodes. In-bed minutes can overlap sleep minutes and are never added to asleep totals. In-bed or awake evidence alone does not establish a live slept total. Detailed awake evidence can override an observed sleep summary to a measured zero.
5. Assign every selected stage to the final episode wake day. Use absolute duration arithmetic across DST. Use the final interval's recorded end offset for XML. Live HealthKit uses sample timezone metadata when present; otherwise it captures the query timezone and applies that timezone's historical DST offset. Without metadata, the recording timezone cannot be reconstructed.
6. Ignore unknown stages when forming episodes. XML retains its legacy zero-valued unknown-stage day without letting it move known sleep.

Live queries use one civil day of lookaround and retain raw unfinished episodes across one-day chunks, including equality at the 30-minute continuation boundary. Repeated overlap objects do not add duration. Only requested wake days enter the live daily projection.

XML aggregate rows use nil asleep/stage fields when a day has no asleep evidence. Missing awake or in-bed evidence likewise leaves its companion metric absent. An asleep summary fully overridden by detailed awake evidence remains an observed zero. The XML import writer coalesces missing fields only on the rows supplied by that explicit import, in one transaction for Apple/daily projections. It does not scan history or replace unrelated fields/sources. Metric-series upserts retain absent keys. The import mapping revision is 2.

## Qualification limits

The reducer fixes new projections. It does not rewrite banked historical rows. A partial XML fragment or one observed cross-day episode cannot prove a complete prior-day total: an existing row can also contain a previous night or a nap absent from that input. Such rows remain until complete authoritative inputs or contribution provenance support a separate correction. Known daily-aggregate and workout tombstones, as well as unknown-window tombstones, can likewise leave stale projections. Actual deletion reconciliation needs UUID-to-projection provenance or complete contribution/visibility proof; this change preserves banked data instead of guessing that a projection is absent.

Package tests cover the deterministic policies. Native integration tests and real HealthKit permission, locked-device, observer-delivery, and timezone behavior require separate verification.
