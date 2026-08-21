import Foundation

// 手動註冊(無 XCTest runtime 探索可用)。新增測試方法時記得加進對應清單。

let iso = ISO8601Tests()
runSuite("ISO8601Tests", [
    ("testParseVariants", iso.testParseVariants),
    ("testStrictParseRequiresFullConsumption", iso.testStrictParseRequiresFullConsumption),
    ("testStrictParseRejectsSemanticallyInvalidComponents", iso.testStrictParseRejectsSemanticallyInvalidComponents),
])

let scanner = JSONLScannerTests()
runSuite("JSONLScannerTests", [
    ("testChunkBoundaryScanPreservesOffsetsAndLines", scanner.testChunkBoundaryScanPreservesOffsetsAndLines),
])

let trends = TrendsDataTests()
runSuite("TrendsDataTests", [
    ("testDailyBucketsAggregateByLocalDay", trends.testDailyBucketsAggregateByLocalDay),
    ("testUsageStreakCurrentAndLongest", trends.testUsageStreakCurrentAndLongest),
    ("testDailyBucketsTopProjectModelAndCost", trends.testDailyBucketsTopProjectModelAndCost),
])

let scheduled = ScheduledReportTests()
runSuite("ScheduledReportTests", [
    ("testPlistXMLContentAndEscaping", scheduled.testPlistXMLContentAndEscaping),
])

let installHook = InstallHookTests()
runSuite("InstallHookTests", [
    ("testShellSingleQuote", installHook.testShellSingleQuote),
    ("testFreshVariants", installHook.testFreshVariants),
    ("testRefusals", installHook.testRefusals),
    ("testWrapSimpleScriptPath", installHook.testWrapSimpleScriptPath),
    ("testTildeExpansion", installHook.testTildeExpansion),
    ("testDirectoryOrSpecialTargetRefused", installHook.testDirectoryOrSpecialTargetRefused),
    ("testComplexCommandRefused", installHook.testComplexCommandRefused),
    ("testBareRelativeMissingRefused", installHook.testBareRelativeMissingRefused),
    ("testCommandPointingAtHookRefused", installHook.testCommandPointingAtHookRefused),
    ("testCanonicalFormsAlreadyInstalled", installHook.testCanonicalFormsAlreadyInstalled),
    ("testCanonicalWithoutTypeGetsPreciseRefusal", installHook.testCanonicalWithoutTypeGetsPreciseRefusal),
    ("testCanonicalIsByteExactNoTrim", installHook.testCanonicalIsByteExactNoTrim),
    ("testEmbeddedHookMatchesScriptsFile", installHook.testEmbeddedHookMatchesScriptsFile),
    ("testRunnerFreshInstall", installHook.testRunnerFreshInstall),
    ("testRunnerIdempotentAndRepairsHook", installHook.testRunnerIdempotentAndRepairsHook),
    ("testRunnerWrapExistingScriptEndToEnd", installHook.testRunnerWrapExistingScriptEndToEnd),
    ("testRunnerDryRunWritesNothing", installHook.testRunnerDryRunWritesNothing),
    ("testRunnerSymlinkedSettingsRefusedButHookRepairable", installHook.testRunnerSymlinkedSettingsRefusedButHookRepairable),
    ("testRunnerConfigDirIsRegularFile", installHook.testRunnerConfigDirIsRegularFile),
    ("testRunnerBackupCollision", installHook.testRunnerBackupCollision),
    ("testNewCommandEscapedInOutput", installHook.testNewCommandEscapedInOutput),
    ("testRefuseComplexEscapesControlChars", installHook.testRefuseComplexEscapesControlChars),
    ("testACLClearedOnCreatedFiles", installHook.testACLClearedOnCreatedFiles),
    ("testRunnerSymlinkToHookRefused", installHook.testRunnerSymlinkToHookRefused),
    ("testAlreadyInstalledCanonicalAliasToHookRefused", installHook.testAlreadyInstalledCanonicalAliasToHookRefused),
    ("testHookACLRepairedWhenPresent", installHook.testHookACLRepairedWhenPresent),
    ("testACLAbsentErrnoClassification", installHook.testACLAbsentErrnoClassification),
    ("testAlreadyInstalledHardlinkToHookRefused", installHook.testAlreadyInstalledHardlinkToHookRefused),
    ("testHookACLLookupErrorFailsClosed", installHook.testHookACLLookupErrorFailsClosed),
    ("testCLIUnknownArgWritesNothing", installHook.testCLIUnknownArgWritesNothing),
    ("testCLIProcessExitCode", installHook.testCLIProcessExitCode),
    ("testCLIDryRunCreatesNothing", installHook.testCLIDryRunCreatesNothing),
])

let claude = ClaudeCodeAdapterTests()
runSuite("ClaudeCodeAdapterTests", [
    ("testParsesFixture", claude.testParsesFixture),
    ("testStatuslinePayloadYieldsOfficialRateLimits", claude.testStatuslinePayloadYieldsOfficialRateLimits),
    ("testHookFrozenSchemaFixtureDecodes", claude.testHookFrozenSchemaFixtureDecodes),
    ("testHookProducedFileDecodesEndToEnd", claude.testHookProducedFileDecodesEndToEnd),
    ("testIncrementalScanDoesNotDuplicate", claude.testIncrementalScanDoesNotDuplicate),
    ("testDetectAvailabilityRechecksInjectedRootAfterCreation", claude.testDetectAvailabilityRechecksInjectedRootAfterCreation),
    ("testStatuslinePerWindowFreshestComposition", claude.testStatuslinePerWindowFreshestComposition),
    ("testStatuslineSplitReadingsEndToEndNoCrossPollution", claude.testStatuslineSplitReadingsEndToEndNoCrossPollution),
    ("testPlanLabelMappingPriority", claude.testPlanLabelMappingPriority),
    ("testPlanOnlyReadingEmittedFromConfigFixture", claude.testPlanOnlyReadingEmittedFromConfigFixture),
])

let codex = CodexAdapterTests()
runSuite("CodexAdapterTests", [
    ("testParsesTotalsDeltasAndRateLimits", codex.testParsesTotalsDeltasAndRateLimits),
    ("testIncrementalPreservesContext", codex.testIncrementalPreservesContext),
    ("testCodexClassifiesWindowsByDurationThroughRefresh", codex.testCodexClassifiesWindowsByDurationThroughRefresh),
])

let grok = GrokCodeAdapterTests()
runSuite("GrokCodeAdapterTests", [
    ("testParsesGrowthCompactionModelAndProject", grok.testParsesGrowthCompactionModelAndProject),
    ("testCompactionRegressionEmitsNoNegativeOrZero", grok.testCompactionRegressionEmitsNoNegativeOrZero),
    ("testIncrementalEmitsOnlyNewDelta", grok.testIncrementalEmitsOnlyNewDelta),
    ("testShrinkTriggersFullRescanWithStableIds", grok.testShrinkTriggersFullRescanWithStableIds),
    ("testEventIdFallbackToSessionAndOffset", grok.testEventIdFallbackToSessionAndOffset),
    ("testTimestampSecondsMillisFallbackAndSkip", grok.testTimestampSecondsMillisFallbackAndSkip),
    ("testPrivacySentinelNeverLeaks", grok.testPrivacySentinelNeverLeaks),
    ("testAvailabilityFollowsRootExistence", grok.testAvailabilityFollowsRootExistence),
    ("testModelFallbackToSignalsThenNil", grok.testModelFallbackToSignalsThenNil),
    ("testGrokEnabledInDefaultSettings", grok.testGrokEnabledInDefaultSettings),
    ("testGeneratedPricesNeverAutoPriceGrok", grok.testGeneratedPricesNeverAutoPriceGrok),
    ("testCuratedEntryDeliberatelyPricesGrok", grok.testCuratedEntryDeliberatelyPricesGrok),
    ("testBillingTierParsedFromLogTail", grok.testBillingTierParsedFromLogTail),
    ("testPlanOnlyReadingEmittedThroughRefresh", grok.testPlanOnlyReadingEmittedThroughRefresh),
])

let ledger = LedgerTests()
runSuite("LedgerTests", [
    ("testDedupeAndPersistence", ledger.testDedupeAndPersistence),
    ("testQueries", ledger.testQueries),
    ("testForEachParityAndHalfOpenInterval", ledger.testForEachParityAndHalfOpenInterval),
    ("testMissingThenRestoredLedgerReloads", ledger.testMissingThenRestoredLedgerReloads),
    ("testInternPoolBoundedAfterRemovalAndFailedAppend", ledger.testInternPoolBoundedAfterRemovalAndFailedAppend),
    ("testForEachEventReentrantMutationIsSafe", ledger.testForEachEventReentrantMutationIsSafe),
    ("testRevisionAdvancesOnCommitsOnly", ledger.testRevisionAdvancesOnCommitsOnly),
])

let trustMachine = TrustHealthMachineTests()
runSuite("TrustHealthMachineTests", [
    ("testEveryStateEntryAndExit", trustMachine.testEveryStateEntryAndExit),
    ("testSchemaKillEscalationPathsAndAbsorbing", trustMachine.testSchemaKillEscalationPathsAndAbsorbing),
    ("testReactivateSemantics", trustMachine.testReactivateSemantics),
    ("testStaleOverlayAndRecoveryMapping", trustMachine.testStaleOverlayAndRecoveryMapping),
])

let trustFreshness = TrustFreshnessTests()
runSuite("TrustFreshnessTests", [
    ("testNilObservationNeverStale", trustFreshness.testNilObservationNeverStale),
    ("testHysteresisBands", trustFreshness.testHysteresisBands),
    ("testNegativeAgeIsClockChangedNotStale", trustFreshness.testNegativeAgeIsClockChangedNotStale),
])

let trustConflict = TrustConflictTests()
runSuite("TrustConflictTests", [
    ("testRaiseAfterThreeDivergentAndPairDedup", trustConflict.testRaiseAfterThreeDivergentAndPairDedup),
    ("testIncomparableWhenObservedTooFarApart", trustConflict.testIncomparableWhenObservedTooFarApart),
    ("testClearByConvergenceAndByWithdrawal", trustConflict.testClearByConvergenceAndByWithdrawal),
    ("testPairDedupSurvivesNonAdjacencyAndReset", trustConflict.testPairDedupSurvivesNonAdjacencyAndReset),
    ("testTwoStageExpiry", trustConflict.testTwoStageExpiry),
])

let trustOrdering = TrustOrderingTests()
runSuite("TrustOrderingTests", [
    ("testSameOrderedSequenceIsDeterministic", trustOrdering.testSameOrderedSequenceIsDeterministic),
    ("testCrossSourcePermutationsSafetyInvariant", trustOrdering.testCrossSourcePermutationsSafetyInvariant),
    ("testStabilizationConvergence", trustOrdering.testStabilizationConvergence),
])

let trustWiring = TrustWiringTests()
runSuite("TrustWiringTests", [
    ("testActiveOkAfterSuccessfulRefresh", trustWiring.testActiveOkAfterSuccessfulRefresh),
    ("testDisabledBeatsEverything", trustWiring.testDisabledBeatsEverything),
    ("testFailedRefreshIsTransientErrorNotStaleNotGeneric", trustWiring.testFailedRefreshIsTransientErrorNotStaleNotGeneric),
    ("testStaleWhenObservationWindowExceededAndParseWarnings", trustWiring.testStaleWhenObservationWindowExceededAndParseWarnings),
])

