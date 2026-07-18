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
    /// 漫遊範圍:允許帶寬 = 此百分比 × 螢幕寬,以 home(放置點)為中心;100 = 整幕(原行為)。
    var petWanderRangePercent: Double = 100
    /// Pet Engine V2(實驗性):物理/行為新引擎 + Bird demo 通道。預設關 = 位元不變。
    /// 已知限制(E3 前):啟用時拖曳寵物會被引擎位置拉回;Bird 沿用狗的餵食選單。
    var petEngineV2Enabled: Bool = false
    /// 心情轉變時的像素對話泡泡("WOW!"、"yum yum!" 等)。
    var petSpeechEnabled: Bool = true
    var quietMode: Bool = false
    var refreshIntervalSeconds: Double = 45
    var notificationsEnabled: Bool = true
    var launchAtLogin: Bool = false
    var petPositionX: Double?
    var petPositionY: Double?
    /// 選單列徽章顯示模式(Full / Compact / Pet Only)。
    var menuBarDisplayMode: MenuBarDisplayMode = .full
    /// Snooze Alerts:此時刻前不發系統通知(追蹤照常);nil / 過期 = 未 snooze。
    var alertsSnoozedUntil: Date?
    /// 每日自動匯出 HTML 報告(由 launchd 排程跑 aipet report)。
    var dailyExportEnabled: Bool = false
    var dailyExportHour: Int = 9
    var dailyExportMinute: Int = 0
    var dailyExportRangeDays: Int = 30
    var dailyExportFolderPath: String?
    /// EngineV2 pack id 儲存覆寫(FIX-4):非 nil 時優先於 `species` enum 對映。
    /// bird 等尚無 enum case 的 pack id 由此到達(flag 後偵錯/前向相容通道,E1 無 UI);
    /// 儲存的 `species` enum 保持不動。
    var speciesPackIdOverride: String?
    /// OpenRouter credits 監控(opt-in,**預設關**;boundary 變更見 docs/DATA_SOURCES.md)。
    /// GUI-only 設定,刻意不放 `core` —— CLI 維持零網路。
    var openRouterCreditsEnabled: Bool = false
    var core = CoreSettings()

    // MARK: - EngineV2 pack id 相容 facade(M2 §3-A;語意委派 PetSpecies,PetCore 端可測)

    /// 物種的 SpeciesPack id:`speciesPackIdOverride ?? species.packId`。
    /// 消費端一律經 facade 讀取,E2+ 新物種(bird…)落地時只擴 pack 資料面。
    var speciesPackId: String {
        PetSpecies.effectivePackId(override: speciesPackIdOverride, stored: species)
    }

    /// pack id 反解出 legacy 物種(過渡期 UI 與 legacy 渲染仍吃 enum)。
    /// 未知 pack id → .dog(flag 矩陣:settings 遷移未知→"dog";override 存在時真正可達)。
    var resolvedSpecies: PetSpecies { PetSpecies.resolved(fromPackId: speciesPackId) }

    init() {}

    // 對新增欄位寬容:逐鍵 decodeIfPresent + 預設值,舊 settings.json 缺鍵
    // 不會讓整份設定解碼失敗而被重置(synthesized Decodable 沒有這個保證)。
    private enum CodingKeys: String, CodingKey {
        case appMode, species, petVisible, petSize, petOpacity, clickThrough
        case petWanderEnabled, petWanderRangePercent, petEngineV2Enabled
        case petSpeechEnabled, quietMode, refreshIntervalSeconds
        case notificationsEnabled, launchAtLogin, petPositionX, petPositionY
        case menuBarDisplayMode, alertsSnoozedUntil
        case dailyExportEnabled, dailyExportHour, dailyExportMinute, dailyExportRangeDays, dailyExportFolderPath
        case speciesPackIdOverride
        case openRouterCreditsEnabled
        case core
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
        petWanderRangePercent = WanderBand.clampRangePercent(
            (try? c.decodeIfPresent(Double.self, forKey: .petWanderRangePercent)) ?? 100 ?? 100)
        petEngineV2Enabled = (try? c.decodeIfPresent(Bool.self, forKey: .petEngineV2Enabled)) ?? false ?? false
        petSpeechEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .petSpeechEnabled)) ?? true ?? true
        quietMode = (try? c.decodeIfPresent(Bool.self, forKey: .quietMode)) ?? false ?? false
        refreshIntervalSeconds = (try? c.decodeIfPresent(Double.self, forKey: .refreshIntervalSeconds)) ?? 45 ?? 45
        notificationsEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled)) ?? true ?? true
        launchAtLogin = (try? c.decodeIfPresent(Bool.self, forKey: .launchAtLogin)) ?? false ?? false
        petPositionX = (try? c.decodeIfPresent(Double.self, forKey: .petPositionX)) ?? nil
        petPositionY = (try? c.decodeIfPresent(Double.self, forKey: .petPositionY)) ?? nil
        menuBarDisplayMode = (try? c.decodeIfPresent(MenuBarDisplayMode.self, forKey: .menuBarDisplayMode)) ?? .full ?? .full
        alertsSnoozedUntil = (try? c.decodeIfPresent(Date.self, forKey: .alertsSnoozedUntil)) ?? nil
        dailyExportEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .dailyExportEnabled)) ?? false ?? false
        dailyExportHour = (try? c.decodeIfPresent(Int.self, forKey: .dailyExportHour)) ?? 9 ?? 9
        dailyExportMinute = (try? c.decodeIfPresent(Int.self, forKey: .dailyExportMinute)) ?? 0 ?? 0
        dailyExportRangeDays = (try? c.decodeIfPresent(Int.self, forKey: .dailyExportRangeDays)) ?? 30 ?? 30
        dailyExportFolderPath = (try? c.decodeIfPresent(String.self, forKey: .dailyExportFolderPath)) ?? nil
        speciesPackIdOverride = (try? c.decodeIfPresent(String.self, forKey: .speciesPackIdOverride)) ?? nil
        openRouterCreditsEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .openRouterCreditsEnabled)) ?? false ?? false
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
