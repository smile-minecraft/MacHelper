# MacHelper 交接清單

最後更新：2026-11-05。`/Applications` 裡的 build 仍是 `202611041531`，本輪新增的程式還沒有安裝，等使用者確認後再安裝，並照第五節與第六節在實機上驗收。

## 一、做完但還沒在實機上確認

- [ ] **選單列不再跳動**：數字改成預留最寬字串的寬度、靠右對齊。程序清單改成「黏性排序」，溫度依名稱固定排序，也拿掉了數字的滾動動畫。要實際看一陣子，確認選單列圖示和小面板的列都不再移動。這台機器對操作 App 的自動化工具沒有輔助使用權限（`AXIsProcessTrusted()` 回傳 false），離線快照的替代做法也進不去：快照的第二個 App 實例啟動時無條件檢查 Helper 的重註冊，而使用者偏好裡沒有已登記的 Helper CDHash，無法證明那次檢查只是空跑（會動到 Helper 註冊狀態），所以留給有人工或有授權的工作階段驗證。
- [ ] **旭日圖在主視窗的大小**：離線截圖（`--snapshot-disk`）看起來超出邊界，推測是 ImageRenderer 給的尺寸不對，App 內應該正常。要打開「磁碟分析」實際掃描一次確認。離線快照同上，目前無法安全執行，維持未驗證。
- [ ] **旭日圖／樹狀圖的互動**：
  - 游標旁的浮動提示
  - 旭日圖的路徑高亮，其他區塊變暗
  - 樹狀圖單擊只進一層
  - 單擊檔案會開快速查看

  互動行為需要對 App 視窗的輔助使用權限才能自動操作，目前沒有權限也不能要求授權，維持未驗證。
- [ ] **磁碟分析的儲存掃描**：在「磁碟分析」掃描一個位置並等它完成，結束 MacHelper（⌘Q）再開。預期：打開「磁碟分析」後停在最後一次完成掃描的位置，顯示上次的結果，上方有掃描時間、「這份結果可能已過時」和「清除已儲存的掃描」；收集、移至垃圾桶、重複檔案比對停用並說明原因，重新掃描可用。在還原狀態實際試三個入口：項目右鍵選單的「Add to Collector」是灰色；收集區顯示「Collecting is disabled for a saved scan…」，沒有「Move to Trash…」按鈕；「Duplicates」分頁顯示「Duplicate search is disabled for a saved scan…」，沒有「Find Duplicates」按鈕；圖表下方也不再顯示右鍵或拖曳項目到收集區的說明。按「重新掃描」完成後，這些操作恢復。按「清除已儲存的掃描」回到空白起始狀態；快取無法刪除時（例如把 `scan-results` 目錄或快取檔設成唯讀），預期畫面維持還原結果，收集區顯示「The saved scan could not be cleared: …」和系統原因，恢復權限後再按一次才回到空白起始狀態。切換到另一個掃描過的位置時，應該顯示該位置自己的上次結果。把 `~/Library/Application Support/MacHelper/scan-results/` 裡的快取檔換成無效的 JSON 再重開，預期回到空白起始狀態且不顯示錯誤。掃描完成後在 Finder 刪除或改名其中一個檔案，或把部分資料夾改成不可讀（也可以撤銷 MacHelper 的「完全取用磁碟」權限），再重開 App：預期仍顯示掃描當下的快照，已刪除的項目還在畫面上，可以瀏覽、顯示於 Finder、快速查看，但收集、移至垃圾桶和重複檔案比對維持停用；畫面不會反映掃描後的變化。外接磁碟掃描完成後卸載它再重開 App：預期掃描位置退回第一個可用位置（Home），顯示 Home 的上次結果，不是已卸載磁碟的結果。這是已接受的行為，不另外提示。這一步會讀寫正式快取檔，操作前先備份該目錄。以上畫面和重開 App 的流程仍待使用者手動確認。
- [ ] **自動清理背景排程的啟用**：關閉狀態已在 2026-11-04 實機確認三件事：`machelper autoclean --status --json` 顯示 `enabled:false`；`~/Library/LaunchAgents` 沒有 App 的 plist，`launchctl print gui/$(id -u)/com.machelper.MacHelper.AutoClean` 也找不到服務（未註冊）；執行一次 `machelper autoclean --run-if-due --json` 得到 `ran:false`、不建立 `~/Library/Application Support/MacHelper/autoclean.json`，操作日誌也沒有新條目。掃描器與執行器的組合另以隔離測試覆蓋：在暫存樹上用宣告為垃圾桶動作的規則掃描並執行，確認只搬規則命中的兩個測試檔、無關檔案不動，執行紀錄寫到測試自己的暫存檔；這兩個測試檔每次執行都會留在系統垃圾桶，測試沒有清掉它們。這兩個測試是在另一個獨立 scratch 目錄、以先前建置好的測試二進位重跑，2/2 通過；這次沒有重新編譯。這個組合不涵蓋排程入口本身，也沒有驗證入口會執行風險與預設選取過濾；內建規則的測試只是自行套用同樣的篩選條件，確認篩選後沒有清空垃圾桶的規則、動作都是垃圾桶，並沒有呼叫 `AutoClean.run`，所以不能證明入口真的這樣過濾，也不能證明所有低風險規則都預設選取。保護路徑只在第二個測試直接對三條代表性路徑呼叫 `PathSafety.check`，掃描和執行沒有把保護路徑當候選。還未驗證：打開開關註冊正式的每小時服務之後，`launchctl print` 與 `machelper autoclean --status` 的註冊和首輪執行——啟用會寫入正式設定與正式操作紀錄，目前無法證明那一輪執行完全隔離，保持未驗證。
- [x] **解除安裝（隔離測試）**：2026-11-04 建了可重建的測試 App（`~/Applications/SelfcheckProbe.app`，bundle ID `net.macprobe.selfcheck`）與殘留：Caches、Logs、HTTPStorages 的 helper 變體、Preferences、指向測試 App 的 LaunchAgent、`~/.local/bin` 的 symlink。`machelper uninstall` 的預覽選中 7 項、每一項都指向測試資料；執行後 7 項全部進垃圾桶，測試 App 的私人資料與無關的 `~/Library/Caches/net.macprobe.refusethis` 都在原地，`defaults read net.macprobe.selfcheck` 也乾淨。重建之後用 `--with-data` 再驗一次（這次資料目錄取名 `~/.selfcheckprobe`）：App 和 home 資料一併搬垃圾桶，無關資料仍保留。以 Hermes 為例的實際移除尚未執行，只用唯讀預覽看過計畫：預設只選 App、caches、WebKit、Preferences；`~/.hermes`、背景服務 `ai.hermes.gateway` 和 6 個指令連結列為候選但預設不選；帶 `--with-data` 時這些都會被選中，`~/.hermes` 的 node/npm/npx 會跟著走；`~/.claude` 不在候選清單。垃圾桶直接列舉被系統擋住，每項去向與位元組數以 `machelper history --json` 的操作日誌為準。
- [ ] **背景記錄（MacHelper 結束後繼續記錄）**：程式、設定頁開關與安裝用的 plist 已接好，但還沒有在任何實機上啟用過。照第五節的步驟驗證；這一步會註冊使用者層級的 LaunchAgent，並寫入正式的歷史資料庫。
- [ ] **主視窗各頁**：一鍵優化、解除安裝、啟動項目已改用 `Palette` 配色、細分隔線和卡片式底部操作列；還沒在實機上看過版面、間距和深色模式。
- [ ] **GPU 溫度與 CPU 功耗**：程式已完成，檢查項目見第六節。
- [ ] **本輪新增功能的實機驗收**：資料管理、操作紀錄、程序用量歷史、感測器與核心歷史、設定備份與還原、設定視窗一致性、像素圖示；檢查項目見第六節。

## 二、還沒做的功能

