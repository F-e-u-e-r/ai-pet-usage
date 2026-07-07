import Foundation
import UsageCore
import PetCore

final class PixelArtTests: XCTestCase {
    func testAllFramesWellFormed() {
        for species in PetSpecies.allCases {
            let sprite = PixelPets.sprite(for: species)
            for state in PixelAnimState.allCases {
                let frames = sprite.frames(for: state)
                XCTAssertFalse(frames.isEmpty, "\(species) 缺少 \(state) 動畫")
                for (fi, frame) in frames.enumerated() {
                    XCTAssertEqual(frame.count, sprite.height,
                                   "\(species)/\(state) 幀 \(fi) 列數錯誤")
                    for (ri, row) in frame.enumerated() {
                        XCTAssertEqual(row.count, sprite.width,
                                       "\(species)/\(state) 幀 \(fi) 第 \(ri) 列寬度 \(row.count) ≠ \(sprite.width)")
                        for ch in row where ch != "." {
                            XCTAssertNotNil(sprite.palette[ch],
                                            "\(species)/\(state) 幀 \(fi) 第 \(ri) 列未知字元 '\(ch)'")
                        }
                    }
                }
            }
        }
    }

    func testSpeechPhrases() {
        XCTAssertNotNil(PetSpeech.phrases(for: .celebration))
        XCTAssertNotNil(PetSpeech.phrases(for: .eating))
        XCTAssertNil(PetSpeech.phrases(for: .sleeping), "睡覺不說話")
        XCTAssertEqual(shortProviderCode("claude-code"), "CC")
        XCTAssertEqual(shortProviderCode("codex"), "CX")
    }

    func testAnimStateMapping() {
        XCTAssertEqual(PixelPets.animState(for: .sleeping, walking: false), .sleep)
        XCTAssertEqual(PixelPets.animState(for: .eating, walking: false), .eat)
        XCTAssertEqual(PixelPets.animState(for: .celebration, walking: false), .jump)
        XCTAssertEqual(PixelPets.animState(for: .idle, walking: true), .walk)
        XCTAssertEqual(PixelPets.animState(for: .warning, walking: true), .alert,
                       "警戒狀態不得漫遊行走")
        XCTAssertEqual(PixelPets.animState(for: .focused, walking: false, species: .dog), .sit)
        XCTAssertEqual(PixelPets.animState(for: .focused, walking: false, species: .cat), .focusedActive,
                       "貓的 focused 進入專注綠眼狀態")
        XCTAssertEqual(PixelPets.animState(for: .happy, walking: false), .happy,
                       "開心 → 搖尾/尾尖搖擺狀態")
    }

    func testGlyphsWellFormed() {
        for mood in [PetMood.warning, .exhausted, .confused, .hungry] {
            let glyph = PixelGlyphs.glyph(for: mood)
            XCTAssertNotNil(glyph)
            let widths = Set(glyph!.rows.map(\.count))
            XCTAssertEqual(widths.count, 1, "\(mood) 字形列寬不一致")
        }
        XCTAssertNil(PixelGlyphs.glyph(for: .sleeping), "睡眠以姿勢/呼吸表現,不用徽章(不得出現 zzz)")
    }

    func testMicroAnimationFramesWellFormed() {
        // micro-animation 幀不在 animations dict 內,單獨驗證網格與 palette
        for species in PetSpecies.allCases {
            let sprite = PixelPets.sprite(for: species)
            for state in PixelAnimState.allCases {
                for micro in PixelPets.microAnimations(species: species, state: state) {
                    XCTAssertFalse(micro.frames.isEmpty, "\(species)/\(state)/\(micro.name) 無幀")
                    XCTAssertTrue(micro.interval.lowerBound >= 3,
                                  "\(micro.name) 間隔下限過短(會像機械 loop)")
                    for (fi, frame) in micro.frames.enumerated() {
                        XCTAssertEqual(frame.count, sprite.height, "\(micro.name) 幀 \(fi) 列數錯誤")
                        for (ri, row) in frame.enumerated() {
                            XCTAssertEqual(row.count, sprite.width,
                                           "\(micro.name) 幀 \(fi) 第 \(ri) 列寬度錯誤")
                            for ch in row where ch != "." {
                                XCTAssertNotNil(sprite.palette[ch],
                                                "\(micro.name) 幀 \(fi) 未知字元 '\(ch)'")
                            }
                        }
                    }
                }
            }
        }
        // walk / sleep / eat / jump 期間不得插播
        for species in PetSpecies.allCases {
            for state in [PixelAnimState.walk, .sleep, .eat, .jump] {
                XCTAssertTrue(PixelPets.microAnimations(species: species, state: state).isEmpty,
                              "\(species)/\(state) 不應有 micro-animation")
            }
        }
    }
}

