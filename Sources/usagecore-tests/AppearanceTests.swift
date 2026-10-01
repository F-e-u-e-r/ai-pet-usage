import Foundation
import AppKit
import UsageCore
import PetCore

// Appearance V1(owner-locked contract,reviews/appearance-v1/DESIGN-NOTE.md):
//   * app 層級偏好 System / Light / Dark,經 `NSApp.appearance` 整 app 一體套用;
//   * 持久化在 GUI-only `AppSettings`,缺鍵/未知值 fail-soft → `.system`,不得毒化 sibling 設定;
//   * badge exception:選單列徽章跟隨**系統**外觀(注入 `systemIsDark`),不讀 NSApp.effectiveAppearance。
// 證據分工(owner tightening 2):PetCore 單元測試證可抽出的語意;source guard 鎖 app target 的
// 可執行接線(usagecore-tests 無法 import executable target);live 手動切換 / 重啟持久化 = runtime acceptance。

// MARK: - PetCore 語意

final class AppearanceTests: XCTestCase {
    /// 模擬 `AppSettings` 的逐鍵寬容解碼形狀:appearance 走 `decodeTolerant`,sibling 各自逐鍵解碼。
    private struct Probe: Codable, Equatable {
        var appearance: AppearancePreference = .system
        var sibling: Int = 7
        var flag: Bool = true

        init() {}
        init(appearance: AppearancePreference, sibling: Int, flag: Bool) {
            self.appearance = appearance; self.sibling = sibling; self.flag = flag
        }