let grokQuota = GrokQuotaTests()
runSuite("GrokQuotaTests", [
    ("testValidEnvelopeNeverRendersCreditUsagePercentAsQuota", grokQuota.testValidEnvelopeNeverRendersCreditUsagePercentAsQuota),
    ("testEnvelopeClassification", grokQuota.testEnvelopeClassification),
    ("testHTTPStatusAndOversizedMapping", grokQuota.testHTTPStatusAndOversizedMapping),
    ("testObservationEventMappingAndMachineIntegration", grokQuota.testObservationEventMappingAndMachineIntegration),
    ("testRequestShapeAndRedirectRefusal", grokQuota.testRequestShapeAndRedirectRefusal),
    ("testKeyParserNestedRealSchemaAndNarrow", grokQuota.testKeyParserNestedRealSchemaAndNarrow),
    ("testKeyParserNarrowIgnoresAdversarialSiblingTypes", grokQuota.testKeyParserNarrowIgnoresAdversarialSiblingTypes),
    ("testKeyParserMultiAccountDeterministicSelection", grokQuota.testKeyParserMultiAccountDeterministicSelection),
    ("testKeyParserFormatUnrecognizedVsRetryable", grokQuota.testKeyParserFormatUnrecognizedVsRetryable),
    ("testKeyParserOneBadEntryDoesNotKillValidSibling", grokQuota.testKeyParserOneBadEntryDoesNotKillValidSibling),
    ("testIssuerExactHostNotSubstring", grokQuota.testIssuerExactHostNotSubstring),
    ("testExpiresAtFractionalSecondsUsedInSelection", grokQuota.testExpiresAtFractionalSecondsUsedInSelection),
    ("testPolicyZeroEgressWhenDisabledAndFull401Cycle", grokQuota.testPolicyZeroEgressWhenDisabledAndFull401Cycle),
    ("testCredentialChangeGate", grokQuota.testCredentialChangeGate),
])

let trustPlanLabel = TrustPlanLabelTests()
runSuite("TrustPlanLabelTests", [
    ("testDecisionTreeBranches", trustPlanLabel.testDecisionTreeBranches),
])

let percentShares = PercentSharesTests()
runSuite("PercentSharesTests", [
    ("testSharesSumToExactly100", percentShares.testSharesSumToExactly100),
    ("testSharesExtremeScaledAndRowQuota", percentShares.testSharesExtremeScaledAndRowQuota),
    ("testReportProjectShareColumnUsesGroupQuota", percentShares.testReportProjectShareColumnUsesGroupQuota),
])

let aggCache = AggregationCacheTests()
runSuite("AggregationCacheTests", [
    ("testProjectPageCacheHitAndInvalidation", aggCache.testProjectPageCacheHitAndInvalidation),
    ("testTrendsInvalidatesOnNewEvents", aggCache.testTrendsInvalidatesOnNewEvents),
    ("testTrendsSeesFutureTimestampedEventAsNowAdvances", aggCache.testTrendsSeesFutureTimestampedEventAsNowAdvances),
])

let limits = LimitEngineTests()
runSuite("LimitEngineTests", [
    ("testMonotonicGuardWithinWindow", limits.testMonotonicGuardWithinWindow),
    ("testUsedPercentCappedAtHundred", limits.testUsedPercentCappedAtHundred),
    ("testSameWindowZeroWindowMinutesDoesNotClobberStoredLength", limits.testSameWindowZeroWindowMinutesDoesNotClobberStoredLength),
    ("testExpiredWindowRolloverAdoptsFirstReading", limits.testExpiredWindowRolloverAdoptsFirstReading),
    ("testLiveWindowTakeoverNeedsSecondReading", limits.testLiveWindowTakeoverNeedsSecondReading),
    ("testBackendFlapSingleReadingCannotPoisonWindow", limits.testBackendFlapSingleReadingCannotPoisonWindow),
    ("testPendingConfirmationSurvivesEngineReload", limits.testPendingConfirmationSurvivesEngineReload),
    ("testDuplicateReplayCannotConfirmPending", limits.testDuplicateReplayCannotConfirmPending),
    ("testOldObservationsAreFullyInert", limits.testOldObservationsAreFullyInert),
    ("testStaleCandidateWindowRejected", limits.testStaleCandidateWindowRejected),
    ("testSweepThenAdoptEmitsSingleReset", limits.testSweepThenAdoptEmitsSingleReset),
    ("testOldSameWindowReplayKeepsPendingAlive", limits.testOldSameWindowReplayKeepsPendingAlive),
    ("testEarlierResetWindowRecoversFlapCapturedSlot", limits.testEarlierResetWindowRecoversFlapCapturedSlot),
    ("testPendingKeepsMonotonicMaxWithinCandidateWindow", limits.testPendingKeepsMonotonicMaxWithinCandidateWindow),
    ("testOutOfOrderIncumbentReadingKeepsNewerPending", limits.testOutOfOrderIncumbentReadingKeepsNewerPending),
    ("testNilResetIncumbentAdoptsResetBearingReadingImmediately", limits.testNilResetIncumbentAdoptsResetBearingReadingImmediately),
    ("testFreshIncumbentReadingCancelsPending", limits.testFreshIncumbentReadingCancelsPending),
    ("testThirdWindowCandidateReplacesPending", limits.testThirdWindowCandidateReplacesPending),
    ("testLegacyStateFileWithoutPendingKeyDecodes", limits.testLegacyStateFileWithoutPendingKeyDecodes),
    ("testNilResetRolloverAcceptsLowerAndEmitsReset", limits.testNilResetRolloverAcceptsLowerAndEmitsReset),
    ("testHistoryDedupPreservesSlopeAcrossEqualRefreshes", limits.testHistoryDedupPreservesSlopeAcrossEqualRefreshes),
    ("testFullReindexAllowsDownwardCorrection", limits.testFullReindexAllowsDownwardCorrection),
    ("testThresholdCrossingsAndExhausted", limits.testThresholdCrossingsAndExhausted),
    ("testExpiredWindowShowsRecoveredAndSweepEmitsReset", limits.testExpiredWindowShowsRecoveredAndSweepEmitsReset),
    ("testClaudeOfficialReadingsBeatBudgetEstimation", limits.testClaudeOfficialReadingsBeatBudgetEstimation),
    ("testClaudeStaleReadingsFallBackToBudget", limits.testClaudeStaleReadingsFallBackToBudget),
    ("testClaudeExpiredReadingsWaitTwentyFourHoursBeforeBudgetFallback", limits.testClaudeExpiredReadingsWaitTwentyFourHoursBeforeBudgetFallback),
    ("testClaudeFiveHourFallsBackEvenWhenWeeklyReadingIsStillFutureDated", limits.testClaudeFiveHourFallsBackEvenWhenWeeklyReadingIsStillFutureDated),
    ("testClaudeExpiredFiveHourFallsBackImmediatelyWhenLedgerShowsPostResetActivity", limits.testClaudeExpiredFiveHourFallsBackImmediatelyWhenLedgerShowsPostResetActivity),
    ("testClaudeExpiredFiveHourToleratesScanRaceRightAfterReset", limits.testClaudeExpiredFiveHourToleratesScanRaceRightAfterReset),
    ("testClaudeFiveHourBlocks", limits.testClaudeFiveHourBlocks),
    ("testClaudeIdleFiveHourShowsIdleNotFakePercent", limits.testClaudeIdleFiveHourShowsIdleNotFakePercent),
    ("testClaudeBudgetPercentAndEstimatedReset", limits.testClaudeBudgetPercentAndEstimatedReset),
    ("testEstimatedResetSuppressedWhenOfficialWindowGoverns", limits.testEstimatedResetSuppressedWhenOfficialWindowGoverns),
    ("testEstimatedResetFiresForNextBoundaryWhenOfficialStopsGoverning", limits.testEstimatedResetFiresForNextBoundaryWhenOfficialStopsGoverning),
    ("testEstimatedResetStaleBoundaryDoesNotFireAfterSleep", limits.testEstimatedResetStaleBoundaryDoesNotFireAfterSleep),
    ("testSweepDoesNotCelebrateStaleExpiry", limits.testSweepDoesNotCelebrateStaleExpiry),
    ("testSweepStillCelebratesFreshExpiry", limits.testSweepStillCelebratesFreshExpiry),
    ("testFoldRolloverProcessedLateAdoptsSilently", limits.testFoldRolloverProcessedLateAdoptsSilently),
    ("testPreferOfficialResetsDropsEstimatedDuplicate", limits.testPreferOfficialResetsDropsEstimatedDuplicate),
    // 同窗官方下修(二筆確認;DATA_SOURCES policy 通道 (c))
    ("testSameWindowSingleLowerReadingStaysPinned", limits.testSameWindowSingleLowerReadingStaysPinned),
    ("testSameWindowDecreaseAdoptsAfterTwoNewerReadings", limits.testSameWindowDecreaseAdoptsAfterTwoNewerReadings),
    ("testSameWindowDecreaseReplayCannotSelfConfirm", limits.testSameWindowDecreaseReplayCannotSelfConfirm),
    ("testSameWindowDecreaseSecondReadingSlightlyHigherStillConfirms", limits.testSameWindowDecreaseSecondReadingSlightlyHigherStillConfirms),
    ("testRisingReadingClearsPendingDecrease", limits.testRisingReadingClearsPendingDecrease),
    ("testFullReindexClearsPendingDecreaseAndStampsReason", limits.testFullReindexClearsPendingDecreaseAndStampsReason),
    ("testDecreaseEpsilonBoundary", limits.testDecreaseEpsilonBoundary),
    ("testLegacyStateWithoutNewFieldsDecodes", limits.testLegacyStateWithoutNewFieldsDecodes),
    ("testPendingDecreaseSurvivesEngineReload", limits.testPendingDecreaseSurvivesEngineReload),
    ("testCorrectedSurfacesOnly24Hours", limits.testCorrectedSurfacesOnly24Hours),
    ("testPrimaryOnlyReadingsDoNotDisturbStaleWeekly", limits.testPrimaryOnlyReadingsDoNotDisturbStaleWeekly),
    ("testOutOfOrderHighReadingKeepsPendingDecrease", limits.testOutOfOrderHighReadingKeepsPendingDecrease),
    ("testPlanOnlyReadingSetsPlanTypeWithoutWindows", limits.testPlanOnlyReadingSetsPlanTypeWithoutWindows),
    ("testLoadSanitizesCrossTypedCodexWindows", limits.testLoadSanitizesCrossTypedCodexWindows),
    ("testCodexWeeklyOnlySnapshotTombstonesFiveHour", limits.testCodexWeeklyOnlySnapshotTombstonesFiveHour),
])

let pricing = PricingTests()
runSuite("PricingTests", [
    ("testMatchingAndCost", pricing.testMatchingAndCost),
    ("testUnknownModelIsNotSilentlyPriced", pricing.testUnknownModelIsNotSilentlyPriced),
    ("testUserOverrideBeatsBuiltin", pricing.testUserOverrideBeatsBuiltin),
    ("testBundledPriceListCoversCurrentModels", pricing.testBundledPriceListCoversCurrentModels),
    ("testPriceIndexSemantics", pricing.testPriceIndexSemantics),
    ("testPriceKeyCollisionAndExactVsWildcardOverrideParity", pricing.testPriceKeyCollisionAndExactVsWildcardOverrideParity),
])

let updateModel = UpdateModelTests()
runSuite("UpdateModelTests", [
    ("testParseVersionIsStrictAndFailsClosed", updateModel.testParseVersionIsStrictAndFailsClosed),
    ("testIsNewerIsNumericNotLexical", updateModel.testIsNewerIsNumericNotLexical),
    ("testLatestApplicableSkipSuppressesThatVersionAndOlder", updateModel.testLatestApplicableSkipSuppressesThatVersionAndOlder),
])

let report = ReportTests()
runSuite("ReportTests", [
    ("testReportSectionsAndRedaction", report.testReportSectionsAndRedaction),
])

