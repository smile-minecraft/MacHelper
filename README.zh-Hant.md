<p align="center">
  <img src="docs/images/mascot.gif" width="240" alt="MacHelper 史萊姆：呼吸、揮手、跳躍、慶祝">
</p>

<h1 align="center">MacHelper</h1>

<p align="center">
  <b>完全在本機運作的 Mac 工具：系統監控、風扇控制、清理和磁碟分析，全部收在一個選單列 App 裡。</b>
</p>

<p align="center">
  <a href="https://github.com/smile-minecraft/MacHelper/releases/latest"><img src="https://img.shields.io/github/v/release/smile-minecraft/MacHelper?label=release&color=5b8def" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-1f2430" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Apple%20Silicon-arm64-1f2430" alt="Apple Silicon">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-4cc38a" alt="MIT"></a>
</p>

<p align="center">
  <a href="README.md">English</a> · 繁體中文 · <a href="README.zh-Hans.md">简体中文</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a>
</p>

<p align="center">
  <img src="docs/images/menubar.png" width="320" alt="選單列上的 MacHelper：CPU 折線、記憶體和溫度">
</p>

<p align="center">
  <img src="docs/images/overview.png" width="860" alt="概覽：健康分數、即時數值和最耗資源的 App">
</p>

<p align="center">
  <a href="#安裝"><b>安裝</b></a> ·
  <a href="#功能"><b>功能</b></a> ·
  <a href="#第一次打開"><b>第一次打開</b></a> ·
  <a href="#命令列"><b>命令列</b></a> ·
  <a href="#從原始碼建置"><b>從原始碼建置</b></a>
</p>

---

MacHelper 量測和儲存的所有資料都留在你的 Mac 上：不需要帳號、沒有分析追蹤，除了檢查更新之外不連網路。需要 macOS 14 以上的 Apple Silicon Mac，以 MIT 授權開源。

## 安裝

```sh
brew install --cask smile-minecraft/tap/machelper
```

