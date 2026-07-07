# AI Pet Usage — 最終計畫（v0.2 → v1.0）

狀態：已定案的執行計畫（尚未動工）。
來源：合併自 2026-07-07 全庫審查報告（`fable review.txt`）與寵物重寫計畫
（原 `docs/PET_REWRITE_PLAN.md`，已由本文件取代）。
慣例：✋ 標記需要 owner 簽核的閘門；未過閘門不進下一步。

---

## 1. 現況基線（2026-07-07）

- 對照 `ROADMAP.md`：Phase 0–4 實質完成；Phase 5 完成一半（Projects 頁 + 範圍匯出
  已有；趨勢、排程報告、OpenCode 未做）；Phase 6（發佈）未開始。
- 測試：56 個測試、20,682 個 assertion 全數通過（`Scripts/swiftpm.sh run usagecore-tests`）。
- 安全審查結論：**無重大安全問題**。本機優先邊界落實（runtime 零網路 I/O）、HTML
  報告完整 escaping、flock 跨行程互斥 + 內容穩定 ID 去重皆已驗證。
- 價目表為最新（fable-5／opus-4-8／gpt-5.5，2026-06-24／2026-07-06 版），非阻塞項。
- 已知排程事項：**2026-09-01 Sonnet 5 由 $2/$10 調回 $3/$15**，屆時更新
  `model-prices.json`。

---

## 2. 待修清單（來自 2026-07-07 審查）

### 高嚴重度

**H1 — JSONLScanner 每行 removeSubrange 造成平方級複雜度**
`Sources/UsageCore/JSONLScanner.swift:44`。每解析一行就對 `carry` 移除前綴，`Data`
移除前綴會 memmove 剩餘全部位元組；4 MiB chunk 以 2 KB 行計約 4 GB 記憶體搬移。
首次索引「十餘秒」主因即此；幾百 MB 的歷史會惡化到分鐘級。
修法：改索引游標走訪，整個 chunk 消化完才一次丟棄已處理前綴。行為不變、回到線性。
測試：合成大檔的行為斷言（計時斷言選配）。

### 中嚴重度

**M1 — resets_at 永遠缺席時百分比被單調防護「釘死」**
`Sources/UsageCore/LimitEngine.swift:174-180`（`isSameWindow(nil,nil)==true` → 走
`:139` 的單調 max）。若 statusline 來源持續給 `used_percentage` 但無 `resets_at`，
看過 90% 之後真正 reset 後的低讀值會被永遠忽略。機率低但失效模式糟糕。
修法：nil-nil 且讀值比現值低 >20 個百分點時，比照 `:165-171` 視為 rollover 並發
reset transition。測試：nil-resets_at rollover 案例。

**M2 — 執行中打開 Notifications 開關不會請求系統授權**
`Notifier.requestAuthorization()` 只在 `AppModel.swift:72`（start）呼叫。啟動時關、
之後在 `SettingsViews.swift:60` 打開 → 授權停在 not-determined，通知靜默失敗直到
重啟。修法：toggle 為 true 時補呼叫 requestAuthorization（一行）。

**M3 — adapter 資料目錄在 init 凍結，啟動後才安裝的 CLI 偵測不到**
`ClaudeCodeAdapter.swift:27`、`CodexAdapter.swift:24` 的 roots 於 init 以存在性
filter 決定且不再重算，與 OnboardingCard 文案（run one session → Refresh 即見資料）
矛盾。修法：把候選目錄存在性檢查移進 `detectAvailability()`／`refreshUsage()`。
測試：init 後才建立目錄的 fixture。

### 低嚴重度（依影響排序）