- [ ] **系統層級的項目要管理員權限**：
  - 系統啟動項目（`/Library/LaunchDaemons` 等）只能看，不能停用或刪除
  - 解除安裝時 `/Library` 底下的殘留只列出來
  - 287 個 root 程序看不到 CPU 和記憶體用量

  做法：在 Helper 加 XPC 操作，協定升到 v4，並加嚴格的路徑和 label 白名單。
- [ ] **睡眠／喚醒測試**：風扇策略在喚醒後的 reassert 邏輯沒有在實機上驗證過。

電池充電上限與桌面小工具已由使用者決定取消，不再規劃。

## 三、設計還可以再修

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
- 專案已是 git repository，目前只有一個 commit「Initial MacHelper project」。本輪的修改都還在工作區，尚未提交或推送，等實機驗收完成後再處理。
- 簽章用 `Config/Local.xcconfig` 裡的 Personal Team（9Z9Y3M27R4）。
- 外接磁碟區分大小寫，所以內附 CLI 必須叫 `machelper-cli`。

## 五、背景記錄實機驗證

背景記錄把 MacHelper 的每分鐘歷史交給使用者層級的 LaunchAgent `com.machelper.MacHelper.MonitorAgent`。它執行 App 內的 `machelper-cli monitor --record`，設定檔是 App 寫出的 `monitor-agent.json`；App 關閉後仍會繼續寫入同一份 `history.sqlite`。App 和背景程式同時執行時，同一分鐘的資料會在資料庫交易內合併，不需要先關掉 App 的記錄。

這一步會註冊正式的 LaunchAgent、寫入 `~/Library/Application Support/MacHelper/` 的正式資料，而且在「登入項目」按下允許之後，MacHelper 結束時仍會持續取樣。任何一步不對，照最後的「停用」做。

### 安裝前

第 1 到 2 步要在執行 `scripts/install.sh` 之前做完。備份時 App 和背景程式都不能正在寫入。

1. 先處理背景記錄。先看「MacHelper 結束後繼續記錄」開關；如果開關是開的，或 `launchctl print` 還找得到服務，開啟 MacHelper → 設定 → 一般 → 背景記錄，關閉「MacHelper 結束後繼續記錄」，等狀態變成「關閉」（詳細步驟見「換版前先停用背景記錄」）；如果 App 顯示關閉但服務還在，照「服務還在但 App 顯示關閉」處理。關掉背景記錄一定要開 App，所以關完後 App 還會執行，下一步要另外結束它。如果開關本來就是關的，而且服務不存在，不用開 App。

   不論哪一種，都要先確認服務消失：

```sh
launchctl print gui/$(id -u)/com.machelper.MacHelper.MonitorAgent
```

   預期：`Could not find service`，指令回傳非 0。如果還找得到服務，先處理到服務消失；服務沒有消失就不要備份、不要安裝。

2. 結束 MacHelper（⌘Q，只關視窗不算），並確認 App 真的結束：

```sh
if pgrep -x MacHelper >/dev/null 2>&1; then
  osascript -e 'quit app "MacHelper"' 2>/dev/null || true
  sleep 1
  pkill -x MacHelper 2>/dev/null || true
fi
sleep 2
pgrep -x MacHelper
```

   預期：`pgrep` 沒有輸出，指令回傳非 0。也可以在「活動監視器」搜尋 MacHelper 確認。App 還在執行就不要備份。

   確認結束後，備份到新的時間戳目錄。備份前會先刪掉舊的 `~/Desktop/MacHelper-backup-path.txt`；刪不掉就停止，不會繼續備份。只有這次備份和檢查都成功，才會寫入新的路徑檔，第一行是備份目錄，第二行是備份時間。資料目錄沒有 `history.sqlite` 時，代表從未記錄過歷史，備份只含目前存在的檔案，仍然會列出備份內容：

```sh
zsh -f <<'BACKUP'
set -eu
DATA="$HOME/Library/Application Support/MacHelper"
BACKUP_FILE="$HOME/Desktop/MacHelper-backup-path.txt"
if ! rm -f "$BACKUP_FILE"; then
  echo "無法刪除舊的備份路徑檔，不要備份也不要安裝。"
  exit 1
fi
if pgrep -x MacHelper >/dev/null 2>&1; then
  echo "MacHelper 還在執行，先結束再備份。"
  exit 1
fi
if pgrep -x machelper-cli >/dev/null 2>&1; then
  echo "背景記錄程式 machelper-cli 還在執行，先關閉「MacHelper 結束後繼續記錄」並等它結束再備份。"
  exit 1
fi
STAMP="$(date +%Y%m%d%H%M%S)"
BACKUP="$HOME/Desktop/MacHelper-backup-$STAMP"
BACKUP_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
if ! mkdir "$BACKUP"; then
  echo "無法建立備份目錄，不要安裝。"
  exit 1
fi
if [ -d "$DATA" ] && ! ditto "$DATA" "$BACKUP"; then
  if [[ "$BACKUP" == "$HOME/Desktop/MacHelper-backup-"* ]]; then
    rm -rf "$BACKUP"
  fi
  echo "備份失敗，不要安裝。"
  exit 1
fi
if [ ! -f "$BACKUP/history.sqlite" ]; then
  echo "資料目錄沒有 history.sqlite：從未記錄過歷史，備份只含目前存在的檔案。"
  ls -la "$BACKUP"
fi
if ! printf '%s\n%s\n' "$BACKUP" "$BACKUP_TIME" > "$BACKUP_FILE"; then
  echo "無法寫入備份路徑檔，不要安裝。"
  exit 1
fi
echo "備份完成：$BACKUP"
echo "備份時間：$BACKUP_TIME"
BACKUP
```

   預期：印出「備份完成：…」和「備份時間：…」。沒有這兩行就不要安裝，也不要跳過備份直接安裝；舊的路徑檔可能還指向更早的備份。備份失敗時舊的路徑檔已經刪除，「還原上一版」會因此停住，不會拿到上一次的舊備份。這次的路徑會寫進 `~/Desktop/MacHelper-backup-path.txt`，第一行是備份目錄，第二行是備份時間（`YYYY-MM-DD HH:MM:SS`）；「還原上一版」會讀第一行，並且在動資料之前印出第二行讓使用者確認。`ditto` 會一起複製 `history.sqlite-wal`、`history.sqlite-shm`（如果存在）；不要在 App 或背景程式寫入時只複製資料庫檔案。

3. 在專案目錄（有 `scripts/install.sh` 的資料夾）執行安裝：

```sh
scripts/install.sh
```

   如果 MacHelper 還在執行，腳本會先結束它，把目前的 `/Applications/MacHelper.app` 複製到 `build/previous/MacHelper.app`（輸出會印出實際路徑）。替換時先把新版複製到 `/Applications` 內的隱藏暫存目錄 `.MacHelper-new-<時間>-<程序編號>`，對暫存目錄完成簽章驗證後，才把目前的 App 改名成 `.MacHelper-old-<時間>-<程序編號>`，再把新版改名成 `MacHelper.app`。複製或驗證失敗時目前的 App 不會動；舊版改名後的步驟失敗時會把舊版放回。成功後才刪除舊版暫存目錄。`build/previous` 只保留最後一次成功安裝前的版本；不要連續安裝兩次，新版本有問題時要先照「還原上一版」還原，不要直接再安裝一次。

   安裝後只檢查產物，不註冊服務：

```sh
ls -l /Applications/MacHelper.app/Contents/Library/LaunchAgents/com.machelper.MacHelper.MonitorAgent.plist
ls -l /Applications/MacHelper.app/Contents/MacOS/machelper-cli
plutil -lint /Applications/MacHelper.app/Contents/Library/LaunchAgents/com.machelper.MacHelper.MonitorAgent.plist
```

預期：兩個檔案都存在，`plutil` 顯示 `OK`。plist 的 `BundleProgram` 必須是 `Contents/MacOS/machelper-cli`。