也可以從 [Releases](https://github.com/smile-minecraft/MacHelper/releases/latest) 下載 `MacHelper-<版本>.dmg`，把 MacHelper 拖到「應用程式」。每個版本都用 Developer ID 簽署並通過 Apple 公證，可以直接打開。下載檔的校驗碼放在發布頁的 `SHA256SUMS.txt`。

MacHelper 會自己保持最新：背景檢查到新版本時，側邊欄、選單列面板和設定頁會出現 **更新到 x.y.z** 按鈕，按下後才會安裝。更新視窗會用 App 目前的語言顯示更新內容。

## 功能

<table>
  <tr>
    <td width="50%" valign="top">
      <h3>監控</h3>
      <img src="docs/images/monitor.png" alt="監控：CPU、GPU、記憶體、溫度、風扇和耗電圖表，附警戒線">
      <p>CPU（效能核心與節能核心）、GPU、記憶體壓力、溫度、風扇、耗電、電池、磁碟和網路速度。即時圖表和每分鐘一筆的歷史記錄，可看 1 小時、24 小時或 7 天，記憶體和溫度有警戒線。選單列的每一項都能選文字、折線、直條、長條、圓環、方塊、熱度膠囊或雙線顯示。</p>
    </td>
    <td width="50%" valign="top">
      <h3>健康檢查</h3>
      <img src="docs/images/health.png" alt="健康檢查：分數、最近 24 小時的數值和可用空間變化">
      <p>依最近幾小時的歷史、可用空間和背景項目算出健康分數，並說明扣分原因和建議做法。另外會唯讀檢查 Gatekeeper、FileVault、防火牆、系統完整性保護、自動安全性更新和 XProtect。</p>
    </td>
  </tr>
  <tr>
    <td colspan="2" valign="top">
      <h3>磁碟分析</h3>
      <img src="docs/images/disk.png" alt="磁碟分析：個人資料夾的旭日圖和最大的資料夾">
      <p>旭日圖和矩形樹狀圖（點任何資料夾都會直接進入）、可依種類和時間篩選的最大檔案、重複檔案（能辨識 APFS 複製檔和硬連結）、和上次掃描相比的變化，以及找出久未使用大檔案和異常膨脹資料夾的空間建議。把項目拖到收集籃，就能一次移到垃圾桶。</p>
    </td>
  </tr>
</table>

| | |
|---|---|
| **風扇控制** | 自動、固定轉速或溫度曲線（安靜、平衡、效能、自訂），「只升不降」模式、硬性安全上限，並可依正在執行的 App 或電源自動切換設定檔。 |
| **一鍵優化** | 先預覽再清理：低風險的快取直接刪除，中高風險的項目移到垃圾桶。有受保護路徑、永不清理清單、操作記錄、維護作業、專案建置產物清理和定時自動清理。 |
| **解除安裝** | 用 Bundle ID、內嵌 Helper、權限、容器資訊、launchd 擁有者、Homebrew zap 清單和各 App 規則找出 App 留下的東西。只靠名稱比對到的項目會標示出來讓你確認，也能找出已刪除 App 的殘留檔案。 |
| **啟動項目** | 你的 Launch Agent（停用、啟用、移除）、所有使用者的 Agent 和系統 Daemon，並標出所屬 App 和已經失效的項目。 |
| **Homebrew 更新** | 更新用 Homebrew 安裝的 App。 |
| **AI Agent Skill** | 為 Claude Code 和 Codex 安裝 Skill，讓它們安全地使用 MacHelper：一律先預覽，刪除前一定先問你。 |
| **通知** | CPU 溫度過高、記憶體壓力過大、磁碟空間不足時提醒你。 |
| **可選的歷史記錄** | 程序、感測器和核心歷史預設關閉。程序歷史只記錄名稱、CPU 和記憶體（不記錄路徑、參數或使用者名稱），保留 1 到 30 天。 |
| **史萊姆** | 吉祥物會跟著 Mac 的狀態變色（藍、黃、紅），對點擊、游標停留和拖曳有反應，也會回應過熱或清理完成等事件。會遵守「減少動態效果」和 VoiceOver。 |
| **語言** | 英文、繁體中文、簡體中文、日文、韓文和西班牙文。可在「設定 → 一般 → 語言」指定，不跟隨系統語言。 |

## 第一次打開

MacHelper 會一次一個地引導你開啟兩項權限。兩項都是選用的，其他功能不需要它們也能使用。

1. **完全取用磁碟**讓磁碟分析和清理能看到受保護的位置，例如「郵件」下載項目和其他 App 的快取。請到 **系統設定 → 隱私權與安全性 → 完全取用磁碟** 打開 MacHelper，引導視窗會自動偵測。受系統完整性保護的資料夾即使打開了也無法讀取，磁碟分析會另外列出。
2. **Helper** 是一個小型的 root 背景程式，負責風扇控制、系統快取與記錄檔清理、系統背景項目和系統程序用量。引導視窗會幫你安裝、打開 **系統設定 → 一般 → 登入項目與延伸功能** 讓你允許，並確認它有回應。它會驗證每個呼叫者的程式碼簽章。Helper 沒啟用時，按側邊欄底部的 **設定 Helper…** 可以再打開引導。

## 命令列

App 內附 `machelper` 指令（Homebrew 會幫你建立連結）。每個指令預設只預覽，也都支援 `--json`，適合寫腳本或讓 AI Agent 使用。執行 `machelper guide` 看總覽，`machelper <指令> --help` 看各指令說明。

```sh
machelper status --json                 # 目前所有數值
machelper clean                         # 預覽會清理的項目
machelper clean --max-risk low --yes    # 只清理低風險項目
```

## 從原始碼建置

需要 Xcode 16 以上和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。

```sh
xcodegen generate
scripts/install.sh          # Release 建置 → /Applications/MacHelper.app，然後重新打開
swift test                  # Swift 套件的單元測試
```

簽章、專案結構、截圖製作、發布流程（包含各語言的更新說明）和翻譯方式請看[英文 README](README.md)。

## 授權

MIT，見 [LICENSE](LICENSE)。
