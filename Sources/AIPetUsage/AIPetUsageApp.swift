import SwiftUI
import AppKit
import UsageCore
import PetCore

@main
struct AIPetUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        AppDelegate.sharedModel = model
    }

    var body: some Scene {
        // .window style:下拉是自訂 SwiftUI 面板(彩色狀態 header + 動作列),
        // 預設 .menu style 無法做非灰字的自訂 header(UIUX spec §8)。
        MenuBarExtra {
            MenuBarPanel()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Window("AI Pet Usage", id: "dashboard") {
            DashboardRoot()
                .environment(model)
        }
        .defaultSize(width: 920, height: 660)

        Settings {
            SettingsRoot()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var sharedModel: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 選單列常駐工具:不佔 Dock、不搶焦點。
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            AppDelegate.sharedModel?.start()
        }
        // A2 app 內更新檢查(opt-in,預設關)。啟動延遲首檢 + 每 6h 週期;checkForUpdates 內部
        // 再驗開關/每日節流/失敗退避,故長時間執行也能可靠約每日檢查一次,使用者關閉後即停。
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            await UpdateChecker.shared.checkForUpdates(manual: false)
        }
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in await UpdateChecker.shared.checkForUpdates(manual: false) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppDelegate.sharedModel?.stop() }
    }
}

// MARK: - 選單列 label

/// 彩色徽章 label:🐶 ● CC 91% ● CX 53%(dot = 身分色、% = severity 色)。
/// 顏色經 ImageRenderer 烤成非 template NSImage;烤製失敗時退回純文字。
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // 讀取 appearanceTick,使深/淺色切換時重新烤圖
        let _ = model.appearanceTick
        return Group {
            if let image = MenuBarBadgeRenderer.image(petEmoji: model.menuBarPetEmoji,
                                                      badges: model.menuBarBadges,
                                                      showsPlaceholder: model.menuBarShowsPlaceholder) {
                Image(nsImage: image)
            } else {
                Text(model.menuBarTitle).monospacedDigit()
            }
        }
        .accessibilityLabel(model.menuBarAccessibilityLabel)
    }
}