let fmtUSDTests = FmtUSDTests()
runSuite("FmtUSDTests", [
    ("testThousandsSeparatorAndDecimals", fmtUSDTests.testThousandsSeparatorAndDecimals),
    ("testFmtTokensUnifiedDialect", fmtUSDTests.testFmtTokensUnifiedDialect),
])

let localTime = LocalTimeTests()
runSuite("LocalTimeTests", [
    ("testFormatsWithUTCOffset", localTime.testFormatsWithUTCOffset),
])

let feedingTests = FeedingEngineTests()
runSuite("FeedingEngineTests", [
    ("testHungerDecay", feedingTests.testHungerDecay),
    ("testTokenXPIsCapped", feedingTests.testTokenXPIsCapped),
    ("testHealthyDayBonusOnRollover", feedingTests.testHealthyDayBonusOnRollover),
    ("testWarningCancelsHealthyBonus", feedingTests.testWarningCancelsHealthyBonus),
    ("testTreatEconomyAndFeeding", feedingTests.testTreatEconomyAndFeeding),
])

let moodTests = MoodEngineTests()
runSuite("MoodEngineTests", [
    ("testPriorityOrdering", moodTests.testPriorityOrdering),
    ("testTransientStatesBeatEverything", moodTests.testTransientStatesBeatEverything),
    ("testBurnRateDrivesAnimationSpeed", moodTests.testBurnRateDrivesAnimationSpeed),
    ("testNoDataMakesConfused", moodTests.testNoDataMakesConfused),
    ("testWarningReasonIsProviderReportedWithValues", moodTests.testWarningReasonIsProviderReportedWithValues),
    ("testWarningReasonEstimatedNotShownAsOfficial", moodTests.testWarningReasonEstimatedNotShownAsOfficial),
    ("testSleepingReasonIncludesIdleMinutes", moodTests.testSleepingReasonIncludesIdleMinutes),
    ("testHungryReasonUsesFullness", moodTests.testHungryReasonUsesFullness),
    ("testExhaustedReasonHasWindowValueProvenance", moodTests.testExhaustedReasonHasWindowValueProvenance),
    ("testExhaustedEstimatedNotShownAsOfficial", moodTests.testExhaustedEstimatedNotShownAsOfficial),
    ("testExhaustedRanksRawDoubleNotRounded", moodTests.testExhaustedRanksRawDoubleNotRounded),
    ("testShortReasonEstimatedIsMarked", moodTests.testShortReasonEstimatedIsMarked),
    ("testShortReasonProviderReportedIsBare", moodTests.testShortReasonProviderReportedIsBare),
    ("testNoProvidersReasonDistinctFromSleeping", moodTests.testNoProvidersReasonDistinctFromSleeping),
    ("testErrorReasonSeparateFromStale", moodTests.testErrorReasonSeparateFromStale),
    ("testEveryMoodHasNonEmptyReason", moodTests.testEveryMoodHasNonEmptyReason),
    ("testTiredWeeklyReasonCarriesProvenance", moodTests.testTiredWeeklyReasonCarriesProvenance),
    ("testWarningTriggerPicksHighestProvider", moodTests.testWarningTriggerPicksHighestProvider),
    ("testCelebrationAttributionOfficialAndEstimated", moodTests.testCelebrationAttributionOfficialAndEstimated),
    ("testCelebrationWithoutAttributionFallsBackGeneric", moodTests.testCelebrationWithoutAttributionFallsBackGeneric),
    ("testPetStateBackwardCompatibleDecodeWithoutCelebrationFields", moodTests.testPetStateBackwardCompatibleDecodeWithoutCelebrationFields),
    ("testSummaryMarksEstimatedPercentAndCelebrationPrefix", moodTests.testSummaryMarksEstimatedPercentAndCelebrationPrefix),
    ("testAutoPhraseCelebrationUsesShortReason", moodTests.testAutoPhraseCelebrationUsesShortReason),
])

let integration = CoordinatorIntegrationTests()
runSuite("CoordinatorIntegrationTests", [
    ("testEndToEndRefreshAndExport", integration.testEndToEndRefreshAndExport),
    ("testFullReindexPreservesUnavailableProviderHistory", integration.testFullReindexPreservesUnavailableProviderHistory),
    ("testWatchPlanWatchesExistingDirsAndStatuslineTriggers", integration.testWatchPlanWatchesExistingDirsAndStatuslineTriggers),
])

let fileLock = FileLockTests()
runSuite("FileLockTests", [
    ("testExclusiveAcquireAndRelease", fileLock.testExclusiveAcquireAndRelease),
])

let crossProcess = LedgerCrossProcessTests()
runSuite("LedgerCrossProcessTests", [
    ("testReloadIfChangedConvergesAndDedupes", crossProcess.testReloadIfChangedConvergesAndDedupes),
    ("testAppendAfterPartialFinalLinePreservesNewEventOnReload",
     crossProcess.testAppendAfterPartialFinalLinePreservesNewEventOnReload),
])

let sharedSettings = SharedSettingsTests()
runSuite("SharedSettingsTests", [
    ("testCLIReadsGUISettingsFile", sharedSettings.testCLIReadsGUISettingsFile),
])

let compactionLock = CompactionLockTests()
runSuite("CompactionLockTests", [
    ("testInitIsReadOnlyAndCompactionRunsUnderRefresh", compactionLock.testInitIsReadOnlyAndCompactionRunsUnderRefresh),
])

let refreshLock = RefreshLockTests()
runSuite("RefreshLockTests", [
    ("testRefreshSkipsWhenLockHeldByAnotherProcess", refreshLock.testRefreshSkipsWhenLockHeldByAnotherProcess),
])

let pixel = PixelArtTests()
runSuite("PixelArtTests", [
    ("testAllFramesWellFormed", pixel.testAllFramesWellFormed),
    ("testAnimStateMapping", pixel.testAnimStateMapping),
    ("testGlyphsWellFormed", pixel.testGlyphsWellFormed),
    ("testSpeechPhrases", pixel.testSpeechPhrases),
    ("testMicroAnimationFramesWellFormed", pixel.testMicroAnimationFramesWellFormed),
    ("testDogEatFramePreservesHeadCrown", pixel.testDogEatFramePreservesHeadCrown),
    ("testCatJumpFramePreservesHeadCrown", pixel.testCatJumpFramePreservesHeadCrown),
])

let animatorTests = PixelAnimatorTests()
runSuite("PixelAnimatorTests", [
    ("testCatFocusTransitionsPlaySequentially", animatorTests.testCatFocusTransitionsPlaySequentially),
    ("testMicroAnimationFirstFireFallsInConfiguredInterval", animatorTests.testMicroAnimationFirstFireFallsInConfiguredInterval),
    ("testWalkSuppressesMicroAnimations", animatorTests.testWalkSuppressesMicroAnimations),
    ("testReduceMotionShowsStaticPoseWithoutTransitions", animatorTests.testReduceMotionShowsStaticPoseWithoutTransitions),
])

let brandTests = ProviderBrandTests()
runSuite("ProviderBrandTests", [
    ("testBadgesAlphabeticalOmitMissingAndSeverity", brandTests.testBadgesAlphabeticalOmitMissingAndSeverity),
    ("testIdleBadgeShownWithoutPercentButHiddenInCompactAndDistinctFromNoData", brandTests.testIdleBadgeShownWithoutPercentButHiddenInCompactAndDistinctFromNoData),
    ("testCompactShowsProviderWhenOnlyWeeklyWarns", brandTests.testCompactShowsProviderWhenOnlyWeeklyWarns),
    ("testFiveHourMissingWithWeeklyPresentShowsDash", brandTests.testFiveHourMissingWithWeeklyPresentShowsDash),
    ("testSeverityThresholdsAndCompactFilter", brandTests.testSeverityThresholdsAndCompactFilter),
    ("testAccessibilitySummaryUsesFullNames", brandTests.testAccessibilitySummaryUsesFullNames),
    ("testIdentityDotsAreStableAndDistinct", brandTests.testIdentityDotsAreStableAndDistinct),
    ("testSpeciesFoodsKeepStableIds", brandTests.testSpeciesFoodsKeepStableIds),
])

let hourly = HourlyBreakdownTests()
runSuite("HourlyBreakdownTests", [
    ("testBucketsCarryBreakdownAndTopProject", hourly.testBucketsCarryBreakdownAndTopProject),
])

let engineGoldenA = EngineV2GoldenSetATests()
runSuite("EngineV2GoldenSetATests", [
    ("testFreeFall", engineGoldenA.testFreeFall),
    ("testHorizontalGlide", engineGoldenA.testHorizontalGlide),
    ("testFlapArc", engineGoldenA.testFlapArc),
    ("testEscapeCap", engineGoldenA.testEscapeCap),
])

let engineDeterminism = EngineV2DeterminismTests()
runSuite("EngineV2DeterminismTests", [
    ("testXorshiftKnownValues", engineDeterminism.testXorshiftKnownValues),
    ("testBehaviorGraphSameSeedBitIdentical", engineDeterminism.testBehaviorGraphSameSeedBitIdentical),
    ("testEngineLoopSameSeedBitIdentical", engineDeterminism.testEngineLoopSameSeedBitIdentical),
    ("testMotionSameScriptBitIdentical", engineDeterminism.testMotionSameScriptBitIdentical),
])

let engineRegions = EngineV2RegionMapTests()
runSuite("EngineV2RegionMapTests", [
    ("testGeometryFormulas", engineRegions.testGeometryFormulas),
    ("testShortScreenWaterBandNeverEmpty", engineRegions.testShortScreenWaterBandNeverEmpty),
])

let engineScenarios = EngineV2MotionScenarioTests()
runSuite("EngineV2MotionScenarioTests", [
    ("testDragFlingSoftLanding", engineScenarios.testDragFlingSoftLanding),
    ("testHardFlingCapsAndEventuallyLands", engineScenarios.testHardFlingCapsAndEventuallyLands),
    ("testLargeDTClamped", engineScenarios.testLargeDTClamped),
    ("testNaNReleaseModeRecovers", engineScenarios.testNaNReleaseModeRecovers),
    ("testNaNDebugModeTraps", engineScenarios.testNaNDebugModeTraps),
    ("testCeilingAndWallBounce", engineScenarios.testCeilingAndWallBounce),
])

let engineProfiles = EngineV2ProfileScenarioTests()
runSuite("EngineV2ProfileScenarioTests", [
    ("testFlyerHoverStaysInBand", engineProfiles.testFlyerHoverStaysInBand),
    ("testFlyerHoverShortScreen", engineProfiles.testFlyerHoverShortScreen),
    ("testSwimmerLeavesWaterBallisticReturn", engineProfiles.testSwimmerLeavesWaterBallisticReturn),
    ("testSwimmerNeutralBuoyancy", engineProfiles.testSwimmerNeutralBuoyancy),
    ("testWalkerCruiseTargetVelocity", engineProfiles.testWalkerCruiseTargetVelocity),
])

let engineGraph = EngineV2BehaviorGraphTests()
runSuite("EngineV2BehaviorGraphTests", [
    ("testZeroWeightRowFallsBackToIdle", engineGraph.testZeroWeightRowFallsBackToIdle),
    ("testQuietAndReduceMotionMask", engineGraph.testQuietAndReduceMotionMask),
    ("testRegionConditionedEdges", engineGraph.testRegionConditionedEdges),
    ("testMoodTierDistanceDecay", engineGraph.testMoodTierDistanceDecay),
    ("testGlobalPriorityOrder", engineGraph.testGlobalPriorityOrder),
])

