# MacHelper 交接清單

最後更新：2026-11-04。build `202611041531` 已裝在 `/Applications`。71 個測試通過，翻譯檢查沒有缺漏。

## 一、做完但還沒在實機上確認

- [ ] **選單列不再跳動**：數字改成預留最寬字串的寬度、靠右對齊。程序清單改成「黏性排序」，溫度依名稱固定排序，也拿掉了數字的滾動動畫。要實際看一陣子，確認選單列圖示和小面板的列都不再移動。
- [ ] **旭日圖在主視窗的大小**：離線截圖（`--snapshot-disk`）看起來超出邊界，推測是 ImageRenderer 給的尺寸不對，App 內應該正常。要打開「磁碟分析」實際掃描一次確認。
- [ ] **旭日圖／樹狀圖的互動**：
  - 游標旁的浮動提示
  - 旭日圖的路徑高亮，其他區塊變暗
  - 樹狀圖單擊只進一層
  - 單擊檔案會開快速查看
- [ ] **自動清理背景排程**：打開開關後，用 `launchctl print gui/$(id -u)/com.machelper.MacHelper.AutoClean` 和 `machelper autoclean --status` 確認有註冊。
- [ ] **解除安裝**：以 Hermes 為例，實際移除一次，確認 `~/.hermes`、背景服務、指令連結都被處理，`~/.claude` 這類資料會保留。
- [ ] **主視窗各頁**：一鍵優化、解除安裝、啟動項目的列表還是舊的版面，沒有套用新的設計元件。

## 二、還沒做的功能

- [ ] **電池充電上限**：這台是 Mac mini，沒有電池，也沒有 `CH*` SMC 鍵，無法測試。要在 MacBook 上先用 `mhprobe keys CH` 找鍵，再經由 Helper 寫入。
- [ ] **桌面小工具（Widget）**：需要 App Group，免費 Personal Team 能不能用還不確定。
- [ ] **系統層級的項目要管理員權限**：
  - 系統啟動項目（`/Library/LaunchDaemons` 等）只能看，不能停用或刪除
  - 解除安裝時 `/Library` 底下的殘留只列出來
  - 287 個 root 程序看不到 CPU 和記憶體用量

  做法：在 Helper 加 XPC 操作，協定升到 v4，並加嚴格的路徑和 label 白名單。
- [ ] **GPU 溫度**：這台的 HID 感測器沒有歸類為 GPU 的項目，GPU 頁的溫度顯示「–」。可以查 SMC 的 `Tg*` 鍵補上。
- [ ] **CPU 功耗**：IOReport 的 CPU energy 在 M4 上讀到 0，SMC 鍵的對應還沒做。
- [ ] **睡眠／喚醒測試**：風扇策略在喚醒後的 reassert 邏輯沒有在實機上驗證過。

## 三、設計還可以再修

- [ ] 主視窗的一鍵優化、解除安裝、啟動項目三頁，改用新元件：`HairlinePanel`、`KeyValueRow`、`ProcessTable` 風格的列表，以及鋅灰配色。
- [ ] 設定視窗（Form）仍是系統預設樣式。
- [ ] 像素圖：
  - 概覽圖示（儀表）的指針還可以再修
  - 可以為各硬體頁（CPU／GPU／記憶體／SSD／網路）畫專屬的小圖示，取代 SF Symbols
- [ ] 選單列圖示本身（`StatusItemView`）可以參考 Stats 的多種樣式再精緻化。
- [ ] `DiskAnalysisView.hoverCard` 已經沒有使用，可以刪掉。

## 四、常用指令與檔案

| 用途 | 指令／位置 |
|---|---|
| 建置並安裝 | `scripts/install.sh` |
| 單元測試 | `DEVELOPER_DIR=/Volumes/Smile-Data/Applications/Xcode-27.2.0.app/Contents/Developer swift test` |
| 翻譯：新增 / 檢查 | `scripts/l10n/add.py <catalog> 'English' '中文'`；建置後跑 `scripts/l10n/check.py` |
| 像素圖 | 改 `scripts/pixel/generate.py` → `scripts/pixel/review.sh <dir>` 預覽 → `scripts/pixel/build-assets.sh` |
| 截圖檢查 | `MacHelper --snapshot DIR`（選單列＋小面板各頁）、`--snapshot-window DIR [--dark]`（主視窗各頁，側欄會是空白）、`--snapshot-disk PATH DIR`（兩種圖表）。用第二個實例執行，不要關掉正在用的 App。 |
| Helper 自我測試 | `/Applications/MacHelper.app/Contents/MacOS/MacHelper --selftest` |
| CLI | `~/.local/bin/machelper --help`（說明見 `docs/CLI.md`） |
| 解除安裝的個別 App 規則 | `Sources/CleanEngine/UninstallRules/apps.json` |
| 設計元件 | `App/Design/Theme.swift`（顏色、Palette）、`App/Design/Components.swift` |

注意事項：
- 專案不是 git repository，沒有任何 commit。
- 簽章用 `Config/Local.xcconfig` 裡的 Personal Team（9Z9Y3M27R4）。
- 外接磁碟區分大小寫，所以內附 CLI 必須叫 `machelper-cli`。
