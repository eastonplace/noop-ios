# Repository Regression and Qualification Tests

`ReferenceCore` tests the pure contracts. Implement the tests below in the real repository against GRDB,
Repository, IntelligenceEngine, BLEManager, SwiftUI projection seams, and lifecycle wiring. Use actor-idle,
generation, or durable-state seams. Do not use arbitrary sleeps or repeated `Task.yield()` calls.

## 1. Canonical Health authority and UI parity

```text
CanonicalSleepScoreRepositoryTests
- importedWHOOPWinsInOffShadowAndOn
- activeSourceAuthorityBeatsLexicographicSourceIdentifier
- shadowUsesLegacyForProductionAndV2ForDiagnostic
- shadowUsesV2BeforeProvisionalWhenLegacyIsAbsent
- onUsesV2BeforeLegacy
- TodaySleepTrendsWidgetWatchUseSameDayValueSourceModelGeneration
- displayedHistoricalNightUsesItsOwnProvenance
- scalarOnlyV2ScorePublishesWithoutDailyMetric
- failedV2ReadPreservesPreviousVerifiedPoint
- successfulCompleteAbsentReadClearsPoint
- SleepPerformanceModeChangeRebuildsCanonicalModelWithoutRowChange
```

```text
CanonicalHealthSurfaceStoreTests
- dailySleepMetricAndAppleRowsComeFromOneReadTransaction
- scorerCommitCannotCreateMixedWalGeneration
- overlappingSparseWindowsDeduplicateByNaturalKey
- inputSourceOrderDefinesAuthority
- stressAndAppleOnlyChangesAdvanceTrendsRevisionOnly
- SleepScoreOnlyChangeAdvancesPresentationAndTrendsRevision
- metadataOnlyGenerationOrFrontierChangeAdvancesNoPresentationRevision
```

## 2. Today snapshot and verified projection

```text
VerifiedHealthProjectionTests
- priorDayStrainIsNotVisibleAsCurrent
- latestNightRecoveryAndSleepRemainVisibleWithAgingLabel
- oldMetricIsStaleAndDisplaysLastScoredDay
- algorithmOrVisibleValueChangeBumpsPresentationIdentity
- unavailableReasonChangeBumpsPresentationIdentity
- metadataOnlyFrontierObservedAtOrGenerationChangeDoesNotBumpPresentationIdentity
- sourceDeletionProducesUnavailableEvidence
- olderPartialProducerCannotResurrectUnavailableGeneration
- restoreRejectsOldDatabaseContext
```

```text
VerifiedTodaySnapshotCommitTests
- candidateIsNotPublishedBeforeSaveAndReadBack
- processDeathAfterSaveBeforeInMemoryPublishHydratesCommittedValue
- saveRejectionDoesNotPublishCandidate
- readBackFailureKeepsLastCommittedInMemorySnapshotAndMarksWriterDirty
- verifierRejectsWrongSourceDayAlgorithmOrFrontier
- scalarSleepAndDurationCanCommitIndependently
```

## 3. Repository, Trends, and Sleep

```text
RepositoryExactPublicationTests
- exactDayPublishReplacesOnlyAuthoritativeDays
- exactDayPublishDeletesMissingSleepSession
- scoreOnlyChangeAdvancesRefreshSequence
- snapshotFailureDoesNotFailAuthoritativePublish
- publicationFenceReturnsDeferredNotFailed
- launchUsesBoundedRecentCache
- historyExtentStillReportsEarliestMultiYearDay
- selectedUncachedHistoricalDayLoadsExactlyAndCachesIt
- TrendsMonthDoesNotLoadFullHistory
- TrendsUsesOneCapturedCanonicalGeneration
- SleepInitialPageDoesNotLoadAllSessions
- SleepNavigationLoadsOneOlderPage
- currentDayAndPostBackfillExecuteNo4000DayQuery
- RepositoryCalendarBoundsHandleSpringAndFallDST
```

Instrument query count, read ranges, WAL generation, and SQLite query plans. Do not infer correctness from elapsed
time alone.

## 4. Receipt V2 and cursor integrity

