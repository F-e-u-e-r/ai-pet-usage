<div align="center">

# 🐾 AI Pet Usage

**一隻會對 AI 使用量做出反應的 macOS 桌面寵物 —— 配額、token 消耗、花費與工作節奏。**

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)
![Swift 5](https://img.shields.io/badge/Swift-5-F05138?logo=swift&logoColor=white)
![SwiftUI + AppKit](https://img.shields.io/badge/UI-SwiftUI%20%2B%20AppKit-6E4AFF)
![Local-first](https://img.shields.io/badge/privacy-local--first-2EA043)
[![License: AGPL-3.0-only](https://img.shields.io/badge/license-AGPL--3.0--only-blue)](LICENSE)

你的 AI 使用量化身為一隻活生生的夥伴 —— 不必開儀表板,也不必下指令。

[English](README.md) · **繁體中文**

</div>

```text
  /\_/\        tokens today   ▓▓▓▓▓▓▓░░░  68%
 ( o.o )       burn rate      steady · mood: focused
  > ^ <        next reset     in 2h 14m
```

**已實作並執行中。** 一個以 SwiftUI/AppKit 打造、從零寫起的選單列 app,帶一隻漂浮的像素寵物。此 repo 收錄可運作的 app(SwiftPM,[`Sources/`](Sources)),外加最關鍵的文件:究竟讀取了哪些本機檔案、為何要讀([`docs/DATA_SOURCES.md`](docs/DATA_SOURCES.md)),以及專案的走向([`ROADMAP.md`](ROADMAP.md))。

## ✨ 亮點

- 🍎 **原生 macOS** —— SwiftUI + AppKit 選單列 app,搭配漂浮的像素寵物面板。
- 📊 **三個頁面,而非一張擁擠的儀表板** —— Today、Limits、Projects,另有含使用熱區圖與連續紀錄的 Trends 頁。
- 🔌 **Provider 轉接器** —— Codex 與 Claude Code(含官方 5h/週限額);Grok Code 預設啟用(token 用量 + 方案等級;本 app 尚未接入 Grok 的官方限額);**OpenCode**(預設關 —— Settings → Providers;從其本機 SQLite 以唯讀 + 執行期欄位白名單讀取,提供各專案/模型的 token 用量與 opencode 回報成本);Antigravity 在研究閘後。
- 💳 **OpenRouter credits(opt-in,預設關)** —— 用 opencode 搭配 OpenRouter 預付 credit?開啟 Settings → Providers → OpenRouter credits,即可在選單列下拉面板與寵物泡泡看到剩餘額度(含 bar 與資料年齡)。只讀 opencode 存的 key、只連 openrouter.ai、不落地任何資料 —— 細節見 [`docs/DATA_SOURCES.md`](docs/DATA_SOURCES.md)。
- 🧮 **本機帳本 + 額度引擎** —— 配額、重置視窗、token 消耗率,以及來自定價註冊表(每筆皆註明來源與日期)的各模型花費。
- 🐕 **餵食/XP 迴圈與心情引擎** —— 寵物會對配額剩餘、消耗率、資料過期、專注時段、使用里程碑等訊號做出反應。
- 📄 **離線 HTML 報表匯出** —— 一份可離線閱讀的本機快照,涵蓋 Today、Limits、Projects、定價假設與資料品質註記。
- 👀 **即時更新與排程匯出** —— FSEvents 檔案監看讓資料保持新鮮;報表匯出可依排程執行。
- 🪶 **僅監看(低記憶體)模式** —— Settings → General:完全不建立漂浮寵物視窗與動畫,餵食/XP 引擎僅在完整寵物模式下實例化(切到僅監看即釋放);使用量追蹤、選單列、頁面、通知與匯出照常運作。
- ⌨️ **無頭 `aipet` CLI** —— 從終端機取得狀態、報表與 sprite 匯出。

## 📦 安裝(alpha)

**Homebrew(Apple Silicon)** —— 推薦:

```bash
brew install --cask F-e-u-e-r/tap/ai-pet-usage
```

一併處理安裝、`brew upgrade` 與 `brew uninstall`。**或**到 [Releases](https://github.com/F-e-u-e-r/ai-pet-usage/releases) 取得最新的 `AI-Pet-Usage-…-arm64.zip`,把 app 拖進 Applications。

從原始碼建置(約一分鐘;Intel Mac 必須這樣做):

```bash
git clone https://github.com/F-e-u-e-r/ai-pet-usage.git
cd ai-pet-usage
Scripts/build-app.sh
open "dist/AI Pet Usage.app"
```

- **需求**:macOS 14+。Homebrew cask 與預先建置的 zip 為 Apple Silicon;從原始碼建置需 Xcode Command Line Tools（`xcode-select --install`）。
- **首次啟動**:alpha 為 ad-hoc 簽章、**未經公證**,macOS 首次會封鎖。先嘗試打開 app,再到 **系統設定 → 隱私權與安全性** 選 **「強制打開」/「仍要打開」**(依 macOS 版本而定;僅在你信任此版本時)。Homebrew **不會**移除這一次性核准 —— 只有 Developer ID 公證能(規劃於 beta)。
- app 常駐於選單列;想讓它一直開著,可在 Settings 啟用 **launch at login**。可**檢查 GitHub 更新**(opt-in —— Settings → General → *Automatically check for updates*;僅版本檢查,不送任何使用資料),或從選單列隨時手動檢查。
- Developer ID 簽章/公證的下載規劃於 beta(見 [`ROADMAP.md`](ROADMAP.md))。

### Claude Code 官方限額(可選的 statusline hook)

Claude Code 會把官方限額(真實的 5 小時 / 週 `used_percentage`)餵給你在 `statusLine` 設定的指令。只要有 hook 把這份 payload 存到本機,app 就能顯示**官方回報**的限額 —— 不必手動設 token budget。

**最簡單:一行指令。** app bundle 內建的 `aipet` CLI 會全部裝好(寫入內建 hook、先備份 `settings.json`;若你的 `statusLine` 已指向一個 **script 檔**,就原封包住那個 script):

```bash
"/Applications/AI Pet Usage.app/Contents/MacOS/aipet" install-hook          # Homebrew / zip 安裝
.build/debug/aipet install-hook                                             # 從原始碼建置
```

加 `--dry-run` 可先預覽、不寫入。若你既有的 `statusLine` 是**複合指令**(含管線/參數)而非單一 script 路徑,它不會亂猜 —— 會拒絕並給指引、零改動,讓你自行手動包裹(見下)。symlink/dotfiles 管理的 settings、非 `command` 型 statusLine、非本工具管理的 hook 引用同樣一律拒絕且零改動;安裝完會印出復原指令。

**手動替代方案** —— 同一支 hook 在 repo 的 [`Scripts/claude-statusline-hook.sh`](Scripts/claude-statusline-hook.sh)(不在 app bundle 內 —— Homebrew 使用者請 clone repo 或從 release 的原始碼 zip 取得)。

全新安裝(還沒有自訂 statusline)—— 在 `~/.claude/settings.json` 加入:

```json
"statusLine": {"type": "command", "command": "/bin/bash /path/to/ai-pet-usage/Scripts/claude-statusline-hook.sh"}
```

**已有自訂 statusline?** 用包裹模式 —— 你的腳本**完全不會被修改**,其 stdin(原始 JSON 原封 byte)、stdout、stderr 與退出碼全部原樣透傳:

1. 打開 `~/.claude/settings.json`,找到現有的 `statusLine.command`,先把那串字存起來(復原 = 貼回去)。
2. 改成讓 hook 包裹你的指令:

```json
"statusLine": {"type": "command", "command": "/bin/bash /path/to/ai-pet-usage/Scripts/claude-statusline-hook.sh --wrap /Users/you/.claude/statusline-command.sh"}
```

- 包裹目標必須**可執行**;沒有執行權限的純 shell 腳本請寫 `--wrap /bin/bash -- /path/to/script.sh`。
- 額外參數放在 `--` 之後逐一傳遞(`--wrap /path/to/cmd -- --compact`);不接受整串複合 shell 指令。
- 落地內容是**凍結白名單**——恰好這個形狀,別無其他(session id、transcript 路徑、cwd 與任何層級的未知欄位一律丟棄):

```json
{"schema_version": 1, "captured_at": "<UTC ISO8601>",
 "model": {"id": "...", "display_name": "..."},
 "rate_limits": {"five_hour": {"used_percentage": 42, "resets_at": 1789000000},
                 "seven_day":  {"used_percentage": 81, "resets_at": 1789400000}}}
```

- hook **不發送任何網路請求**;檔案只存在 `~/Library/Application Support/AIPetUsage/`。payload 缺可用的 `rate_limits` 時**不會覆蓋上一份好檔**;資料新舊由 app 依檔案 mtime 判定。
- 替代方案:已有其他工具把 payload 存到 `~/.claude/usage-status.json` 的話,直接可用,毋需本腳本。

## 🚀 建置與執行

```bash
Scripts/swiftpm.sh build                 # 建置全部
Scripts/swiftpm.sh run usagecore-tests   # 執行測試套件
Scripts/build-app.sh                     # 產出 dist/AI Pet Usage.app
open "dist/AI Pet Usage.app"

.build/debug/aipet status                # 無頭狀態(CLI)
.build/debug/aipet sprites               # 匯出像素寵物拼貼表 → dist/sprite-preview/
.build/debug/aipet report --out r.html   # 無頭 HTML 匯出
```

> [!IMPORTANT]
> 一律透過 `Scripts/swiftpm.sh` 建置,而非裸用 `swift build`。

<details>
<summary>為何需要這層包裝(開發機的 CommandLineTools 怪癖)</summary>

這台機器的 CommandLineTools 安裝有兩個版本不一致的缺陷(過期的 `PackageDescription.private.swiftinterface` 與重複的 `SwiftBridging` modulemap),包裝指令碼在每次呼叫時繞過它們、且不觸動系統檔案。重裝 CLT(`sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install`)後,這些繞法會自動停用。此外 CLT 缺少 XCTest,因此測試以 `usagecore-tests` 執行檔搭配一個相容 XCTest 的迷你 harness 執行。

</details>

## 🗂️ Repo 結構

| 路徑 | 內容 |
| --- | --- |
| [`Sources/UsageCore`](Sources/UsageCore) | Provider 轉接器、帳本、額度引擎、定價、HTML 報表 —— 不相依 UI,因此解析邏輯日後可供 CLI 或 Tauri 版重用。各模型定價位於 [`model-prices.json`](Sources/UsageCore/Resources/model-prices.json)(每筆註明來源與日期;見 [`docs/DATA_SOURCES.md`](docs/DATA_SOURCES.md))。 |
| [`Sources/PetCore`](Sources/PetCore) | 餵食/XP 引擎與心情引擎 —— 只消費正規化後的 `UsageCore` 狀態。 |
| [`Sources/AIPetUsage`](Sources/AIPetUsage) | macOS app:選單列、漂浮寵物面板、三個頁面、設定。 |
| [`Sources/aipet`](Sources/aipet) | 供驗證與腳本化的無頭 CLI。 |
| [`Sources/usagecore-tests`](Sources/usagecore-tests) | 帶合成 fixture 的測試套件。 |
| [`docs/DATA_SOURCES.md`](docs/DATA_SOURCES.md) | 究竟讀取哪些本機檔案,以及為何。 |

## 🛡️ 隱私 —— 預設本機優先

- ✅ 只讀取已知的本機使用量檔案,或使用者設定的路徑。
- 🚫 不上傳使用量資料。共有兩個可選的網路呼叫,皆 opt-in 且預設關閉:更新檢查(Settings → General)向 GitHub 查詢最新版本;OpenRouter credits 檢查(Settings → Providers)向 openrouter.ai 查詢預付餘額 —— 兩者都不送任何使用資料。
- 🚫 不需要帳號憑證 —— 沒有 app 帳號、不用登入。(可選的 OpenRouter credits 監控只是重用 opencode 已存的 key、僅作為請求標頭;app 永遠不會向你要憑證。)
- 💬 每個權限提示都會說明為何需要。
- 🧩 Provider 轉接器保持隔離,資料來源變動不影響寵物引擎。

## ⚙️ 併行模型(app + CLI)

app 與 `aipet` CLI 共用 `~/Library/Application Support/AIPetUsage/`。這在設計上是安全的:

- CLI 的 `status`/`report` **預設唯讀** —— 直接呈現磁碟上既有的帳本與額度狀態(加 `--refresh` 才重新掃描 provider 記錄)。
- 每個寫入階段(app 刷新、CLI `--refresh`、`reindex`)都會取得一把獨占的跨行程檔案鎖(`refresh.lock`,以 flock 實作)。無法在 60 秒內取得鎖的行程會略過寫入,在資料品質註記回報「refresh skipped」,並提供快取資料。
- 寫入前,每個行程都會與另一方的進度收斂(檔案大小改變時重載帳本、以每檔 max-offset 合併掃描狀態、重載額度狀態)。事件 ID 以內容為準恆定,任何重疊都會去重而非重複計數。

## 🧭 產品方向

這個 app 結合兩個構想:

1. 一隻帶互動機制的輕量 **桌面寵物**。
2. 一個 **本機優先的 AI 使用量監看器**,對象包含 Codex、Claude Code、Antigravity、Grok Code,以及後續的 OpenCode。

寵物讓使用量狀態一目了然,無需開啟儀表板或執行指令,並對有用的訊號做出反應:配額剩餘、重置視窗、token 消耗率、資料過期、專注時段與使用里程碑。

此產品刻意避開擁擠的單頁儀表板:使用量分拆為三個頁面(Today、Limits、Projects),而 HTML 報表匯出屬於 alpha 範圍,作為同一份資料可離線閱讀的本機快照。

### 平台與技術棧

macOS 優先;Windows 與 Linux 規劃為 macOS MVP 穩定後的下一個平台步驟。

- **SwiftUI + AppKit** 負責桌面外殼、漂浮寵物視窗、選單列、通知與登入時啟動。
- **獨立的 usage core** 搭配 provider 轉接器,讓解析邏輯日後可供 Tauri 或 CLI 版重用。
- **本機 JSON 或 SQLite 儲存** 保存設定、成就與每日摘要。

Provider 優先序:**v1 核心** —— Codex 與 Claude Code · **已出貨、資料有限** —— Grok Code(預設啟用;token 用量 + 方案等級;本 app 尚未接入 Grok 官方限額)· **研究中** —— Antigravity(若出現可靠的本機資料來源)· **v2** —— OpenCode。

## 📚 文件

| 文件 | 內容 |
| --- | --- |
| [`ROADMAP.md`](ROADMAP.md) | 從產品定義到發佈的分階段交付計畫。 |
| [`docs/DATA_SOURCES.md`](docs/DATA_SOURCES.md) | 各 provider 轉接器讀取的確切本機檔案,以及額度計算政策。 |
| [`docs/HTML_REPORT_EXPORT_SPEC.md`](docs/HTML_REPORT_EXPORT_SPEC.md) | 本機靜態 HTML 報表匯出的需求。 |

## ⚖️ 授權

Copyright (C) 2026 F-e-u-e-r

本專案採用 [GNU AGPL-3.0-only](LICENSE) 授權。所有程式碼與像素美術(狗、貓、鳥的字串網格 sprite)皆為本 repo 原創,並適用同一授權。

此 app 讀取第三方工具(Claude Code、Codex 與 Grok CLI 的 session 記錄與狀態檔)產生的本機資料檔。讀取它們不改變其各自的所有權或條款,且本專案從不轉散佈其內容 —— 一切都留在你的機器上(見 [`docs/DATA_SOURCES.md`](docs/DATA_SOURCES.md))。