let enginePacks = EngineV2PackTests()
runSuite("EngineV2PackTests", [
    ("testRegistryRegisterAndLookup", enginePacks.testRegistryRegisterAndLookup),
    ("testBirdPackFramesWellFormed", enginePacks.testBirdPackFramesWellFormed),
    ("testBrokenPackFallbackResolution", enginePacks.testBrokenPackFallbackResolution),
    ("testBirdFallbackChainPrefersDeclaredOrder", enginePacks.testBirdFallbackChainPrefersDeclaredOrder),
    // E2a 真美術 golden + palette 契約
    ("testBirdArtPaletteAndFrameVariety", enginePacks.testBirdArtPaletteAndFrameVariety),
    ("testBirdBehaviorTableFrozenAcrossArtSwap", enginePacks.testBirdBehaviorTableFrozenAcrossArtSwap),
    ("testPackPalettePropagationAndDefault", enginePacks.testPackPalettePropagationAndDefault),
    ("testPackDisplayInfo", enginePacks.testPackDisplayInfo),
    ("testDogJumpFramePreservesEarTips", enginePacks.testDogJumpFramePreservesEarTips),
])

let usageRing = UsageRingModelTests()
runSuite("UsageRingModelTests", [
    ("testEntriesFilterOrderAndCap", usageRing.testEntriesFilterOrderAndCap),
    ("testDiametersGrowOutwardFromSpriteClearBase", usageRing.testDiametersGrowOutwardFromSpriteClearBase),
    ("testCapacityOuterDiameterAcrossSizes", usageRing.testCapacityOuterDiameterAcrossSizes),
])

let wanderBand = WanderBandTests()
runSuite("WanderBandTests", [
    ("testFullRangeEqualsWholeScreen", wanderBand.testFullRangeEqualsWholeScreen),
    ("testNarrowBandCentersOnHome", wanderBand.testNarrowBandCentersOnHome),
    ("testHomeNearEdgeClampsIntoScreen", wanderBand.testHomeNearEdgeClampsIntoScreen),
    ("testOriginRangeConversionAndNarrowedFrame", wanderBand.testOriginRangeConversionAndNarrowedFrame),
    ("testV2AndLegacyBandsAgreeOnCenterInterval", wanderBand.testV2AndLegacyBandsAgreeOnCenterInterval),
    ("testClampRangePercent", wanderBand.testClampRangePercent),
    ("testDegenerateScreenReturnsSinglePoint", wanderBand.testDegenerateScreenReturnsSinglePoint),
    ("testMotionClampHorizontally", wanderBand.testMotionClampHorizontally),
])

let wanderCursorPause = WanderCursorPauseTests()
runSuite("WanderCursorPauseTests", [
    ("testPauseWhenCursorOverAndNotClickThrough", wanderCursorPause.testPauseWhenCursorOverAndNotClickThrough),
    ("testNoPauseWhenClickThrough", wanderCursorPause.testNoPauseWhenClickThrough),
    ("testNoPauseWhenCursorAway", wanderCursorPause.testNoPauseWhenCursorAway),
])

let resetLabel = ResetLabelTests()
runSuite("ResetLabelTests", [
    ("testCountdownForms", resetLabel.testCountdownForms),
    ("testCompactPrecedenceAndPrefix", resetLabel.testCompactPrecedenceAndPrefix),
    ("testCompactWorstCaseFitsBudget", resetLabel.testCompactWorstCaseFitsBudget),
    ("testAccessibilityFullSentence", resetLabel.testAccessibilityFullSentence),
])

let engineLoopTests = EngineV2LoopTests()
runSuite("EngineV2LoopTests", [
    ("testExactlyOneCommitPerTick", engineLoopTests.testExactlyOneCommitPerTick),
    ("testWorking1OverlayMoodReshape", engineLoopTests.testWorking1OverlayMoodReshape),
    ("testDragLanePreemptsGraphFlavor", engineLoopTests.testDragLanePreemptsGraphFlavor),
    ("testMasksAndDisabledActionsInLoop", engineLoopTests.testMasksAndDisabledActionsInLoop),
])

let engineGovernor = EngineV2GovernorAndFlagTests()
runSuite("EngineV2GovernorAndFlagTests", [
    ("testGovernorStopsWithinFiveSeconds", engineGovernor.testGovernorStopsWithinFiveSeconds),
    ("testFlagOffByDefaultAndLegacySnapshotUnchanged", engineGovernor.testFlagOffByDefaultAndLegacySnapshotUnchanged),
    ("testFrozenConstants", engineGovernor.testFrozenConstants),
])

let engineDragRecognizer = EngineV2DragRecognizerTests()
runSuite("EngineV2DragRecognizerTests", [
    ("testPressBelowThresholdsIsClick", engineDragRecognizer.testPressBelowThresholdsIsClick),
    ("testBoundaryExactlyFourPxAnd120msIsDrag", engineDragRecognizer.testBoundaryExactlyFourPxAnd120msIsDrag),
    ("testMaxDistanceRetainedWhenReturningNearOrigin", engineDragRecognizer.testMaxDistanceRetainedWhenReturningNearOrigin),
    ("testStickyUntilEndedAndBeganResets", engineDragRecognizer.testStickyUntilEndedAndBeganResets),
    ("testAgreesWithFrozenPredicate", engineDragRecognizer.testAgreesWithFrozenPredicate),
])

let engineInteractionLane = EngineV2InteractionLaneTests()
runSuite("EngineV2InteractionLaneTests", [
    ("testQueuedInteractionPreemptsImmediately", engineInteractionLane.testQueuedInteractionPreemptsImmediately),
    ("testInteractionLaneFrozenWhileDragging", engineInteractionLane.testInteractionLaneFrozenWhileDragging),
    ("testInteractionPlaysThenGraphResumes", engineInteractionLane.testInteractionPlaysThenGraphResumes),
    ("testDeterminismWithInteractionSchedule", engineInteractionLane.testDeterminismWithInteractionSchedule),
])

let engineMutationGuard = EngineV2MutationGuardTests()
runSuite("EngineV2MutationGuardTests", [
    ("testGoldenGateCanFail", engineMutationGuard.testGoldenGateCanFail),
    ("testFrozenDecelSetMatchesLaw", engineMutationGuard.testFrozenDecelSetMatchesLaw),
])

let engineLegacyPacks = EngineV2LegacyPackTests()
runSuite("EngineV2LegacyPackTests", [
    ("testDogPackFramesIdenticalToLegacy", engineLegacyPacks.testDogPackFramesIdenticalToLegacy),
    ("testCatPackFramesIdenticalToLegacy", engineLegacyPacks.testCatPackFramesIdenticalToLegacy),
    ("testMissingLegacyStatesResolveLikeLegacyFallback", engineLegacyPacks.testMissingLegacyStatesResolveLikeLegacyFallback),
    ("testPackMetadataMatchesLegacy", engineLegacyPacks.testPackMetadataMatchesLegacy),
    ("testActionIDMappingIsRawValuePassthrough", engineLegacyPacks.testActionIDMappingIsRawValuePassthrough),
    ("testSpeciesPackIdMapping", engineLegacyPacks.testSpeciesPackIdMapping),
    ("testDogPackDrivesEngineLoop", engineLegacyPacks.testDogPackDrivesEngineLoop),
])

let engineBridgeLogic = EngineV2BridgeLogicTests()
runSuite("EngineV2BridgeLogicTests", [
    ("testDirectiveRearmCycleActiveDockedActive", engineBridgeLogic.testDirectiveRearmCycleActiveDockedActive),
    ("testDockTenSecondsSleepFiveSeconds", engineBridgeLogic.testDockTenSecondsSleepFiveSeconds),
    ("testPackSwitchRebuildPreservesPositionAndUsesNewFrames", engineBridgeLogic.testPackSwitchRebuildPreservesPositionAndUsesNewFrames),
    ("testPackIdOverrideFacadeAndUnknownResolution", engineBridgeLogic.testPackIdOverrideFacadeAndUnknownResolution),
])

let engineLocomotionGlue = EngineV2LocomotionGlueTests()
runSuite("EngineV2LocomotionGlueTests", [
    ("testBirdGroundEdgeAllowsFlyFlapFromIdle", engineLocomotionGlue.testBirdGroundEdgeAllowsFlyFlapFromIdle),
    ("testFlyerTakesOffFromGroundViaFlyFlap", engineLocomotionGlue.testFlyerTakesOffFromGroundViaFlyFlap),
    ("testWalkerWalkCruisesAndTurnsAtBounds", engineLocomotionGlue.testWalkerWalkCruisesAndTurnsAtBounds),
    ("testWalkerIdleHasNoDrift", engineLocomotionGlue.testWalkerIdleHasNoDrift),
])

let engineLocomotionGate = EngineV2LocomotionGateTests()
runSuite("EngineV2LocomotionGateTests", [
    ("testReduceMotionFlyerSettlesWithoutImpulses", engineLocomotionGate.testReduceMotionFlyerSettlesWithoutImpulses),
    ("testQuietSwimmerStopsDrifting", engineLocomotionGate.testQuietSwimmerStopsDrifting),
    ("testWanderDisabledStopsCruiseButKeepsPoseCycle", engineLocomotionGate.testWanderDisabledStopsCruiseButKeepsPoseCycle),
])

let flyerEnvelopeCycle = FlyerEnvelopeCycleTests()
runSuite("FlyerEnvelopeCycleTests", [
    ("testEnvelopeIdentityAt100Percent", flyerEnvelopeCycle.testEnvelopeIdentityAt100Percent),
    ("testEnvelopeGroundLerpAt10Percent", flyerEnvelopeCycle.testEnvelopeGroundLerpAt10Percent),
    ("testEnvelopeAnchorsToGroundYNonZeroOrigin", flyerEnvelopeCycle.testEnvelopeAnchorsToGroundYNonZeroOrigin),
    ("testFlyerLandsInsteadOfPermanentHoverAt100", flyerEnvelopeCycle.testFlyerLandsInsteadOfPermanentHoverAt100),
    ("testFlyerStaysBelowCeilingAndLandsAt10Percent", flyerEnvelopeCycle.testFlyerStaysBelowCeilingAndLandsAt10Percent),
    ("testFlyerCeilingDoesNotLowerWalkerOrSwimmer", flyerEnvelopeCycle.testFlyerCeilingDoesNotLowerWalkerOrSwimmer),
    ("testSleepForcesDescentNoMidairFreeze", flyerEnvelopeCycle.testSleepForcesDescentNoMidairFreeze),
    ("testCycleDeterministicSameSeed", flyerEnvelopeCycle.testCycleDeterministicSameSeed),
    ("testSnapToGroundForcesLanding", flyerEnvelopeCycle.testSnapToGroundForcesLanding),
    ("testSnapThenCommitPresentsGroundedPose", flyerEnvelopeCycle.testSnapThenCommitPresentsGroundedPose),
    ("testTeleportPlacesAndClearsMomentum", flyerEnvelopeCycle.testTeleportPlacesAndClearsMomentum),
    ("testTeleportThenTickContinuesFromDropPoint", flyerEnvelopeCycle.testTeleportThenTickContinuesFromDropPoint),
])

let redaction = RedactionTests()
runSuite("RedactionTests", [
    ("testHomePrefixToTilde", redaction.testHomePrefixToTilde),
    ("testHomeBoundaryDoesNotEatOtherUser", redaction.testHomeBoundaryDoesNotEatOtherUser),
    ("testOtherUsersPathRedacted", redaction.testOtherUsersPathRedacted),
    ("testNonHomeAbsolutePathsRedacted", redaction.testNonHomeAbsolutePathsRedacted),
    ("testTokenPatternsRedacted", redaction.testTokenPatternsRedacted),
    ("testOrdinaryTextUntouched", redaction.testOrdinaryTextUntouched),
    ("testIdempotent", redaction.testIdempotent),
])