```text
HistoricalDataCommitReceiptV2Tests
- fingerprintV2IsStableAcrossRawCaptureSettingChange
- fingerprintV2IsStableAcrossDerivedTimestampCorrectionAndRecordedZone
- fingerprintV2ChangesWhenAnyOrderedFrameChanges
- fingerprintV2ChangesWhenHistoryEndOrScopeChanges
- exactReplayReturnsOriginalReceiptAndCursor
- sameTrimDifferentFingerprintFailsClosed
- equalGenerationDifferentTrimCannotRewriteCursor
- olderGenerationCannotRegressCursor
- newLineageOrEpochMayReuseTrim
- decodedCountsAndInsertedCountsRemainDistinct
- timestampBucketsRemainSparse
- metadataOnlyTimestampRangeCreatesNoAnalysisWork
- receiptPersistsRecordedTimeZone
- legacyFingerprintIsNotSilentlyAdmittedAsExactV2Work
```

```text
RawOutboxIntegrityTests
- exactRawReplayIsNoOp
- reusedIdentityWithDifferentPayloadFails
- advertisedUncompressedLengthAboveCapThrowsBeforeAllocation
- advertisedLengthMustEqualFrameCountAndByteSizePackedLength
- impossibleFrameCountThrowsBeforeReserveCapacity
- truncatedFrameArchiveThrowsInsteadOfReturningPrefix
- trailingFrameArchiveBytesThrow
- storedFrameCountOrByteSizeMismatchThrows
- decompressionOutputLengthMismatchThrows
```

## 5. Receipt admission and source retirement

```text
HistoricalReceiptAdmissionTests
- workAndConsumerWatermarkCommitAtomically
- crashBeforeAdmissionCommitReplaysReceipts
- crashAfterAdmissionCommitDoesNotDuplicateWork
- decodedRowsWithZeroInsertsCreateWork
- emptyFinalReceiptDoesNotHideEarlierProductiveReceipt
- emptyLegacyReceiptAdvancesWatermarkWithoutFullRepair
- decoderOnlyDroppedRecordsDoNotCreateStorageRepair
- legacyStoredMutationCreatesLowPriorityFullRepair
- moreThanMaximumPageContinuesInSameRuntimeSignal
- receiptsFromDifferentRecordedZonesCreateSeparateWork
- currentPhysiologicalDayGetsHigherPriority
- exactTimestampHealCreatesExactWork
- unknownStorageHealCreatesFullRepairWork
- workKindIdentityUsesStableKeyRatherThanJsonBytes
```

```text
HistoricalScopeRetirementTests
- sourceTransitionAdvancesOldConsumerThroughLastReceipt
- sourceTransitionQuarantinesOldNonterminalWorkInSameTransaction
- retiredScopeDoesNotAppearInAdmissionContexts
- completedOldWorkAndReceiptsRemainAvailableForAudit
- newLineageStartsAtIndependentCursorEpoch
```

## 6. Durable analysis journal and coordinator

```text
AnalysisMutationJournalTests
- analysisGenerationIsSeparateAutoincrementDomain
- scoreRowsCommitBeforeMutationRecord
- sameWorkReceiptEdgeReplaysSemantically
- sameWorkReceiptEdgeWithDifferentDaysFrontierOrAlgorithmConflicts
- databaseReplacementRejectsOldMutation
- deleteDataRemovesDeviceMutationRows
```

For every crash seam, terminate and relaunch:

```text
before receipt admission
between work insert and consumer watermark (must be impossible transactionally)
after work admission
while leased before analysis
while analyzing
while a long analysis lease heartbeat is active
after score commit before mutation journal
after mutation journal before work-state advance
after verification before snapshot commit
after snapshot commit before Repository publish
after Repository publish before exact projection/outbox transaction
after outbox enqueue during each destination
```

Expected durable state is `complete`, `retryable` with `nextAttemptAt`, or `quarantined` with a terminal code.
No committed receipt generation disappears. No completed analysis is repeated because a destination retries.

```text
HistoricalPipelineCoordinatorTests
- currentDayJumpsAheadOfDeepHistory
- overlappingPendingWorkCoalescesWithoutFillingCalendarGaps
- newReceiptDuringAnalysisCreatesOneFollowUpWorkItem
- workLeaseRenewsDuringLongAnalysisAndVerification
- workCompletesImmediatelyAfterExactProjectionAndOutboxRowsCommit
- destinationRetriesDoNotHoldOrRecoverAnalysisLease
- batchBudgetSelfSignalsUntilNoDueWork
- pendingCountReadFailureIsReportedAsUnknownNotZero
```

## 7. Exact-day Intelligence

