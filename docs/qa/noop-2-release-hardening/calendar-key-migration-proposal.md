# F16 / DL-05: non-Gregorian persisted day keys

**Disposition: confirmed, unfixed P1; coordinated migration required before claiming non-Gregorian calendar support is release-qualified.** This is inherited behavior present at the reviewed `26e150d2bbd1fcdf14a65de06e834e8b0841d5da` head, not a regression introduced by this hardening patch. The production helpers and the existing skipped XCTest remain unchanged.

## Candidate finding text

Normal analysis and manual day-key writers use the device's selected calendar year/month/day, while import/refresh readers and exact historical analysis use Gregorian keys. For the same Bangkok instant, unchanged production helpers produce `2569-10-12` under a Buddhist calendar versus the canonical `2026-10-12`; Japanese, Hebrew, and Islamic calendar probes also disagree. This can hide computed or manually logged data, separate it from imported history, and give ordinary and exact receipt analyses different persisted identities. Correcting only `civilDayWindows` would leave repository/UI/manual keys inconsistent; correcting all helpers without a migration would strand existing day-key-only records. Preserve ambiguous manual records and resolve collisions in a separately reviewed, restart-safe migration. Do not count the guarded Buddhist test as passing or this defect as fixed.

## Reproduced evidence

The standalone script [calendar-key-probe.py](calendar-key-probe.py) extracts **nine declarations without changing their bodies** from current production files, wraps them in isolated types, and compiles them with Swift Foundation. It creates synthetic in-memory SQLite tables for a separate key/predicate demonstration. It does not open an application or health database. The generated body hashes and original locations are in [calendar-key-probe-source-manifest.json](calendar-key-probe-source-manifest.json); complete output is in [calendar-key-probe-results.json](calendar-key-probe-results.json).

Reference: `2026-10-12 06:00 Asia/Bangkok`, Unix `1_791_759_600`, after the 04:00 logical rollover. The existing skipped test uses this same instant.

| Calendar passed to production helpers | Engine `CivilDayWindow.day` | Repository local/logical key | Repository refresh / store key |
| --- | --- | --- | --- |
| Gregorian | `2026-10-12` | `2026-10-12` | `2026-10-12` |
| Buddhist | `2569-10-12` | `2569-10-12` | `2026-10-12` |
| Japanese | `0008-10-12` | `0008-10-12` | `2026-10-12` |
| Hebrew | `5787-02-01` | `5787-02-01` | `2026-10-12` |
| Islamic civil | `1448-04-29` | `1448-04-29` | `2026-10-12` |

**All five cases retain the same correct midnight instant** `1_791_738_000`, next midnight `1_791_824_400`, and 86,400-second interval. The defect is stored key identity, not the existing civil-day/DST interval arithmetic. The second Buddhist key is `2569-10-11`, where the skipped test expects `2026-10-11`.

The unchanged `civilDayStart("2026-10-12", calendar: buddhist)` also returns `-15_342_936_124` instead of `1_791_738_000`. A Gregorian key interpreted in the selected calendar's era becomes a different historical instant. Other non-Gregorian cases likewise differ; the output records their exact values.

The SQLite probe reproduces these additional, explicitly limited consequences:

1. With imported `my-whoop/2026-10-12` and computed `my-whoop-noop/2569-10-12` rows, a Gregorian refresh range selects only the imported row. It does not merge the two as one day.
2. A persisted `metricSeries` hydration total under `2569-10-12` is absent when read at `2026-10-12` after a helper-only correction. Its original row still exists.
3. If the native journal already contains opposite answers for the same question under both keys, a naive re-key fails with `UNIQUE constraint failed: journal.deviceId, journal.day, journal.question`. A last-writer overwrite would instead discard an answer without evidence of which was intended.
4. The **verbatim production timestamp-heal DELETE predicate**, supplied the Gregorian today key and the existing 2023-11-14 floor, deletes the non-Gregorian computed daily row as a future date. This proves the SQL consequence if that heal runs; it does not claim every affected user's one-shot/pending heal is currently armed. Raw timestamped samples are not changed by this fixture.

These are host executions of extracted production helpers plus a synthetic SQLite contract probe. They are **not a native end-to-end app run**, a real user's database inspection, or executed full `analyzeRecent`/journal/hydration integration tests. The production reachability below is source evidence.

## Reachable production paths

Line references below describe the reviewed source; the extraction manifest records exact helper locations and hashes.