安裝後在 Spotlight 搜尋 MacHelper、打開 Launchpad，並到「系統設定 → 一般 → 登入項目」檢查：只能看到一份 MacHelper。看到重複時，記下每個出現的位置，回報並暫時不要刪除任何東西。安裝失敗時，如果 `/Applications` 內留下 `.MacHelper-new-*` 或 `.MacHelper-old-*`，先不要手動刪除或改名；`MacHelper.app` 不見時照「還原上一版」的「如果目前的 App 不見」處理，其他暫存路徑回報。補回上一版時才繼續還原；第一次安裝補回的是這次的新版，沒有上一版可還原，不要執行還原腳本。

### 啟用前先記基準

4. 開啟 MacHelper 讓它記錄一分鐘，然後查詢歷史資料庫。`-readonly` 只開啟查詢，不會寫入：

```sh
sqlite3 -readonly "$HOME/Library/Application Support/MacHelper/history.sqlite" \
  "SELECT COUNT(*), datetime(MAX(time), 'localtime') FROM sample;"
```

預期：得到筆數與最後一筆時間。資料庫不存在時先記 0 和「無」。如果 `-readonly` 因為 WAL 的 `-shm` 權限失敗，改用同一個 `SELECT` 但不加 `-readonly`；這個查詢本身不會改資料。

5. 開啟「設定 → 一般 → 背景記錄」。打開「MacHelper 結束後繼續記錄」。

預期：狀態可能先顯示「等待「登入項目」核准」。到「系統設定 → 一般 → 登入項目」的「允許在背景執行」區域，找到 MacHelper 並打開。設定頁也有「開啟登入項目」按鈕。回到 MacHelper 後 5 秒內狀態會更新；如果還沒寫入第一筆，可能先顯示「已啟用，但記錄器沒有回報」，最多等 2 分鐘再判斷。

6. 確認服務已註冊：

```sh
launchctl print gui/$(id -u)/com.machelper.MacHelper.MonitorAgent
```

預期：找得到服務，`state = running`，程式指向 `/Applications/MacHelper.app/Contents/MacOS/machelper-cli`，參數是 `monitor --record`。這一步只讀取，不會啟動或停止服務。

7. 確認背景程式的心跳：

```sh
/Applications/MacHelper.app/Contents/MacOS/machelper-cli monitor --status
```

若 `~/.local/bin/machelper` 已經安裝，也可以用 `machelper monitor --status`。預期：`Last heartbeat` 是最近 2 分鐘內的時間，沒有 `last error`。

### 關閉 App 之後

8. 記下目前時間，結束 MacHelper。等 2 到 3 分鐘。等待時間的依據：背景程式每 10 秒寫一次心跳，畫面把超過 120 秒沒更新的心跳視為停止；完整的一分鐘資料要等到下一分鐘開始取樣時才寫入。

9. 再查一次心跳與資料庫：

```sh
/Applications/MacHelper.app/Contents/MacOS/machelper-cli monitor --status
sqlite3 -readonly "$HOME/Library/Application Support/MacHelper/history.sqlite" \
  "SELECT COUNT(*), datetime(MAX(time), 'localtime') FROM sample;"
```

預期：心跳時間比步驟 7 新，資料庫的 `MAX(time)` 超過結束 App 的時間，筆數每分鐘約增加 1。若筆數沒增加但心跳是新的，先確認「設定 → 選單列」至少有一個項目是開啟的。

### 登出再登入

10. 登出目前的使用者，再登入。先不要開 MacHelper。
11. 重跑步驟 6、7、9 的三個指令。

預期：服務仍在 `running`，心跳在登入後 2 分鐘內更新，資料庫的 `MAX(time)` 繼續往後走。這證明 LaunchAgent 由 launchd 在使用者登入時啟動，不需要 App 先開著。

### 睡眠與喚醒

12. 讓 Mac 睡眠至少 5 分鐘，再喚醒。等 1 到 2 分鐘。
13. 重跑 `monitor --status`、`launchctl print` 和資料庫查詢。

預期：心跳更新到喚醒之後，資料庫在喚醒後繼續每分鐘增加。睡眠期間不會有每分鐘的資料列（最多補上睡前那一分鐘）；圖表應該在缺口處斷線，不應把睡眠前後連成一條線。喚醒後 2 分鐘仍沒有新心跳時，先看「設定 → 一般 → 背景記錄」的狀態；顯示停止就關掉再打開開關一次。

### 停用

14. 開啟 MacHelper → 設定 → 一般 → 背景記錄，關閉「MacHelper 結束後繼續記錄」。

預期：狀態在 5 秒內變成「關閉」。背景程式註冊會被移除，但先前寫入的歷史資料會保留。

15. 確認服務已移除：

```sh
launchctl print gui/$(id -u)/com.machelper.MacHelper.MonitorAgent
```

預期：`Could not find service`，指令回傳非 0。`machelper monitor --status` 可能還會印出最後一次心跳，因為心跳檔沒有刪除；再等 1 分鐘重跑，時間應該不會變。

### 換版前先停用背景記錄

這是「安裝前」第 1 步的詳細做法。已經啟用背景記錄時，不要直接重跑安裝腳本。新舊 App 共用同一個 bundle 路徑，替換時服務可能還在執行舊的執行檔；先移除註冊再換版，後續每一步的狀態也比較好判斷。

1. 開啟 MacHelper → 設定 → 一般 → 背景記錄，關閉「MacHelper 結束後繼續記錄」，等狀態變成「關閉」。
2. 確認服務已經消失：

```sh
launchctl print gui/$(id -u)/com.machelper.MacHelper.MonitorAgent
```

預期：`Could not find service`，指令回傳非 0。如果還找得到服務，先照「服務還在但 App 顯示關閉」處理，不要繼續。

這一節只做到第 2 步，不安裝。服務消失後回到「安裝前」第 2 步，先結束 App、確認備份完成，再執行安裝。

### 還原上一版

`scripts/install.sh` 每次替換 `/Applications/MacHelper.app` 之前，會把上一版完整複製到專案的 `build/previous/MacHelper.app`，並在輸出印出位置。`build/previous` 只保留最後一次成功安裝前的版本，所以不要連續安裝兩次；新版本壞掉時要先還原，不要直接再安裝一次，否則好的上一版會被壞版本覆蓋。

下面的流程會先把所有前提檢查完，才動 App 和資料。任何一步失敗都會停在原地，或把目前的資料和 App 放回原狀；不會先刪掉目前的 App，也不會把備份合併進現有資料。如果連放回都失敗，腳本會印出還在的位置，先不要刪除任何目錄。還原前背景服務和 `machelper-cli` 都必須先停止。目前的 `/Applications/MacHelper.app` 必須還在；不見時先照下面「如果目前的 App 不見」補回。補回的是上一版時，簽章驗證通過才繼續；如果是第一次安裝、改放回安裝中斷留下的新版，就沒有上一版可還原，不要執行下面的還原腳本。在專案目錄（有 `scripts/install.sh` 的資料夾）依序做：

1. 先停用背景記錄，這一步不能跳過。新版本還能開時，開啟 MacHelper → 設定 → 一般 → 背景記錄，關掉「MacHelper 結束後繼續記錄」，等狀態變成「關閉」。App 開不起來時，直接到「系統設定 → 一般 → 登入項目 → 允許在背景執行」把 MacHelper 關掉。兩種情況都要用下面的指令確認服務消失；還找得到服務就登出再登入重查，仍在就停止，不要還原：

```sh
launchctl print gui/$(id -u)/com.machelper.MacHelper.MonitorAgent
```

預期：`Could not find service`，指令回傳非 0。還原腳本也會檢查 `machelper-cli`；它還在執行時會停止，並提示先關閉背景記錄、等程序結束。

#### 如果目前的 App 不見