```text
IntelligenceExactDayTests
- formulasMatchLegacyAnalyzeRecentForSameFixtureDays
- oneCurrentNightReadsOnlyAffectedRawWindows
- sparseJanuaryAndMarchReceiptsDoNotAnalyzeFebruary
- requestedNoScoreDayStillAppearsInAuthoritativeAnalyzedDays
- DSTSpringForwardUses23HourCivilWindow
- DSTFallBackUses25HourCivilWindow
- timezoneTravelKeepsEachReceiptInRecordedZone
- napUpdateTouchesMainWakeDayDependenciesOnly
- lateRRRowsRescoreTheirAffectedNight
- baselineAggregatesReadOnceWithoutHistoricalRawRescan
- exactPathNeverCallsRepositoryRefresh
```

## 8. BLE confirmed writes

```text
BLEConfirmedWriteQueueIntegrationTests
- staleCallbackRetiresExactOldCharacteristicTokenBeforeReturning
- samePeripheralReplacementCharacteristicConsumesOnlyReplacementToken
- oldConnectionGenerationCannotConsumeNewToken
- timeoutPrunesAbandonedTokens
- permanentlyForgottenPeripheralCanClearItsTokens
- receiptTransactionFailureNeverSendsTrimAck
- exactReplayAfterLostAckSendsAck
- trimAckOccursAfterRawCursorReceiptCommitAndBeforeScoringCompletes
```

## 9. External outbox

```text
ExternalPublicationOutboxIntegrationTests
- oneItemPerContextGenerationDestination
- exactProjectionAndEveryDestinationInsertAtomically
- semanticProjectionReplayIgnoresDictionaryEncodingOrder
- sameGenerationDifferentProjectionConflicts
- processDeathAfterSnapshotCommitResumesEveryDestination
- widgetDoesNotWaitForHealthKit
- healthKitPathIsWriteOnlyAndNeverPrompts
- projectionGenerationMismatchQuarantines
- destinationRetryIsIndependent
- longDestinationWriteRenewsLease
- batchBudgetSelfSignalsUntilNoDueItems
- pruneRetainsRecentRowsPerContext
- pruneRetainsAnyProjectionReferencedByNonSucceededItem
- pruneFailureIsReportedAndDoesNotAcknowledgeWork
- TodayWidgetWatchValuesMatchExactProjectionGeneration
```

## 10. Device, deletion, and restore

```text
DeviceLifecyclePhase34Tests
- setActiveMissingDeviceLeavesCurrentActiveUnchanged
- archivedDeviceCannotBecomeActive
- rePairRetiresOldScopeBeforeActivatingNewLineage
- deleteAllDataDeletesWorkConsumerMutationSnapshotOutboxAndProjectionRows
- logicalWhoopFamilyDeletionAlsoClearsComputedSiblingRows
- restoreChangesDatabaseIdentityAndRejectsOldLeasesWorkMutationsAndProjections
- everyDeviceIdTableIsCoveredByDeviceScopedTables
```

## 11. Storage risks that require protocol evidence

Add diagnostic tests/telemetry now. Do not ship a guessed primary-key migration.

```text
HistoricalRecordCollisionDiagnostics
- firstSeenFingerprintComparesDecodedAndInsertedCountsByStream
- rrCollisionLogsStableFrameAndRecordEvidenceWhenAvailable
- repeatedSameKindEventCollisionLogsStableFrameAndRecordEvidenceWhenAvailable
- rawReceiptEvidenceRemainsAvailableForReproduction
```

A later schema change is allowed only after the decoder exposes a stable protocol sequence, frame offset, or
record ordinal for RR and event identity.

## 12. Performance and physical qualification

- Multi-year fixture: first meaningful Today paint ≤500 ms p95 from durable snapshot.
- Current committed burst → verified snapshot ≤30 seconds p95 in foreground.
- Eligible background execution → verified snapshot ≤5 minutes p95.
- Normal morning raw reads cover 1–2 day/night windows.
- No 4,000-day query before Today publication.
- No main-thread stall over 100 ms attributable to the pipeline.
- No value → blank transitions.
- Test app terminated and phone locked overnight.
- Test poor Bluetooth, disconnect, reconnect, and lost ACK replay.
- Test 23:59 → 00:01 and 03:59 → 04:00.
- Test DST changes and timezone travel.
- Verify Today, Sleep, Trends, widget, Watch, and HealthKit from the same generation.