        private enum CodingKeys: String, CodingKey { case appearance, sibling, flag }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            appearance = AppearancePreference.decodeTolerant(from: c, forKey: .appearance)
            sibling = (try? c.decodeIfPresent(Int.self, forKey: .sibling)) ?? 7
            flag = (try? c.decodeIfPresent(Bool.self, forKey: .flag)) ?? true
        }
    }

    private func decode(_ json: String) throws -> Probe {
        try JSONDecoder().decode(Probe.self, from: Data(json.utf8))
    }

    // test 1:缺 appearance 鍵(舊 settings.json)→ .system;sibling 照常。
    func testMissingAppearanceDecodesAsSystem() throws {
        let p = try decode(#"{"sibling": 3, "flag": false}"#)
        XCTAssertEqual(p.appearance, .system)
        XCTAssertEqual(p.sibling, 3)
        XCTAssertEqual(p.flag, false)
    }

    // test 2:未知 raw value("ocean")→ .system,且 sibling 設定仍正確解碼(整份不得失敗重置)。
    func testUnknownAppearanceFailsSoftToSystemWithoutPoisoningSiblings() throws {
        let p = try decode(#"{"appearance": "ocean", "sibling": 42, "flag": false}"#)
        XCTAssertEqual(p.appearance, .system, "unknown raw value must fail soft to .system")
        XCTAssertEqual(p.sibling, 42, "sibling settings must survive an unknown appearance value")
        XCTAssertEqual(p.flag, false)
    }

    // test 2b:型別錯誤 / null / 物件 → 同樣 fail-soft,不拋、不毒化。
    func testWrongTypeOrNullAppearanceFailsSoftToSystem() throws {
        for json in [#"{"appearance": 3, "sibling": 5}"#,
                     #"{"appearance": null, "sibling": 5}"#,
                     #"{"appearance": {"a": 1}, "sibling": 5}"#,
                     #"{"appearance": ["dark"], "sibling": 5}"#] {
            let p = try decode(json)
            XCTAssertEqual(p.appearance, .system, json)
            XCTAssertEqual(p.sibling, 5, json)
        }
    }

    // test 3:合法值("dark")往返;三個 case 的 raw 字串即 contract。
    func testValidAppearanceRoundTrips() throws {
        let fromJSON = try decode(#"{"appearance": "dark"}"#)
        XCTAssertEqual(fromJSON.appearance, .dark)

        for pref in AppearancePreference.allCases {
            let data = try JSONEncoder().encode(Probe(appearance: pref, sibling: 1, flag: true))
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertTrue(text.contains("\"appearance\":\"\(pref.rawValue)\""), text)
            XCTAssertEqual(try JSONDecoder().decode(Probe.self, from: data).appearance, pref)
        }
    }

    // raw value / 顯示名 / 順序 = UI 分段順序 System | Light | Dark(UI 用 "System",不是 "Default")。
    func testRawValuesDisplayNamesAndCaseOrder() {
        XCTAssertEqual(AppearancePreference.allCases, [.system, .light, .dark])
        XCTAssertEqual(AppearancePreference.allCases.map(\.rawValue), ["system", "light", "dark"])
        XCTAssertEqual(AppearancePreference.allCases.map(\.displayName), ["System", "Light", "Dark"])
        XCTAssertNil(AppearancePreference(rawValue: "Default"))
        XCTAssertNil(AppearancePreference(rawValue: "Dark"), "raw values are lowercase by contract")
    }

    // test 4:純映射 AppearancePreference → NSAppearance.Name?(system = nil = 跟隨系統)。
    func testPreferenceToAppearanceNameMapping() {
        XCTAssertNil(AppearancePreference.system.nsAppearanceName)
        XCTAssertEqual(AppearancePreference.light.nsAppearanceName, NSAppearance.Name.aqua)
        XCTAssertEqual(AppearancePreference.dark.nsAppearanceName, NSAppearance.Name.darkAqua)
        // 映射出的名稱必須能實際建構 NSAppearance(非 nil 的兩個)。
        for pref in AppearancePreference.allCases {
            if let name = pref.nsAppearanceName {
                XCTAssertNotNil(NSAppearance(named: name), pref.rawValue)
            }
        }
    }

    // test 5:徽章墨色只跟**系統**外觀(注入值)走:深色選單列 → 近白字;淺色 → 近黑字;
    // 與 app 偏好無關(helper 根本不吃偏好;下方迴圈記錄此意圖)。
    func testBadgeInkFollowsInjectedSystemAppearanceOnly() {
        XCTAssertEqual(MenuBarBadgeInk.baseWhite(systemIsDark: true), 0.98)
        XCTAssertEqual(MenuBarBadgeInk.baseWhite(systemIsDark: false), 0.15)
        XCTAssertGreaterThan(MenuBarBadgeInk.baseWhite(systemIsDark: true),
                             MenuBarBadgeInk.baseWhite(systemIsDark: false),
                             "dark menu bar needs lighter ink than light menu bar")
        for _ in AppearancePreference.allCases {
            // app 偏好改變時墨色不變:同一個 systemIsDark 永遠得到同一個值。
            XCTAssertEqual(MenuBarBadgeInk.baseWhite(systemIsDark: true), 0.98)
            XCTAssertEqual(MenuBarBadgeInk.baseWhite(systemIsDark: false), 0.15)
        }
    }

    // test 6:SystemAppearanceProvider 透過注入的 reader 解析;問的鍵必須是全域 AppleInterfaceStyle。
    func testSystemAppearanceProviderResolvesThroughInjectedReader() {
        final class Recorder: @unchecked Sendable { var asked: [String] = [] }
        let rec = Recorder()
        let dark = SystemAppearanceProvider { key in rec.asked.append(key); return "Dark" }
        XCTAssertTrue(dark.systemIsDark)
        XCTAssertEqual(rec.asked, [SystemAppearanceProvider.interfaceStyleKey])
        XCTAssertEqual(SystemAppearanceProvider.interfaceStyleKey, "AppleInterfaceStyle")

        // macOS 淺色模式下全域鍵**不存在**(nil)→ 淺色。
        XCTAssertFalse(SystemAppearanceProvider { _ in nil }.systemIsDark)
        XCTAssertFalse(SystemAppearanceProvider { _ in "Light" }.systemIsDark)
        XCTAssertFalse(SystemAppearanceProvider { _ in "" }.systemIsDark)
        XCTAssertFalse(SystemAppearanceProvider { _ in "Blue" }.systemIsDark)
        // 大小寫寬容(系統寫 "Dark";防禦性接受 "dark")。
        XCTAssertTrue(SystemAppearanceProvider { _ in "dark" }.systemIsDark)
        // 每次讀取即時解析(不快取):reader 改口即改判。
        final class Cell: @unchecked Sendable { var value: String? = "Dark" }
        let cell = Cell()
        let live = SystemAppearanceProvider { _ in cell.value }
        XCTAssertTrue(live.systemIsDark)
        cell.value = nil
        XCTAssertFalse(live.systemIsDark)
    }

    // test 6b:production `live` 讀的是 macOS **全域**域(= `defaults read -g AppleInterfaceStyle`),不是本
    // process 的 UserDefaults 合成視圖。獨立 oracle = `defaults` 工具;再用 argument domain(純記憶體、不落盤)
    // 放相反值當影子:`live` 判定必須不受影響。若有人改成 `UserDefaults.standard` 或
    // `CFPreferencesCopyAppValue(…, kCFPreferencesAnyApplication)`(兩者都吃 volatile 覆蓋;2026-09-28 probe),此測試轉紅。
    func testLiveProviderReadsGlobalDomainNotProcessDefaults() throws {
        let expected = try defaultsToolSaysDark()
        XCTAssertEqual(SystemAppearanceProvider.live.systemIsDark, expected,
                       "live provider must agree with `defaults read -g AppleInterfaceStyle`")

        let key = SystemAppearanceProvider.interfaceStyleKey
        let shadow = expected ? "Light" : "Dark"
        let original = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var shadowed = original
        shadowed[key] = shadow
        UserDefaults.standard.setVolatileDomain(shadowed, forName: UserDefaults.argumentDomain)
        // 還原用「設回原字典」而非 remove(remove 對 argument domain 不生效;只影子本鍵,其他測試不讀它)。
        defer { UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), shadow,
                       "precondition: the process defaults view is shadowed")
        XCTAssertEqual(SystemAppearanceProvider.live.systemIsDark, expected,
                       "live provider must resolve the global system appearance, not the process defaults view")
    }

    /// 獨立 oracle:`/usr/bin/defaults read -g AppleInterfaceStyle` → "Dark"(exit 0)= 深色;淺色時鍵不存在(exit ≠ 0)。
    private func defaultsToolSaysDark() throws -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        p.arguments = ["read", "-g", SystemAppearanceProvider.interfaceStyleKey]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = err.fileHandleForReading.readDataToEndOfFile()
        guard p.terminationStatus == 0 else { return false }
        return text.caseInsensitiveCompare("Dark") == .orderedSame
    }
}