只有 `/Applications/MacHelper.app` 不存在時才做這一步。有 `build/previous/MacHelper.app` 時，先從那裡把上一版放回，驗證簽章通過才繼續後面的還原。沒有上一版可以放回時（通常是第一次安裝），改找安裝中斷留下的 `/Applications/.MacHelper-new-*`：恰有一個而且簽章驗證通過，才把它改名成 `/Applications/MacHelper.app`；其他情況一律停止，保留現場，不要刪除或改名任何東西。

```sh
zsh -f <<'RECOVER'
APP="/Applications/MacHelper.app"
APPLICATIONS="/Applications"
PREVIOUS="build/previous/MacHelper.app"
if [[ -e "$APP" ]]; then
  echo "$APP 已存在，不用補回。"
elif [[ -d "$PREVIOUS" ]]; then
  if ! ditto "$PREVIOUS" "$APP"; then
    echo "放回上一版失敗，停止；保留現場，不要刪除任何東西，回報這個狀況。"
  elif ! codesign --verify --deep --strict "$APP"; then
    echo "放回的 App 簽章驗證失敗，停止；保留現場，不要刪除任何東西，回報這個狀況。"
  else
    echo "已把上一版放回 $APP，簽章驗證通過；繼續下面的還原流程。"
  fi
else
  echo "找不到上一版 $PREVIOUS：沒有上一版可以放回，改找安裝中斷留下的暫存 App。"
  CANDIDATES=("$APPLICATIONS"/.MacHelper-new-*(N))
  if [[ ${#CANDIDATES} -ne 1 ]]; then
    echo "找到 ${#CANDIDATES} 個 $APPLICATIONS/.MacHelper-new-*："
    for CANDIDATE in "${CANDIDATES[@]}"; do echo "  $CANDIDATE"; done
    echo "無法判斷哪一個是完整的新版，停止；保留現場，不要刪除或改名任何東西。"
    echo "直接重新執行 scripts/install.sh（它會重新建置並安全替換），不要走還原流程。"
  elif [[ ! -d "${CANDIDATES[1]}" ]] || ! codesign --verify --deep --strict "${CANDIDATES[1]}"; then
    echo "暫存 App ${CANDIDATES[1]} 不是完整的 App 或簽章驗證失敗，停止；保留現場，不要刪除或改名任何東西。"
    echo "直接重新執行 scripts/install.sh（它會重新建置並安全替換），不要走還原流程。"
  elif [[ -e "$APP" ]]; then
    echo "$APP 在檢查時出現了，停止；保留現場，不要刪除或改名任何東西。"
    echo "直接重新執行 scripts/install.sh（它會重新建置並安全替換），不要走還原流程。"
  elif ! mv "${CANDIDATES[1]}" "$APP"; then
    echo "把暫存 App 改名為 $APP 失敗，停止；保留現場，不要刪除任何東西。"
    echo "直接重新執行 scripts/install.sh（它會重新建置並安全替換），不要走還原流程。"
  else
    echo "沒有上一版可還原；已把安裝中斷留下的新版改名為 $APP，簽章驗證通過。"
    echo "不要執行下面的還原腳本；App 有問題時直接重新執行 scripts/install.sh。"
  fi
fi
RECOVER
```

如果安裝輸出指出舊版暫存在 `/Applications/.MacHelper-old-*`，先不要刪除，把路徑一起回報。新版暫存 `.MacHelper-new-*` 只有在沒有上一版、恰有一個而且簽章驗證通過時才會改名；其他情況不要手動改名或刪除，直接重新執行 `scripts/install.sh`，它會重新建置並安全替換。

2. 把下面整段貼到終端機。腳本會先檢查服務、`machelper-cli`、目前的 App、上一版 App、備份目錄和備份內容；全部通過才開始，並在動任何資料之前印出備份時間，要求按 Enter 確認。不要同時執行兩個還原；暫存名稱包含程序編號，不會相撞，但兩個流程會操作同一份 App 和資料。順序是：先把備份複製到資料目錄旁邊的暫存目錄並確認，再把目前資料改名移走、把暫存目錄改名成 `MacHelper`，最後才在 `/Applications` 內把目前的 App 改名成隱藏目錄 `.MacHelper-after-install-<時間>-<程序編號>`（同一個磁碟區的改名，不是複製到專案），再放入上一版並驗證簽章：

