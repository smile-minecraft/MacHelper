# 桌面小工具（Widget）可行性查證

查證日期：2026-11-04。本文只評估可行性與環境條件，不實作正式小工具，也沒有簽發憑證、取得 Apple 帳號憑證、註冊或變更 Apple 帳號、佈署描述檔、共享能力註冊或任何系統隱私權限。所有本機實驗都使用由讀者自行建立的臨時目錄（見「重現方式」），沒有碰 MacHelper 的正式建置產物、`.build`，也沒有修改 `project.yml`、Info.plist 或簽署設定。探針如果曾被 LaunchServices 註冊，完成後應以 `lsregister -u` 註銷。

最小探針的完整來源直接放在本文「重現方式」裡，是自包含的；不依賴任何可能被清理的本機暫存目錄。

## 結論先講

- **WidgetKit 版本條件**：WidgetKit framework 自 macOS 11.0 起可用；小工具放在「通知中心」自 macOS 11 世代就有，**放在桌面自 macOS 14 Sonoma 起支援**。是否能實際擺上桌面以系統版本為前提，而不是小工具作者可以繞過的事。來源見「官方文件與版本條件」。
- **目前機器**：macOS 27.2、arm64，滿足 macOS 14 以上的桌面小工具條件；MacHelper 部署目標 macOS 14.0 亦滿足 WidgetKit 的最低版本。
- **能編譯**：有實證。最小探針（應用程式＋WidgetKit 擴充功能，macOS 14 目標）在 Xcode 27.2 以 ad-hoc 簽署成功建置。
- **能簽署（ad-hoc）**：有實證。應用程式與擴充功能皆 ad-hoc 簽署有效。
- **以正式團隊簽署並使用 `<teamID>.<group name>` 格式**：未實證。ad-hoc 簽署成功**不代表**團隊格式可用；依官方文件，系統會檢查簽名裡的開發團隊 ID 是否與該 App Group 的 `<teamID>` 前綴相符，ad-hoc 沒有團隊 ID，無法證明這條路線在這台機器可行。本文沒有、也不應該再做團隊簽署來「順便」驗證。
- **實際共享容器的執行時期行為**：未驗證。簽名正確容器仍可能因 sandbox、檔案權限、macOS 15+ 的 SIP 保護、或使用者拒絕授權而讀不到。
- **直接讀一般 Application Support 目錄**：不能保證。同一使用者下仍可能受小工具擴充功能的 sandbox 狀態（macOS 上未證實）、檔案權限與系統隱私保護影響；本文沒有實測。
- **App 呼叫 `WidgetCenter.reloadTimelines` 不保證立即更新**：WidgetKit 對每個小工具有每日更新預算（常見約 40–70 次，約略對應 15–60 分鐘一次，且系統會學習使用者習慣、依可見度與最近一次 reload 時間調整；應用程式在前景時的 reload 不計入預算；時間軸項目至少間隔約 5 分鐘）。每次取樣呼叫 reload 只代表「請求」，不是「立即重繪」，也可能被系統合併。來源見「官方文件與版本條件」。
- **能實際加入桌面**：本次沒有實測（需要在使用者桌面 UI 操作），維持未驗證。
- **免費 Personal Team 能否使用 App Group**：不預設答案。官方文件規定 `<teamID>.<group name>` 不需佈署描述檔與註冊（系統比對簽名團隊 ID）；`group.` 前綴需佈署描述檔含該 entitlement、需註冊或 `REGISTER_APP_GROUPS=YES`。Apple 的「Supported capabilities (macOS)」表格是圖示，本文無法從文字確認 Personal Team 欄是否勾選 App groups。因此只能說「哪條路線對方案依賴最低」，不能說「免費帳號支援或不支援」。

## 本機環境與探針結果

### 環境（皆實際查證，2026-11-04）

- `sw_vers`：`ProductVersion: 27.2`、`BuildVersion: 26B123`；`uname -m`：`arm64`。
- `xcodebuild -version`（搭配已驗證的 `DEVELOPER_DIR=/Volumes/Smile-Data/Applications/Xcode-27.2.0.app/Contents/Developer`）：`Xcode 27.2`、`Build version 27B52`；`xcrun --sdk macosx --show-sdk-version`：`27.2`。
- `xcodegen --version`：`Version: 2.46.0`（本機已安裝）。
- MacHelper `project.yml`：deployment target macOS 14.0、`MACOSX_DEPLOYMENT_TARGET: 14.0`、Swift 6；沒有 `type: app-extension` 或 widget 類 target；App 沒有 `*.entitlements` 檔；`Signing.xcconfig` 預設 `CODE_SIGN_STYLE = Manual`、`CODE_SIGN_IDENTITY = -`（ad-hoc）；`Config/Local.xcconfig` 存在且已被 git 忽略，本次沒有讀取其內容（也未確認其中是否設定開發團隊）。
- `security find-identity -v -p codesigning`：有效身分 1 個（Apple Development 開發憑證），種類為開發憑證。帳號類型、團隊是否付費、團隊 ID 一律未讀取也不回報；本文只記「有一個有效的 Apple Development 身分可用」。