let diagReport = DiagnosticReportTests()
runSuite("DiagnosticReportTests", [
    ("testTextHasNoLeaks", diagReport.testTextHasNoLeaks),
    ("testJSONHasNoLeaks", diagReport.testJSONHasNoLeaks),
    ("testAllowListedContentPresent", diagReport.testAllowListedContentPresent),
    ("testUnknownProviderDropped", diagReport.testUnknownProviderDropped),
    ("testMissingTokensAreNilNotZero", diagReport.testMissingTokensAreNilNotZero),
    ("testIdleWindowNeverRendersZero", diagReport.testIdleWindowNeverRendersZero),
    ("testEnabledProvidersClosedFilter", diagReport.testEnabledProvidersClosedFilter),
    ("testInProcessReadOnlyNoMutation", diagReport.testInProcessReadOnlyNoMutation),
    ("testQualityClassification", diagReport.testQualityClassification),
    ("testDeterministicAcrossInputPermutation", diagReport.testDeterministicAcrossInputPermutation),
    ("testJSONValidAndSchemaVersion", diagReport.testJSONValidAndSchemaVersion),
    ("testCLIDiagNoFilesystemMutation", diagReport.testCLIDiagNoFilesystemMutation),
])

let privRedaction = PrivacyRedactionTests()
runSuite("PrivacyRedactionTests", [
    ("testDisplayProjectNameNormal", privRedaction.testDisplayProjectNameNormal),
    ("testDisplayProjectNamePathLikeNameBasenamed", privRedaction.testDisplayProjectNamePathLikeNameBasenamed),
    ("testDisplayProjectNameNilNameFallsToBasename", privRedaction.testDisplayProjectNameNilNameFallsToBasename),
    ("testDisplayProjectNameEmpty", privRedaction.testDisplayProjectNameEmpty),
    ("testDisplayProjectNameWindowsAndUNCBasenamed", privRedaction.testDisplayProjectNameWindowsAndUNCBasenamed),
    ("testSafeDataQualitySlashFreeSecretsDropped", privRedaction.testSafeDataQualitySlashFreeSecretsDropped),
    ("testSafeDataQualityKnownTemplateKept", privRedaction.testSafeDataQualityKnownTemplateKept),
    ("testSafeDataQualityUnparsableInjectedTailDropped", privRedaction.testSafeDataQualityUnparsableInjectedTailDropped),
    ("testSafeDataQualityDropsRawErrorAndPath", privRedaction.testSafeDataQualityDropsRawErrorAndPath),
    ("testSafeDataQualityUnknownPathyStringGeneralized", privRedaction.testSafeDataQualityUnknownPathyStringGeneralized),
    ("testSafeDataQualityCorrectedDropsAbsoluteTime", privRedaction.testSafeDataQualityCorrectedDropsAbsoluteTime),
    ("testSafeDataQualityPercentUnavailableKeptWithoutPath", privRedaction.testSafeDataQualityPercentUnavailableKeptWithoutPath),
])

let reportRedaction = ReportRedactionTests()
runSuite("ReportRedactionTests", [
    ("testReportNoFullPathWhenProjectNameNil", reportRedaction.testReportNoFullPathWhenProjectNameNil),
    ("testReportSinkDefensiveAgainstPathName", reportRedaction.testReportSinkDefensiveAgainstPathName),
    ("testReportNoRawParserError", reportRedaction.testReportNoRawParserError),
    ("testReportScrubsPathShapedModelIdAndPricingSource", reportRedaction.testReportScrubsPathShapedModelIdAndPricingSource),
    ("testRefreshErrorEmbeddingUnparsableNotMisclassified", reportRedaction.testRefreshErrorEmbeddingUnparsableNotMisclassified),
    ("testUnparsableCountIsPositional", reportRedaction.testUnparsableCountIsPositional),
    ("testDisplayModelIdAndSafeLabel", reportRedaction.testDisplayModelIdAndSafeLabel),
    ("testAbsolutePathScrubCatchesSchemeAndEmbeddedForms", reportRedaction.testAbsolutePathScrubCatchesSchemeAndEmbeddedForms),
    ("testAbsolutePathScrubTildeUserAndFileHost", reportRedaction.testAbsolutePathScrubTildeUserAndFileHost),
    ("testAbsolutePathScrubCompoundURLNotBypassed", reportRedaction.testAbsolutePathScrubCompoundURLNotBypassed),
    ("testProjectSummaryBasenamesPathAtSource", reportRedaction.testProjectSummaryBasenamesPathAtSource),
])

let menuMetrics = MenuPanelMetricsTests()
runSuite("MenuPanelMetricsTests", [
    ("testWindowColumnFitsWorstCase", menuMetrics.testWindowColumnFitsWorstCase),
    ("testPanelWidthAccommodatesColumns", menuMetrics.testPanelWidthAccommodatesColumns),
])

let statusRenderer = StatusRendererTests()
runSuite("StatusRendererTests", [
    ("testStatusDefaultSuppressesPathsErrorsAndControls", statusRenderer.testStatusDefaultSuppressesPathsErrorsAndControls),
    ("testStatusFullPassesRawButStripsControls", statusRenderer.testStatusFullPassesRawButStripsControls),
    ("testStatusProjectIdFallbackStripsControls", statusRenderer.testStatusProjectIdFallbackStripsControls),
    ("testStatusPlanLabelPolicy", statusRenderer.testStatusPlanLabelPolicy),
    ("testSourcesDisclosureRendering", statusRenderer.testSourcesDisclosureRendering),
    ("testRootDisclosureClassify", statusRenderer.testRootDisclosureClassify),
    ("testAdapterDisclosureCustomRoots", statusRenderer.testAdapterDisclosureCustomRoots),
])

let codexPrivacy = CodexPrivacyTests()
runSuite("CodexPrivacyTests", [
    ("testCodexAdapterIgnoresMessageContent", codexPrivacy.testCodexAdapterIgnoresMessageContent),
    ("testCodexAdapterUsesNarrowDecoder", codexPrivacy.testCodexAdapterUsesNarrowDecoder),
    ("testCodexDecoderStrictnessAndFallbacks", codexPrivacy.testCodexDecoderStrictnessAndFallbacks),
])

let claudePrivacy = ClaudePrivacyTests()
runSuite("ClaudePrivacyTests", [
    ("testClaudeAdapterIgnoresMessageContent", claudePrivacy.testClaudeAdapterIgnoresMessageContent),
    ("testClaudeAdapterUsesNarrowDecoder", claudePrivacy.testClaudeAdapterUsesNarrowDecoder),
])

let openCode = OpenCodeAdapterTests()
runSuite("OpenCodeAdapterTests", [
    ("testHappyPathFoldsAndEmitsProviderCost", openCode.testHappyPathFoldsAndEmitsProviderCost),
    ("testIncrementalDeltaOnly", openCode.testIncrementalDeltaOnly),
    ("testRegressionThenRegrowthNeverCollides", openCode.testRegressionThenRegrowthNeverCollides),
    ("testMixedSignClassesResetAll", openCode.testMixedSignClassesResetAll),
    ("testReplayFromStaleStateReusesIdForDedupUndercount", openCode.testReplayFromStaleStateReusesIdForDedupUndercount),
    ("testCostZeroWithTokensIsAmbiguousNotFree", openCode.testCostZeroWithTokensIsAmbiguousNotFree),
    ("testCostRegressionResetsIndependentlyTokensStillEmit", openCode.testCostRegressionResetsIndependentlyTokensStillEmit),
    ("testCostOnlyRegressionPersistsResetBaseline", openCode.testCostOnlyRegressionPersistsResetBaseline),
    ("testAuthorizerDeniesViewOverSqliteMaster", openCode.testAuthorizerDeniesViewOverSqliteMaster),
    ("testNegativeCountersRejected", openCode.testNegativeCountersRejected),
    ("testReadOnlyOpenCreatesNoSidecarsOnCheckpointedDb", openCode.testReadOnlyOpenCreatesNoSidecarsOnCheckpointedDb),
    ("testReadOnlyOpenInUnwritableDirectoryFailsSoftOnly", openCode.testReadOnlyOpenInUnwritableDirectoryFailsSoftOnly),
    ("testLegacyFieldsDecodeStrictly", openCode.testLegacyFieldsDecodeStrictly),
    ("testMalformedModelJSON", openCode.testMalformedModelJSON),
    ("testMissingColumnFailsSoft", openCode.testMissingColumnFailsSoft),
    ("testAuthorizerDeniesDecoyViewOverCredentials", openCode.testAuthorizerDeniesDecoyViewOverCredentials),
    ("testBusyDatabaseFailsSoft", openCode.testBusyDatabaseFailsSoft),
    ("testWatchFilesExactAndNoDirectoryRoots", openCode.testWatchFilesExactAndNoDirectoryRoots),
    ("testZeroTokenSessionEmitsNothing", openCode.testZeroTokenSessionEmitsNothing),
    ("testCustomDbLocationDisclosesCustom", openCode.testCustomDbLocationDisclosesCustom),
    ("testNewFieldsCodableRoundTripAndTolerantDecode", openCode.testNewFieldsCodableRoundTripAndTolerantDecode),
    ("testPricingPrecedenceProviderReportedCost", openCode.testPricingPrecedenceProviderReportedCost),
])

let openRouter = OpenRouterCreditsTests()
runSuite("OpenRouterCreditsTests", [
    ("testKeyParserHappyPathAndForeignEntriesIgnored", openRouter.testKeyParserHappyPathAndForeignEntriesIgnored),
    ("testKeyParserRefusals", openRouter.testKeyParserRefusals),
    ("testRequestShape", openRouter.testRequestShape),
    ("testRedirectAlwaysRefusedAndTrustedResponseHost", openRouter.testRedirectAlwaysRefusedAndTrustedResponseHost),
    ("testParseResponseHappyPath", openRouter.testParseResponseHappyPath),
    ("testParseResponseNarrowAndFailClosed", openRouter.testParseResponseNarrowAndFailClosed),
    ("testSnapshotRemainingIsSignedAndFractionClampsGeometryOnly", openRouter.testSnapshotRemainingIsSignedAndFractionClampsGeometryOnly),
    ("testMoneyAndAgeFormatting", openRouter.testMoneyAndAgeFormatting),
    ("testPresentationFreshSuccess", openRouter.testPresentationFreshSuccess),
    ("testPresentationStaleByAge", openRouter.testPresentationStaleByAge),
    ("testPresentationFailedAttemptKeepsAgedValueHonestly", openRouter.testPresentationFailedAttemptKeepsAgedValueHonestly),
    ("testPresentationErrorStatesWithoutSnapshot", openRouter.testPresentationErrorStatesWithoutSnapshot),
    ("testPresentationZeroCreditsNeverRendersZeroOfZero", openRouter.testPresentationZeroCreditsNeverRendersZeroOfZero),
    ("testPresentationFailedAfterZeroCreditsShowsFailureNotZeroClaim", openRouter.testPresentationFailedAfterZeroCreditsShowsFailureNotZeroClaim),
    ("testPresentationStaleBoundaryAt30Minutes", openRouter.testPresentationStaleBoundaryAt30Minutes),
    ("testFetchGateSingleFlightAndGenerationSemantics", openRouter.testFetchGateSingleFlightAndGenerationSemantics),
    ("testPresentationOverspendShowsHonestNegative", openRouter.testPresentationOverspendShowsHonestNegative),
    ("testBubbleComposeWithoutExtraIsIdentityUpToBudget", openRouter.testBubbleComposeWithoutExtraIsIdentityUpToBudget),
    ("testBubbleComposeWithExtraLine", openRouter.testBubbleComposeWithExtraLine),
    ("testBubbleComposeDataPageBudget", openRouter.testBubbleComposeDataPageBudget),
])

