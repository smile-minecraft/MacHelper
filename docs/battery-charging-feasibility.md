# MacBook 充電上限的可行性查證

查證日期：2026-11-04。本文是唯讀研究結果，不實作充電控制，也沒有對硬體做任何寫入；沒有啟動、建立、列舉或執行任何使用者捷徑，沒有修改 SMC、Helper、Helper 註冊狀態或任何系統設定。所有本機探查都限於唯讀命令。

本文把四類證據分開標示：**官方資料**（Apple 支援文章與使用手冊，附網址與日期）、**第三方資訊**（非 Apple 來源，僅作佐證）、**程式碼推論**（從程式碼與本機 ioreg 推得，未實測）、**本機實測**（本機執行唯讀命令的輸出）。

## 結論先講

- Apple 在 macOS Tahoe 26.4 為具 Apple silicon 的 Mac 推出了原生的充電上限功能（Charge Limit），由系統設定「系統設定 > 電池」控制，可選範圍 80%–100%（範圍由 Apple 官方文章確認）。這是官方支援的系統功能，行為可逆；「Apple 保證硬體安全」這類說法本文不做，因為文件沒有這樣寫。
- macOS 26.4 的 Shortcuts 也新增了「Set Battery Charge Limit」動作（官方 App 釋出說明，見「官方資料」）。`shortcuts run` 命令列工具可以執行使用者先建立好的捷徑（官方使用手冊）。所以「系統設定是唯一控制方式」「無法合法自動化」這類絕對說法是錯的，本文不再這樣主張。
- 但是，下列整合問題官方都沒有回答，必須等 MacBook 實機驗證，不能假定：Set Battery Charge Limit 動作的參數形式（例如是否接受百分比、是否會跳出提示）、目前上限值能否讀回、執行時的授權與信任流程、MacHelper 能否以文件化方式建立／安裝／署名一個捷徑給使用者、以及與系統設定並存時的行為。在這些都驗證之前，不能宣稱 MacHelper 完整支援自動化 Charge Limit。
- pmset 沒有充電上限設定（本機 man page，實測）；查不到 IOKit 公開 API 或 MDM 宣告（見下文）——查不到不等於 Apple 已宣告不存在，本文不從搜尋結果推斷官方否認。
- 第三方工具（如 AlDente）用 SMC 鍵寫入來控制充電，不是 Apple 官方行為，本文不採用、未測試，也不能當安全證據。官方的 Shortcuts 動作路線在實機驗證前，同樣只能算「已知存在、尚未驗證整合細節」。
- 這台 Mac mini 沒有實體電池（ioreg：BatteryInstalled = No），不能提供充電相關的實機證據。充電上限要到有電池、具 Apple silicon 且系統版本 ≥ macOS Tahoe 26.4 的 MacBook 上驗證，驗證方案在本文後段。

## 本機唯讀探查結果（Mac mini）

執行命令（皆唯讀，2026-11-04；以下標示「實測」）：