// MARK: - App target 接線 source guard(fail-closed;#filePath 定位,cwd 無關)

/// 鎖住 usagecore-tests 無法直接執行的 glue:AppSettings 用 tolerant decode、AppModel 單一 refresh authority、
/// 啟動/手動變更都走 `applyAppearancePreference()`、MenuBarLabel 把系統外觀注入 renderer、CoreSettings/CLI 零耦合。
/// 這些守則只鎖接線形狀;行為證據在上方 PetCore 測試 + runtime acceptance(owner tightening 2)。
final class AppearanceWiringGuardTests: XCTestCase {
    private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    /// 取兩個錨點之間的片段;錨點消失 → 測試失敗(不得默默略過)。
    private func section(_ text: String, from start: String, to end: String) throws -> String {
        guard let s = text.range(of: start) else { throw GuardError.anchorMissing(start) }
        guard let e = text.range(of: end, range: s.upperBound..<text.endIndex) else { throw GuardError.anchorMissing(end) }
        return String(text[s.lowerBound..<e.lowerBound])
    }
    private enum GuardError: Error { case anchorMissing(String) }

    private func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    // AppSettings:GUI-only 欄位、CodingKey、tolerant decode;不得直接 decode enum(unknown 會拋 → 整份重置)。
    func testAppSettingsUsesTolerantAppearanceDecode() throws {
        let text = try read(appSource("AppSettings.swift"))
        XCTAssertTrue(text.contains("var appearance: AppearancePreference = .system"))
        XCTAssertTrue(text.contains("appearance = AppearancePreference.decodeTolerant(from: c, forKey: .appearance)"),
                      "appearance must be decoded via the tolerant raw-string helper")
        XCTAssertFalse(text.contains("decode(AppearancePreference.self"),
                       "direct enum decode would throw on unknown raw values")
        XCTAssertFalse(text.contains("decodeIfPresent(AppearancePreference.self"),
                       "direct enum decodeIfPresent would throw on unknown raw values")
        // CodingKeys 必須列出 appearance(否則 synthesized/自訂 keys 會靜默丟掉持久化值)。
        let keys = try section(text, from: "private enum CodingKeys", to: "init(from decoder: Decoder)")
        XCTAssertTrue(keys.contains("appearance"), "CodingKeys must carry the appearance key")
    }