| # | 問題 | 位置 | 修法 |
|---|---|---|---|
| L1 | FileLock 忙等（usleep 最長 60s）阻塞 Swift concurrency cooperative thread | `Persistence.swift:62-74` | 改 `Task.sleep` 的 async acquire |
| L2 | ledger 追加非原子：kill 中斷留半行，下次 append 接上 → 兩筆事件永久壞 | `UsageLedger.swift:73-78` | append 前檢查檔尾 `\n`，缺則補 |
| L3 | statusline 未變時 fold() 每刷新附加重複 history 樣本，擠掉有斜率的舊樣本；`sweepExpiredWindows`／`noteEstimatedBlock` 無條件 save() 每 45s 重寫 | `LimitEngine.swift:148-151` | 相同 (at, percent) 不 append；加 dirty flag |
| L4 | updateSettings fire-and-forget Task 可能亂序落地 | `AppModel.swift:187` | 遞增序號或 serial 消費者 |
| L5 | 手動拖曳寵物每個 move event 寫一次 settings.json | `PetPanel.swift:94-99` | debounce 或滑鼠放開才寫 |
| L6 | 還原寵物位置未夾限到可見螢幕（外接螢幕拔除後找不回） | `PetPanel.swift:51-57` | 對 `NSScreen.screens` visibleFrame clamp |
| L7 | `reading.windowMinutes` 為 0 時覆蓋正確值 | `LimitEngine.swift:143` | 僅讀值 >0 才覆蓋 |
| L8 | Full Reindex 清掉「暫時不可用」provider 的歷史 | `UsageCoordinator.swift:169-177` | reset 前檢查重掃集合，或 data-quality 註記 |

微項：`.gitignore` 全域 `*.html` 未來會擋 HTML fixture／文件，可改只 ignore 根目錄報告。

### 安全硬化（非漏洞）

| # | 項目 | 說明 |
|---|---|---|
| S1 | statusline hook 暫存檔名固定（`Scripts/claude-statusline-hook.sh:18`） | 多 session 併發互踩 → 瞬間壞 JSON（可自癒）。改 `mktemp` 同目錄 + `mv` |
| S2 | statusline payload 原封保存 | adapter 只解析 rate_limits（`ClaudeCodeAdapter.swift:94`），但檔案含 session id／transcript path／cwd；hook 可改只落地 `rate_limits` + `model` |
| S3 | 發佈簽章 | `build-app.sh:43` ad-hoc 本機夠用；對外發佈需 Developer ID + hardened runtime + notarization（歸入里程碑 M4）。App 必須讀 `~/.claude` 與 `~/.codex` → **不可能上 App Store sandbox**，走直接發佈 + Homebrew cask |

---

## 3. 寵物重寫（Pet v2 — 正面大頭吉祥物風格）

範圍：美術資料 + 風格規則 + 少量狀態對映調整。動畫引擎（`PixelAnimator`）、渲染器
（`PixelFrameView`）、驗收工具（`aipet sprites`）、幀格式測試全部沿用（皆 grid-agnostic）。

### 3.1 參考研究與授權邊界（依 `docs/LICENSING_STRATEGY.md`，只取概念、不碰程式碼與素材）

| 參考 | 可學的概念 | 授權 → 使用邊界 |
|---|---|---|
| `alvinunreal/openpets` | agent 活動反應狀態（thinking／editing／testing／success／error）；寵物畫廊幀預覽 | MIT（碼），素材不明 → 純概念參考 |
| `rullerzhou-afk/clawd-on-desk` | 風格最接近目標：正面像素吉祥物；12 狀態詞彙（idle／thinking／typing／building／subagent juggling／error／happy／notification／sweeping／carrying／sleeping）；閒置升級鏈（呵欠→瞌睡→睡著）；視線跟隨；游標喚醒 | **AGPL-3.0（碼）+ 美術 all rights reserved + Clawd 角色屬 Anthropic → 最嚴格：純概念。不碰碼與像素，且本 app 不得出現螃蟹／近似 Clawd 的角色**（註：本 repo 雖同為 AGPL-3.0、程式碼授權相容，但美術與角色 IP 不因此開放，clean-room 規則照舊） |
| `crafter-station/petdex` | 格式紀律：固定 sprite sheet 規格（8×9 sheet、72 幀、192×208 px/幀）、每狀態約 6 幀 ≈ 5.5 fps；「文件化的寵物格式」是社群皮膚的基礎 | MIT（碼），美術歸投稿者 → 只取格式概念，不進畫廊素材 |
| `basionwang-bot/HermesPet` | 成長階段（蛋→幼年→成年→成熟）對映互動等級；物種多樣性；一次性趣味互動（吃檔案、螢幕邊緣傳送門） | Apache-2.0 → 概念參考（重用程式碼合法但無需要） |