- `sw_vers`（實測）：`ProductName: macOS`、`ProductVersion: 27.2`、`BuildVersion: 26B123`。（系統回報的行為如此，照實記錄；同期 Apple 安全釋出公告列出 macOS Golden Gate 27 於 2026-09-14 釋出。版本字串與 build 號不一致，不影響本文結論。）
- `system_profiler SPHardwareDataType`（實測）：`Model Name: Mac mini`、`Model Identifier: Mac16,10`、`Model Number: Z1CF00029TA/A`、`Chip: Apple M4`、10 核心、32 GB。
- `system_profiler SPPowerDataType`（實測）：無 UPS、`Current Power Source: Yes`、`AC Charger Information: Family: 0x0000`、無電池區塊。
- `pmset -g batt`／`pmset -g ps`（實測）：`Now drawing from 'AC Power'`，沒有電池百分比行。
- `pmset -g cap`（實測）：AC Power 能力為 `displaysleep disksleep sleep womp autorestart autorestartatconnect standby powernap ttyskeepawake tcpkeepalive lowpowermode`，沒有任何充電上限相關項目。
- `pmset` 的 man page（本機執行 `man pmset | col -b`，實測）：全部 setting 與 GETTING 項目都沒有 charge limit／charging 相關項目。這只證明 pmset 沒有這個設定，不證明 Apple 沒有其他官方途徑。
- `ioreg -r -c AppleSmartBattery`（實測）：節點存在，但 `BatteryInstalled = No`、`BatteryPackCount = 0`、`CurrentCapacity = 0`、`MaxCapacity = 0`、`CycleCount = 0`、`ExternalConnected = Yes`、`AdapterDetails` 為 `FamilyCode=0`。
- `ioreg -l | grep -i charge`（實測）：只看到 `AppleSMCChargerUtil`（3 個，`CFBundleIdentifier` 為 `com.apple.driver.AppleSMC`）與電池覆寫鍵名（`OverrideBatteryInputMeasuredPs` 之類）；這些都不是 Apple 文件化的使用者介面，AppleSMCChargerUtil 的存在也不構成可寫入的官方 API。
- `Sources/Metrics/Battery.swift`（程式碼推論，未在此機實測該函式）：`BatterySampler.sample()` 讀 `AppleSmartBattery` 並在 `guard let current = int("CurrentCapacity"), let max = int("MaxCapacity"), max > 0` 不成立時回傳 nil。本機 ioreg 顯示 `MaxCapacity = 0`，因此推論 `sample()` 在此機會回傳 nil——這是依程式碼與唯讀 ioreg 的推論，不是執行結果，也不是「因為沒有 battery service」（服務存在，只是容量為零）。「未在真實電池硬體上驗證」的註解應保留到實機驗證完成。

以上只能證明「這台機器沒有可驗證的充電行為，pmset 沒有充電上限設定」，不能推斷其他機型，也不能推斷 Apple 沒有其他途徑。

## 官方資料

### Charge Limit（macOS Tahoe 26.4 起，系統設定）

來源：Apple 支援文章「About Optimized Battery Charging and Charge Limit on Mac」，<https://support.apple.com/en-us/102338>，Published Date: April 06, 2026，查閱日 2026-11-04。原文重點：

- 「**Charge Limit** — Requires macOS Tahoe 26.4 or later and a Mac with Apple silicon」。
- 設定路徑：Apple 選單 >「系統設定」>「電池」> 按「Charging」旁的資訊鈕 > 選擇 80%–100% 的 Charge Limit >「完成」。Apple 官方文章只確認範圍是 80% 到 100%；選項的固定級距（例如 5%）只有第三方示範提到（見「第三方資訊」，不作官方依據）。
- 「Use Charge Limit to set a limit on what your Mac considers a full charge. Your Mac will charge to within a few percentage points of the charge limit, then stop charging and show "Charged to [%] Limit" in the battery status menu. If the battery charge level drops more than 5% while connected to power, charging resumes…」。
- 達到上限後可從電池選單選「Charge to Full Now」充滿；無論用 Optimized Battery Charging 或 Charge Limit，系統「will occasionally charge to 100% to maintain accurate battery state-of-charge estimates」。
- Optimized Battery Charging 需要 macOS Big Sur 11 或更新；在 Tahoe 26.4 起同一個設定頁面可以順便設定 Charge Limit。
- 以上是官方支援的系統功能；「可逆、隨時可改回」來自同一頁面的設定流程，不是 Apple 對硬體安全提供額外保證。

### Shortcuts 的 Set Battery Charge Limit 動作（macOS 26.4 起）

來源：Apple 支援文章「What's new in Shortcuts for iOS, iPadOS, macOS, watchOS, and visionOS 26」，<https://support.apple.com/en-us/125148>，Published Date: March 26, 2026，查閱日 2026-11-04。原文重點：