let dashShareSafety = DashboardShareSafetyTests()
runSuite("DashboardShareSafetyTests", [
    ("testShareSafeDataQualityRedactsRawPathsAndErrors", dashShareSafety.testShareSafeDataQualityRedactsRawPathsAndErrors),
    ("testShareSafeErrorNeverShowsRawAndNilWhenClean", dashShareSafety.testShareSafeErrorNeverShowsRawAndNilWhenClean),
])

let dataIntegrityRead = DataIntegrityReadTests()
runSuite("DataIntegrityReadTests", [
    ("testUnreadableLedgerIsPoisonedNotEmpty", dataIntegrityRead.testUnreadableLedgerIsPoisonedNotEmpty),
    ("testMalformedLedgerPoisonedAndPreserved", dataIntegrityRead.testMalformedLedgerPoisonedAndPreserved),
    ("testValidLedgerWithTornTailNotPoisoned", dataIntegrityRead.testValidLedgerWithTornTailNotPoisoned),
    ("testScanStateReadOrThrowTriState", dataIntegrityRead.testScanStateReadOrThrowTriState),
    ("testUnreadableLimitsStateIsPoisoned", dataIntegrityRead.testUnreadableLimitsStateIsPoisoned),
    ("testAppendWriteFailureRollsBackMemory", dataIntegrityRead.testAppendWriteFailureRollsBackMemory),
    ("testCompactWriteFailurePreservesOldFileAndMemory", dataIntegrityRead.testCompactWriteFailurePreservesOldFileAndMemory),
])

let diReindex = DataIntegrityReindexTests()
runSuite("DataIntegrityReindexTests", [
    ("testIncompleteReindexPreservesOldSlice", diReindex.testIncompleteReindexPreservesOldSlice),
    ("testCompleteZeroResultPreservesNonEmptyBaseline", diReindex.testCompleteZeroResultPreservesNonEmptyBaseline),
    ("testCumulativeSnapshotReindexPreservesHistory", diReindex.testCumulativeSnapshotReindexPreservesHistory),
    ("testStrictDiskAdoptionOfScanState", diReindex.testStrictDiskAdoptionOfScanState),
    ("testDeletedScanStateAdoptedAsEmpty", diReindex.testDeletedScanStateAdoptedAsEmpty),
    ("testCASRejectsStaleMemoryReplace", diReindex.testCASRejectsStaleMemoryReplace),
    ("testGateRejectsForeignProviderCandidateEvents", diReindex.testGateRejectsForeignProviderCandidateEvents),
    ("testCompactPrecheckPreservesSuspectRawOnMixedAgeFile", diReindex.testCompactPrecheckPreservesSuspectRawOnMixedAgeFile),
    ("testCASRefusesUnreconciledSnapshot", diReindex.testCASRefusesUnreconciledSnapshot),
    ("testCompactSkippedWhenRawUnreadable", diReindex.testCompactSkippedWhenRawUnreadable),
    ("testCompactRefusesStaleFingerprint", diReindex.testCompactRefusesStaleFingerprint),
    ("testCompactRefusesUnreconciledSnapshot", diReindex.testCompactRefusesUnreconciledSnapshot),
    ("testReplacePreservesForeignRawRepresentation", diReindex.testReplacePreservesForeignRawRepresentation),
    ("testCASRefusesUnstattableLedgerPath", diReindex.testCASRefusesUnstattableLedgerPath),
    ("testCompactPreservesForeignRawOnWiredPath", diReindex.testCompactPreservesForeignRawOnWiredPath),
    ("testCompactRawPreservingKeepsGarbageSuffixTimestamp", diReindex.testCompactRawPreservingKeepsGarbageSuffixTimestamp),
    ("testReplaceRefusesRawOnlyIDCollision", diReindex.testReplaceRefusesRawOnlyIDCollision),
    ("testCompactRawPreservingKeepsOutOfRangeTimestamp", diReindex.testCompactRawPreservingKeepsOutOfRangeTimestamp),
    ("testAppendRefusesForeignDriftBeforeWrite", diReindex.testAppendRefusesForeignDriftBeforeWrite),
    ("testCompactRawPreservingRefusesWriteThatWouldPoison", diReindex.testCompactRawPreservingRefusesWriteThatWouldPoison),
    ("testAppendRefusesReuseOfPreservedRawOnlyID", diReindex.testAppendRefusesReuseOfPreservedRawOnlyID),
    ("testAppendRefusesReuseAfterReplacePreservedForeignRawID", diReindex.testAppendRefusesReuseAfterReplacePreservedForeignRawID),
    ("testAppendAllowsNewUniqueIDDespiteReservedRawIDs", diReindex.testAppendAllowsNewUniqueIDDespiteReservedRawIDs),
    ("testAppendDriftPreflightWinsOverStaleReservedIDs", diReindex.testAppendDriftPreflightWinsOverStaleReservedIDs),
    ("testAppendDetectsDriftBeforeReservedIDSkip", diReindex.testAppendDetectsDriftBeforeReservedIDSkip),
    ("testAppendRefusesDriftIntoTruncatedFile", diReindex.testAppendRefusesDriftIntoTruncatedFile),
    ("testReindexAppliesRetentionCutoff", diReindex.testReindexAppliesRetentionCutoff),
    ("testCumulativeBaselinePreservedWhenScanStateMissing", diReindex.testCumulativeBaselinePreservedWhenScanStateMissing),
    ("testCumulativeBaselinePreservedWhenDiskHasDifferentMark", diReindex.testCumulativeBaselinePreservedWhenDiskHasDifferentMark),
])

let diLedger = DataIntegrityLedgerTests()
runSuite("DataIntegrityLedgerTests", [
    ("testSameSizeDifferentContentReloads", diLedger.testSameSizeDifferentContentReloads),
    ("testReplaceProviderSliceWriteFailurePreservesDiskAndMemory", diLedger.testReplaceProviderSliceWriteFailurePreservesDiskAndMemory),
    ("testQualityNotesShareSafeAndHonest", diLedger.testQualityNotesShareSafeAndHonest),
    ("testListFilesFlagsIncompleteOnUnreadableSubtree", diLedger.testListFilesFlagsIncompleteOnUnreadableSubtree),
    ("testNewlineOnlyLedgerIsPoisoned", diLedger.testNewlineOnlyLedgerIsPoisoned),
    ("testValidRowsWithCorruptMiddleRowStayHealthy", diLedger.testValidRowsWithCorruptMiddleRowStayHealthy),
    ("testStatFailurePreservesExistingLedgerFailClosed", diLedger.testStatFailurePreservesExistingLedgerFailClosed),
    ("testEmptyLedgerFirstWriteFailurePreservesFile", diLedger.testEmptyLedgerFirstWriteFailurePreservesFile),
])

// #48 Option C binding matrix(pivot comment 5120184667 §6)。SPEC 測試:gate 已於
// 2026-08-01 接線,全數案例必須綠燈(歷史:落地前 13 案例紅燈為紅燈優先證明)。
let mxMatrix = MonotonicMatrixTests()
runSuite("MonotonicMatrixTests", [
    ("testMX01_candidateMissingHistoricalEvent_preserves", mxMatrix.testMX01_candidateMissingHistoricalEvent_preserves),
    ("testMX02_cleanTruncationDirectReindex_preserves", mxMatrix.testMX02_cleanTruncationDirectReindex_preserves),
    ("testMX03_truncationThenIncrementalThenReindex_preserves", mxMatrix.testMX03_truncationThenIncrementalThenReindex_preserves),
    ("testMX04_scanStateLossThenReindex_preserves", mxMatrix.testMX04_scanStateLossThenReindex_preserves),
    ("testMX05_nilSourcePathBaselineCandidateMissing_preserves", mxMatrix.testMX05_nilSourcePathBaselineCandidateMissing_preserves),
    ("testMX06_nilSourcePathIdenticalCandidate_passesGate", mxMatrix.testMX06_nilSourcePathIdenticalCandidate_passesGate),
    ("testMX07_completeZeroResultNonEmptyBaseline_preserves", mxMatrix.testMX07_completeZeroResultNonEmptyBaseline_preserves),
    ("testMX08_completeZeroResultEmptyBaseline_staysEmpty", mxMatrix.testMX08_completeZeroResultEmptyBaseline_staysEmpty),
    ("testMX09_supersetWithNewEvents_replaces", mxMatrix.testMX09_supersetWithNewEvents_replaces),
    ("testMX10_allowlistedModelEnrichment_replaces", mxMatrix.testMX10_allowlistedModelEnrichment_replaces),
    ("testMX11_nonMonotonicChanges_preserve", mxMatrix.testMX11_nonMonotonicChanges_preserve),
    ("testMX12_duplicateCandidateIDs_preserves", mxMatrix.testMX12_duplicateCandidateIDs_preserves),
    ("testMX13_staleBaselineRace_noStaleOverwrite", mxMatrix.testMX13_staleBaselineRace_noStaleOverwrite),
    ("testMX14_providerIsolation_mismatchDoesNotBlockOther", mxMatrix.testMX14_providerIsolation_mismatchDoesNotBlockOther),
    ("testMX15_unknownRawFieldFailsClosed", mxMatrix.testMX15_unknownRawFieldFailsClosed),
    ("testMX16_reducedNearMissFixture_preserves", mxMatrix.testMX16_reducedNearMissFixture_preserves),
    ("testMX16b_frozenIsolatedCopyEntryPoint", mxMatrix.testMX16b_frozenIsolatedCopyEntryPoint),
    ("testMX17_codexEnrichmentTokenFieldsUnchanged_replaces", mxMatrix.testMX17_codexEnrichmentTokenFieldsUnchanged_replaces),
    ("testMX18_replacementFailureNoPartialSlice", mxMatrix.testMX18_replacementFailureNoPartialSlice),
    ("testMX19_rawDuplicateBaselineID_failsClosed", mxMatrix.testMX19_rawDuplicateBaselineID_failsClosed),
    ("testMX20_emptyBaselineCompleteCandidate_initializes", mxMatrix.testMX20_emptyBaselineCompleteCandidate_initializes),
])

// CanonicalLedgerV1 stage acceptance(#48 pivot §2;gate 已接線,由 coordinator 消費)。
let clTests = CanonicalLedgerTests()
runSuite("CanonicalLedgerTests", [
    ("testSchemaValidLineAndMissingRequiredKeys", clTests.testSchemaValidLineAndMissingRequiredKeys),
    ("testAbsentNullZeroNormalization", clTests.testAbsentNullZeroNormalization),
    ("testDuplicateIDsFailBothSidesBeforeAnyOverwrite", clTests.testDuplicateIDsFailBothSidesBeforeAnyOverwrite),
    ("testUnknownKeysFailClosed", clTests.testUnknownKeysFailClosed),
    ("testNumberBackingAndRangeFailClosed", clTests.testNumberBackingAndRangeFailClosed),
    ("testImmutableFieldMutationsFail", clTests.testImmutableFieldMutationsFail),
    ("testOptionalFieldMutationsFail", clTests.testOptionalFieldMutationsFail),
    ("testAllowlistedModelEnrichmentPasses", clTests.testAllowlistedModelEnrichmentPasses),
    ("testCandidatePersistedByteCanonicalization", clTests.testCandidatePersistedByteCanonicalization),
    ("testVersionAndSpecConstantsFrozen", clTests.testVersionAndSpecConstantsFrozen),
    ("testEncodingDomainGate", clTests.testEncodingDomainGate),
])