| Path | Evidence | Consequence |
| --- | --- | --- |
| Ordinary analysis versus exact historical work | `Strand/Data/IntelligenceAnalysisCoordinator.swift:836–849` uses `context.gregorianCalendar()` for committed work, otherwise `.current`; `CommittedAnalysisRuns.swift:21–27` preserves the recorded zone in a Gregorian calendar. | These two production lanes can name the same local interval differently. |
| Civil-day writer | `Strand/Data/IntelligenceEngine.swift:391–410` builds the key from the supplied calendar's components; `1589–1590` carries it into the scan; `1908` passes it to `AnalyticsEngine.analyzeDay`. `Packages/StrandAnalytics/Sources/StrandAnalytics/AnalyticsEngine.swift:952–955` stores the supplied day in `DailyMetric`. | Incorrect era-based strings become real computed row identities, not just displayed dates. |
| Persisted derived history | `IntelligenceEngine.swift:3005–3041` reconciles `dailyMetric` and day-keyed `metricSeries` using the same enumerated range. `Packages/WhoopStore/Sources/WhoopStore/MetricsCache.swift:473–499` writes these keys and uses lexical day ranges. | Gregorian and era-based rows can coexist outside each other's reconciliation range. |
| Repository reads and Today keys | `Repository.swift:1152–1157,1178–1186` creates local/logical keys from the current calendar. `2373–2415` refreshes with `dayString`; the shared formatter at `5308–5316` uses POSIX Gregorian formatting. `MetricPresentation.swift:141–164` explicitly treats stored keys as Gregorian. | Selection and persisted refresh can disagree even inside the same repository. |
| Manual hydration | `Strand/Screens/HydrationView.swift:300` calls `logHydration` without a day. `Strand/Data/HydrationStore.swift:109–120` defaults to `Repository.localDayKey`, writes the total, and stores the entry bucket. | Normal user logging can persist era-based keys. Existing buckets need preservation when producers are corrected. |
| Native journal / notes / mood | `Strand/Screens/JournalLogCard.swift:71–78` defaults through `Repository.localDayKey`; `StrandiOS/Coach/CoachJournalSession.swift:125` does the same for its initial day. `JournalReviewedSave.swift:43–104` writes the reviewed key; `JournalDayDetailsStore.swift:73–95` writes day notes and mood. | User-authored answers and details can use the same noncanonical identities. A numeric-looking Gregorian-valid future key is not rejected merely because it came from another calendar. |
| Manual sleep recovery | `Strand/Data/Repository+SleepRecovery.swift:221–236,269–294` derives the wake-day key from `Calendar.current`, reads that baseline range, and constructs the daily override. `SleepRecoveryDailyOverrideStore.swift:80–166` persists the override, daily row, and Rest series together. | Correct recovery-session timestamps can be coupled to the wrong day-keyed daily overlay/baseline range. |
| Existing timestamp heal | `Packages/WhoopStore/Sources/WhoopStore/TimestampHeal.swift:67–68,80–87` compares day strings to an already-Gregorian local today. `IntelligenceEngine.swift:1202–1224` runs the heal when its one-shot or pending flag requires it. | Noncanonical computed keys can be treated as future/ancient data when this existing maintenance path executes. |

Imported/history lookup, UI blanks, mixed baselines, manual save reachability, and coexistence of normal/exact output are supported by those paths. The full app consequences have not been separately executed on an iOS device using a non-Gregorian preferred calendar.

## The existing deferral is only partly stale

`StrandiOSTests/IntelligenceTimestampSafetyTests.swift:77–95` deliberately skips DL-05 until the coordinated N3-4 work is ready. Its statement that the **store's** `localDayKey` still needs Gregorian conversion is stale: `WhoopStore.localDayKey` already explicitly selects Gregorian/POSIX. The engine and repository helpers remain inconsistent, and this review found no shipped journal/hydration calendar re-key migration.

The earlier `docs/reviews/2026-10-22-noop-audit/metrics-report.md:150` and handoff classified this as a candidate because it had not been reproduced. The executable evidence above now supports a confirmed finding. It does not authorize removing the skip before the complete producer/read/compatibility contract is corrected.

## Confirmed persisted scope and preservation constraints

| Storage | Demonstrated producer / relationship | Required preservation |
| --- | --- | --- |
| `dailyMetric` | Ordinary engine and manual sleep recovery | Rebuild only source-proven derived rows; preserve imports and user recovery overlays. Do not collapse sources or overwrite a different day's data. |
| `metricSeries` | Derived engine outputs; `hydration/hydration`; native `noop-mood/mood`; recovered `sleep_performance` | Move associated values consistently with their owning day. Do not add duplicate derived scores or sum old/new daily hydration totals blindly. |
| `journal` | Reviewed native answers, keyed by `(deviceId, day, question)` | Keep answers and attached notes; imported and native namespaces remain distinct. Conflicting answers require an explicit policy, not unordered last-write wins. |
| `journalDayNote` | Native reviewed day notes | Preserve complete text and distinguish conflicting notes. The schema stores a day key, not the originating calendar/era/zone or event timestamp. |
| `sleepRecoveryDailyOverride` | User recovery wake-day overlay, coupled to a timestamped sleep session and daily/series rows | Keep recovery provenance and fields intact; re-key the complete overlay/daily/Rest relationship atomically. |
| UserDefaults `noop.hydrationEntries.<day>` | Individual entry arrays written by `HydrationStore` | Preserve entry UUIDs, amounts, and `loggedAt`; deduplicate by stable identity when combining aliases. Database totals and entry arrays must survive interruption between storage systems. |