- 「What's new in iOS, iPadOS, macOS, watchOS, and visionOS 26.4」— New Actions 列出 **“Set Battery Charge Limit” (iOS, iPadOS, and macOS)**。
- 同一頁面另有 macOS 26 新增的 Automations 觸發器（含「When my Mac connects to power」與「When battery level rises above 50%」）與 Control Center 列出捷徑為控制項的功能，意指官方預期這個動作可以放進自動化流程；但這一頁沒有描述 Set Battery Charge Limit 的參數、回傳值或限制。

來源：Apple 使用手冊「Run shortcuts from the command line」，<https://support.apple.com/guide/shortcuts-mac/run-shortcuts-from-the-command-line-apd455c82f02/mac>（Select version: macOS 27 Golden Gate），查閱日 2026-11-04。原文重點：

- 「You can use the Terminal app on your Mac to run a shortcut from the command line… you can pass documents, images, text, and more. Then the shortcut can pass the output to another process or write to a file.」
- 「Shortcuts are run using the shortcuts command… `shortcuts run "Combine Images"`」；可以用 `-i`／`--input-path` 傳入輸入、用 `-o`／`--output-path` 輸出、成功 exit 0、失敗 exit 1；也可以 `shortcuts list` 查詢使用者既有的捷徑。
- 也就是：命令列可以執行**使用者先建立好**的捷徑；它不是「直接呼叫 System Settings 底層 API」。手冊沒有說明 Set Battery Charge Limit 動作本身的行為細節。

合起來看：官方提供了「Shortcuts 動作」這條可自動化的官方途徑，`shortcuts run` 可以從終端機執行使用者建立好的捷徑。下列事項是官方**沒有**說明的，一律標為未知，需要 MacBook 實機驗證，不能假定程式可以直接呼叫該動作、或宣稱完整支援：

- Set Battery Charge Limit 動作的參數型別與允許值（是否吃百分比、是否接受變數、是否有固定級距）。
- 目前 Charge Limit 值能否被讀回（該動作似乎是 Set；有沒有對應的 Get／內建變數，手冊沒有說明）。
- 從 `shortcuts run` 執行時是否需要使用者互動、預先授權或確認提示；以及第一次執行時的信任流程。
- MacHelper 能否以文件化方式建立、安裝、署名或更新一個捷徑給使用者，而不需要使用者手動拖拉安裝；若不行，較可能只能引導使用者自己建立捷徑（尚未驗證），且不保證使用者會做。
- 動作與系統設定的優先順序（例如捷徑設了上限後，UI 顯示、校準充到 100% 的行為）。
- 該動作在沒有電池的機型上的行為（不存在、報錯、或靜默無效）。
- App Store 或 Helper 程序（xpc/root）對此動作的存取權限與限制。

### 哪些 Mac 符合資格

來源：Apple 支援文章「macOS Tahoe 26 is compatible with these computers」，<https://support.apple.com/en-us/122867>，查閱日 2026-11-04。清單包含 MacBook Pro（13/14/16 吋、2019 起，含 M1 2020 與 Intel 型號）、MacBook Air（M1 2020 起）、MacBook Neo (A18 Pro)、iMac（Apple silicon 2021 起與 2020 Retina 5K）、Mac mini（M1 2020 起）、Mac Studio（2022 起）、Mac Pro（2019 起）。但 Charge Limit 的硬性條件是「具 Apple silicon」：Intel 的 MacBook Pro（16 吋 2019、13 吋 2020 四個 Thunderbolt 3）雖列在 Tahoe 26 相容清單裡，不符合 Charge Limit 的 Apple silicon 條件，不應列入支援矩陣。本文所說「Apple 官方支援」的範圍，以支援文章 102338 的條件為準。Shortcuts 動作的適用機型由官方標示為「iOS, iPadOS, and macOS」的 26.4 新動作，沒有逐機型列表；能否在所有列在 122867 的 Apple silicon MacBook 上用，要實機確認。

桌上型機（Mac mini、iMac、Mac Studio、Mac Pro）沒有電池，Charge Limit 沒有適用對象；本機的 `BatteryInstalled = No` 就是實例。

### macOS 版本脈絡