// MARK: - PixelAnimator(one-shot 轉場 + micro 排程 + reduce-motion)

final class PixelAnimatorTests: XCTestCase {
    func testCatFocusTransitionsPlaySequentially() {
        let sprite = PixelPets.sprite(for: .cat)
        let animator = PixelAnimator(species: .cat, initialState: .idle, seed: 7)
        let t0 = date("2026-01-15T10:00:00Z")
        _ = animator.frame(species: .cat, target: .idle, sprite: sprite, at: t0, reduceMotion: false)

        let start = animator.frame(species: .cat, target: .focusedActive, sprite: sprite,
                                   at: t0, reduceMotion: false)
        XCTAssertEqual(start, sprite.frames(for: .focusStart)[0], "進入專注須先播 focus-start,不得紅綠直切")

        let mid = animator.frame(species: .cat, target: .focusedActive, sprite: sprite,
                                 at: t0.addingTimeInterval(0.15), reduceMotion: false)
        XCTAssertEqual(mid, sprite.frames(for: .focusStart)[1])

        let active = animator.frame(species: .cat, target: .focusedActive, sprite: sprite,
                                    at: t0.addingTimeInterval(1.0), reduceMotion: false)
        XCTAssertTrue(sprite.frames(for: .focusedActive).contains(active), "轉場結束後進入 focused loop")

        let exit = animator.frame(species: .cat, target: .idle, sprite: sprite,
                                  at: t0.addingTimeInterval(2.0), reduceMotion: false)
        XCTAssertEqual(exit, sprite.frames(for: .focusEnd)[0], "退出專注不得 hard cut,須播 focus-end")
    }

    func testMicroAnimationFirstFireFallsInConfiguredInterval() {
        let sprite = PixelPets.sprite(for: .dog)
        let animator = PixelAnimator(species: .dog, initialState: .idle, seed: 42)
        let t0 = date("2026-01-15T10:00:00Z")
        guard let twitch = PixelPets.microAnimations(species: .dog, state: .idle).first else {
            XCTAssertTrue(false, "狗 idle 缺 earTwitch micro"); return
        }
        var firstFire: Double?
        var s = 0.0
        while s < 20 {
            let f = animator.frame(species: .dog, target: .idle, sprite: sprite,
                                   at: t0.addingTimeInterval(s), reduceMotion: false)
            if firstFire == nil, f == twitch.frames[0] { firstFire = s }
            s += 0.05
        }
        XCTAssertNotNil(firstFire, "20 秒內應觸發至少一次 ear twitch")
        if let t = firstFire {
            XCTAssertTrue(t >= twitch.interval.lowerBound && t <= twitch.interval.upperBound + 0.2,
                          "第一次觸發應落在 \(twitch.interval) 內,實際 \(t)s")
        }
    }

    func testWalkSuppressesMicroAnimations() {
        let sprite = PixelPets.sprite(for: .dog)
        let animator = PixelAnimator(species: .dog, initialState: .walk, seed: 1)
        let t0 = date("2026-01-15T10:00:00Z")
        let walkFrames = sprite.frames(for: .walk)
        var offender: [String]?
        var s = 0.0
        while s < 30 {
            let f = animator.frame(species: .dog, target: .walk, sprite: sprite,
                                   at: t0.addingTimeInterval(s), reduceMotion: false)
            if !walkFrames.contains(f) { offender = f }
            s += 0.1
        }
        XCTAssertNil(offender, "walk 期間不得插播 micro-animation")
    }

    func testReduceMotionShowsStaticPoseWithoutTransitions() {
        let sprite = PixelPets.sprite(for: .cat)
        let animator = PixelAnimator(species: .cat, initialState: .idle, seed: 3)
        let t0 = date("2026-01-15T10:00:00Z")
        let pose = animator.frame(species: .cat, target: .focusedActive, sprite: sprite,
                                  at: t0, reduceMotion: true)
        XCTAssertEqual(pose, sprite.frames(for: .focusedActive)[0],
                       "reduce-motion 直接顯示 focused 靜態姿勢(綠眼+前傾耳),不播 focus-start 與 pulse")
        let later = animator.frame(species: .cat, target: .focusedActive, sprite: sprite,
                                   at: t0.addingTimeInterval(5), reduceMotion: true)
        XCTAssertEqual(later, pose)
    }
}

// MARK: - ProviderBrand / MenuBadge