// #64 durable-commit crash matrix(PLAN-v1 §5 preregistered;C7 注入 + C1–C3 構造 + 順序/等價鎖)。
let duraMatrix = DurabilityMatrixTests()
runSuite("DurabilityMatrixTests", [
    ("testC7aCompactSyncFileFailureFailsClosedOldIntact", duraMatrix.testC7aCompactSyncFileFailureFailsClosedOldIntact),
    ("testC7aFirstCreateSyncFileFailureLeavesNoLedger", duraMatrix.testC7aFirstCreateSyncFileFailureLeavesNoLedger),
    ("testC7aRawPreservingSyncFileFailurePreservesOriginalBytes", duraMatrix.testC7aRawPreservingSyncFileFailurePreservesOriginalBytes),
    ("testC7aCASReplaceSyncFileFailureThrowsMemoryUnchanged", duraMatrix.testC7aCASReplaceSyncFileFailureThrowsMemoryUnchanged),
    ("testP1PreRenameStatFailureFailsClosedOldIntact", duraMatrix.testP1PreRenameStatFailureFailsClosedOldIntact),
    ("testC7bCompactRenameFailureFailsClosedOldIntact", duraMatrix.testC7bCompactRenameFailureFailsClosedOldIntact),
    ("testC7cCompactDirSyncFailureOutcomeUnknownFailClosed", duraMatrix.testC7cCompactDirSyncFailureOutcomeUnknownFailClosed),
    ("testC7cCASReplaceDirSyncFailureOutcomeUnknownFailClosed", duraMatrix.testC7cCASReplaceDirSyncFailureOutcomeUnknownFailClosed),
    ("testC7P2AppendSyncFailureNoAckOutcomeUnknown", duraMatrix.testC7P2AppendSyncFailureNoAckOutcomeUnknown),
    ("testP1BarrierCallOrder", duraMatrix.testP1BarrierCallOrder),
    ("testP2ExactlyOneSyncFilePerAppendNoRename", duraMatrix.testP2ExactlyOneSyncFilePerAppendNoRename),
    ("testFingerprintEquivalenceAcrossRename", duraMatrix.testFingerprintEquivalenceAcrossRename),
    ("testC1TempResidueInertOldIntactNextMutationProceeds", duraMatrix.testC1TempResidueInertOldIntactNextMutationProceeds),
    ("testC3RenameVisibleNewValidRestart", duraMatrix.testC3RenameVisibleNewValidRestart),
    ("testC3TornWriteRestartToleratedNeverSilentlyEmpty", duraMatrix.testC3TornWriteRestartToleratedNeverSilentlyEmpty),
])

// #49 R4 replay/idempotence characterization(PLAN-v1 phase 2;現行 engine,零產品碼改動)。
let l49 = Limit49CharacterizationTests()
runSuite("Limit49CharacterizationTests", [
    ("testReplayFullBatchEmitsNoTransitionsAndPreservesStore", l49.testReplayFullBatchEmitsNoTransitionsAndPreservesStore),
    ("testCrossProviderSharedStoreReplayConverges", l49.testCrossProviderSharedStoreReplayConverges),
    ("testRolloverReplayWithinRecencyDoesNotRecelebrate", l49.testRolloverReplayWithinRecencyDoesNotRecelebrate),
    ("testRow1SyncFileFailureFailsClosedOldDurable", l49.testRow1SyncFileFailureFailsClosedOldDurable),
    ("testRow2RenameFailureFailsClosedOldDurable", l49.testRow2RenameFailureFailsClosedOldDurable),
    ("testRow3DirSyncFailureOutcomeUnknownReplayConverges", l49.testRow3DirSyncFailureOutcomeUnknownReplayConverges),
    ("testRow7CoordinatorHoldsWatermarkWhenLimitsCommitFails", l49.testRow7CoordinatorHoldsWatermarkWhenLimitsCommitFails),
    ("testRow9DerivedSaveFailureIsLoudButNonblocking", l49.testRow9DerivedSaveFailureIsLoudButNonblocking),
    ("testAM1FailedIngestStateNeverLaunderedByDerivedSave", l49.testAM1FailedIngestStateNeverLaunderedByDerivedSave),
    ("testAM2DerivedRewriteGoesThroughFullBarrier", l49.testAM2DerivedRewriteGoesThroughFullBarrier),
    ("testAM3SweepMarkerDurableBeforeResetDelivery", l49.testAM3SweepMarkerDurableBeforeResetDelivery),
    ("testAM45FullReindexRetrySemanticsAndUnchangedClears", l49.testAM45FullReindexRetrySemanticsAndUnchangedClears),
    ("testAM6InjectedAFailureNotLaunderedByBCommit", l49.testAM6InjectedAFailureNotLaunderedByBCommit),
    ("testAM7DerivedFailureDoesNotInvalidateDurableIngest", l49.testAM7DerivedFailureDoesNotInvalidateDurableIngest),
    ("testAM8DerivedErrorAccumulatesUntilCycleReset", l49.testAM8DerivedErrorAccumulatesUntilCycleReset),
])

// #49 Plan v2 preregistered(I1–I4;cases 9/10 = AM-5/AM-6 既有 lock)。
let l49v2 = Limit49V2Tests()
runSuite("Limit49V2Tests", [
    ("testV2C1SameProcessUnchangedRequiresRebarrierAfterC7c", l49v2.testV2C1SameProcessUnchangedRequiresRebarrierAfterC7c),
    ("testV2C2RestartUnchangedRequiresConfirmation", l49v2.testV2C2RestartUnchangedRequiresConfirmation),
    ("testV2C3DecreaseEndingBatchReplayIdempotent", l49v2.testV2C3DecreaseEndingBatchReplayIdempotent),
    ("testV2C4TemporalAuthoritySixCases", l49v2.testV2C4TemporalAuthoritySixCases),
    ("testV2C5OfficialThenEstimatedCrossCycleZeroDuplicate", l49v2.testV2C5OfficialThenEstimatedCrossCycleZeroDuplicate),
    ("testV2C6EstimatedMarkerFailureZeroThenExactlyOne", l49v2.testV2C6EstimatedMarkerFailureZeroThenExactlyOne),
    ("testV2C7RequestedFullOnCumulativePathUsesFullSemantics", l49v2.testV2C7RequestedFullOnCumulativePathUsesFullSemantics),
    ("testV2C8ProcessDeathAbsentWatermarkDerivesFullSemantics", l49v2.testV2C8ProcessDeathAbsentWatermarkDerivesFullSemantics),
])

// #83 A′ red-first(PLAN-v2 §5 CE + §3.4 rows + §3.3 bump + R7;owner GO 2026-08-14)。
let l49v3 = Limit49V3Tests()
runSuite("Limit49V3Tests", [
    ("testV3BumpOrdinaryChangedIncrementsUnchangedDoesNot", l49v3.testV3BumpOrdinaryChangedIncrementsUnchangedDoesNot),
    ("testV3CE3FullUnchangedStillBumpsGeneration", l49v3.testV3CE3FullUnchangedStillBumpsGeneration),
    ("testV3CE4DerivedWriteDoesNotAdvanceGeneration", l49v3.testV3CE4DerivedWriteDoesNotAdvanceGeneration),
    ("testV3AckEstablishedAfterCommit", l49v3.testV3AckEstablishedAfterCommit),
    ("testV3CE1CrossProviderGeneration", l49v3.testV3CE1CrossProviderGeneration),
    ("testV3Row4LimitsLeadScanOrdinaryZeroDuplicate", l49v3.testV3Row4LimitsLeadScanOrdinaryZeroDuplicate),
    ("testV3Row7ScanStateLossOrdinaryNoHistoricalReplay", l49v3.testV3Row7ScanStateLossOrdinaryNoHistoricalReplay),
    ("testV3Row2ReservedShapeResumesFullSemantics", l49v3.testV3Row2ReservedShapeResumesFullSemantics),
    ("testV3Row8PoisonGenAbsentAckPresent", l49v3.testV3Row8PoisonGenAbsentAckPresent),
    ("testV3Row5PoisonGenLessThanAck", l49v3.testV3Row5PoisonGenLessThanAck),
    ("testV3R7PreClearProducesReservedShape", l49v3.testV3R7PreClearProducesReservedShape),
    ("testV3R7OrdinaryPathsNeverManufactureReservedShape", l49v3.testV3R7OrdinaryPathsNeverManufactureReservedShape),
    ("testV3R7NaturallyEmptyWatermarkDoesNotTriggerResumeFull", l49v3.testV3R7NaturallyEmptyWatermarkDoesNotTriggerResumeFull),
    ("testV3MigrationLazyEstablishmentOnFirstReconciliation", l49v3.testV3MigrationLazyEstablishmentOnFirstReconciliation),
    ("testV3U1ResumeFullKeepsOutcomesEmptyAndLoud", l49v3.testV3U1ResumeFullKeepsOutcomesEmptyAndLoud),
    ("testV3U1Row7EmitsLoudQualityNote", l49v3.testV3U1Row7EmitsLoudQualityNote),
    ("testV3U2PoisonExcludedFromDerivedPasses", l49v3.testV3U2PoisonExcludedFromDerivedPasses),
    ("testV3U3FoldRolloverSuppressedAfterEstimatedDelivery", l49v3.testV3U3FoldRolloverSuppressedAfterEstimatedDelivery),
    ("testV3U3FoldRolloverStillFiresWhenEstimatedSuppressed", l49v3.testV3U3FoldRolloverStillFiresWhenEstimatedSuppressed),
    ("testV3U4FirstContactUsesFullFold", l49v3.testV3U4FirstContactUsesFullFold),
    ("testV3U5CrossProviderReadingDoesNotBumpSubject", l49v3.testV3U5CrossProviderReadingDoesNotBumpSubject),
    ("testV3IntentWithGenLeadTakesOrdinaryAndClears", l49v3.testV3IntentWithGenLeadTakesOrdinaryAndClears),
    ("testV3W1UnavailablePoisonedStillExcludedFromDerivedPasses", l49v3.testV3W1UnavailablePoisonedStillExcludedFromDerivedPasses),
    ("testV3W2NilBoundaryRolloverSuppressedAfterEstimatedDelivery", l49v3.testV3W2NilBoundaryRolloverSuppressedAfterEstimatedDelivery),
    ("testV3W2NilBoundaryRolloverFiresWhenEstimatedSuppressed", l49v3.testV3W2NilBoundaryRolloverFiresWhenEstimatedSuppressed),
    ("testV3W3FullExemptionScopedToReconcilingProvider", l49v3.testV3W3FullExemptionScopedToReconcilingProvider),
    ("testV3W4EstablishmentIndependentOfUnrelatedMutation", l49v3.testV3W4EstablishmentIndependentOfUnrelatedMutation),
    ("testV3W5CumulativeFailedFoldOmitsSuccessOutcome", l49v3.testV3W5CumulativeFailedFoldOmitsSuccessOutcome),
    ("testV3U1ResumeIncompleteLegAlsoGated", l49v3.testV3U1ResumeIncompleteLegAlsoGated),
    ("testV3X1AvailabilityFlapClearsStalePreservedUnavailable", l49v3.testV3X1AvailabilityFlapClearsStalePreservedUnavailable),
    ("testV3X2AdapterlessEnabledPoisonedStillExcluded", l49v3.testV3X2AdapterlessEnabledPoisonedStillExcluded),
    ("testV3X3SecondaryWindowAlsoScopedToReconcilingProvider", l49v3.testV3X3SecondaryWindowAlsoScopedToReconcilingProvider),
    ("testV3G1SanitizeInvalidatesDurabilityConfirmation", l49v3.testV3G1SanitizeInvalidatesDurabilityConfirmation),
    ("testV3G2EstimatedDeliveredSuppressesLateOfficialSameBoundary", l49v3.testV3G2EstimatedDeliveredSuppressesLateOfficialSameBoundary),
    ("testV3G2SuppressedEstimatedDoesNotSwallowFreshOfficial", l49v3.testV3G2SuppressedEstimatedDoesNotSwallowFreshOfficial),
    ("testV3CumulativeEstablishesGenAndAck", l49v3.testV3CumulativeEstablishesGenAndAck),
])