來源：Apple 支援文章「Apple security releases」，<https://support.apple.com/en-us/100100>，查閱日 2026-11-04：macOS Tahoe 26 於 2025-09-15 釋出，列出的相容機型包含 Mac mini（2020 起）等；macOS Golden Gate 27 於 2026-09-14 釋出；Shortcuts 釋出說明（125148）與 Charge Limit 支援文章（102338）都對應 26.4 世代，使用手冊也以 macOS 27 為版本選項。依 102338 與 125148 的寫法，macOS 27 系統應涵蓋這兩個能力，但「macOS 27 每個小版本在所有 Apple silicon Mac 上的實際行為」尚未以實機驗證。

### 官方文件沒有回答、但也不能推斷「不存在」的部分

- `pmset` 沒有充電上限設定（本機 man page，實測）。
- MDM／設定描述檔：查不到 Apple 對 Charge Limit 的 MDM restriction 或 declaration。Jamf 社群討論（2026-03-13，「New Battery Charger Limit」，<https://community.jamf.com/general-discussions-2/new-battery-charger-limit-57887>，第三方）也記錄了找不到 pmset 與設定描述檔途徑；這是第三方佐證。搜尋不到官方說明不等於 Apple 宣告不存在，也不等於一定沒有，本文不做這個推斷。
- IOKit（Context7 函式庫 `/websites/developer_apple_iokit`，2026-11-04 查詢）：針對 battery charge limit／IOPMKit charge limit 查詢，沒有對應的公開 API 文件；Apple 開發者文件與論壇（developer.apple.com，2026-11-04 查詢）也沒有找到直接設定 Charge Limit 的公開符號。同樣地，找不到不等於官方否認；能見官宣的官方自動化途徑是 Shortcuts 動作。
- 唯讀讀取電池狀態屬於公開 API（`IOPSCopyPowerSourcesList`／`IOPSCopyPowerSourcesInfo`、`AppleSmartBattery` 唯讀屬性），但那是讀，不是寫。

## 第三方資訊（僅佐證，不作官方依據）

- AppleVis Podcast（<https://www.applevis.com/podcasts/how-limit-maximum-charge-your-macs-battery>，2026-02 前後，示範 macOS 26.4）：實機示範把 Charge Limit 設成 80、85、90、95、100%，顯示級距為 5%、以及設定頁面的滑桿位置與百分比的對應關係。這表示 5% 級距很可能成立，但 Apple 官方文章（102338）只確認範圍 80–100%，級距未經 Apple 文件確認。
- 9to5Mac（<https://9to5mac.com/2026/04/03/macos-26-4-adds-three-new-battery-features-on-mac-heres-how-to-use-them/>，2026-04-03）：描述 macOS 26.4 的三項電池功能，包括「Set Battery Charge Limit」Shortcuts 動作、可放進自動化（例如依時間觸發）、以及「Slow Charger」指示器。內容與官方 125148 相符，僅作佐證，不能取代官方文件。
- Macworld（<https://www.macworld.com/article/3063625/finally-apple-adds-macbook-battery-charge-limit-to-macos-26-4.html>，2026-02-17）：描述 Charge Limit 於 26.4 加入、80–100% 範圍。與官方 102338 一致，僅佐證。

## 非官方方式（僅記錄，不採用、不測試）

- 第三方充電限制工具（AlDente 等）透過 SMC 鍵（例如 `BCLM`、部分 Apple silicon 韌體上的 `CHWA` 之類）寫入限制值。這些鍵不是 Apple 公開文件化的使用者介面；寫入來源是逆向與社群經驗，不受 Apple 支援，行為隨韌體與機型改變。Apple StackExchange（<https://apple.stackexchange.com/questions/406957/can-i-tell-my-mac-to-charge-to-80-only>）與 GitHub gist（`NightMachinery/402863ccf37515a804b2f5fa15672375`）都記錄了這類做法與「Apple silicon 需要更新韌體才可能有效、行為不保證」的限制；兩者都是非官方來源。
- macOS Tahoe 26.4 之後，Apple 原生控制與這些 SMC 寫入（以及 Set Battery Charge Limit 動作）之間的相互作用，沒有任何資料可以證實；把它當場寫入來「驗證看看」是超出唯讀查證的範圍，本文沒有，也不建議任何人做。
- 判定：SMC 充電寫入路線，在具備（1）Apple 官方文件，或（2）明確、可復原的 Apple silicon 實機證據之前，都不能當成 MacHelper 的功能來宣稱支援。官方 Shortcuts 動作是可以實機驗證的方向，但在動作行為、授權模型與安裝信任流程查明之前，也不視為已可整合。

