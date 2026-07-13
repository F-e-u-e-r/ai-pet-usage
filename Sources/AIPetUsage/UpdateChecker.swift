import AppKit
import Foundation
import UsageCore

/// A2 app 內更新通知器(發佈策略共識:非 Sparkle)。查 GitHub Releases API → 比對版本 →
/// NSAlert 顯示「what's new」+ View Update / Skip This Version / Later。刻意**不**從 GUI 內
/// 執行 brew;只開 release 頁並附上可複製的 brew 指令。每日節流 + 記住已跳過 tag;
/// 自動檢查為使用者可切換的設定(見 update.autoCheckEnabled)。純版本邏輯在 UsageCore.UpdateModel。
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    /// 自動檢查開關(GUI-only 偏好,存 UserDefaults;**預設關閉 = opt-in**,符合 local-first:
    /// 未經使用者啟用不主動連 GitHub)。手動「Check for Updates…」永遠可用。
    static let autoCheckDefaultsKey = "update.autoCheckEnabled"
    static var autoCheckEnabled: Bool {
        UserDefaults.standard.object(forKey: autoCheckDefaultsKey) as? Bool ?? false
    }

    private let releasesURL = URL(string: "https://api.github.com/repos/F-e-u-e-r/ai-pet-usage/releases")!
    private let brewUpgradeCommand = "brew upgrade --cask ai-pet-usage"
    private let minInterval: TimeInterval = 24 * 3600   // 成功後每日節流
    private let failureBackoff: TimeInterval = 3600      // 失敗後退避,避免每次 relaunch 重打

    private enum Key {
        static let lastCheck = "update.lastCheckAt"       // 最後一次成功檢查
        static let lastAttempt = "update.lastAttemptAt"   // 最後一次嘗試(含失敗)
        static let skippedTag = "update.skippedTag"
    }

    /// 目前版本(數字);缺 CFBundleShortVersionString → 無法解析 → latestApplicable nil(fail closed)。
    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    /// source/dev 建置(AIPetUsageBuildChannel = source/dev):不做更新比對(版號非正式通道,
    /// 且數字版號 0.0.0 若比對會被任何 release 蓋過而誤報)。key 不存在(舊 release build)→
    /// 視為正式版照常檢查(向後相容)。
    private var isDevBuild: Bool {
        let channel = Bundle.main.infoDictionary?["AIPetUsageBuildChannel"] as? String
        return channel == "source" || channel == "dev"
    }

    /// single-flight:選單/設定/延遲自動可能併發,避免疊多個 fetch 與 modal alert。
    private var isChecking = false

    /// 手動:忽略節流與 skip,無更新時回報「已是最新」、失敗時回報錯誤。
    /// 自動:遵守每日節流、尊重 skip、靜默失敗(隱私與不打擾)。
    func checkForUpdates(manual: Bool) async {
        // 自動路徑:於此刻(啟動 8s 延遲之後)重讀開關,使延遲期間關閉也能生效。
        if !manual, !Self.autoCheckEnabled { return }
        // 併發防護:isChecking 於首個 await 前同步設定,MainActor 序列化 prologue → 真正單流。
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        // source/dev 建置:不比對更新(避免對 0.0.0 誤報「落後」)。
        if isDevBuild {
            if manual {
                presentInfo(title: "Development build",
                            text: "You’re running a source/development build. Update checks apply to released builds — see the project’s Releases page for the latest version.")
            }
            return
        }

        let defaults = UserDefaults.standard
        let now = Date()
        if !manual {
            if let last = defaults.object(forKey: Key.lastCheck) as? Date,
               now.timeIntervalSince(last) < minInterval { return }          // 每日成功節流
            if let attempt = defaults.object(forKey: Key.lastAttempt) as? Date,
               now.timeIntervalSince(attempt) < failureBackoff { return }    // 失敗退避
        }
        defaults.set(now, forKey: Key.lastAttempt) // 記錄嘗試(失敗退避基準)

        let releases: [GitHubRelease]
        do {
            releases = try await fetchReleases()
        } catch {
            if manual {
                presentInfo(title: "Couldn't check for updates",
                            text: "Please try again later.\n\n\(error.localizedDescription)")
            }
            return
        }
        defaults.set(Date(), forKey: Key.lastCheck) // 僅成功抓取才推進節流時點

        let skipped = manual ? nil : defaults.string(forKey: Key.skippedTag)
        guard let update = UpdateModel.latestApplicable(releases: releases,
                                                        currentVersion: currentVersion,
                                                        skippedTag: skipped) else {
            if manual {
                presentInfo(title: "You're up to date",
                            text: "AI Pet Usage \(currentVersion) is the latest version.")
            }
            return
        }
        present(update)
    }

    private func fetchReleases() async throws -> [GitHubRelease] {
        var req = URLRequest(url: releasesURL)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("AIPetUsage/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode([GitHubRelease].self, from: data)
    }

    private func present(_ release: GitHubRelease) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "A new version is available"
        let title = (release.name?.isEmpty == false) ? release.name! : release.tagName
        var info = "\(title) is available (you have \(currentVersion))."
        if let body = release.body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            info += "\n\nWhat’s new:\n" + whatsNew(from: body)
        }
        info += "\n\nInstalled via Homebrew? Update with:\n\(brewUpgradeCommand)"
        alert.informativeText = info
        alert.addButton(withTitle: "View Update…")     // 開 release 頁;刻意不從 app 內裝
        alert.addButton(withTitle: "Skip This Version")
        alert.addButton(withTitle: "Later")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // 只開 https 的 github.com 連結(防護:來自遠端 JSON 的 html_url 不可全信);
            // 不合規則退回已知安全的 releases 首頁。
            if let url = URL(string: release.htmlURL), url.scheme == "https",
               url.host == "github.com" || (url.host?.hasSuffix(".github.com") ?? false) {
                NSWorkspace.shared.open(url)
            } else {
                NSWorkspace.shared.open(URL(string: "https://github.com/F-e-u-e-r/ai-pet-usage/releases")!)
            }
        case .alertSecondButtonReturn:
            UserDefaults.standard.set(release.tagName, forKey: Key.skippedTag)
        default:
            break // Later:下次再提示(節流過後)
        }
    }

    /// 取 release body 的「What's new」內容(release-note 契約),否則退回前幾行非空。純顯示、截斷。
    private func whatsNew(from body: String) -> String {
        let lines = body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var out: [String] = []
        if let start = lines.firstIndex(where: { $0.lowercased().contains("what’s new") || $0.lowercased().contains("what's new") }) {
            for line in lines[(start + 1)...] {
                if line.hasPrefix("## ") { break }
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { out.append(line) }
                if out.count >= 8 { break }
            }
        }
        if out.isEmpty {
            out = Array(lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }.prefix(6))
        }
        let text = out.joined(separator: "\n")
        return text.count > 600 ? String(text.prefix(600)) + "…" : text
    }

    private func presentInfo(title: String, text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