### 探針觀察到的事實與還原不出的事

探針專案由下方「重現方式」的來源建立，內含：

- `ProbeApp`：SwiftUI `Window`，macOS 14 目標，ad-hoc 簽署，內嵌一個 widget 擴充功能。
- `ProbeWidget`：`app-extension` 類型，`com.apple.widgetkit-extension`，用 `StaticConfiguration` 提供一個 `systemSmall`／`systemMedium` 靜態小工具，時間軸策略 `.after(+30 分鐘)`。

實際執行觀察（2026-11-04）：

- `xcodegen generate` 成功。
- `xcodebuild ... build` 得到 `BUILD SUCCEEDED`。
- `codesign -dvv`：應用程式與 `appex` 皆為 ad-hoc 簽署（`Signature=adhoc`）；appex 的 entitlements 只有除錯用的 `com.apple.security.get-task-allow=true`。
- `open WidgetProbeApp.app` 啟動成功、行程存活數秒後由測試者結束。直接以二進位執行時會立即結束且無輸出；`open` 是正常的啟動路徑。
- `pluginkit -m -A` 的輸出沒有列出探針的 `com.example.widgetprobe.app.widget`，而清單內有系統內建的 widget。差異原因未釐清：可能是 `pluginkit` 不列舉 WidgetKit 擴充功能、可能是註冊時機、也可能是 ad-hoc 簽署所致。這是推論，不是結論；本文不再以此排除或證明可行性。
- `log show` 在觀察窗口內找不到 `chronod` 與探針相關的註冊訊息；可能只是觀察時間太短或查詢方式不對。
- `lsregister -dump` 認出探針應用程式；完成後已以 `lsregister -u` 註銷。

各項目前的證據等級（三者等級不同，不可混用）：

| 項目 | 等級 | 說明 |
|---|---|---|
| 能編譯 | 有實證 | 探針 `BUILD SUCCEEDED`，含 widget 擴充功能 |
| 可簽署（ad-hoc） | 有實證 | 雙產物 codesign 有效 |
| 可簽署（正式團隊＋`<teamID>.` entitlements） | 未驗證 | 本次未用任何開發憑證簽署；ad-hoc 成功不是證據 |
| 可實際共享容器 | 未驗證 | 需要正式簽署後在機器上實測容器存取；未做 |
| 能實際加入桌面 | 未驗證 | 需在使用者桌面 UI 操作；小工具庫是否列出探針未確認 |
| 正式 MacHelper 可行 | 未驗證 | 正式整合未開始 |

## 官方文件與版本條件

以下皆於 2026-11-04 查閱：