    // CoreSettings(UsageCore)與 CLI 零耦合:appearance 是 GUI-only。
    func testCoreSettingsAndCLIHaveNoAppearanceCoupling() throws {
        let core = try read(coreSource("LimitEngine.swift"))
        XCTAssertFalse(core.lowercased().contains("appearance"), "CoreSettings must not learn about appearance")
        for url in try swiftFiles(in: sourcesRoot().appendingPathComponent("aipet")) {
            let text = try read(url)
            XCTAssertFalse(text.contains("AppearancePreference"), url.lastPathComponent)
            XCTAssertFalse(text.contains("SystemAppearanceProvider"), url.lastPathComponent)
        }
    }

    // MenuBarBadge:renderer 純函數,吃注入的 systemIsDark;不得自己讀 NSApp / 繪圖 context / defaults。
    func testMenuBarBadgeRendererIsPureAndTakesInjectedSystemAppearance() throws {
        let text = try read(appSource("MenuBarBadge.swift"))
        XCTAssertTrue(text.contains("systemIsDark: Bool"), "renderer must take the resolved system appearance as input")
        XCTAssertTrue(text.contains("MenuBarBadgeInk.baseWhite(systemIsDark: systemIsDark)"),
                      "ink must come from the pure PetCore decision")
        for forbidden in ["effectiveAppearance", "currentDrawing", "AppleInterfaceStyle",
                          "UserDefaults", "CFPreferences", "NSApp.", "AppearancePreference"] {
            XCTAssertFalse(text.contains(forbidden), "MenuBarBadge.swift must not contain `\(forbidden)`")
        }
        // 視圖內每個 Text 都必須明確 .foregroundStyle:ImageRenderer 的預設 ink 是固定淺色配色(黑),
        // 不跟 systemIsDark(probe G4;r1 review finding)。片段 = 該 Text 到下一個 Text 之間的 modifier 鏈。
        let view = try section(text, from: "struct MenuBarBadgeView", to: "enum MenuBarBadgeRenderer")
        let textCall = try Regex("\\WText\\(")   // 前置非識別字元:排除 windowText(…) 這類以 Text( 結尾的識別字
        let starts = view.matches(of: textCall).map(\.range.upperBound)
        XCTAssertFalse(starts.isEmpty, "anchor: MenuBarBadgeView must contain Text( views")
        for (i, start) in starts.enumerated() {
            let end = i + 1 < starts.count ? starts[i + 1] : view.endIndex
            XCTAssertTrue(view[start..<end].contains(".foregroundStyle("),
                          "MenuBarBadgeView Text #\(i + 1) must carry an explicit foregroundStyle (ink from baseColor)")
        }
    }

    // AppModel:單一 refresh authority(appearanceTick),系統通知與手動變更共用 applyAppearancePreference() 路徑;
    // 啟動即套用持久化偏好;NSApp 層級整 app 套用。
    func testAppModelRoutesLaunchAndManualChangeThroughOneApplyPath() throws {
        let text = try read(appSource("AppModel.swift"))
        let apply = try section(text, from: "private func applyAppearancePreference()", to: "\n    }\n")
        XCTAssertTrue(apply.contains("NSApp.appearance = settings.appearance.nsAppearanceName"),
                      "apply must set NSApp.appearance from the persisted preference mapping")
        XCTAssertTrue(apply.contains("appearanceTick += 1"),
                      "manual change must re-bake through the same appearanceTick authority")

        let start = try section(text, from: "func start() {", to: "private func startFileWatching()")
        XCTAssertTrue(start.contains("applyAppearancePreference()"), "launch must apply the persisted preference")

        let update = try section(text, from: "func updateSettings(", to: "func setLaunchAtLogin(")
        XCTAssertTrue(update.contains("let oldAppearance = settings.appearance"))
        XCTAssertTrue(update.contains("if oldAppearance != settings.appearance"))
        let changeBranch = try section(update, from: "if oldAppearance != settings.appearance", to: "}")
        XCTAssertTrue(changeBranch.contains("applyAppearancePreference()"),
                      "appearance change must route into the shared apply/refresh path")

        // 系統外觀通知仍走同一個 tick(不得另設第二個計數器)。
        let observer = try section(text, from: "AppleInterfaceThemeChangedNotification", to: "\n    }\n")
        XCTAssertTrue(observer.contains("appearanceTick += 1"))
        XCTAssertEqual(count("var appearanceTick", in: text), 1, "exactly one refresh counter")
        XCTAssertTrue(text.contains("private(set) var appearanceTick"))

        // 系統外觀:production provider,對 label 暴露 systemIsDark。
        XCTAssertTrue(text.contains("SystemAppearanceProvider.live"))
        XCTAssertTrue(text.contains("var systemIsDark: Bool"))
    }