## 安全限制與回復方式

可採用或可驗證的（已有官方依據或可驗證）：

- 使用者自行到「系統設定 > 電池 > Charging」設定 Charge Limit；到同一個頁面可改回或關閉；行為可逆，不需要 Helper 或 root 權限。
- 「Charge to Full Now」隨時可以單次強制充滿。
- 使用者建立的捷徑裡放「Set Battery Charge Limit」，透過 `shortcuts run` 從終端機執行——這是官方文件描述的執行方式（見「Run shortcuts from the command line」）；執行結果的安全邊界（提示、授權、失敗行為）要等實機驗證。
- 原生功能是官方支援的系統設定，不等於 Apple 對硬體安全給出額外保證；文中一律以「官方支援」「可逆」描述，不用「保證」。
- Optimized Battery Charging 會學習使用習慣，盡量在充過 80% 前暫停；在 Tahoe 26.4 以上的設定頁同時可見。
- 系統可能為了維持電量估算偶爾充到 100%；設定上限下，電量掉超過 5% 才會恢復充電；這兩點是 Apple 文件的正常行為，不是故障。

不可採用的（沒有證據或明確危險）：

- 任何對 SMC 充電鍵的寫入；沒有官方文件、沒有 Apple silicon 實機證據、沒有經過驗證的回復機制。回復方式（刪除／還原鍵值）本身也未被 Apple 保證，所以不能當成安全網。
- 把「第三方工具在某些 Intel／某些 Apple silicon 韌體上似乎有效」當成安全證據——那是別的軟體的行為，不是 Apple 的保證，也不代表本專案的 Helper 可以安全寫入。
- 未先驗證就在這台 Mac mini（沒有實體電池）上測任何充電控制或捷徑動作；它無法產生有效結果，且有改動系統設定的風險。

需要注意的限制：

- Charge Limit 的可用下限是 80%（Apple 官方確認範圍）；有沒有更細級距（例如 5%）只有第三方說法，未經 Apple 文件確認。
- 有上限時充到之內的百分比、校準週期與恢復充電的門檻行為，由系統控制，不能由 MacHelper 微調。
- 低於 macOS Tahoe 26.4 的機器沒有 Charge Limit 與該 Shortcuts 動作（依 125148 與 102338 的版本標示）；Optimized Battery Charging 最低支援 Big Sur 11，且只是延遲充電，不是硬上限。
- Shortcuts `shortcuts run` 會回傳 exit 0／1，但「捷徑是否真的有改到 Charge Limit」需要驗證很夠：退出碼 0 不代表任意動作都成功套用，還要回頭看系統設定或充電行為。
- MacHelper 若要使用捷徑路徑，多半需要使用者先自己建立捷徑（官方手冊描述的是執行「已存在」的捷徑）；MacHelper 能否免安裝就自動擁有這個捷徑，是實機與 App Store 政策都要確認的問題。

## 現有程式可以安全做什麼（以及還不能做什麼）

現在可以做的：