- **WidgetKit（framework）**：availability 標示 macOS 11.0 起。Mac 上的原生小工具放在桌面與「通知中心」。來源：`https://developer.apple.com/documentation/widgetkit`
- **桌面擺放是 macOS 14 Sonoma 起的能力**：Apple Mac 使用手冊「Add and customize widgets on Mac」（適用 macOS Sonoma 14 起，目前 macOS 27／26 版本亦有對應頁面）說明在桌面或通知中心加入小工具的步驟。來源（macOS 14 版）：`https://support.apple.com/guide/mac-help/add-and-customize-widgets-mchl52be5da5/14.0/mac/14.0`；同文件亦有 macOS 27 版本。
- **Creating a widget extension**：小工具擴充功能需由應用程式內嵌；「For an app's widget to appear in the widget gallery, a person must launch the app that contains the widget at least once after the app is installed.」來源：`https://developer.apple.com/documentation/widgetkit/creating-a-widget-extension`
- **Keeping a widget up to date**：WidgetKit 對每個小工具個別分配每日更新預算；常見預算約 40–70 次／24 小時，約略對應 15–60 分鐘一次；預算與可見度、最近 reload 時間、應用程式是否在前景等因素有關；應用程式在前景時的 reload 不計入預算；時間軸項目應至少間隔約 5 分鐘；WidgetKit 可能合併多個小工具的 reload；WidgetKit 有時也會自行 reload 以保持內容新鮮。來源：`https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date.md`
- **WidgetCenter**：macOS 11.0 起可用；`reloadTimelines(ofKind:)` 只是請求，不保證立即生效。來源：`https://developer.apple.com/documentation/widgetkit/widgetcenter.md`
- **Adding interactivity to widgets and Live Activities**：按鈕／開關自 iOS 17／macOS 14 世代起提供（範例以 `if #available(iOS 17.0, *)` 包裹）；僅靜態顯示的小工具不受此限制。來源：`https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities.md`
- **App Groups Entitlement（`com.apple.security.application-groups`）**：macOS 10.7+。`group.<group name>` 需在開發者網站註冊；macOS 也支援 `<Developer team ID>.<group name>`，這種格式不需在開發者網站註冊。來源：`https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups` 與同文的 `.md` 版本。
- **Configuring app groups**：「In macOS, app groups can facilitate communication between sandboxed apps, and between sandboxed and nonsandboxed apps.」「You need to register app groups for iOS, iPadOS, tvOS, visionOS, and watchOS apps.」來源：`https://developer.apple.com/documentation/xcode/configuring-app-groups.md`
- **Accessing app group containers in your existing macOS app**：
  - macOS 15 起，即使應用程式沒有 App Sandbox，app group 容器也提供 System Integrity Protection；不屬於該群組的應用程式存取容器會觸發使用者授權提示。
  - 宣告 `group.` 開頭的群組時，「you need to include the group in your app's provisioning profile」；佈署描述檔必須包含所有 restricted entitlements，值必須相符（含萬用字元）。啟用 Automatically manage signing 並把 `REGISTER_APP_GROUPS` 設為 `YES` 時，Xcode 才會自動取得含該 entitlement 的新描述檔。
  - 使用 `<Developer team ID>.<group name>` 格式時：「you don't need a provisioning profile. The system checks that the team identifier prefix matches the developer team identifier you use to sign the app」。限制：不適用於 iOS／iPadOS／tvOS／visionOS／watchOS；Keychain Access Groups 不支援此前綴。
  - 來源：`https://developer.apple.com/documentation/xcode/accessing-app-group-containers.md`
- **Supported capabilities (macOS)**（Account Help Reference）：依方案列出 macOS 佈署描述檔可用的能力，含 App groups。表格以圖示呈現，本文無法確認 Personal Team 欄是否勾選 App groups。來源：`https://developer.apple.com/help/account/reference/supported-capabilities-macos/`

判讀：

- App Group entitlement 在 macOS 被定位為 unrestricted（Apple 工程師在開發者論壇的說明：macOS 早於佈署描述檔機制支援 App Group，因此 entitlement 是 unrestricted；`<teamID>.` 前綴由系統比對簽名團隊 ID；`group.` 前綴走開發者網站註冊＋描述檔授權）。來源：Apple Developer Forums「App Groups: macOS vs iOS」`https://developer.apple.com/forums/thread/721701`（Apple 工程師在開發者論壇的說明，非官方文件；僅作脈絡佐證）。
- 因此「macOS 上 `<teamID>.<group name>` 不需佈署描述檔」是官方文件直接寫明的；實際是否可用仍取決於簽名裡的團隊 ID 與系統檢查，**必須以正式簽署的建置驗證**。
- 不預設免費 Personal Team 的可用性；只能說 `<teamID>.` 對方案依賴最低，`group.` 需要描述檔授權。
- 桌面小工具以 macOS 14 為前提；MacHelper 部署目標 14.0 相容，但這只是框架層相容，不代表實機行為未實測。

## 資料共享的選項與待驗證條件

MacHelper 的資料流：`MonitorStore`（`App/Monitor/MonitorStore.swift`）每個採樣週期各模組取樣（SMC、HID 感測器、網路、磁碟、CPU 等）；`Sources/Storage/MetricsHistory.swift` 把每分鐘平均值寫進 `~/Library/Application Support/MacHelper/history.sqlite`（GRDB，預設 7 天保留，`MetricsHistory.defaultURL` 支援 `readOnly` 開啟）。沒有任何對外共享機制。

選項（推薦順序僅供討論，皆未實證）：

1. **應用程式寫快照、小工具讀檔案（不用 App Group）**。App 每次取樣後把**最小必要資料**（見下方條件）寫成 JSON 快照，小工具的 `getTimeline` 只負責讀取並顯示。
   - 為什麼不能直接當成可行：MacHelper 不是 sandboxed 應用程式，但**小工具擴充功能在 macOS 是否進入 sandbox 沒有本機實證**；同一使用者下的檔案讀取仍可能被 sandbox、檔案權限、macOS 15+ SIP 對容器的保護，或使用者拒絕授權擋住。這條路線必須以實機驗證。
