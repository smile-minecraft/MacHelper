# 磁碟掃描與 iCloud「僅限雲端」項目：唯讀檢查報告

- 日期：2026-11-04
- 範圍：`Sources/DiskScan`、`Sources/CSystemBridge`、`App/Disk`、`App/Shell/AppDelegate.swift`、`machelper duplicates`
- 方式：閱讀程式碼，並用 `find -flags +dataless` 實地確認系統行為（沒有修改任何程式碼）

## 結論

| 項目 | 會不會下載檔案內容 | 會不會觸發網路請求 | 嚴重度 |
|---|---|---|---|
| 掃描讀取檔案屬性（`getattrlistbulk`） | 不會 | 不會 | — |
| 掃描進入只在雲端的資料夾 | 不會 | **會**（抓取資料夾清單） | 低 |
| 找重複檔案（`DuplicateFinder`） | 目前不會，但只是剛好避開 | 可能 | **中（潛在風險）** |
| Quick Look 預覽 | 會 | 會 | 可接受（使用者主動點開） |

## 背景

macOS 上 iCloud Drive 和 File Provider 雲端硬碟（`~/Library/Mobile Documents`、`~/Library/CloudStorage`）裡「只在雲端」的項目，會帶有 `SF_DATALESS` 旗標。macOS 預設的 I/O 設定是「需要時自動下載」（`IOPOL_MATERIALIZE_DATALESS_FILES` 預設開啟），所以：

- 讀取一個 dataless **檔案**的內容 → 系統會把整個檔案下載回來
- 列出一個 dataless **資料夾**的內容 → 系統會從雲端抓這個資料夾的清單（檔名和屬性）
- `stat`/`lstat`/`getattrlist` 只讀屬性，**不會**觸發下載

**實測：** 檢查時我用 `find` 統計 `~/Library/Mobile Documents`，第一次查到 18 個 dataless 資料夾。因為 `find` 會進入資料夾，第二次再查就變成 0 個，代表那 18 個資料夾的清單已經被抓下來了（檔案內容沒有下載）。這證實了：在這台機器上，只要列出 dataless 資料夾的內容，就會觸發抓取。

本機目前的狀況（檢查後）：

| 位置 | dataless 資料夾 | dataless 檔案 |
|---|---|---|
| `~/Library/Mobile Documents` | 0（原本有 18 個，被檢查時的 `find` 抓下來了） | 4554 |
| `~/Library/CloudStorage` | 0 | 44755 |

## 問題 1：掃描會抓取只在雲端的資料夾清單（低）