The native `journal` model/schema (`JournalWorkoutAppleCache.swift:10–24`, `Database.swift:157–165`) and `journalDayNote` schema (`JournalDayNoteMigration.swift:10–15`) have no original calendar identifier, era, or zone. `metricSeries` (`Database.swift:204–210`) similarly has only owner/day/key/value. Hydration's newer entry model contains `loggedAt`, but historical totals need not have matching per-entry data, and `loggedAt` does not record the original local zone or an explicitly selected day.

Therefore **a blanket numerical year offset or parsing every old key in today's calendar is not a safe migration**. Buddhist offsets do not handle other calendars; Japanese keys omit era, and travel/calendar changes can make current preferences differ from the original writer. Correct Gregorian rows may already coexist with legacy rows after an exact receipt pass or a preference change.

Dependent references require an inventory before implementation: `dayOwnership` is looked up using the analysis day, and receipt/maintenance day sets, lift/strain day references, recovery identities, and persisted/RAM day caches can depend on that key. These are compatibility review obligations, not claims that this probe executed malformed writes into every such table. Timestamped raw streams, workouts, and sleep sessions should retain their existing absolute timestamps.

## Bounded safe implementation proposal

This is a separate migration work item; it is not a broad scoring redesign.

1. **Unify the storage contract.** Use a shared Gregorian storage calendar with the supplied time-zone identity for every key producer and inverse parser in the affected paths. Preserve current local-midnight/04:00 rollover rules, real 23/25-hour DST intervals, and all scientific arithmetic. User-selected calendars/locales continue to control display formatting. Engine-only normalization is insufficient.
2. **Build an auditable mapping before destructive writes.** Classify records by source and provenance. Derive corrected days from trustworthy raw/session timestamps and the relevant recorded zone when available. Preserve original rows and keys when calendar/era/zone evidence is ambiguous; do not silently guess, delete, or overwrite manual history. A resolution mechanism for ambiguous manual records must be designed before calling the migration complete.
3. **Define collisions per data type.** Recompute derived daily values under the existing formulas from the proven source, instead of summing duplicate scores. Preserve authoritative imported values and user-edited recovery. For journal conflicts retain both candidate values/notes until a deterministic, reviewable resolution is available. Merge hydration entries by UUID and derive a total only from complete, trustworthy entry sets; preserve legacy totals whose entry evidence is incomplete.
4. **Make migration restart-safe across storage systems.** Use transactional database updates for each complete related key set, with durable progress and original-to-canonical mapping evidence. UserDefaults cannot participate in the same SQLite transaction: retain old buckets until the durable database mapping and new bucket are verified, resume idempotently after interruption, and never mark a day done before both representations agree. Avoid broad future/ancient cleanup until calendar reconciliation has classified affected keys.
5. **Coordinate reads, writers, and caches.** Prevent ordinary and exact analysis from writing different key schemes during transition. Apply compatible reads for unresolved legacy records; invalidate stale day caches only after the canonical state is durable. Protect source/database ownership and preserve recovery undo conflicts. Inventory the dependent day references above before declaring the re-key complete.

A shared helper by itself is a small code change. The preservation requirements make the complete fix a higher-risk multi-store migration; no partial implementation is recommended in this hardening patch.

## Acceptance criteria before removing the skip

- Execute the existing Buddhist assertion without `XCTSkip`, plus Gregorian/Japanese/Hebrew/Islamic cases through actual repository/analysis integration. Assert normal, imported, exact-receipt, manual-recovery, and UI reads agree on the same canonical key.
- Preserve the existing spring/fall DST assertions, 04:00 logical rollover, and timezone-travel behavior; compare absolute window instants and existing scientific outputs before/after on Gregorian fixtures.
- Seed a prior-version database with legacy-only keys, canonical-only keys, and collisions in every confirmed storage type. Include native notes/answers lacking timestamps, imported rows, recovery overlays, and hydration totals without entry arrays. Prove no ambiguous manual content is silently lost.
- Exercise interrupted/resumed migration between every database/UserDefaults boundary, conflict rollback, repeated launch, restore/source changes, and competing normal/exact analysis. Verify idempotence and complete daily/overlay/series consistency.
- Verify the timestamp heal and lexical cleanup do not delete unresolved calendar aliases, and that a repaired raw-backed day reappears in history under the intended Gregorian identity.
- Run a native non-Gregorian simulator/device scenario with existing history. Host helper output alone is insufficient to clear the release gate.

## Reproduction

From the repository root, with Swift installed:

```sh
python3 docs/qa/noop-2-release-hardening/calendar-key-probe.py \
  --swiftc /path/to/swiftc \
  --output-dir /tmp/noop-calendar-daykey-probe
```

The script exits successfully only if the observed Gregorian control, Buddhist mismatch, matching midnight intervals, missing hydration lookup, journal collision, and heal predicate behavior reproduce. Success means the **known defect was reproduced**, not that production is fixed. The checked-in JSON includes the compiler version. No production source, migration, scientific formula, database schema, or skipped test was changed by this investigation.