- 讀取並顯示電池資訊（`BatterySampler` 讀 AppleSmartBattery；桌上型機沒有可用電池資料時回傳 nil；此行為的註解「未在真實電池硬體上驗證」應保留到實機驗證完成）。
- 在電池頁／選單提醒使用者：若需要設定充電上限，可自行到「系統設定 > 電池 > Charging」設定 Charge Limit（需 macOS 26.4+、Apple silicon），或在 Shortcuts 建立一個含「Set Battery Charge Limit」的捷徑；並提供文字指引。不由 MacHelper 呼叫任何未驗證的寫入。
- 提供使用者自建捷徑的說明（例如：在 Shortcuts 新增捷徑、加入 Set Battery Charge Limit、選擇 80%），讓使用者自行決定是否執行。

還不能做、要等驗證的：

- MacHelper 自動建立、安裝、簽署或更新一個內含 Set Battery Charge Limit 的捷徑。
- MacHelper 透過 `shortcuts run` 自動呼叫捷徑完成設定，並把結果回報給使用者。
- 任何對 SMC 的寫入或繞過系統設定的做法。
- 宣稱「MacHelper 支援／保證設定充電上限」——在實機矩陣全數通過前，一律寫「未驗證／需實機」。

若日後 Apple 提供公開 API 或 MDM 宣告，再評估以該介面實作啟用／停用／上限值。

## MacBook 實機驗證方案

設備條件：MacBook（具 Apple silicon）＋ macOS ≥ 26.4；至少一台執行 macOS 26.4–26.x。沒有設備就保留「未驗證」，不得宣稱支援。

驗證矩陣（標註「使用者授權」的格子需在使用者在場、明確同意下執行；全程不涉及 SMC 寫入）：

| 情境 | 機型／系統 | 要做的事 | 預期結果 | 判定 |
|---|---|---|---|---|
| 原生支援主路徑 | Apple silicon MacBook，macOS ≥ 26.4 | 記錄 `sw_vers`、`system_profiler SPHardwareDataType`；開「系統設定 > 電池 > Charging」；設定 Charge Limit 80% | 出現 Charge Limit 選項；電池充到接近 80% 停止，選單列顯示「Charged to 80% Limit」 | 官方文件與實機一致 |
| 上限行為 | 同上 | 觀察充電停止；掉超過 5% 後再接電源 | 充電恢復至上限 | 與 102338 一致 |
| 覆寫路徑 | 同上 | 在選單列選「Charge to Full Now」 | 充滿至 100% | 行為符合文件 |
| 還原路徑 | 同上 | 將 Charge Limit 改回 100%／關閉 Optimized Battery Charging 看狀態列 | Charge Limit 消失／改回預設 | 完全可逆 |
| 跨重開機／睡眠 | 同上 | 設定 80%，重開機、睡眠喚醒、拔插電源 | 設定持續生效 | 記錄實際行為 |
| 校準行為 | 同上 | 連續使用數天 | 偶爾充到 100% 屬正常（文件已述） | 記錄而非阻擋 |
| 應用層證據 | 同上 | 記錄 `pmset -g batt`、`system_profiler SPPowerDataType`、`ioreg -r -c AppleSmartBattery`（唯讀） | `BatteryInstalled = Yes`、有容量與循環次數 | 提供可重現數據 |
| Shortcuts 動作存在性 | 同上 | 在 Shortcuts 搜尋「Set Battery Charge Limit」 | 動作存在且可加入捷徑 | 與 125148 一致 |
| Shortcuts 手動執行（使用者授權） | 同上 | 使用者自建一個捷徑，內含 Set Battery Charge Limit 80%，執行 | Charge Limit 變成 80%（到系統設定確認） | 動作有效 |
| Shortcuts 參數確認（使用者授權） | 同上 | 編輯該捷徑，記錄動作的參數介面（接受哪種值、是否有提示） | 參數與級距具體記錄，不假定 | 記錄實際介面 |
| `shortcuts run` 從終端機執行（使用者授權） | 同上 | `shortcuts run "<使用者建立的捷徑名稱>"`；`echo $?`；再到系統設定確認 | exit 0；Charge Limit 改變 | 與手冊描述一致 |
| 退出碼語意 | 同上 | 讓捷徑輸入無效值或故意失敗 | exit 1，且 Charge Limit 不變 | 與手冊一致 |
| 讀回目前上限值 | 同上 | 檢查動作是否能輸出目前值、有無對應讀取動作 | 有或沒有，記錄實際 | 決定能否做狀態顯示 |
| 捷徑的安裝與信任流程 | 同上 | 研究 MacHelper 要怎麼讓使用者取得該捷徑（分享／匯入／使用者手動建立）；不實際分發 | 安裝途徑與限制列表 | App Store／權限風險 |
| 桌上型對照 | Mac mini／iMac／Mac Studio | 同上 UI 與唯讀命令 | 無電池、無 Charge Limit 或動作無法生效 | 確認不適用，不宣稱支援 |
| Intel MacBook | 16 吋 2019／13 吋 2020 4TB | 同上 UI 與 Shortcuts 搜尋 | 無 Charge Limit；動作預期不存在 | 標示不支援 |
| 舊系統 | 任一 MacBook，macOS ≤ 26.3 | 同上 UI 與 Shortcuts 搜尋 | 無 Charge Limit；Optimized Battery Charging 自 Big Sur 11 起可用 | 標示系統限制 |
| 缺欄位／變體 | macOS 27.x 各小版本 | 觀察本文所未驗證的版本差異 | 未知，記錄即可 | 未驗證項目 |

