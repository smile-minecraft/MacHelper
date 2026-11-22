<p align="center">
  <img src="docs/images/mascot.gif" width="200" alt="MacHelper 史萊姆：呼吸、揮手、跳躍、慶祝">
</p>

<h1 align="center">MacHelper</h1>

<p align="center">
  <b>專為 Apple Silicon 打造的原生 macOS 系統監控、風扇控制、清理、磁碟分析與 AI 就緒 CLI 工具——本機優先、完全開源。</b>
</p>

<p align="center">
  <a href="https://github.com/smile-minecraft/MacHelper/releases/latest"><img src="https://img.shields.io/github/v/release/smile-minecraft/MacHelper?label=Release&color=5b8def" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-1f2430" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Apple%20Silicon-arm64-1f2430" alt="Apple Silicon">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-4cc38a" alt="MIT license"></a>
  <a href="https://smile-minecraft.github.io/MacHelper/"><img src="https://img.shields.io/badge/Website-Docs-5b8def" alt="官方網站與說明文件"></a>
</p>

<p align="center">
  <a href="README.md">English</a> ·
  <b>繁體中文</b> ·
  <a href="README.zh-Hans.md">简体中文</a> ·
  <a href="README.ja.md">日本語</a> ·
  <a href="README.ko.md">한국어</a> ·
  <a href="README.es.md">Español</a>
</p>

<p align="center">
  <a href="#為什麼選擇-machelper">為什麼選擇 MacHelper</a> ·
  <a href="#安裝">安裝</a> ·
  <a href="#功能">功能</a> ·
  <a href="#隱私與遙測">隱私</a> ·
  <a href="#第一次打開">第一次打開</a> ·
  <a href="#命令列">CLI</a> ·
  <a href="#搭配-ai-agent-使用">AI Agent</a> ·
  <a href="#常見問題">常見問題</a> ·
  <a href="#從原始碼建置">建置開發</a>
</p>

<p align="center">
  <img src="docs/images/menubar.png" width="320" alt="選單列上的 MacHelper：CPU 折線、記憶體和溫度">
</p>

<p align="center">
  <img src="docs/images/overview.png" width="860" alt="概覽：健康分數、即時數值和最耗資源的 App">
</p>

---

MacHelper 是免費、以 MIT 授權開源的選單列 App 與命令列工具，使用原生 Swift 撰寫，適用於搭載 macOS 14 或以上版本的 Apple Silicon Mac。它將**系統監控**（CPU、GPU、記憶體、溫度、風扇、功耗、電池、磁碟與網路）、**風扇控制**、**快取與垃圾清理**、**磁碟空間分析**以及 **App 解除安裝**整合在同一個輕量級 App 中。

同時內建支援 `--json` 輸出的 `machelper` 命令列工具、一鍵去識別化診斷報告（`machelper report --json`），以及專為 Claude Code、Codex、OpenCode 等 AI 程式助理打造的技能——一律先預覽再執行，移除任何項目之前都會先向你確認。

## 為什麼選擇 MacHelper

不用同時安裝五套付費工具，MacHelper 用一個原生 App 就能搞定全套日常維護：

| 核心能力 | 可取代工具 | MacHelper 的做法 |
|---|---|---|
| **系統與選單列監控** | iStat Menus | 原生 SwiftUI/AppKit 感測器讀數、效能/節能核心分流、1 小時/24 小時/7 天歷史、8 種選單列樣式 |
| **風扇轉速與曲線** | Macs Fan Control | 固定轉速或自訂溫度曲線、「只升不降」模式、依執行中 App 或電源來源切換設定檔 |
| **系統清理與維護** | CleanMyMac | 宣告式清理規則、預設只預覽不刪除、中高風險移至垃圾桶、嚴格受保護路徑 |
| **磁碟空間分析** | DaisyDisk | 高速 `getattrlistbulk` 旭日圖與矩形樹狀圖、懂 APFS 複製檔的重複偵測、空間成長追蹤 |
| **App 完整解除安裝** | AppCleaner | 追蹤 Bundle ID、內嵌 Helper、容器、launchd 與 Homebrew zap 規則，外加孤兒殘留清理 |
| **AI Agent 自動化** | *MacHelper 獨有* | `machelper report --json` 去識別化診斷報告、`--yes` 安全確認閘道、內建 Agent 技能 |

> **免費 · 開源（MIT）· 原生 Swift · Apple Silicon · 預設本機優先**

## 安裝

