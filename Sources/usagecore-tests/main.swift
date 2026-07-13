import Foundation

// 手動註冊(無 XCTest runtime 探索可用)。新增測試方法時記得加進對應清單。

let iso = ISO8601Tests()
runSuite("ISO8601Tests", [
    ("testParseVariants", iso.testParseVariants),
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

let claude = ClaudeCodeAdapterTests()
runSuite("ClaudeCodeAdapterTests", [
    ("testParsesFixture", claude.testParsesFixture),
    ("testStatuslinePayloadYieldsOfficialRateLimits", claude.testStatuslinePayloadYieldsOfficialRateLimits),
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

finishTestRun()