    // 整 app 只有一處 NSApp.appearance 指派(AppModel),沒有 per-window / per-view 外觀覆寫或 colorScheme 分支。
    func testAppHasSingleAppLevelAppearanceAssignmentAndNoPerViewBranching() throws {
        var nsAppAssignments = 0
        for url in try swiftFiles(in: appRoot()) {
            let text = try read(url)
            nsAppAssignments += count("NSApp.appearance =", in: text)
            let name = url.lastPathComponent
            XCTAssertFalse(text.contains("preferredColorScheme"), "\(name): no per-view color scheme override")
            XCTAssertFalse(text.contains(".colorScheme("), "\(name): no per-view color scheme override")
            if name != "AppModel.swift" {
                XCTAssertFalse(text.contains(".appearance = NSAppearance("), "\(name): no per-window appearance override")
            }
            // 只有這四個 glue 檔可以認識 AppearancePreference;Theme/Dashboard/A1 hover/badge 一律不知道。
            let allowed: Set<String> = ["AppSettings.swift", "AppModel.swift", "SettingsViews.swift", "AIPetUsageApp.swift"]
            if !allowed.contains(name) {
                XCTAssertFalse(text.contains("AppearancePreference"), "\(name) must not branch on the app appearance preference")
            }
        }
        XCTAssertEqual(nsAppAssignments, 1, "exactly one NSApp.appearance assignment (AppModel.applyAppearancePreference)")
    }

    // MenuBarLabel 把解析後的系統外觀注入 renderer,並讀 appearanceTick 以重烤。
    func testMenuBarLabelInjectsSystemAppearanceIntoRenderer() throws {
        let text = try read(appSource("AIPetUsageApp.swift"))
        XCTAssertTrue(text.contains("systemIsDark: model.systemIsDark"))
        XCTAssertTrue(text.contains("model.appearanceTick"))
    }

    // General Settings:分段選擇器 Appearance [ System | Light | Dark ],寫回走 updateSettings。
    func testGeneralSettingsHasSegmentedAppearancePicker() throws {
        let text = try read(appSource("SettingsViews.swift"))
        let picker = try section(text, from: "Picker(\"Appearance\"", to: ".pickerStyle(.segmented)")
        XCTAssertTrue(picker.contains("AppearancePreference.allCases"))
        XCTAssertTrue(picker.contains("model.updateSettings { $0.appearance = "))
    }

    // MARK: 路徑

    private func sourcesRoot() -> URL {
        URL(fileURLWithPath: #filePath)              // …/Sources/usagecore-tests/AppearanceTests.swift
            .deletingLastPathComponent()             // …/Sources/usagecore-tests
            .deletingLastPathComponent()             // …/Sources
    }
    private func appRoot() -> URL { sourcesRoot().appendingPathComponent("AIPetUsage") }
    private func appSource(_ name: String) -> URL { appRoot().appendingPathComponent(name) }
    private func coreSource(_ name: String) -> URL {
        sourcesRoot().appendingPathComponent("UsageCore").appendingPathComponent(name)
    }
    /// 目錄下(**遞迴**,含 `EngineV2Bridge/` 等子目錄)的 .swift 檔;空清單視為錨點失效 → 失敗。
    private func swiftFiles(in dir: URL) throws -> [URL] {
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            throw GuardError.anchorMissing(dir.path)
        }
        let items = walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        guard !items.isEmpty else { throw GuardError.anchorMissing(dir.path) }
        return items.sorted { $0.path < $1.path }
    }
}
