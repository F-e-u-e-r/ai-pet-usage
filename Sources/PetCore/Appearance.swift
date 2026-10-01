import Foundation
import AppKit

// Appearance V1(owner-locked contract;reviews/appearance-v1/DESIGN-NOTE.md)。
// 兩條獨立的軸:**appearance**(System / Light / Dark,本檔)與未來的 **theme**(調色盤,`Theme.*` token 層)——
// V1 刻意不宣告 `AppTheme`。這裡只放可測的純語意;套用到 `NSApp.appearance` 與 `appearanceTick` 重烤
// 是 app target(`AppModel`)唯一的 production 路徑。

/// App 層級外觀偏好。`.system` = 跟隨 macOS(`NSApp.appearance = nil`)。
/// raw value 即 settings.json 的持久化字串;UI 顯示 "System"(不是 "Default")。
public enum AppearancePreference: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark

    public var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// 純映射:偏好 → 要交給 `NSAppearance(named:)` 的名稱;`.system` → nil(清掉 app 覆寫、回到系統)。
    public var nsAppearanceName: NSAppearance.Name? {
        switch self {
        case .system: return nil
        case .light: return .aqua
        case .dark: return .darkAqua
        }
    }

    /// 寬容解碼(AppSettings 逐鍵 fail-soft 慣例):先讀 raw 字串再對映,缺鍵 / null / 型別錯誤 /
    /// 未知值("ocean")一律 → `.system`,且絕不拋出 —— 直接 `decode(AppearancePreference.self)`
    /// 遇未知 raw 會拋,讓整份設定解碼失敗而重置 sibling。
    public static func decodeTolerant<K: CodingKey>(from container: KeyedDecodingContainer<K>,
                                                    forKey key: K) -> AppearancePreference {
        let raw = (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil
        return raw.flatMap(AppearancePreference.init(rawValue:)) ?? .system
    }
}

/// 選單列徽章墨色的純決策(badge exception):選單列是系統的,**只**跟系統外觀走,與 app 偏好無關。
public enum MenuBarBadgeInk {
    /// 一般文字灰階(0…1):深色選單列 → 近白;淺色 → 近黑。烤圖時無法用動態色,故在此固定。
    public static func baseWhite(systemIsDark: Bool) -> CGFloat {
        systemIsDark ? 0.98 : 0.15
    }
}

/// macOS **全域**外觀解析器。production `live` 讀使用者全域偏好域(`defaults read -g`)裡的
/// `AppleInterfaceStyle` —— 不是 `NSApp.effectiveAppearance`(會被 app 偏好覆寫)、不是繪圖 context、
/// 也不是本 process 的 UserDefaults 合成視圖(app domain / argument domain 可能有影子)。reader 可注入供測試。
public struct SystemAppearanceProvider: Sendable {
    public typealias Reader = @Sendable (_ globalKey: String) -> String?

    /// 系統寫入的全域鍵:深色 = "Dark";淺色時鍵**不存在**。
    public static let interfaceStyleKey = "AppleInterfaceStyle"

    private let read: Reader

    public init(read: @escaping Reader) {
        self.read = read
    }

    /// 真機讀取:`CFPreferencesCopyValue(key, AnyApplication, CurrentUser, AnyHost)` = 使用者全域域
    /// (`~/Library/Preferences/.GlobalPreferences.plist`,cfprefsd 即時值,等同 `defaults read -g`)。
    /// 首手驗證(2026-09-28 probe):System Settings 把 AppleInterfaceStyle 寫在此域;此讀法不受本 process
    /// app-domain 影子影響,也不受 argument / registration 等 volatile 覆蓋影響 —— 相對地
    /// `CFPreferencesCopyAppValue(…, kCFPreferencesAnyApplication)` 會吃到 volatile 覆蓋,故不採用。
    public static var live: SystemAppearanceProvider {
        SystemAppearanceProvider { key in readUserGlobalDomain(key) }
    }

    private static func readUserGlobalDomain(_ key: String) -> String? {
        CFPreferencesCopyValue(key as CFString, kCFPreferencesAnyApplication,
                               kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String
    }

    /// 每次讀取即時解析(不快取);"Dark"(大小寫寬容)→ true,nil / 其他 → false(淺色)。
    public var systemIsDark: Bool {
        read(Self.interfaceStyleKey)?.caseInsensitiveCompare("Dark") == .orderedSame
    }
}