```sh
brew install --cask smile-minecraft/tap/machelper
```

也可以從 [Releases](https://github.com/smile-minecraft/MacHelper/releases/latest) 下載 `MacHelper-<版本>.dmg`，並將 **MacHelper** 拖進「應用程式」。每個正式版本都使用 Developer ID 簽署並通過 Apple 公證，可直接打開；檔案校驗碼公布於各發布頁的 `SHA256SUMS.txt`。你也可以前往 [MacHelper 官方網站](https://smile-minecraft.github.io/MacHelper/) 瀏覽功能介紹與版本亮點。

**自動更新：** MacHelper 會在背景檢查新版本，並在側邊欄、選單列面板與設定中顯示 **更新到 x.y.z** 按鈕——在你主動點擊前不會進行任何安裝。更新視窗會依照你選定的 App 語言顯示更新內容。

## 功能

<table>
  <tr>
    <td width="50%" valign="top">
      <h3>系統監控</h3>
      <img src="docs/images/monitor.png" alt="監控：CPU、GPU、記憶體、溫度、風扇和耗電圖表，附警戒線">
      <p>提供 CPU（效能核心與節能核心）、GPU、記憶體壓力、溫度、風扇、功耗、電池、磁碟與網路吞吐量的即時圖表與每分鐘歷史（1 小時、24 小時或 7 天），並在記憶體與溫度圖表加上警戒線。選單列的每一項都可以自訂為文字、折線、直條、長條、圓環、方塊、熱度膠囊或雙線。</p>
    </td>
    <td width="50%" valign="top">
      <h3>健康檢查</h3>
      <img src="docs/images/health.png" alt="健康檢查：分數、最近 24 小時的數值和可用空間變化">
      <p>根據最近幾小時的系統歷史、可用空間與背景項目計算健康分數，明確指出扣分原因與建議做法。同時唯讀檢查 Gatekeeper、FileVault、防火牆、系統完整性保護（SIP）、自動安全性更新與 XProtect 狀態。</p>
    </td>
  </tr>
  <tr>
    <td colspan="2" valign="top">
      <h3>磁碟分析</h3>
      <img src="docs/images/disk.png" alt="磁碟分析：個人資料夾的旭日圖和最大的資料夾">
      <p>互動式旭日圖與矩形樹狀圖（點擊任何資料夾即可深入檢視）、支援種類與時間篩選的最大檔案清單、重複檔案偵測（正確辨識 APFS 複製檔與硬連結）、跨次掃描容量變化比對，以及針對久未使用大檔案與異常膨脹資料夾的空間建議。將項目拖進收集籃，即可一次移到垃圾桶。</p>
    </td>
  </tr>
</table>

| 功能領域 | 特色說明 |
|---|---|
| **風扇控制** | 支援自動、固定轉速或溫度曲線（安靜、平衡、效能、自訂）、「只升不降」模式、硬性安全上限，並可依目前執行的 App 或電源來源自動切換設定檔。 |
| **一鍵優化** | 宣告式清理規則搭配預覽：低風險快取直接刪除，中高風險項目移至垃圾桶。內建受保護路徑、永不清理清單、操作記錄、系統維護作業、專案建置產物清理與排程自動清理。 |
| **App 解除安裝** | 透過 Bundle ID、內嵌 Helper、權限、容器資訊、`launchd` 擁有者、Homebrew zap 清單與各 App 規則找出殘留項目。僅憑名稱比對到的項目會標示提醒確認，也能掃描已刪除 App 的遺留檔案。 |
| **啟動項目** | 管理你的使用者 Launch Agent（停用、啟用、移除），並檢視所有使用者 Agent 與系統 Daemon，清楚標出所屬 App 與失效項目。 |
| **Homebrew 更新** | 直接在 MacHelper 內檢視並更新透過 Homebrew 安裝的 App 與 Cask。 |
| **警示通知** | CPU 溫度過高、記憶體壓力危急或磁碟空間不足時發出提醒。 |
| **可選的歷史記錄** | 程序、感測器與核心歷史預設關閉。程序歷史僅保留名稱、CPU 與記憶體（不記錄路徑、參數或使用者名稱），保留期限可設為 1–30 天。 |
| **史萊姆吉祥物** | 會跟著 Mac 狀態變色（藍、黃、紅），對點擊、游標停留、拖曳與過熱或清理完成等事件做出反應，並完整支援「減少動態效果」與 VoiceOver。 |
| **多國語言** | 支援英文、繁體中文、簡體中文、日文、韓文與西班牙文，可在 **設定 → 一般 → 語言** 獨立於系統語言指定。 |

## 隱私與遙測

- **預設本機優先（Local-first）。** MacHelper 所量測、掃描與儲存的一切資料都留在你的 Mac 上，不需要帳號、沒有雲端同步，也沒有任何背景追蹤。除了檢查更新外，除非你主動開啟，否則不會發出任何網路連線。
- **可選遙測（預設關閉）。** 你可以在 **設定 → 一般 → 隱私權與診斷** 自願開啟，僅分享完全匿名的功能使用次數與粗略效能診斷（App 版本、macOS 版本、晶片系列與去識別化計數器）。
- **零敏感資料。** 絕不收集任何檔案路徑、程序名稱、磁碟內容、主機名稱或個人識別資訊。送出前可在設定內預覽完整的 JSON 負載內容，也能隨時關閉——一旦關閉，系統會立即清除匿名識別碼與待傳送佇列。

## 第一次打開

MacHelper 會一次一個地引導你開啟兩項權限。兩項皆為選用，不開啟也能正常使用其他所有功能：

1. **完全取用磁碟**讓磁碟分析與清理能夠讀取受保護的位置，例如「郵件」下載項目與其他 App 的快取。請前往 **系統設定 → 隱私權與安全性 → 完全取用磁碟** 打開 MacHelper，引導視窗會自動偵測完成。受系統完整性保護（SIP）的資料夾即使開啟也無法讀取，磁碟分析會另外列出。
2. **Helper** 是一個輕量的 root 背景常駐程式，負責風扇控制、系統快取與記錄檔清理、系統背景項目與系統程序用量。引導視窗會協助安裝、打開 **系統設定 → 一般 → 登入項目與延伸功能** 讓你核准，並確認其正常回應。它會驗證每個呼叫者的程式碼簽章。若未啟用，可點擊側邊欄底部的 **設定 Helper…** 重新開啟引導。

## 命令列

MacHelper 隨附 `machelper` CLI（Homebrew 安裝時會自動建立連結）。所有指令預設僅預覽並支援 `--json`，非常適合腳本與 AI Agent 使用。執行 `machelper guide` 可查看總覽，執行 `machelper <指令> --help` 可查看各指令說明。

```sh
machelper report --json                 # 去識別化的完整系統診斷報告
machelper status --json                 # 即時硬體、溫度、風扇與電池狀態快照
machelper clean                         # 預覽將被清理的項目
machelper clean --max-risk low --yes    # 僅清理低風險項目
```

## 搭配 AI Agent 使用

當你請 AI 助理（Claude Code、Codex、OpenCode 等）幫忙診斷 Mac 為何變慢或發燙、釋放磁碟空間、清理 `node_modules` 或 Xcode 殘留檔、完整解除安裝 App，或檢查啟動項目時，`machelper` 提供了安全且結構化的操作介面。

- **一次取得去識別化診斷報告（`machelper report`）。** 執行 `machelper report --json`（或 `machelper report --format markdown`），即可一次產生涵蓋硬體規格、即時指標、健康分數、儲存空間、安全性稽核、清理預覽與啟動項目的完整診斷報告。報告預設會自動遮罩個人使用者名稱、家目錄路徑、主機名稱、IP 與 MAC 位址，且 JSON 輸出包含結構化的 `suggestedActions` 與 `availableTools`，讓 AI Agent 能安全串接後續的 `machelper` 指令。
- **預設安全。** 所有會修改系統的指令預設都只做預覽，直到明確加上 `--yes` 才會執行。移除的項目預設移到垃圾桶（除非加上 `--permanent`），受保護路徑（鑰匙圈、郵件、照片、`~/.ssh`、`~/Documents` 等）永遠無法刪除。
- **機器可讀。** 各指令皆支援 `--json`，固定提供 `schemaVersion` 欄位與可預期的結束代碼，並可透過 `machelper --experimental-dump-help` 取得完整 JSON 指令樹。
- **內建 Agent 技能。** 執行 `machelper skill install claude` 或 `machelper skill install codex`（亦可於設定頁面安裝）會寫入 `SKILL.md`，要求 Agent 一律先檢查／預覽，並先取得使用者同意再執行變更。

```sh
brew install --cask smile-minecraft/tap/machelper
machelper guide                          # Agent 應優先閱讀的操作指南
machelper report --json                  # 完整去識別化診斷報告 + suggestedActions
machelper insights ~ --json              # 久未使用的大型檔案與膨脹資料夾
machelper clean --json                   # 預覽清理；加上 --yes 前先向使用者確認
```

給語言模型閱讀的結構化索引位於 [llms.txt](llms.txt)。

## 常見問題

**有沒有免費開源、可以取代 CleanMyMac 或 iStat Menus 的 App？**
有的。MacHelper 採用 MIT 授權，把系統清理、選單列監控、風扇控制、磁碟分析與 App 解除安裝整合在一個原生 App 中，無須帳號，也不用訂閱。

**怎麼控制 Apple Silicon Mac 的風扇轉速？**
安裝 MacHelper 並設定 Helper（首次啟動會有引導）。之後便能讓風扇自動運轉、固定轉速，或依自訂溫度曲線運作，並支援硬性安全上限與依 App 或電源來源自動切換設定檔。

**如何取得給 AI 助理分析的系統報告而不外洩個人隱私？**
執行 `machelper report --json`（或 `--format markdown`）。它會一次彙整硬體、即時指標、健康分數、儲存空間、安全性檢查、清理預覽與啟動項目，同時預設自動移除使用者名稱、路徑、主機名稱、IP 與 MAC 位址。

**怎麼從終端機釋放 Mac 的磁碟空間？**
先執行 `brew install --cask smile-minecraft/tap/machelper`，再用 `machelper clean` 預覽、`machelper clean --max-risk low --yes` 清理低風險快取；使用 `machelper insights ~` 找出久未使用的超大檔案與膨脹資料夾，或用 `machelper purge --path ~/Developer` 清除 `node_modules`、`target`、`.build` 等建置產物。

**怎麼把 Mac App 連同殘留檔一起完整解除安裝？**
執行 `machelper uninstall "App 名稱"` 預覽偏好設定、快取、容器、啟動項目與 Homebrew zap 項目，加上 `--yes` 即可移至垃圾桶。執行 `machelper uninstall --orphans` 可找出已刪除 App 的遺留檔案。

**Intel Mac 或較舊的 macOS 能用嗎？**
不能。MacHelper 僅支援執行 macOS 14 或以上版本的 Apple Silicon Mac。

**MacHelper 會收集什麼資料？**
預設情況下，除了檢查更新之外不會有任何資料離開你的 Mac。若你在 **設定 → 一般 → 隱私權與診斷** 主動開啟遙測，MacHelper 只會傳送完全匿名的使用次數與粗略效能診斷（App 版本、macOS 版本、晶片系列），不包含任何檔案路徑、程序名稱或個人識別資訊，你隨時都能檢視確切的 JSON 內容並關閉。

## 從原始碼建置

需求：Apple Silicon Mac、Xcode 26 或以上版本，以及 [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）。執行 `make` 可列出所有可用目標。

```sh
make setup      # 檢查工具、下載 Sparkle、產生 MacHelper.xcodeproj
make open       # 用 Xcode 打開專案，按 ⌘R 建置並執行
make run        # 或建置 Debug 版到 build/ 並直接開啟
make test       # 執行 Swift 套件的單元測試
make install    # Release 建置 → /Applications/MacHelper.app 並重新啟動
```

日常開發建置會輸出至 `build/`，不會動到 `/Applications`。從 `build/` 啟動前請先結束已安裝的 MacHelper，因為兩者共用同一份設定與資料。若要測試 root Helper 相關變更（風扇控制、系統清理），使用 `make install` 最方便。增減原始碼檔案後請執行 `make project`；在沒有電池的桌上型 Mac 上可使用 `make run ARGS=--demo-battery` 模擬電池讀數。

**效能分析工具：** MacHelper 在掃描、感測器取樣與 UI 熱點路徑皆內建 Apple 原生 `OSSignposter` 標記，開發時可直接執行 `scripts/perf/xctrace-profile.sh` 從命令列擷取 Instruments 追蹤檔。

<details>
<summary><b>開發者參考：本機簽章設定、專案結構、截圖匯出、發布與翻譯</b></summary>

簽章覆寫（`Config/Local.env`、`Config/Local.xcconfig`）、完整目錄結構、README 截圖與史萊姆 GIF 匯出參數、發布流程（含各語言更新說明）以及 String Catalog 翻譯流程，請參閱[英文 README](README.md#building)。

</details>

## 授權

MIT — 詳見 [LICENSE](LICENSE)。