2. **App Group `<teamID>.<group name>`（macOS 專屬格式，不需佈署描述檔與網站註冊）**。依官方文件不需佈署描述檔；macOS 15+ 起容器對非 sandboxed 應用程式也有 SIP 保護；對正式方案而言共享邊界最清楚。**仍屬未驗證**：簽名團隊 ID 比對、容器存取、以及以 ad-hoc 以外的簽署建置，都沒有實測。啟用 entitlement（對兩個 target 加入 macOS 專用 `.entitlements`）已屬既有授權範圍，不需再問一次；但簽發憑證、取得 Apple 帳號憑證、變更系統隱私權限，本次都不可自行做。
3. **App Group `group.<group name>`**。需開發者網站註冊＋描述檔含該 entitlement（或 `REGISTER_APP_GROUPS=YES` 讓 Xcode 自動取得），對「免費 Personal Team 能否支援」這個未知數沒有幫助；不建議採用。
4. **小工具直接讀 `history.sqlite`（readOnly）**。只作候選、不當成可行；原因：小工具要內嵌 GRDB、依賴 schema 穩定度，還要確認 WidgetKit 主機（chronod）讀同一檔案沒有鎖競爭；這些都沒有實測。

正式方案在決定前，應逐一驗證這些條件（缺一即不能宣稱可行）：

- **最小必要資料**：只共享選定的顯示數值（例如 CPU／GPU／記憶體／溫度／風扇／功耗＋更新時間＋可用性旗標），不整份 history、不含設定、日誌或任何可識別使用者身分的資料。
- **過期／不可用狀態**：快照超過約定時間未更新、讀取失敗或格式錯誤時，小工具必須顯示固定的「過期」或「不可用」標記，不顯示錯誤數值；正式方案要實測 App 關閉後的呈現。
- **存取權限**：容器或檔案的實際讀取結果、macOS 15+ SIP 提示、sandbox 狀態、使用者拒絕授權後的行為，全部要在實機確認；讀不到時不可退化成猜測數值。
- **WidgetKit 系統調度**：每日預算、入口間隔 ≥ 約 5 分鐘、app 在前景時 reload 不計入預算、reload 被合併的情況；這決定更新頻率設計，不是「取樣一次就 reload 一次」；更新的即時性不可當成規格保證。
- **失敗語意**：快照損毀、檔案不存在、容器未授權、磁碟錯誤各自的顯示，需要釘在測試當中。

小工具不應做的事：取代 root Helper 做 SMC 寫入；收取超出顯示需要的資料；把硬體行為用推估值表示。

## 後續建議

1. 先定義顯示內容與更新頻率（建議以時間軸項目間隔 ≥ 5 分鐘為界，`WidgetCenter.reloadTimelines` 當作「請求」用，不可當保證；App 在前景時的 reload 不計入預算）；每個數值都定義「可用／過期／不可用」三態。
2. 在 MacHelper 加入 `MacHelperWidgetExtension`（`type: app-extension`，`com.apple.widgetkit-extension`），內嵌於應用程式 target；先以「JSON 快照讀檔」做最小切片，實機確認：小工具出現在小工具庫、可拖上桌面、App 關閉後顯示過期狀態、容器／檔案讀取失敗顯示不可用。
3. 選項 1 一旦被實機否證，改走選項 2（`<teamID>.<group name>`）：兩個 target 各加 macOS 專用 entitlements；加入 entitlement 已獲授權，不需再詢問；但取得憑證、變更系統隱私權限仍需由使用者親自處理。`Local.xcconfig` 是否設定開發團隊由使用者確認（本文未讀）。
4. 正式整合時同時驗證 macOS 14.0 建置與目前系統版本；實測小、中尺寸、深色／淺色外觀。
5. 「免費 Personal Team 能否啟用 `group.` App Group」列為未知；不阻塞選項 2；不為此變更帳號或描述檔。
6. 完成實作前不動 `HANDOFF.md` 的小工具項目；實作與桌面實測由後續任務進行。

## 重現方式（自包含）

以下來源可直接重建探針；不引用任何本機固定路徑。2026-11-04 查證時，原始探針位於由讀者自建的臨時目錄；該目錄可能已被清理，因此本文保留完整來源。建議做法：

