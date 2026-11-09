# MacHelper

[English](README.md) · 繁體中文 · [简体中文](README.zh-Hans.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Español](README.es.md)

給 macOS 14 以上使用的全功能 Mac 工具，所有資料都留在你的 Mac 上：風扇控制、選單列系統監控、一鍵清理、磁碟分析、App 解除安裝和開機啟動項目管理。以 MIT 授權開源。

## 功能

- **選單列監控**：CPU（效能核心與節能核心）、GPU、記憶體壓力、磁碟與網路速度、溫度、風扇、耗電和電池，每一項都能選文字、折線、長條或圓環顯示。也會列出最耗 CPU 和記憶體的程序。
- **歷史記錄**：每分鐘一筆平均值，預設保留 7 天，可在「設定 → 一般 → 資料管理」改成 1、3、7、14 或 30 天。可以看最近 1 小時、24 小時和 7 天。
- **可選的程序、感測器與核心歷史**：預設關閉，在「設定 → 一般 → 資料管理」分別開啟。程序歷史只記錄程序名稱、CPU 和記憶體用量，不記錄路徑、命令列參數或使用者名稱，每分鐘只保留 CPU 和記憶體各前 10 名。
- **通知**：CPU 溫度過高、記憶體壓力過大、磁碟空間不足時提醒你。
- **風扇控制**：自動、固定轉速或溫度曲線（安靜、平衡、效能、自訂），「只升不降」模式、硬性安全上限，並可依正在執行的 App 或電源自動切換設定檔。透過會驗證呼叫者簽章的 root Helper 執行。
- **一鍵清理**：先預覽再清理。低風險的快取和記錄檔直接刪除，中高風險的項目移到垃圾桶。有受保護路徑、永不清理清單、操作記錄、維護作業、專案建置產物清理，以及低風險項目的定時自動清理。
- **磁碟分析**：旭日圖和樹狀圖、可依種類和時間篩選的最大檔案、重複檔案（能辨識 APFS 複製檔和硬連結）、和上次掃描相比的變化，以及一次移到垃圾桶的收集區。
- **空間建議**：找出半年以上沒用的大檔案和看起來異常膨脹的資料夾，並在圖表上標示出來。
- **App 解除安裝**：用 Bundle ID、內嵌 Helper、權限、容器資訊、launchd 擁有者、Homebrew zap 清單和各 App 規則找出 App 留下的東西，只靠名稱比對到的項目會標示出來讓你確認。也能找出已刪除 App 的殘留檔案。
- **開機啟動項目**：你的 Launch Agent（停用、啟用、移除）、所有使用者的 Agent 和系統 Daemon，並標出所屬 App 和已經失效的項目。
- **Homebrew 更新**：更新用 Homebrew 安裝的 App。
- **自動更新**：背景檢查並下載新版本，安裝前詢問。
- **安全性檢查**：讀取 Gatekeeper、FileVault、防火牆、系統完整性保護、自動安全性更新和 XProtect 的狀態（只讀取，不會更改）。
- **命令列工具**：所有功能都能用指令操作，方便自動化和 AI Agent 使用。預設只預覽，每個指令都支援 `--json`。執行 `machelper guide` 看總覽，`machelper <指令> --help` 看各指令說明。
- **AI Agent Skill**：可以為 Claude Code 和 Codex 安裝 Skill，讓它們安全地使用 MacHelper：一律先預覽，刪除前一定先問你。
- **語言**：英文、繁體中文、簡體中文、日文、韓文和西班牙文。可在「設定 → 一般 → 語言」指定，不跟隨系統語言。

## 安裝

從 [Releases](https://github.com/smile-minecraft/MacHelper/releases) 下載 `MacHelper-<版本>.dmg`，把 MacHelper 拖到「應用程式」。也可以用 Homebrew：

```sh
brew install --cask smile-minecraft/tap/machelper
```

MacHelper 已用 Developer ID 簽署並通過 Apple 公證，可以直接打開。風扇控制和系統清理需要 Helper，MacHelper 詢問時請到 **系統設定 → 一般 → 登入項目** 允許。

想看到整顆磁碟，請在 **系統設定 → 隱私權與安全性 → 完全取用磁碟** 打開 MacHelper。即使打開了，受系統完整性保護或屬於其他使用者的資料夾仍然無法讀取，這是 macOS 的保護，屬於正常現象。

每個版本的下載檔校驗碼放在發布頁的 `SHA256SUMS.txt`。

## 從原始碼建置

需要 Xcode 16 以上和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。

```sh
xcodegen generate
scripts/install.sh          # Release 建置 → /Applications/MacHelper.app，然後重新打開
swift test                  # Swift 套件的單元測試
```

簽章、專案結構、發布流程和翻譯方式請看[英文 README](README.md)。

## 授權

MIT，見 [LICENSE](LICENSE)。