四者共同語言 = 重寫目標：**正面朝向觀眾、大頭、以臉部表達情緒**。

### 3.2 風格規則（可執行的繪製規範）

**鏡頭與版面**
- 所有狀態全正面；方向以傾斜 + 瞳孔偏移表達，任何狀態不畫側面。
- 腳踩底部 1–2 列；水平置中；頭不裁切。

**大頭比例**
- 網格 **24×24**（自 20×18 升級；正方形讓squash／bob 計算簡單）。
- 頭 ≥ 高度 55%、寬度 80–90%；頭身比約 60:40；無脖子；手 2px 短肢、腳 2×2 塊。

**輪廓與調色盤**
- **兩物種都要 1px 連續深色外框**（黑貓的教訓：外框決定任何桌布上的可讀性）。
- 每物種 ≤ 9 色（含外框）；每面最多 2 階 + 1 腮紅色；灰階需保留 ≥ 3 階亮度。

**臉部系統（情緒主載體）**
- 眼睛 3×3 + 固定角落 1px 高光；眼態：張開／半瞇（tired）／閉弧「∪」（sleep、happy）／
  星光（celebration）。
- 眉毛 1px 三態：平（neutral）／揚（alert、confused）／皺（warning、exhausted）——
  **警示先靠皺眉，徽章其次**。
- 嘴型：2px 平線／3×2 開口笑／「o」驚訝／狗 happy 吐舌。腮紅 2×1（貓常駐、狗於
  happy／eating）。
- 瞳孔在 idle／happy／focused 時看向觀眾；±1px 偏移表達走向與好奇。

**物種識別（灰階必須存活）**
- 狗：垂耳三角掛頭側、頭更圓、舌頭。
- 貓：尖耳含內色、鬍鬚、尾巴捲到身前。**貓綠眼專注機制為本 app 原創，保留、改畫正面版**。

**動態規則**
- 一律整數像素位移（既有規則）。
- idle 呼吸：隔幀 1px 身體squash，底列錨定。
- 走路：**不畫腿部循環** —— 1px 垂直 bob + 1px 交替傾斜；渲染器 `flipped` 旗標改語意為
  「傾斜方向」（正面圖近對稱，翻轉安全）。
- 情緒姿勢限 ±2px squash/stretch，表達靠臉。

### 3.3 狀態詞彙與幀預算（`PixelAnimState` cases 不變，全部重繪）

| 狀態 | 幀數 | 備註 |
|---|---|---|
| idle | 2 | 呼吸 squash |
| walk | 4 | bob + 傾斜循環 |
| sit →「attentive」 | 2 | 正面豎耳姿，取代側面坐姿 |
| sleep | 2 | 閉弧眼、慢呼吸 |
| eat | 4 | 食物在身前、咀嚼循環 |
| jump（celebration） | 4 | 蹲 → 伸展 → 空中 → 落地 |
| happy | 4 | 狗尾尖+吐舌；貓尾擺 |
| alert（warning） | 2 | 皺眉 + 耳提起 |
| focusStart / focusedActive / focusEnd（貓） | 4 / 2 / 3 | 機制保留、正面重繪 |
| micro：blink / earTwitch / tailFlick / whiskerTwitch | 各 2 | overlay one-shot，引擎不動 |

每物種約 30 循環幀 + 8 微動作幀。

**Phase-2 選配（各註明概念出處，皆非本次範圍）**
- `working` 狀態（打字手 + 「…」）：openpets／clawd-on-desk 概念；由既有 `focused`
  mood 驅動，可取代狗的 `sit` 對映——建議排在 M3 的 FSEvents 檔案監看之後（即時反應
  才跟得上 agent 活動）。
