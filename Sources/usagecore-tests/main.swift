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
])

let codex = CodexAdapterTests()
runSuite("CodexAdapterTests", [
    ("testParsesTotalsDeltasAndRateLimits", codex.testParsesTotalsDeltasAndRateLimits),
    ("testIncrementalPreservesContext", codex.testIncrementalPreservesContext),
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
    ("testWindowRolloverAcceptsLowerAndEmitsReset", limits.testWindowRolloverAcceptsLowerAndEmitsReset),
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
    ("testClaudeBudgetPercentAndEstimatedReset", limits.testClaudeBudgetPercentAndEstimatedReset),
])

let pricing = PricingTests()
runSuite("PricingTests", [
    ("testMatchingAndCost", pricing.testMatchingAndCost),
    ("testUnknownModelIsNotSilentlyPriced", pricing.testUnknownModelIsNotSilentlyPriced),
    ("testUserOverrideBeatsBuiltin", pricing.testUserOverrideBeatsBuiltin),
    ("testBundledPriceListCoversCurrentModels", pricing.testBundledPriceListCoversCurrentModels),
])

let report = ReportTests()
runSuite("ReportTests", [
    ("testReportSectionsAndRedaction", report.testReportSectionsAndRedaction),
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
    ("testSeverityThresholdsAndCompactFilter", brandTests.testSeverityThresholdsAndCompactFilter),
    ("testAccessibilitySummaryUsesFullNames", brandTests.testAccessibilitySummaryUsesFullNames),
    ("testIdentityDotsAreStableAndDistinct", brandTests.testIdentityDotsAreStableAndDistinct),
    ("testSpeciesFoodsKeepStableIds", brandTests.testSpeciesFoodsKeepStableIds),
])

let hourly = HourlyBreakdownTests()
runSuite("HourlyBreakdownTests", [
    ("testBucketsCarryBreakdownAndTopProject", hourly.testBucketsCarryBreakdownAndTopProject),
])

finishTestRun()