```bash
PROBE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/widget-probe.XXXXXX")"
cd "$PROBE_DIR"
mkdir -p Sources/ProbeApp Sources/ProbeWidget
# 把下方三個檔案寫到對應位置：project.yml、Sources/ProbeApp/ProbeApp.swift、Sources/ProbeWidget/ProbeWidget.swift
cat > project.yml <<'EOF'
name: WidgetProbe
options:
  bundleIdPrefix: com.example.widgetprobe
  deploymentTarget:
    macOS: "14.0"
packages: {}
targets:
  ProbeApp:
    type: application
    platform: macOS
    sources: [Sources/ProbeApp]
    info:
      path: Info.plist
      properties:
        CFBundleDisplayName: Widget Probe App
        LSMinimumSystemVersion: "14.0"
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.example.widgetprobe.app
        PRODUCT_NAME: WidgetProbeApp
        CODE_SIGN_STYLE: Manual
        CODE_SIGN_IDENTITY: "-"
        PROVISIONING_PROFILE_SPECIFIER: ""
    dependencies:
      - target: ProbeWidget
        embed: true
  ProbeWidget:
    type: app-extension
    platform: macOS
    sources: [Sources/ProbeWidget]
    info:
      path: ProbeWidget-Info.plist
      properties:
        CFBundleDisplayName: Probe Widget
        NSExtension:
          NSExtensionPointIdentifier: com.apple.widgetkit-extension
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.example.widgetprobe.app.widget
        PRODUCT_NAME: ProbeWidget
        CODE_SIGN_STYLE: Manual
        CODE_SIGN_IDENTITY: "-"
        PROVISIONING_PROFILE_SPECIFIER: ""
        SKIP_INSTALL: YES
EOF
cat > Sources/ProbeApp/ProbeApp.swift <<'EOF'
import SwiftUI

@main
struct ProbeApp: App {
    var body: some Scene {
        Window("Widget Probe", id: "main") {
            Text("Probe app for WidgetKit feasibility check")
                .padding(40)
        }
    }
}
EOF
cat > Sources/ProbeWidget/ProbeWidget.swift <<'EOF'
import WidgetKit
import SwiftUI

struct ProbeEntry: TimelineEntry {
    let date: Date
}

struct ProbeProvider: TimelineProvider {
    func placeholder(in context: Context) -> ProbeEntry { ProbeEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (ProbeEntry) -> Void) {
        completion(ProbeEntry(date: Date()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ProbeEntry>) -> Void) {
        let entry = ProbeEntry(date: Date())
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: entry.date) ?? entry.date.addingTimeInterval(1800)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct ProbeWidgetView: View {
    let entry: ProbeEntry
    var body: some View {
        Text("Widget probe")
            .font(.headline)
            .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct ProbeWidget: Widget {
    let kind = "ProbeWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ProbeProvider()) { entry in
            ProbeWidgetView(entry: entry)
        }
        .configurationDisplayName("Probe Widget")
        .description("Minimal WidgetKit feasibility probe")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct ProbeWidgetBundle: WidgetBundle {
    var body: some Widget {
        ProbeWidget()
    }
}
EOF

export DEVELOPER_DIR=/Volumes/Smile-Data/Applications/Xcode-27.2.0.app/Contents/Developer
xcodegen generate
xcodebuild -project WidgetProbe.xcodeproj -scheme ProbeApp -configuration Debug \
  -derivedDataPath "$PROBE_DIR/DerivedData" build
codesign -dvv "$PROBE_DIR/DerivedData/Build/Products/Debug/WidgetProbeApp.app"
codesign -dvv "$PROBE_DIR/DerivedData/Build/Products/Debug/WidgetProbeApp.app/Contents/PlugIns/ProbeWidget.appex"
codesign -d --entitlements - "$PROBE_DIR/DerivedData/Build/Products/Debug/WidgetProbeApp.app/Contents/PlugIns/ProbeWidget.appex"
# 若要驗證啟動，請以 open 啟動（直接執行二進位會立即結束）；結束後記得註銷：
# open "$PROBE_DIR/DerivedData/Build/Products/Debug/WidgetProbeApp.app"
# LS=/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister
# "$LS" -u "$PROBE_DIR/DerivedData/Build/Products/Debug/WidgetProbeApp.app"
```

注意：

- 這個探針只證明「編譯＋ad-hoc 簽署＋App 可啟動」，**不證明**桌面小工具可用、小工具庫會出現它，或任何 App Group／容器可讀。
- **小工具尚未實機加入桌面**，也未確認它出現在小工具庫；本文的限制以此為準，不得視為可生產。
- 完成後刪除 `$PROBE_DIR` 即可清除；若曾 `open` 過，記得以上面 `lsregister -u` 註銷。
- 環境差異會改變結果（系統版本、簽署能力、App Group 註冊狀態）；其他相符環境（macOS 14+、Xcode 27、xcodegen）預期能重現 build 成功，但不保證出現桌面小工具。