- 睡前呵欠 one-shot：clawd-on-desk 概念；以 `enterTransition(to: .sleep)` 實作，引擎已支援。
- 依 `PetStateData.level` 的成長階段（蛋／幼年／成年）：HermesPet 概念；美術成本 ×3，
  待 v2 穩定後再議。

### 3.4 授權防線

- 不從參考截圖轉錄任何像素資料；所有幀依 §3.2 數字規則手繪為字串網格。
- **不得出現螃蟹或近似 Clawd 的角色**（Anthropic 角色 IP；clawd-on-desk 美術 ARR）。
- 概念出處已記錄於 §3.1；若日後以生成圖像當視覺參考，須在本文件記錄 prompt／日期／
  工具（LICENSING_STRATEGY 資產規則）。
- 無第三方程式碼／素材引入 → 不需 `THIRD_PARTY_NOTICES.md`。

### 3.5 Pet v2 驗收標準

- 50% 尺寸下兩物種可辨識，且 happy／warning／sleep 不靠徽章可區分。
- 灰階下物種靠剪影可分（垂耳 vs 尖耳+鬍鬚+捲尾）；貓專注態不靠綠色可讀。
- idle／happy／focused 的瞳孔面向觀眾。
- 全部幀通過 well-formed 測試；外框連續；位移皆整數像素。
- monitor-only 與 reduce-motion 靜態姿勢無回歸。

---

## 4. 里程碑時程（單一時間軸）

### M1 — v0.2 鞏固（1–2 週；發佈前必做）

1. 修 H1 + M1 + M2 + M3（各附測試，見 §2）。
2. 修 L1–L3（其餘 L4–L8 視時間；S1 順手做）。
3. 補 **launch-at-login**（ROADMAP Phase 1 遺留交付物；`SMAppService.mainApp` +
   Settings Toggle）。
4. 價目維運自動化：release checklist／cron 跑 `update-price-list.py`；登記 2026-09-01
   Sonnet 5 價格切換。
5. 收尾驗證：測試全綠 + `build-app.sh` + 手動冒煙（選單列深淺色、panel 快捷鍵、hover）。

### M2 — Pet v2 重寫（2–3 週；Phase 0 完成後美術可與 M1 後半並行）

1. **Phase 0**：規格凍結（本文件 §3）✋；更新 `PixelArtTests`（24×24 不變量、每狀態
   最少幀數、調色盤 ≤ 9）。
2. **Phase A（狗）**：先畫 idle + blink → `aipet sprites` 出 contact sheet（100%／50%／
   灰階）→ ✋ **風格在此鎖定**；批准後照 §3.3 順序補完，更新 `microAnimations` 幀參照。
3. **Phase B（貓）**：同流程；焦點三態正面重繪。
4. **Phase C**：對映微調（狗 focused → attentive；選配呵欠轉場），約 50 行；
   `PixelAnimator` 不動。
5. **Phase D**：更新 `SpriteExport.htmlHeader` 驗收清單為 §3.5 → 重出
   `dist/sprite-preview` → 64/96/160pt 實機冒煙（深淺桌布）→ 測試全綠 → ✋ 簽核合併。

### M3 — v0.3 報告與進階（2–4 週）

1. **趨勢視圖**：ledger 加日粒度聚合（`dailyBuckets(in:)`）→ Trends 分頁（7/30/90 天
   曲線 + 週對比）→ HTML 報告對應 section。純本機、零新依賴。
2. **排程報告**：Settings「每日自動匯出」開關 → app 管理 `~/Library/LaunchAgents`
   plist，執行既有 `aipet report --days N`。
3. **儲存層決策閘門** ✋：以真實資料量 profile 全量載入＋排序；若載入 >1–2s 或
   RAM >100 MB → `UsageLedger` 後端換 SQLite（介面已隔離，替換成本低）。
4. **Antigravity／Grok Code adapter 促轉**：照 `docs/PROVIDER_RESEARCH.md` checklist
   確認資料源，過閘門才實作（合成 fixture → adapter → 測試 → 註冊；pet/UI 零改動）。