```sh
zsh -f <<'RESTORE'
set -eu

APP="/Applications/MacHelper.app"
DATA="$HOME/Library/Application Support/MacHelper"
DATA_DIR="${DATA:h}"
PREVIOUS="build/previous/MacHelper.app"
BACKUP_FILE="$HOME/Desktop/MacHelper-backup-path.txt"
SERVICE="gui/$(id -u)/com.machelper.MacHelper.MonitorAgent"
STAMP="$(date +%Y%m%d%H%M%S)-$$"
STAGE="$DATA_DIR/MacHelper.restore-$STAMP"
MOVED="$DATA_DIR/MacHelper.after-install-$STAMP"
REAPPEARED="$DATA_DIR/MacHelper.reappeared-$STAMP"
APP_MOVED="/Applications/.MacHelper-after-install-$STAMP"
APP_FAILED="/Applications/.MacHelper-restore-failed-$STAMP"

remove_own_stage() {
  if [[ "$STAGE" != "$DATA_DIR/MacHelper.restore-"* ]]; then
    echo "暫存路徑不是腳本建立的（$STAGE），停止。"
    return 1
  fi
  rm -rf "$STAGE"
}

restore_installed_data() {
  # 只刪腳本自己建立的暫存目錄，其他路徑一律不碰。
  if [[ -e "$STAGE" ]]; then
    remove_own_stage || return 1
  fi
  # 還原時又出現的資料移到新的名稱，絕不放進會被刪除的目錄。
  if [[ -e "$DATA" && -e "$MOVED" ]]; then
    if [[ -e "$REAPPEARED" ]]; then
      echo "要保留的資料名稱已存在（$REAPPEARED），停止；安裝後的資料在 $MOVED。"
      return 1
    fi
    if ! mv "$DATA" "$REAPPEARED"; then
      echo "無法移走還原時出現的資料（$DATA）；安裝後的資料在 $MOVED。"
      return 1
    fi
    echo "還原後在 $DATA 的資料已移到：$REAPPEARED"
  fi
  if [[ -e "$MOVED" && ! -e "$DATA" ]]; then
    if ! mv "$MOVED" "$DATA"; then
      echo "無法把安裝後的資料放回 $DATA；它還在 $MOVED。"
      return 1
    fi
  fi
  if [[ -e "$MOVED" && -e "$DATA" ]]; then
    echo "安裝後的資料還在 $MOVED，$DATA 也存在；停止，不要手動合併。"
    return 1
  fi
}

# 1. 背景服務和背景程式都要先停止。
SERVICE_OUTPUT="$(launchctl print "$SERVICE" 2>&1 || true)"
if ! printf '%s\n' "$SERVICE_OUTPUT" | grep -q "Could not find service"; then
  echo "背景服務還在，或無法確認它已經消失，停止。"
  printf '%s\n' "$SERVICE_OUTPUT"
  exit 1
fi
if pgrep -x machelper-cli >/dev/null 2>&1; then
  echo "背景記錄程式 machelper-cli 還在執行，停止。"
  echo "先關閉「MacHelper 結束後繼續記錄」，等這個程序結束再試。"
  exit 1
fi

# 2. 所有東西都先確認，才開始動 App 和資料。
if [[ ! -d "$APP" ]]; then
  echo "找不到目前的 $APP，停止；這個流程需要目前的 App 才能安全還原。"
  exit 1
fi
if [[ ! -d "$PREVIOUS" ]]; then
  echo "找不到上一版 $PREVIOUS，停止。"
  exit 1
fi
if ! codesign --verify --deep --strict "$PREVIOUS"; then
  echo "上一版 App 的簽章驗證失敗，停止。"
  exit 1
fi
if [[ ! -f "$BACKUP_FILE" ]]; then
  echo "找不到 $BACKUP_FILE，停止；請先照「安裝前」完成備份。"
  exit 1
fi
BACKUP="$(head -n 1 "$BACKUP_FILE")"
BACKUP_TIME="$(sed -n '2p' "$BACKUP_FILE")"
if [[ -z "$BACKUP" || ! -d "$BACKUP" ]]; then
  echo "備份路徑是空的或不存在（$BACKUP_FILE），停止。"
  exit 1
fi
if [[ -z "$BACKUP_TIME" ]]; then
  BACKUP_TIME="$(basename "$BACKUP")"
fi
if [[ -f "$BACKUP/history.sqlite" ]]; then
  HAD_HISTORY=1
else
  HAD_HISTORY=0
  echo "備份裡沒有 history.sqlite：安裝前從未記錄過歷史，照樣還原其他檔案。"
fi
if [[ -e "$STAGE" || -e "$MOVED" || -e "$APP_MOVED" || -e "$APP_FAILED" || -e "$REAPPEARED" ]]; then
  echo "暫存名稱已存在（$STAMP），等一秒再試。"
  exit 1
fi
echo "使用上一版：$PREVIOUS"
echo "使用備份：$BACKUP"
echo "備份時間：$BACKUP_TIME"
printf '請確認這是安裝前最後一次備份；按 Enter 繼續，輸入其他內容取消：'
if ! read -r CONFIRM < /dev/tty; then
  echo
  echo "無法讀取確認，停止；App 和資料都沒有動。"
  exit 1
fi
if [[ -n "$CONFIRM" ]]; then
  echo "已取消，App 和資料都沒有動。"
  exit 1
fi
echo "確認完成，開始還原。"

# 3. 結束 App。只在它已經執行時送出結束，避免 AppleScript 把 App 開起來。
if pgrep -x MacHelper >/dev/null 2>&1; then
  osascript -e 'quit app "MacHelper"' >/dev/null 2>&1 || true
  sleep 1
  pkill -x MacHelper 2>/dev/null || true
fi
sleep 2
if pgrep -x MacHelper >/dev/null 2>&1; then
  echo "MacHelper 還在執行，停止。"
  exit 1
fi

# 4. 先把備份複製到資料目錄旁邊的暫存目錄，成功才動目前資料。
echo "複製備份到暫存目錄…"
if ! ditto "$BACKUP" "$STAGE"; then
  echo "備份複製到暫存目錄失敗，停止；目前 App 和資料都沒有動。"
  remove_own_stage || exit 1
  exit 1
fi
if [[ "$HAD_HISTORY" == 1 && ! -f "$STAGE/history.sqlite" ]]; then
  echo "暫存目錄缺少 history.sqlite，停止；目前 App 和資料都沒有動。"
  remove_own_stage || exit 1
  exit 1
fi

# 5. 目前資料改名移走，暫存目錄再改名成 MacHelper。同一個父目錄的 mv 是改名，不會合併。
if [[ -d "$DATA" ]]; then
  echo "移走目前資料…"
  if ! mv "$DATA" "$MOVED"; then
    echo "無法移走目前資料，停止；目前 App 和資料都沒有動。"
    remove_own_stage || exit 1
    exit 1
  fi
  if [[ -e "$DATA" ]]; then
    echo "目前資料已移到 $MOVED，但 $DATA 又出現了；開始把目前資料放回。"
    restore_installed_data || exit 1
    echo "已把目前的資料放回 $DATA；停止。"
    exit 1
  fi
  echo "目前資料已移到：$MOVED"
fi
if [[ -e "$DATA" ]]; then
  echo "把備份資料放回前，$DATA 又出現了；停止並把安裝後的資料放回。"
  restore_installed_data || exit 1
  echo "已放回安裝後的資料；停止。"
  exit 1
fi
echo "把備份資料放到 $DATA…"
if ! mv "$STAGE" "$DATA"; then
  echo "還原資料失敗，開始把安裝後的資料放回。"
  restore_installed_data || exit 1
  echo "已放回安裝後的資料；停止。"
  exit 1
fi
if [[ ! -d "$DATA" ]] || [[ "$HAD_HISTORY" == 1 && ! -f "$DATA/history.sqlite" ]]; then
  echo "還原後的資料不完整，開始把安裝後的資料放回。"
  restore_installed_data || exit 1
  echo "已放回安裝後的資料；停止。"
  exit 1
fi

# 6. 目前的 App 只在 /Applications 內改名，再把上一版複製進來。
echo "移走目前的 App…"
if ! mv "$APP" "$APP_MOVED"; then
  if [[ -d "$APP_MOVED" && ! -e "$APP" ]]; then
    mv "$APP_MOVED" "$APP" || {
      echo "目前的 App 在 $APP_MOVED，無法放回 $APP。"
      echo "安裝後的資料在 $MOVED；先不要刪除，回報這個狀況。"
      exit 1
    }
  fi
  echo "無法移走目前的 App，開始把資料放回安裝後的版本。"
  restore_installed_data || exit 1
  echo "已放回安裝後的資料；停止。"
  exit 1
fi
echo "目前的 App 已改名為：$APP_MOVED"
echo "放入上一版 App…"
if ditto "$PREVIOUS" "$APP" && codesign --verify --deep --strict "$APP"; then
  echo "還原完成，簽章驗證通過。"
  echo "資料：$DATA"
  echo "安裝後的資料：$MOVED（原本沒有資料時不會有這個目錄）"
  echo "目前的 App 已改名為：$APP_MOVED（確認上一版可用後再刪除）"
  echo "備份時間：$BACKUP_TIME。"
  exit 0
fi

echo "上一版 App 複製或簽章驗證失敗，開始把目前的 App 和資料放回。"
# 先把不完整的複本改成非 .app 名稱，避免被當成另一個 App。
if [[ -e "$APP" ]]; then
  if [[ -e "$APP_FAILED" ]]; then
    echo "失敗的 App 暫存名稱已存在（$APP_FAILED），停止；目前的 App 在 $APP_MOVED。"
    exit 1
  fi
  if ! mv "$APP" "$APP_FAILED"; then
    echo "無法移走失敗的 App（$APP）；目前的 App 在 $APP_MOVED。"
    echo "安裝後的資料在 $MOVED；先不要刪除，回報這個狀況。"
    exit 1
  fi
  echo "失敗的 App 副本已移到：$APP_FAILED"
fi
if [[ -e "$APP" ]]; then
  echo "要放回目前 App 的位置又有東西了（$APP），停止；目前的 App 在 $APP_MOVED。"
  echo "安裝後的資料在 $MOVED；先不要刪除，回報這個狀況。"
  exit 1
fi
if ! mv "$APP_MOVED" "$APP"; then
  echo "無法把目前的 App 放回 $APP；它還在 $APP_MOVED。"
  echo "開始把安裝後的資料放回。"
  restore_installed_data || exit 1
  echo "已放回安裝後的資料；停止。"
  exit 1
fi
restore_installed_data || exit 1
echo "已放回目前的 App 和安裝後的資料；停止。"
if [[ -e "$APP_FAILED" ]]; then
  echo "失敗的 App 副本保留在 $APP_FAILED，確認後再刪除。"
fi
exit 1
RESTORE
```

腳本成功時最後會印出「還原完成，簽章驗證通過」，以及備份時間、安裝後的資料和 App 位置。任何一步失敗都會停下來，不會繼續後面的動作；把輸出留下來回報，不要手動跳過。移走的目前資料在 `~/Library/Application Support/MacHelper.after-install-<時間>-<程序編號>`；目前的 App 改名成 `/Applications/.MacHelper-after-install-<時間>-<程序編號>`（隱藏目錄，不是 `.app`，腳本會印出路徑）；還原失敗時，不完整的 App 副本會改名成 `/Applications/.MacHelper-restore-failed-<時間>-<程序編號>`，一樣保留供確認。確認舊版可用之後再刪，不要現在刪。