每個情境要保留的證據：`sw_vers` 輸出、`system_profiler` 的 model identifier、設定前後的截圖、`pmset -g batt`、`ioreg` AppleSmartBattery 摘要、Shortcuts 動作介面截圖（如適用）、系統版本與建置號、日期。除使用者授權的使用者自建捷徑執行外，不涉及任何寫入命令。

驗證通過的標準：所有「原生支援主路徑」與 Shortcuts 相關格子行為明確（成功或明確失敗），且全程沒有對硬體鍵寫入。Shortcuts 一格若無法取得明確答案，就保持「未驗證」，不封裝進 MacHelper。

回復方式（實機上）：把 Charge Limit 改回 100% 或關閉；若使用者建立了測試捷徑，使用者可自行刪除；MacHelper 不保存也不分發任何捷徑檔案。若驗證中發現異常，直接記錄並停止，不採取任何硬體操作。

## 目前可以與不能確定的事

可以確定：

- macOS Tahoe 26.4+ 具 Apple silicon 的 Mac 有官方、可逆的 Charge Limit 系統功能（102338，2026-04-06）；可選範圍 80%–100%；Charge to Full Now 與校準為正常行為。
- macOS 26.4 起，官方 Shortcuts 提供「Set Battery Charge Limit」動作（125148，2026-03-26，iOS/iPadOS/macOS）；`shortcuts run` 可以執行使用者既有的捷徑（官方使用手冊，macOS 27 版頁面）。
- Optimized Battery Charging 從 Big Sur 11 起可用。
- 這台 Mac mini 沒有實體電池（ioreg：`BatteryInstalled = No`、`MaxCapacity = 0`）；pmset 沒有充電上限設定（本機 man page）。
- Intel／桌上型機不在 Charge Limit 的 Apple silicon 條件內。

不能確定（保留未知，不因搜尋結果做推斷）：

- Set Battery Charge Limit 動作的參數、級距（5% 仍只有第三方說法）、回傳值與讀回方式。
- `shortcuts run` 執行該動作時的授權、提示與信任流程；退出碼與實際生效的對應關係。
- MacHelper 能否以文件化方式建立／安裝／更新該捷徑；以及 App Store 對此的限制。
- 官方是否有（或未來會有）更直接的 Charge Limit API；目前查無 IOKit／MDM 文件，但這是「未找到」，不是 Apple 官方否認。
- Charge Limit 與 Set Battery Charge Limit 在 macOS 27.x 所有小版本與所有 Apple silicon 機型上的逐機行為；本文查證時沒有實機。
- 原生功能在 Apple silicon 內部如何實作（SMC 或 Power Manager），Apple 沒有公開，我們也不會去探測。
- 任何對充電的 SMC 寫入是否安全；在有官方文件或 Apple silicon 實機安全證據之前，一律不採用。
- 第三方工具在 macOS 26.4+ 與原生功能並存時的行為；不測試、不背書。