// #50 protocol v3 ground truth(第一批)。
let oc50gt = OpenCode50GroundTruthTests()
runSuite("OpenCode50GroundTruthTests", [
    ("testRetentionThenMarkLossMustNotRecount", oc50gt.testRetentionThenMarkLossMustNotRecount),
    ("testMarkLossWithoutCompactionMustNotRecountAndMustCountNewGrowth", oc50gt.testMarkLossWithoutCompactionMustNotRecountAndMustCountNewGrowth),
    ("testCrossProcessMustDeriveFromDurableAuthority", oc50gt.testCrossProcessMustDeriveFromDurableAuthority),
    ("testCursorMustNotHideRollback", oc50gt.testCursorMustNotHideRollback),
])

// #50 authority load contract(D)。
let oc50auth = OpenCode50AuthorityTests()
runSuite("OpenCode50AuthorityTests", [
    ("testValidAuthorityLoads", oc50auth.testValidAuthorityLoads),
    ("testAbsentFileIsAbsentNotRejected", oc50auth.testAbsentFileIsAbsentNotRejected),
    ("testIntegrityMismatchOnRecordOmissionRejected", oc50auth.testIntegrityMismatchOnRecordOmissionRejected),
    ("testD1NegativeCountersRejected", oc50auth.testD1NegativeCountersRejected),
    ("testD1bOverSaneCapCountersRejected", oc50auth.testD1bOverSaneCapCountersRejected),
    ("testD2NonPositiveEpochRejected", oc50auth.testD2NonPositiveEpochRejected),
    ("testD3PendingTargetBelowPreviousRejected", oc50auth.testD3PendingTargetBelowPreviousRejected),
    ("testD3bPendingPreviousMismatchRejected", oc50auth.testD3bPendingPreviousMismatchRejected),
    ("testD3cPendingEpochMismatchRejected", oc50auth.testD3cPendingEpochMismatchRejected),
    ("testD3dPendingEventInconsistentWithTransitionRejected", oc50auth.testD3dPendingEventInconsistentWithTransitionRejected),
    ("testUnparseableIncarnationKeyRejected", oc50auth.testUnparseableIncarnationKeyRejected),
    ("testEpochAtIntMaxIsRejectedNotTrapped", oc50auth.testEpochAtIntMaxIsRejectedNotTrapped),
    ("testCensusBoundaryTamperIsRejectedByDigest", oc50auth.testCensusBoundaryTamperIsRejectedByDigest),
    ("testX3NonPositiveCensusBoundaryRejected", oc50auth.testX3NonPositiveCensusBoundaryRejected),
    ("testX5PendingIdMutationRejectedEvenWithRecomputedDigest", oc50auth.testX5PendingIdMutationRejectedEvenWithRecomputedDigest),
    ("testX5PendingCostTransitionWithoutProviderCostRejected", oc50auth.testX5PendingCostTransitionWithoutProviderCostRejected),
])

// #50 acceptance evidence。
let oc50acc = OpenCode50AcceptanceTests()
runSuite("OpenCode50AcceptanceTests", [
    ("testFirstContactEstablishesZeroDeltaAndDoesNotBackfill", oc50acc.testFirstContactEstablishesZeroDeltaAndDoesNotBackfill),
    ("testA1A3SourceRowGoneRecoveryReplaysExactPreparedEvent", oc50acc.testA1A3SourceRowGoneRecoveryReplaysExactPreparedEvent),
    ("testA2LedgerAlreadyHasEventFinalizesWithoutDuplicate", oc50acc.testA2LedgerAlreadyHasEventFinalizesWithoutDuplicate),
    ("testA4ExpiredPendingFinalizesWithoutResurrection", oc50acc.testA4ExpiredPendingFinalizesWithoutResurrection),
    ("testRetentionCutoffBoundariesMatchCompaction", oc50acc.testRetentionCutoffBoundariesMatchCompaction),
    ("testB2bMissingKnownAuthorityFailsClosed", oc50acc.testB2bMissingKnownAuthorityFailsClosed),
    ("testB2cAbsentAuthorityWithPriorEvidenceFailsClosed", oc50acc.testB2cAbsentAuthorityWithPriorEvidenceFailsClosed),
    ("testE1LimitsRepeatedFailureKeepsAccountingExactlyOnce", oc50acc.testE1LimitsRepeatedFailureKeepsAccountingExactlyOnce),
    ("testE2LimitsRecoversProjectionFromDurableLedger", oc50acc.testE2LimitsRecoversProjectionFromDurableLedger),
    ("testLegacyRefreshUsageRemainsProductionUnreachable", oc50acc.testLegacyRefreshUsageRemainsProductionUnreachable),
    ("testR1LegacyEvidenceWithoutAuthorityFailsClosedAndNamesRecovery", oc50acc.testR1LegacyEvidenceWithoutAuthorityFailsClosedAndNamesRecovery),
    ("testR2ExplicitRebaselineEstablishesCurrentCountersAndCountsOnlyLaterGrowth", oc50acc.testR2ExplicitRebaselineEstablishesCurrentCountersAndCountsOnlyLaterGrowth),
    ("testR5RebaselineWithUnavailableSourceFailsWithoutMutation", oc50acc.testR5RebaselineWithUnavailableSourceFailsWithoutMutation),
    ("testR6RebaselineDurableWriteFailureLeavesPreviousAuthority", oc50acc.testR6RebaselineDurableWriteFailureLeavesPreviousAuthority),
    ("testR9RebaselineOnHealthyAuthorityIsAllowed", oc50acc.testR9RebaselineOnHealthyAuthorityIsAllowed),
    ("testReproGrokF1EmptySourceMaterializesAuthorityDefeatingZeroDeltaFirstContact", oc50acc.testReproGrokF1EmptySourceMaterializesAuthorityDefeatingZeroDeltaFirstContact),
    ("testReproLunaF1RebaselineErasesPendingAndLeadsLedger", oc50acc.testReproLunaF1RebaselineErasesPendingAndLeadsLedger),
])

// #50 owner-approved contract matrix(oracle)。
let oc50cm = OpenCode50ContractMatrixTests()
runSuite("OpenCode50ContractMatrixTests", [
    ("testC1FirstEverEstablishmentIsZeroDelta", oc50cm.testC1FirstEverEstablishmentIsZeroDelta),
    ("testC2IncarnationCreatedAfterCensusBoundaryCountsFirstWindow", oc50cm.testC2IncarnationCreatedAfterCensusBoundaryCountsFirstWindow),
    ("testC3IncarnationOlderThanBoundaryWithoutAnchorFailsClosed", oc50cm.testC3IncarnationOlderThanBoundaryWithoutAnchorFailsClosed),
    ("testC4EventIdsAreIndependentAcrossIncarnations", oc50cm.testC4EventIdsAreIndependentAcrossIncarnations),
    ("testC5RebaselineNeverDiscardsOutstandingPending", oc50cm.testC5RebaselineNeverDiscardsOutstandingPending),
    ("testC5bRebaselineFailsWhenPendingCannotSettle", oc50cm.testC5bRebaselineFailsWhenPendingCannotSettle),
    ("testC6RebaselinePreservesUnobservedAnchors", oc50cm.testC6RebaselinePreservesUnobservedAnchors),
    ("testC7OverflowingPendingTokensRejectAuthorityWithoutTrapping", oc50cm.testC7OverflowingPendingTokensRejectAuthorityWithoutTrapping),
    ("testC8PostRenameDirSyncFailureIsOutcomeUnknown", oc50cm.testC8PostRenameDirSyncFailureIsOutcomeUnknown),
    ("testC9ExplicitProviderCostSuppressesRegistryFallback", oc50cm.testC9ExplicitProviderCostSuppressesRegistryFallback),
    ("testReproGrokR2F1ZeroFirstWindowIncarnationLosesAnchor", oc50cm.testReproGrokR2F1ZeroFirstWindowIncarnationLosesAnchor),
    ("testF1ZeroWindowAnchorPersistsAcrossRefreshesThenCountsExactlyOnce", oc50cm.testF1ZeroWindowAnchorPersistsAcrossRefreshesThenCountsExactlyOnce),
    ("testR6CostPrecedenceReachesConsumerCostResult", oc50cm.testR6CostPrecedenceReachesConsumerCostResult),
    ("testF4EpochAtAdvanceBoundFailsClosedWithoutTrapping", oc50cm.testF4EpochAtAdvanceBoundFailsClosedWithoutTrapping),
    ("testF2RefreshOutcomeUnknownHaltsAccountingUntilReconciledThenCountsOnce", oc50cm.testF2RefreshOutcomeUnknownHaltsAccountingUntilReconciledThenCountsOnce),
    ("testF5RebaselineAdvancesBoundarySoLaterNewSessionsCountFirstWindow", oc50cm.testF5RebaselineAdvancesBoundarySoLaterNewSessionsCountFirstWindow),
    ("testF5BoundaryNeverRegressesOnLaterCensus", oc50cm.testF5BoundaryNeverRegressesOnLaterCensus),
    ("testX1FreshProcessConfirmsAuthorityDurabilityBeforeAnyLedgerAppend", oc50cm.testX1FreshProcessConfirmsAuthorityDurabilityBeforeAnyLedgerAppend),
    ("testX2ConsecutiveCostOnlyChangesEachCountExactlyOnce", oc50cm.testX2ConsecutiveCostOnlyChangesEachCountExactlyOnce),
    ("testX3NegativeBoundaryFailsClosedWithoutBackfill", oc50cm.testX3NegativeBoundaryFailsClosedWithoutBackfill),
    ("testX4IdentityInvalidRowBlocksBoundaryButNotValidRows", oc50cm.testX4IdentityInvalidRowBlocksBoundaryButNotValidRows),
    ("testEmptySourceCensusSucceedsAndAdvancesBoundary", oc50cm.testEmptySourceCensusSucceedsAndAdvancesBoundary),
    ("testR4ACostRollbackBumpsEpochSoRepeatedCostTransitionCounts", oc50cm.testR4ACostRollbackBumpsEpochSoRepeatedCostTransitionCounts),
    ("testR4ASimultaneousTokenAndCostRollbackBumpsEpochExactlyOnce", oc50cm.testR4ASimultaneousTokenAndCostRollbackBumpsEpochExactlyOnce),
    ("testR4BEmptySessionIdExcludedFromCensusAndBoundaryHeld", oc50cm.testR4BEmptySessionIdExcludedFromCensusAndBoundaryHeld),
    ("testR4BRebaselineRefusesEmptySessionIdAndLeavesAuthorityUntouched", oc50cm.testR4BRebaselineRefusesEmptySessionIdAndLeavesAuthorityUntouched),
    ("testR5ASubEpsilonCostDecreaseIsRollback", oc50cm.testR5ASubEpsilonCostDecreaseIsRollback),
    ("testR5ASubEpsilonPositiveCostOnlyGrowthCounts", oc50cm.testR5ASubEpsilonPositiveCostOnlyGrowthCounts),
    ("testR5AExactlyEqualCostIsNeitherGrowthNorRollback", oc50cm.testR5AExactlyEqualCostIsNeitherGrowthNorRollback),
    ("testS6PersistedSubEpsilonPendingSurvivesFreshProcessValidationAndRecovers", oc50cm.testS6PersistedSubEpsilonPendingSurvivesFreshProcessValidationAndRecovers),
])

finishTestRun()