腳本用 `Could not find service` 判斷背景服務消失。系統如果顯示其他語言，這個判斷會安全停止，不會動到 App 或資料。

3. 開啟 App 前再核對一次備份時間。`~/Desktop/MacHelper-backup-path.txt` 第一行是備份目錄，第二行是備份時間；還原腳本已經在動資料前要求確認，這裡再看一次，這個時間必須是安裝前最後一次備份。不是就停止，不要開 App；安裝後的資料（如果原本有）還在 `after-install` 目錄，先回報。有 `history.sqlite` 時，再查還原後的資料庫和備份裡的同一張表，兩個輸出的筆數和最後一筆時間要相同：

```sh
BACKUP_FILE="$HOME/Desktop/MacHelper-backup-path.txt"
BACKUP="$(head -n 1 "$BACKUP_FILE")"
BACKUP_TIME="$(sed -n '2p' "$BACKUP_FILE")"
if [[ -z "$BACKUP_TIME" ]]; then
  BACKUP_TIME="$(basename "$BACKUP")"
fi
echo "備份：$BACKUP"
echo "備份時間：$BACKUP_TIME"
if [[ -f "$BACKUP/history.sqlite" ]]; then
  sqlite3 -readonly "$HOME/Library/Application Support/MacHelper/history.sqlite" \
    "SELECT COUNT(*), datetime(MAX(time), 'localtime') FROM sample;"
  sqlite3 -readonly "$BACKUP/history.sqlite" \
    "SELECT COUNT(*), datetime(MAX(time), 'localtime') FROM sample;"
else
  echo "這次備份沒有 history.sqlite，代表安裝前從未記錄過歷史。"
  ls -la "$HOME/Library/Application Support/MacHelper"
fi
```

有 `history.sqlite` 時，兩個輸出相同代表還原的是同一次備份，而且歷史停在安裝前的最後一筆，不會有安裝後新增的資料。備份沒有 `history.sqlite` 時，確認資料目錄只有備份裡的那些檔案，沒有安裝後才產生的歷史。如果 `-readonly` 因為 WAL 的 `-shm` 權限失敗，改用同一個 `SELECT` 但不加 `-readonly`；查詢本身不會改資料。再開啟 `/Applications/MacHelper.app`，確認版本與畫面正常；有 `history.sqlite` 時，歷史圖表的最後一點就是這一筆。App 開著過一分鐘後會寫入新的分鐘，所以筆數要在開啟 App 前查，或開啟後一分鐘內查；不要在 App 開了一陣子之後才用筆數判斷還原是否成功。

4. 如果這個版本有「設定 → 一般 → 背景記錄」，確認它是關閉；不論有沒有這個選項，`launchctl print` 都要找不到服務。

5. 還原或安裝後，在 Spotlight 搜尋 MacHelper、打開 Launchpad，並到「系統設定 → 一般 → 登入項目」檢查：只能看到一份 MacHelper。看到重複時，記下每個出現的位置，回報並暫時不要刪除任何東西。

### 拒絕或撤銷核准

拒絕核准：

1. 在「啟用前先記基準」的步驟 5 之後，不要到「系統設定 → 一般 → 登入項目」打開 MacHelper。等 1 分鐘。
   預期：設定頁維持「等待「登入項目」核准」；背景心跳停止，`machelper-cli monitor --status` 沒有新的心跳。待核准狀態下 `launchctl print` 會不會留下系統服務（job）還是待確認：找得到或找不到都先記錄，不要判定失敗。App 還開著時，App 自己的每分鐘歷史仍會增加；要查資料庫筆數，先結束 App 再查。
2. 把「MacHelper 結束後繼續記錄」關掉。預期：狀態變成「關閉」。先前如果記錄到有 job，這時要確認它消失；再用 `launchctl print` 確認找不到服務。

撤銷已經給的核准：

1. 到「系統設定 → 一般 → 登入項目 → 允許在背景執行」，把 MacHelper 關掉。
2. 回到 MacHelper，等 5 秒。預期：狀態變成「等待「登入項目」核准」，背景心跳停止更新。App 開著時，App 自己的歷史仍會增加，所以資料庫筆數要在結束 App 後再查；不要用 App 開著時的筆數判斷撤銷是否成功。重新打開核准可以恢復記錄。
3. 要完全移除註冊，把 App 的「MacHelper 結束後繼續記錄」關掉，再用 `launchctl print` 確認 `Could not find service`。

### 服務還在但 App 顯示關閉

這是設定檔說關閉、系統裡卻還有註冊的狀態。這一版 App 啟動時會嘗試取消註冊；失敗時設定頁會顯示「Couldn’t stop background recording: …」。

1. 開啟 MacHelper，停留 10 秒，再看設定頁有沒有錯誤訊息。
2. 重新查詢服務：

```sh
launchctl print gui/$(id -u)/com.machelper.MacHelper.MonitorAgent
```

3. 還找得到的話，把「MacHelper 結束後繼續記錄」打開再關掉一次，讓 App 再呼叫一次取消註冊，等 5 秒後重查。
4. 仍然存在就登出再登入，重查一次。還在的話，保留 `launchctl print` 的完整輸出和設定頁的錯誤訊息回報，不要自行刪除系統資料庫。

必要時可以讀設定檔確認意圖：

```sh
cat "$HOME/Library/Application Support/MacHelper/monitor-agent.json"
```

預期 `backgroundRecordingEnabled` 是 `false`。

### 第二個使用者

背景服務和歷史資料都只屬於註冊的那個使用者。驗證方法：

1. 在「系統設定 → 使用者與群組」建立或登入另一個本機使用者。第二個使用者不要開 MacHelper。
2. 在第二個使用者的終端機查服務與資料，並且實際嘗試讀第一個使用者的資料。把 `<第一個使用者的短名稱>` 換成第一個使用者家目錄的名稱：

```sh
FIRST_USER="<第一個使用者的短名稱>"
if ! id "$FIRST_USER" >/dev/null 2>&1; then
  echo "找不到使用者，重新填短名稱。"
elif [ "$FIRST_USER" = "$(id -un)" ]; then
  echo "這是你自己，請填第一個使用者的短名稱。"
elif [ ! -d "/Users/$FIRST_USER" ]; then
  echo "找不到 /Users/$FIRST_USER，重新填短名稱。"
else
  if [ -d "$HOME/Library/Application Support/MacHelper" ]; then
    echo "第二個使用者有自己的資料目錄，這是異常。"
  else
    echo "第二個使用者沒有資料目錄。"
  fi
  launchctl print gui/$(id -u)/com.machelper.MacHelper.MonitorAgent
  ls "/Users/$FIRST_USER/Library/Application Support/MacHelper"
  sqlite3 -readonly "/Users/$FIRST_USER/Library/Application Support/MacHelper/history.sqlite" \
    "SELECT COUNT(*) FROM sample;"
fi
```

   預期：`id`、家目錄和「不是目前登入的使用者」三項都成立，才會執行後面的查詢；任何一項不成立就照訊息重填。接著印出「第二個使用者沒有資料目錄」；`launchctl print` 顯示 `Could not find service`；`ls` 讀第一個使用者的目錄要出現 `Permission denied`，`sqlite3` 要出現 `unable to open database file` 或 `Permission denied`。只有明確被拒絕才算通過；`No such file or directory`、空白輸出或「看不到內容」都不算通過，先確認短名稱和路徑。如果看得到第一個使用者的資料，就是隔離失敗，停下來回報，不要繼續。

   `/Applications/MacHelper.app` 是共用的，但第二個使用者沒有允許背景執行，也不會寫入第一個使用者的資料。

   這台機器沒有第二個使用者時，這一步可以略過，但要標記為未驗證，不能當成通過。

