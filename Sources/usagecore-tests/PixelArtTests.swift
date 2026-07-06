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
        XCTAssertEqual(PixelPets.animState(for: .warning, walking: true), .sit,
                       "警戒狀態不得漫遊行走")
        XCTAssertEqual(PixelPets.animState(for: .focused, walking: false), .sit)
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