**位置**
- [DiskScanner.swift:99](../Sources/DiskScan/DiskScanner.swift#L99)：每個子資料夾都用 `open()` 打開，再呼叫 `getattrlistbulk` 列出內容
- [DiskScanner.swift:125-131](../Sources/DiskScan/DiskScanner.swift#L125-L131)：遇到子資料夾就加入掃描佇列，沒有檢查 `SF_DATALESS`
- `ScanOptions.skipPaths` 預設是空的，[DiskAnalysisModel.swift:123](../App/Disk/DiskAnalysisModel.swift#L123) 和 [AppDelegate.swift:102](../App/Shell/AppDelegate.swift#L102) 都直接用 `DiskScanner()`，所以掃描 `~` 時會進入 `Library/Mobile Documents` 和 `Library/CloudStorage`

**影響**
- 每遇到一個 dataless 資料夾，就會有一次網路請求；掃描執行緒會停下來等回應
- 會連鎖往下：抓下來的清單裡如果有子資料夾也是 dataless，會繼續觸發。整棵只在雲端的資料夾樹，會被整棵抓下來
- 沒有網路或 iCloud 沒有回應時，會等到逾時，該資料夾最後被算成「無法讀取」
- 抓下來的清單會留在本機。佔用空間很小，但改變了使用者的 iCloud 狀態，不符合「唯讀掃描」的預期

**現況：** 本機目前沒有 dataless 資料夾，所以現在掃描實際上不會觸發。等以後又有資料夾被移回雲端，問題就會再出現。

## 問題 2：找重複檔案可能把整個檔案下載回來（中，潛在）

**位置**
- [Duplicates.swift:36](../Sources/DiskScan/Duplicates.swift#L36)：用 `lstat` 的 `st_size`（邏輯大小）判斷要不要處理，**沒有**檢查 `st_flags & SF_DATALESS`
- [Duplicates.swift:71](../Sources/DiskScan/Duplicates.swift#L71)（`quickHash`）和 [Duplicates.swift:85](../Sources/DiskScan/Duplicates.swift#L85)（`fullHash`）：用 `FileHandle` 讀取檔案內容，`fullHash` 會讀**整個檔案**

**目前為什麼沒出事**
傳進 `DuplicateFinder.find` 的路徑，只會是掃描結果裡單獨列出的檔案節點，而單獨列出的條件是佔用空間 ≥ `keepFilesLargerThan`（[DiskScanner.swift:137](../Sources/DiskScan/DiskScanner.swift#L137)）。dataless 檔案的佔用空間是 0，所以從來不會被傳進來。這是**間接**的保護：

- App：[DiskAnalysisModel.swift:189](../App/Disk/DiskAnalysisModel.swift#L189)
- CLI：[DuplicatesCommand.swift:32](../Sources/machelper/DuplicatesCommand.swift#L32)

**會出事的情況**
1. **時間差：** 掃描完之後、使用者按下「找重複」之前，macOS 因為磁碟空間不足，自動把某些檔案移回雲端。掃描結果裡還留著這些路徑，算雜湊時就會把整個檔案下載回來
2. **API 誤用：** `DuplicateFinder.find(paths:)` 是 `public`。以後如果有其他地方直接傳路徑進來（例如使用者自己選的資料夾清單），就會繞過上面的間接保護

**影響**
CloudStorage 裡有 44755 個只在雲端的檔案。一旦觸發，可能在背景下載好幾 GB 甚至幾十 GB：磁碟被塞滿、耗掉大量網路流量，而且使用者看不出來。這跟清理工具的用途正好相反。

## 建議修法

依優先順序：

1. **在 `DuplicateFinder.find` 裡跳過 dataless 檔案**（改動最小，直接堵住問題 2）
   在 [Duplicates.swift:36](../Sources/DiskScan/Duplicates.swift#L36) 的條件加上 `(st.st_flags & UInt32(SF_DATALESS)) == 0`。
2. **在掃描和算雜湊的執行緒關閉自動下載**（最根本，同時解決兩個問題）
   在 `DiskScanner` 的工作執行緒開頭（[DiskScanner.swift:76](../Sources/DiskScan/DiskScanner.swift#L76) 一帶），以及 `DuplicateFinder.find` 開始讀檔之前，呼叫：
   ```c
   setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
                  IOPOL_SCOPE_THREAD,
                  IOPOL_MATERIALIZE_DATALESS_FILES_OFF);
   ```
   設定後，讀取 dataless 項目會直接回傳錯誤，不會去下載。現有程式碼本來就會處理錯誤：`open` 失敗會被算成無法讀取，`FileHandle` 失敗會回傳 `nil` 並跳過。注意：`DuplicateFinder.find` 是在 `Task.detached` 裡跑的，執行緒不固定，最好在 `find` 函式裡設定、離開時恢復原本的設定，或改成整個程序都套用（`IOPOL_SCOPE_PROCESS`）。
3. **掃描時不進入 dataless 資料夾**（讓掃描結果比較一致）
   [CSystemBridge.c:72](../Sources/CSystemBridge/CSystemBridge.c#L72) 已經讀到 `ATTR_CMN_FLAGS`（`e.flags`）。在 [DiskScanner.swift:125](../Sources/DiskScan/DiskScanner.swift#L125) 判斷是資料夾後，如果 `e.flags & SF_DATALESS` 成立，就只建立節點、不加入掃描佇列。也可以在介面上把它標示成「僅在 iCloud」。

建議的測試：在 iCloud Drive 裡準備一個檔案和一個資料夾，在 Finder 裡選「移除下載項目」，然後執行掃描和 `machelper duplicates`，確認前後 `ls -lO` 都還看得到 `dataless` 旗標。