3. 回到第一個使用者登入，重跑「確認服務已註冊」和「確認背景程式的心跳」的指令。預期：服務仍是 `running`，心跳和資料庫繼續更新。

### 觀察背景程式的 CPU 用量

背景記錄只需要每分鐘的平均，取樣間隔有 5 秒下限，所以空閒時不應該持續佔用 CPU。

1. 啟用背景記錄，結束 MacHelper，等 2 分鐘讓記錄器穩定。
2. 開啟「活動監視器」，選擇「顯示所有程序」，在搜尋欄輸入 `machelper-cli`。
3. 選取該程序，切到「CPU」標籤，觀察 1 分鐘。也可以在「顯示」選單把更新頻率設為 1 秒。
   預期：大部分時間接近 0%，只在取樣時出現短暫波動，不會長時間佔用明顯的 CPU。以原本每秒取樣的項目為例，取樣次數最多降到五分之一。
4. CPU 持續偏高時，記下活動監視器的數值、`machelper-cli monitor --status` 的輸出和「設定 → 選單列」啟用的項目，再回報。

### 已知限制

下面四項是已接受的行為，不會另外修復：

- 啟動時如果設定是關閉、系統卻還有註冊，App 會自動取消註冊。如果你在這幾秒內很快把「MacHelper 結束後繼續記錄」打開，這次自動取消可能把剛註冊的服務取消掉：開關看起來是開的，服務卻沒有註冊，畫面會顯示失敗或沒有回報。遇到就把開關關掉再打開一次，並用「確認服務已註冊」的指令確認服務已經回來。
- 系統回報 `.notFound`（找不到服務），或 `monitor-agent.json` 缺失、損壞時，App 不會自動清理殘留的註冊狀態。照「服務還在但 App 顯示關閉」處理，不要自己刪除系統資料庫。
- 背景記錄開關的意圖只存在 `~/Library/Application Support/MacHelper/monitor-agent.json`。這個檔案不代表系統真的已經註冊或取消註冊；註冊狀態以「系統設定 → 一般 → 登入項目」為主，`launchctl print` 用來確認服務有沒有真的載入。
- MacHelper 自己寫入歷史若失敗（例如磁碟滿、資料庫損壞），不論背景記錄是開是關，都只會在系統日誌留下 `MacHelper history write failed`，設定頁不會顯示。最壞情況是從失敗發生到恢復之間，還沒寫入的分鐘遺失；恢復後不會補齊。查詢時用「Console」搜尋 `MacHelper history write failed`。

其他限制：

- 背景程式寫入失敗會寫進心跳的 `last error`，App 顯示「失敗：…」，這個錯誤會保留到下一次寫入成功為止。在那之前，已經遺失的分鐘同樣不會補寫。
- 第一次升級到有背景記錄的版本時，如果 App 先開啟並遷移了資料庫，背景程式可能因為開啟失敗而結束。launchd 至少等 60 秒後重試；這段時間心跳會記錄資料庫無法開啟的原因，App 顯示失敗原因而不是單純的停止。

### 任何一步不如預期時怎麼停用

- 先回到設定頁關閉背景記錄。這會呼叫系統的取消註冊，是唯一會把註冊狀態清乾淨的正常做法。
- App 打不開或開關沒有反應時，到「系統設定 → 一般 → 登入項目 → 允許在背景執行」把 MacHelper 關掉。這會阻止服務繼續啟動。
- 不要手動把 plist 放進 `~/Library/LaunchAgents`，也不要用 `launchctl bootstrap` 載入它；這個服務由 `SMAppService` 註冊，手動載入會讓註冊狀態和系統設定不一致。
- 停用後如果 `launchctl print` 還找得到服務，先登出再登入，再檢查一次。仍然存在就回報 `launchctl print` 的完整輸出，不要自行刪除系統資料庫。

## 六、各功能的實機檢查清單

這一節補前面章節還沒列出的實機檢查。每項先寫要做什麼，再寫預期看到什麼；不符合預期時，記下操作、畫面訊息和時間，先不要自行修改資料。其他功能若已經在前面章節寫過，這裡不重複。

### 資料管理（保留天數與清除）

- [ ] 開「設定 → 一般 → 資料管理」。預期：看到「監控歷史」的大小，以及「保留監控歷史」目前的天數；預設是「7 天」。
- [ ] 把保留改成「1 天」，關掉設定視窗再打開。預期：仍是「1 天」。確認後改回「7 天」。
- [ ] 按「清除監控歷史…」，在確認對話框按 Return；再按一次，這次按 Esc。預期：兩次都取消，大小和資料不變。對話框要寫明程序用量歷史、感測器與核心歷史、其他設定與操作紀錄都不受影響。
- [ ] 再按一次「清除監控歷史…」，這次按「清除監控歷史」；如果背景記錄是開的，等一分鐘。預期：大小會重新讀取，沒有錯誤訊息；App 不崩潰，下一分鐘繼續寫入新資料。

已知限制：
- 清除當下正在累積的那一分鐘，會在清除後被丟掉，最多損失一分鐘的資料。
- 如果有其他程序正在讀取歷史資料庫，`history.sqlite-wal` 可能暫時不會縮小。這是盡力而為，不代表清除失敗。

### 操作紀錄（設定 → 歷史紀錄）

- [ ] 開「設定 → 歷史紀錄」。預期：最新的紀錄在最上面。
- [ ] 切換「今天／7 天／30 天／全部時間」，再用「類型」篩選。預期：列表和下方的筆數摘要一起改變。
- [ ] 看上方統計。預期：「移到垃圾桶」和「永久刪除」分開顯示；說明寫明大小取自操作紀錄，不代表磁碟空間變化，移到垃圾桶的項目在清空垃圾桶前仍占空間。
- [ ] 找一筆失敗紀錄。預期：有紅色的「失敗」徽章。列表裡沒有失敗紀錄時，這一項先註記跳過。
- [ ] 確認畫面沒有任何刪除按鈕。預期：只看到篩選、重新整理和「這個頁面只讀取紀錄，不會移除任何項目」的說明。
- [ ] 找先前測試留下的 `test-scheduled-clean`（如果有）。預期：出現在「其他」類型。

### GPU 溫度與 CPU 功耗

- [ ] 打開選單列小面板，切到 GPU。預期：溫度和「GPU 最高溫」都有數值，不是「不可用」；下方列出 `Tg` 開頭的 GPU 感測器。
- [ ] 切到 CPU，讓機器有一點負載（例如多開幾個 App）。預期：「CPU 功耗」有瓦數，負載時會變動，不是一直 0；沒有讀值時顯示「不可用」。
- [ ] 打開主視窗的「概覽」。預期：「功耗」磁磚顯示系統瓦數，下面寫「CPU … · GPU …」。
- [ ] 看「監控」的溫度歷史和「概覽」的溫度磁磚。預期：都仍是 CPU 類別的最高溫，不會混入 GPU 溫度。

已知限制：CPU 功耗是 SMC 的估算值，沒有用 `powermetrics` 校準；適合看趨勢，不代表絕對瓦數。

### 設定視窗一致性

先用淺色外觀看一次，再切到深色外觀看一次。

- [ ] 走過「一般、選單列、通知、Helper、歷史紀錄」五個分頁。預期：底色一致；次要文字是灰色；警告是琥珀色；錯誤是玫瑰色。
- [ ] 把視窗縮到最小，再放大。預期：最小 760×580 時沒有水平捲軸；放大時表單跟著伸展。
- [ ] 找一段長說明和一個錯誤訊息（例如匯入壞掉的設定檔）。預期：文字完整換行，沒有被截斷。
- [ ] 用 Tab 鍵走過控制項（Tab 沒反應時，先到系統設定 → 鍵盤開啟「鍵盤導覽」）。預期：每個控制項都有看得見的焦點環。
- [ ] 開 VoiceOver（⌘F5），走過五個分頁和「通知」的兩個步進器。預期：唸出目前選取的分頁；步進器唸出用途和目前數值（「CPU 溫度高於」、「可用磁碟空間低於」）。
- [ ] 到 Helper 分頁按「連線測試」產生紀錄，再選取一段文字。預期：可以選取並複製。