final class ProviderBrandTests: XCTestCase {
    func testBadgesAlphabeticalOmitMissingAndSeverity() {
        let badges = MenuBadgeBuilder.badges(from: [
            (id: "codex", displayName: "Codex", percent: 53),
            (id: "claude-code", displayName: "Claude Code", percent: 91),
            (id: "grok-code", displayName: nil, percent: nil), // 無資料 → 略過
        ], warn: 80, danger: 95)
        XCTAssertEqual(badges.map(\.code), ["CC", "CX"], "依顯示名稱字母序,無資料省略")
        XCTAssertEqual(badges[0].severity, .warn)
        XCTAssertEqual(badges[1].severity, .normal)
        XCTAssertEqual(badges[0].percent, 91)
    }

    func testSeverityThresholdsAndCompactFilter() {
        XCTAssertEqual(UsageSeverity.of(percent: 101, warn: 80, danger: 95), .danger)
        XCTAssertEqual(UsageSeverity.of(percent: 95, warn: 80, danger: 95), .danger)
        XCTAssertEqual(UsageSeverity.of(percent: 80, warn: 80, danger: 95), .warn)
        XCTAssertEqual(UsageSeverity.of(percent: 79.9, warn: 80, danger: 95), .normal)
        XCTAssertEqual(UsageSeverity.of(percent: nil, warn: 80, danger: 95), .normal)

        let compact = MenuBadgeBuilder.badges(from: [
            (id: "claude-code", displayName: "Claude Code", percent: 91),
            (id: "codex", displayName: "Codex", percent: 53),
        ], warn: 80, danger: 95, onlyWarnings: true)
        XCTAssertEqual(compact.map(\.code), ["CC"], "Compact 模式只留 ≥warn 的 provider")
    }

    func testAccessibilitySummaryUsesFullNames() {
        let badges = MenuBadgeBuilder.badges(from: [
            (id: "claude-code", displayName: "Claude Code", percent: 91),
            (id: "codex", displayName: "Codex", percent: 53),
        ], warn: 80, danger: 95)
        let summary = MenuBadgeBuilder.accessibilitySummary(petName: "Golden Retriever", badges: badges)
        XCTAssertEqual(summary,
                       "Golden Retriever. Claude Code 91 percent, warning. Codex 53 percent, normal.",
                       "輔助功能必須念全名與 severity,不得只給短代號")
    }

    func testIdentityDotsAreStableAndDistinct() {
        let dots = ProviderBrands.known.map(\.dotColor)
        XCTAssertEqual(Set(dots).count, dots.count, "各 provider 身分色必須互異")
        XCTAssertTrue(ProviderBrands.brand(for: "grok-code").needsOutline, "GK 深色 dot 需描邊")
        XCTAssertEqual(ProviderBrands.brand(for: "unknown-x", displayName: "Unknown X").code, "UN")
    }

    func testSpeciesFoodsKeepStableIds() {
        let starterIds = FoodItem.starterFoods.map(\.id)
        XCTAssertEqual(FoodItem.dogFoods.map(\.id), starterIds,
                       "物種菜單 id 必須與 starterFoods 相同(eatingFoodId 持久化相容)")
        XCTAssertEqual(FoodItem.catFoods.map(\.id), starterIds)
        for (dog, cat) in zip(FoodItem.dogFoods, FoodItem.catFoods) {
            XCTAssertEqual(dog.treatCost, cat.treatCost, "成本不得因物種而異")
            XCTAssertEqual(dog.satiety, cat.satiety, "飽足度不得因物種而異")
        }
    }
}

final class HourlyBreakdownTests: XCTestCase {
    func testBucketsCarryBreakdownAndTopProject() {
        let ledger = UsageLedger(fileURL: nil)
        func ev(_ id: String, minute: Int, tokens: TokenBreakdown, project: String) -> UsageEvent {
            UsageEvent(id: id, providerId: "codex", projectId: "/p/\(project)", projectName: project,
                       timestamp: date(String(format: "2026-01-15T10:%02d:00Z", minute)),
                       tokens: tokens, sourceKind: "test")
        }
        ledger.append([
            ev("a", minute: 5, tokens: TokenBreakdown(input: 100, output: 50, cacheRead: 1000), project: "alpha"),
            ev("b", minute: 20, tokens: TokenBreakdown(input: 10, output: 5), project: "beta"),
        ])
        let day = DateInterval(start: date("2026-01-15T00:00:00Z"), end: date("2026-01-16T00:00:00Z"))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let buckets = ledger.hourlyBuckets(in: day, calendar: cal)
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets[0].breakdown.input, 110)
        XCTAssertEqual(buckets[0].breakdown.cacheRead, 1000)
        XCTAssertEqual(buckets[0].topProject, "alpha")
        XCTAssertEqual(buckets[0].tokens, 1165)
    }
}
