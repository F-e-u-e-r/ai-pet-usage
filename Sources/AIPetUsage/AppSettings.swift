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
    var core = CoreSettings()

    // Codable 需要對新增欄位寬容:全部給預設值即可。
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