已知風險：琥珀色小字在淺色背景的對比偏低；如果看字吃力，記下是哪一段。

### 像素圖示

- [ ] 打開選單列小面板，依序點 CPU、GPU、記憶體、磁碟、網路。預期：每個分頁標題旁都有對應的像素圖示；淺色與深色都清楚，Retina 不模糊。
- [ ] 打開主視窗「概覽」。預期：八個磁磚（CPU、GPU、記憶體、溫度、風扇、功耗、網路、磁碟）都有像素圖示。
- [ ] 到「設定 → 選單列」把所有項目關掉。預期：選單列只剩 MacHelper 的像素圖示；用 VoiceOver 聽會唸「MacHelper」。
- [ ] 重新打開多個選單列項目。預期：各項目的寬度固定，數字變動時不會忽寬忽窄；排列和改動前一致，沒有逐項圖示。

### 程序用量歷史（預設關閉）

- [ ] 開「設定 → 一般 → 資料管理」。預期：「記錄程序用量」預設關閉；說明寫明只記程序名稱、CPU 與記憶體，不記路徑、命令列參數或使用者名稱。
- [ ] 打開開關，等約一分鐘，到「監控」選「1 小時」。預期：出現程序排行；每列顯示「N / M 分鐘」（出現的分鐘數／這段時間的總分鐘數），有讀不到的程序時顯示「每分鐘最多有 N 個程序無法讀取，未列入排行」。
- [ ] 在還沒有資料時看同一區。預期：顯示空狀態，說明要到「設定 → 一般 → 資料管理」開啟。
- [ ] 按「清除程序用量歷史…」。預期：先出現確認；按取消不變；確認後回到「監控」重新選一次時間範圍，排行清空，監控歷史的大小與保留天數不變。
- [ ] 同時打開背景記錄和程序用量，結束 MacHelper 等 3 到 5 分鐘再開。預期：離開期間仍有程序歷史；`machelper monitor --status` 有新的心跳。
- [ ] 關掉「記錄程序用量」，等兩分鐘。預期：排行不再增加，已記錄的資料不會立刻消失，仍照保留天數處理。
- [ ] 背景記錄開著，把選單列項目全部關掉，只開「記錄程序用量」。預期：背景記錄區顯示「沒有選取選單列指標」，並說明程序歷史仍會記錄；程序歷史繼續增加。

已知行為：這個開關只控制歷史記錄，監控畫面的即時程序列表不受影響。

### 感測器與核心歷史（預設關閉，資料量較大）

- [ ] 開「設定 → 一般 → 資料管理」。預期：「記錄感測器與核心用量」預設關閉；說明提到每分鐘會多幾十列，資料量較大；需要「設定 → 選單列」有 CPU 或溫度項目才會收集。
- [ ] 打開開關，確認選單列有 CPU 或溫度項目。到「監控」等 2 分鐘，選「1 小時」。預期：出現「感測器與核心歷史」；預設顯示第一個可用的核心群組；可從「選擇感測器」勾選其他核心與溫度感測器；每個項目都顯示最後出現時間。
- [ ] 關掉開關一分鐘再打開。預期：關閉期間的圖表是斷開的，不會把前後連成一條線。
- [ ] 按「清除感測器與核心歷史…」。預期：先確認；取消不變；確認後回到「監控」重新選一次時間範圍，只清這一類，監控歷史與程序歷史不變。
- [ ] 開「選擇感測器」看 Apple 晶片。預期：同時有 HID 感測器與 SMC 的 `Tg` 開頭 GPU 感測器，同名的不會重複。
- [ ] 開背景記錄，結束 MacHelper 等 3 分鐘再開。預期：感測器與核心歷史持續增加。
- [ ] 停止記錄或讓 Mac 睡眠一次，再回來看圖表。預期：中斷期間的圖表斷線；超過 10 分鐘沒回報的感測器在選單標「已不再回報」。
- [ ] 選「7 天」，勾選多條感測器。預期：圖表操作順暢，沒有明顯卡頓；如果卡頓，記下選了幾條。

Intel 機器才需要另外看：沒有效能核心或節能核心時，圖表不會補 0 的線。

### 設定備份與還原

- [ ] 開「設定 → 一般 → 備份與還原」，全選八個類別，按「匯出勾選的設定…」。預期：產生一個 JSON 檔；用文字編輯器打開可看到 `format`、`schemaVersion`、`excludedContents`，而且不含歷史、快取、操作紀錄、背景記錄與 Helper 註冊資訊。
- [ ] 立刻按「匯入設定…」選同一個檔。預期：每個類別都是「沒有變更」，沒有「套用匯入」按鈕。如果原本有「預設選取」的自訂清理規則，第一次匯入可能顯示「將被取代」，這是正確的，匯入一律改成不預設選取。
- [ ] 改幾個設定（例如 Dock 圖示和一個選單列項目），再匯入同一個檔。預期：對應類別顯示「將被取代」；按「套用匯入」後畫面和實際行為都回到匯出時的狀態；再匯入同一個檔應全部「沒有變更」。
- [ ] 在匯入預覽畫面按「取消」，再試一次按 Esc。預期：設定完全不變。按 Return 不會直接套用。
- [ ] 分別匯入一般 JSON、損壞的 JSON，以及把 `schemaVersion` 改成 `999` 的檔案。預期：前兩者顯示「這不是 MacHelper 的設定檔」；第三者顯示由較新版本建立、無法匯入；三種都沒有變更。
- [ ] 如果手上有含風扇設定的檔案，在 Helper 未執行或沒有可控風扇的 Mac 上匯入。預期：風扇類別顯示「無法匯入」，其他類別照常。Helper 未執行或風扇狀態還沒讀到時，匯出仍會預設勾選 Fans；只有在確認無法控制風扇時才取消勾選。只要動過任何一個類別的勾選，之後的狀態刷新就不會再自動調整 Fans。
- [ ] 匯入含自訂清理規則的檔案。預期：預覽逐條列出規則，並標明「匯入的規則不會預設選取」；套用後 `~/Library/Application Support/MacHelper/rules/` 裡的規則檔只剩 `imported-rules.json`，原本的其他 `.json` 規則檔被移到垃圾桶（可以救回）。
- [ ] 匯入含註解與空行的清理白名單或額外清除資料夾檔案。預期：套用後只剩路徑，註解與空行不保留。若檔案中的清單是空的，預覽要提示匯入會清除目前的值。
- [ ] 匯入不同語言的一般設定。預期：出現「重新啟動 MacHelper 後套用新的語言」和「重新啟動」按鈕。
- [ ] 在一鍵優化掃描或清理時打開「備份與還原」。預期：「匯入設定…」按鈕是停用的。
- [ ] 匯入後看「歷史紀錄」、「監控」和「Helper」分頁，並在終端機執行 `ls -l ~/.local/bin/machelper`。預期：監控歷史、程序歷史、感測器歷史與操作紀錄都還在；如果有上次的磁碟分析結果，應該還在；背景記錄狀態不變；Helper 註冊狀態不變，命令列工具連結仍存在。

已知限制：
- 套用過程中強制結束 App，可能留下部分套用的狀態。
- 匯入失敗後回復自訂規則時，結果是合併後的等價狀態，不是原本的多檔排版。
- 若還原時有規則檔無法移到垃圾桶，可移動的檔案會先被移走並如實顯示無法還原；留下的舊檔可能改變規則的合併順序，需要手動從垃圾桶取回或整理。
- 預覽只顯示類別層級摘要；風扇與通知不會逐值列出。
- 匯入啟用的風扇自動規則會立即被評估，Helper 仍會再驗證一次。