## 後續需要使用者決定的事項

- 是否能提供一台具 Apple silicon、macOS ≥ 26.4 的 MacBook 做上述實機矩陣驗證（沒有就維持未驗證）。
- MacHelper 的定位：只做「唯讀電池狀態 + 文字指引（系統設定或使用者自建 Set Battery Charge Limit 捷徑）」，還是等實機查明動作行為後再評估整合；本文建議前者，後者不預先假定成立。
- 是否接受「Intel／macOS ≤ 26.3／桌上型機一律顯示不支援」的明確提示策略。
- 若原生 Charge Limit 不可用（例如舊系統），是否要記錄並顯示 Optimized Battery Charging 的說明文字（不控制、只說明）。
- 實機驗證時，是否由使用者在場授權執行「使用者自建的 Set Battery Charge Limit 捷徑」與 `shortcuts run`；未經同意，不在任何非本機環境執行。

## 參考來源

官方（Apple）：

- Apple 支援：About Optimized Battery Charging and Charge Limit on Mac，<https://support.apple.com/en-us/102338>，Published 2026-04-06，查閱 2026-11-04。
- Apple 支援：What's new in Shortcuts for iOS, iPadOS, macOS, watchOS, and visionOS 26（載明 26.4 新增 Set Battery Charge Limit 動作），<https://support.apple.com/en-us/125148>，Published 2026-03-26，查閱 2026-11-04。
- Apple 使用手冊：Run shortcuts from the command line，<https://support.apple.com/guide/shortcuts-mac/run-shortcuts-from-the-command-line-apd455c82f02/mac>（macOS 27 Golden Gate 版），查閱 2026-11-04。
- Apple 支援：macOS Tahoe 26 is compatible with these computers，<https://support.apple.com/en-us/122867>，查閱 2026-11-04。
- Apple 支援：Apple security releases（macOS Tahoe 26 / Golden Gate 27 釋出日期與相容機型），<https://support.apple.com/en-us/100100>，查閱 2026-11-04。
- Apple 使用手冊：If your Mac battery won't charge completely，<https://support.apple.com/guide/mac-help/mchlbfb7e12a/mac>，查閱 2026-11-04。

第三方（僅佐證）：

- AppleVis Podcast：How to Limit the Maximum Charge of Your Mac's Battery（5% 級距示範），<https://www.applevis.com/podcasts/how-limit-maximum-charge-your-macs-battery>，查閱 2026-11-04。
- 9to5Mac：macOS 26.4 adds three new battery features on Mac，<https://9to5mac.com/2026/04/03/macos-26-4-adds-three-new-battery-features-on-mac-heres-how-to-use-them/>，2026-04-03。
- Macworld：Finally! Apple adds MacBook battery charge limit to macOS 26.4，<https://www.macworld.com/article/3063625/finally-apple-adds-macbook-battery-charge-limit-to-macos-26-4.html>，2026-02-17。
- Apple StackExchange：Can I tell my Mac to charge to 80% only?，<https://apple.stackexchange.com/questions/406957/can-i-tell-my-mac-to-charge-to-80-only>。
- GitHub gist：charge limit SMC 做法，<https://gist.github.com/NightMachinery/402863ccf37515a804b2f5fa15672375>。
- Jamf 社群：New Battery Charger Limit，<https://community.jamf.com/general-discussions-2/new-battery-charger-limit-57887>，2026-03-13。

本機與程式：

- 本機 `man pmset(1)`、`sw_vers`、`system_profiler`、`pmset -g` 系列、`ioreg`（唯讀，2026-11-04）。
- Context7 函式庫 `/websites/developer_apple_iokit`：battery charge limit 查詢無公開 API 文件，2026-11-04。
- 專案 `Sources/Metrics/Battery.swift`（閱讀，未實測執行該函式）。
