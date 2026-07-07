import Foundation
import UsageCore
import PetCore

/// App 模式:完整寵物體驗,或純監控(不建立寵物視窗與互動引擎,降低 RAM/CPU)。
enum AppMode: String, Codable, CaseIterable {
    case full
    case monitorOnly

    var displayName: String {
        switch self {
        case .full: return "Pet + Monitor"
        case .monitorOnly: return "Monitor only (low RAM)"
        }
    }
}

/// 選單列顯示模式(UIUX spec §6):Full 預設;Compact 只列 ≥warn 的 provider;
/// Pet Only 只留物種 emoji。
enum MenuBarDisplayMode: String, Codable, CaseIterable {
    case full
    case compact
    case petOnly

    var displayName: String {
        switch self {
        case .full: return "Full (all providers)"
        case .compact: return "Compact (warnings only)"
        case .petOnly: return "Pet only"
        }
    }
}

struct AppSettings: Codable {
    var appMode: AppMode = .full
    var species: PetSpecies = .dog
    var petVisible: Bool = true
    var petSize: Double = 96
    var petOpacity: Double = 1.0
    var clickThrough: Bool = false
    /// 螢幕漫遊(companion mode):閒置時沿螢幕底部邊緣走動。預設關閉。
    var petWanderEnabled: Bool = false
    /// 心情轉變時的像素對話泡泡("WOW!"、"yum yum!" 等)。
    var petSpeechEnabled: Bool = true
    var quietMode: Bool = false
    var refreshIntervalSeconds: Double = 45
    var notificationsEnabled: Bool = true
    var petPositionX: Double?
    var petPositionY: Double?
    /// 選單列徽章顯示模式(Full / Compact / Pet Only)。
    var menuBarDisplayMode: MenuBarDisplayMode = .full
    /// Snooze Alerts:此時刻前不發系統通知(追蹤照常);nil / 過期 = 未 snooze。
    var alertsSnoozedUntil: Date?
    var core = CoreSettings()

    init() {}

    // 對新增欄位寬容:逐鍵 decodeIfPresent + 預設值,舊 settings.json 缺鍵
    // 不會讓整份設定解碼失敗而被重置(synthesized Decodable 沒有這個保證)。
    private enum CodingKeys: String, CodingKey {
        case appMode, species, petVisible, petSize, petOpacity, clickThrough
        case petWanderEnabled, petSpeechEnabled, quietMode, refreshIntervalSeconds
        case notificationsEnabled, petPositionX, petPositionY
        case menuBarDisplayMode, alertsSnoozedUntil, core
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appMode = (try? c.decodeIfPresent(AppMode.self, forKey: .appMode)) ?? .full ?? .full
        species = (try? c.decodeIfPresent(PetSpecies.self, forKey: .species)) ?? .dog ?? .dog
        petVisible = (try? c.decodeIfPresent(Bool.self, forKey: .petVisible)) ?? true ?? true
        petSize = (try? c.decodeIfPresent(Double.self, forKey: .petSize)) ?? 96 ?? 96
        petOpacity = (try? c.decodeIfPresent(Double.self, forKey: .petOpacity)) ?? 1.0 ?? 1.0
        clickThrough = (try? c.decodeIfPresent(Bool.self, forKey: .clickThrough)) ?? false ?? false
        petWanderEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .petWanderEnabled)) ?? false ?? false
        petSpeechEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .petSpeechEnabled)) ?? true ?? true
        quietMode = (try? c.decodeIfPresent(Bool.self, forKey: .quietMode)) ?? false ?? false
        refreshIntervalSeconds = (try? c.decodeIfPresent(Double.self, forKey: .refreshIntervalSeconds)) ?? 45 ?? 45
        notificationsEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled)) ?? true ?? true
        petPositionX = (try? c.decodeIfPresent(Double.self, forKey: .petPositionX)) ?? nil
        petPositionY = (try? c.decodeIfPresent(Double.self, forKey: .petPositionY)) ?? nil
        menuBarDisplayMode = (try? c.decodeIfPresent(MenuBarDisplayMode.self, forKey: .menuBarDisplayMode)) ?? .full ?? .full
        alertsSnoozedUntil = (try? c.decodeIfPresent(Date.self, forKey: .alertsSnoozedUntil)) ?? nil
        core = (try? c.decodeIfPresent(CoreSettings.self, forKey: .core)) ?? CoreSettings() ?? CoreSettings()
    }
}

/// 崩潰安全的設定存放(原子寫入 JSON;UserDefaults 在非 bundle 執行下不可靠)。
final class SettingsStore {
    private let url: URL
    private(set) var settings: AppSettings

    init(dataDir: URL) {
        url = dataDir.appendingPathComponent("settings.json")
        settings = AtomicJSON.read(AppSettings.self, from: url) ?? AppSettings()
    }

    func update(_ mutate: (inout AppSettings) -> Void) {
        mutate(&settings)
        try? AtomicJSON.write(settings, to: url)
    }
}