5. **FSEvents 檔案監看取代 45s 輪詢**：監看 `~/.claude/projects` 與 `~/.codex/sessions`，
   變更觸發 refresh。省電、寵物反應即時——**Pet Phase-2 的 `working` 狀態依賴此項**。

### M4 — v0.4 → v1.0 發佈（2–4 週；Apple 帳號申請在 M1 期間先行送出）

1. 簽章與公證：Developer ID Application 憑證 → `build-app.sh` 加 hardened runtime +
   `notarytool` + staple。不做 sandbox（必須讀 `~/.claude`／`~/.codex`），README／隱私頁
   明講原因。
2. CI 釋出管線：GitHub Actions macOS runner（無需本機 CLT workaround）：測試 → build →
   簽章 → DMG/ZIP → GitHub Release。
3. Homebrew cask + 版本策略；Sparkle 自動更新（或先做手動 Check for Updates）。
4. 首次啟動 onboarding：隱私說明視窗（讀哪些檔、為什麼、什麼都不上傳）。
5. **app icon：以 Pet v2 美術衍生**（M2 產出直接複用）。
6. AGPL-3.0 發佈合規：release 附源碼連結；cask 註明授權。

### Post-v1

- Windows/Linux：以 adapter／ledger／limit 的**規格與檔案格式**（JSONL schema、
  scan-state、dedupe 規則）為可移植資產，用 Rust 重寫 core（Tauri 殼），同一份 fixture
  對齊行為。
- 更多 adapter（Cursor、Gemini CLI、OpenRouter/LiteLLM）、社群皮膚格式（petdex 概念：
  文件化的 sprite 格式 + 匯入器）、成長階段、成就擴充。

**排序邏輯**：M1 先行，因為 scanner 效能與通知授權會在「第一個陌生用戶、第一份大歷史」
時立刻現形；M2 美術工作獨立、可與 M1 後半並行，且產出（角色）是 M4 icon 與行銷素材的
前置；M3 是現有用戶價值最高的增量；M4 的簽章公證有外部等待時間，帳號申請提前到 M1。

---

## 5. 決策閘門（✋ 彙總）

| 閘門 | 時點 | 決策內容 |
|---|---|---|
| G1 | M2 Phase 0 | 本計畫 §3 風格規格簽核 |
| G2 | M2 Phase A | 狗 idle+blink contact sheet 風格鎖定 |
| G3 | M2 Phase D | Pet v2 全套 sheet + 實機冒煙簽核合併 |
| G4 | M3-3 | ledger 是否遷移 SQLite（依 profile 數據） |
| G5 | M3-4 | Antigravity／Grok Code 資料源是否過促轉閘門 |
| G6 | M4 | 首個對外 release 的 go/no-go（簽章鏈 + onboarding 完備） |

## 6. 風險

- **外部等待**：Apple Developer 帳號審核（提前到 M1 申請）；notarization 首次配置踩坑。
- **美術主觀性**：Pet v2 以 G2 提前鎖風格，避免整套畫完再翻案。
- **來源格式漂移**：provider 本機格式可能改版（ROADMAP 既有風險）；adapter 隔離 +
  data-quality 註記已是緩解，M3-5 的檔案監看讓異常更快被看見。
- **角色 IP**：嚴守 §3.4（尤其不做螃蟹角色），避免與 Anthropic／參考專案的角色混淆。
- **價格時效**：2026-09-01 Sonnet 5 調價已入 M1-4 checklist。

## 7. 每里程碑完成定義（DoD）

- **M1**：§2 高+中全修 + L1–L3；新增測試涵蓋各修復；56+ 測試全綠；launch-at-login 可用。
- **M2**：§3.5 驗收全過；`dist/sprite-preview` 更新；G3 簽核。
- **M3**：Trends 頁 + 排程匯出可用；G4 決策落地；（若過 G5）新 adapter 附 fixture 測試。
- **M4**：陌生 Mac 從下載到理解 <5 分鐘（ROADMAP 驗收條件）；公證通過的 DMG；cask 可安裝。
