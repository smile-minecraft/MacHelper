#!/usr/bin/env python3
"""One-time migration: hard-coded Traditional Chinese UI strings -> English source strings + zh-Hant
String Catalog entries. Kept for reference; new strings go straight into the catalogs.

Each entry: (chinese_literal, english_literal, wrap). Literals are Swift source including quotes.
wrap=1 wraps the English literal in String(localized:) (String contexts); wrap=0 keeps it as a
literal (SwiftUI LocalizedStringKey contexts)."""
import json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

T = {
'App/Disk/DiskAnalysisModel.swift': [
 (r'"個人資料夾"', r'"Home Folder"', 1),
 (r'"Macintosh HD（資料）"', r'"Macintosh HD (Data)"', 1),
 (r'"已移到垃圾桶：\(Fmt.bytes(Int64(clamping: report.trashedBytes)))。清空垃圾桶後才會真正釋放空間。"', r'"Moved \(Fmt.bytes(Int64(clamping: report.trashedBytes))) to the Trash. The space is freed when you empty the Trash."', 1),
 (r'"已移除 \(done.count) 項，\(failed.count) 項未處理：\(failed.first?.message ?? "")"', r'"Removed \(done.count) items; \(failed.count) not processed: \(failed.first?.message ?? "")"', 1),
 (r'"\(node.fileCount.formatted()) 個檔案"', r'"\(node.fileCount.formatted()) files"', 1),
 (r'"其他較小項目"', r'"Other smaller items"', 1),
 (r'"\(otherCount.formatted()) 個項目"', r'"\(otherCount.formatted()) items"', 1),
],
'App/Disk/DiskAnalysisView.swift': [
 (r'"停止"', r'"Stop"', 0), (r'"掃描"', r'"Scan"', 0), (r'"重新掃描"', r'"Rescan"', 0),
 (r'"旭日圖"', r'"Sunburst"', 0), (r'"矩形樹狀圖"', r'"Treemap"', 0), (r'"磁碟分析"', r'"Disk Analysis"', 0),
 (r'"選擇要分析的位置，然後按「掃描」。掃描只會讀取，不會修改任何檔案。"', r'"Choose a location to analyze, then click Scan. Scanning only reads; it never changes any files."', 0),
 (r'"掃描 \(model.target.title)"', r'"Scan \(model.target.title)"', 0),
 (r'"已掃描 \(model.progress.files.formatted()) 個檔案 · \(Fmt.bytes(Int64(clamping: model.progress.bytes)))"', r'"Scanned \(model.progress.files.formatted()) files · \(Fmt.bytes(Int64(clamping: model.progress.bytes)))"', 0),
 (r'"掃描失敗"', r'"Scan Failed"', 0),
 (r'"點一下圓環進入資料夾，點中心返回上一層；右鍵或拖到右側收集籃。"', r'"Click a ring to open a folder, click the center to go up; right-click or drag items to the collector."', 0),
 (r'"按兩下進入資料夾；右鍵或拖到右側收集籃。"', r'"Double-click to open a folder; right-click or drag items to the collector."', 0),
 (r'"內容"', r'"Contents"', 0), (r'"最大檔案"', r'"Largest Files"', 0),
 (r'"掃描到 \(Fmt.bytes(Int64(clamping: root.size)))，\(model.progress.files.formatted()) 個檔案，\(String(format: "%.1f", model.elapsed)) 秒"', r'"Found \(Fmt.bytes(Int64(clamping: root.size))) in \(model.progress.files.formatted()) files, \(String(format: "%.1f", model.elapsed)) s"', 0),
 (r'"磁碟已用 \(Fmt.bytes(v.used)) / \(Fmt.bytes(v.total))"', r'"Disk used \(Fmt.bytes(v.used)) of \(Fmt.bytes(v.total))"', 0),
 (r'"可清除 \(Fmt.bytes(v.purgeable))"', r'"Purgeable \(Fmt.bytes(v.purgeable))"', 0),
 (r'"macOS 需要時會自動釋放的空間（大多是 Time Machine 本機快照與系統快取）。"', r'"Space macOS frees automatically when needed (mostly local Time Machine snapshots and system caches)."', 0),
 (r'"本機快照 \(v.localSnapshots) 個"', r'"\(v.localSnapshots) local snapshots"', 0),
 (r'"有 \(model.progress.unreadableDirectories) 個資料夾無法讀取，結果不完整。"', r'"\(model.progress.unreadableDirectories) folders couldn’t be read; the results are incomplete."', 0),
 (r'"開啟「完整磁碟取用權限」設定"', r'"Open Full Disk Access Settings"', 0),
 (r'"收集籃"', r'"Collector"', 0),
 (r'"把要刪除的項目拖到這裡，確認後一次移到垃圾桶。"', r'"Drag items you want to delete here, then move them to the Trash in one go."', 0),
 (r'"移到垃圾桶…"', r'"Move to Trash…"', 0),
 (r'"把 \(model.collector.count) 個項目（\(Fmt.bytes(Int64(clamping: model.collectorSize)))）移到垃圾桶？"', r'"Move \(model.collector.count) items (\(Fmt.bytes(Int64(clamping: model.collectorSize)))) to the Trash?"', 0),
 (r'"移到垃圾桶"', r'"Move to Trash"', 0),
 (r'"項目會移到垃圾桶，可以從垃圾桶復原。系統與個人重要資料夾受保護，不會被移除。"', r'"Items go to the Trash and can be restored from there. System and important personal folders are protected and never removed."', 0),
],
'App/Disk/DiskCharts.swift': [
 (r'"旭日圖：\(focus.name)，\(Fmt.bytes(Int64(clamping: focus.size)))"', r'"Sunburst: \(focus.name), \(Fmt.bytes(Int64(clamping: focus.size)))"', 0),
 (r'"矩形樹狀圖：\(focus.name)，按兩下進入資料夾"', r'"Treemap: \(focus.name), double-click to open a folder"', 0),
 (r'"其他"', r'"Other"', 1),
 (r'"進入資料夾"', r'"Open Folder"', 0), (r'"加入收集籃"', r'"Add to Collector"', 0), (r'"在 Finder 中顯示"', r'"Show in Finder"', 0),
 (r'"快速查看"', r'"Quick Look"', 0), (r'"拷貝路徑"', r'"Copy Path"', 0),
],
'App/Fans/FanControlModel.swift': [
 (r'"自動（系統）"', r'"Automatic (System)"', 1), (r'"固定轉速"', r'"Fixed Speed"', 1), (r'"溫度曲線"', r'"Temperature Curve"', 1),
 (r'"已套用"', r'"Applied"', 1),
],
'App/Fans/FanControlView.swift': [
 (r'"這台 Mac 的風扇無法控制（\(status.strategy)）"', r'"Fans on this Mac can’t be controlled (\(status.strategy))"', 0),
 (r'"風扇控制需要 Helper（\(model.helperStatus.label)）"', r'"Fan control needs the Helper (\(model.helperStatus.label))"', 0),
 (r'"開啟 Helper 診斷"', r'"Open Helper Diagnostics"', 0),
 (r'"風扇 \(f.id)"', r'"Fan \(f.id)"', 0),
 (r'"Helper 指定 \(Int(c)) rpm"', r'"Helper target \(Int(c)) rpm"', 0),
 (r'"系統控制（目標 \(Int(f.reading.targetRPM))）"', r'"System control (target \(Int(f.reading.targetRPM)))"', 0),
 (r'"曲線溫度 \(Fmt.celsius(t))"', r'"Curve temperature \(Fmt.celsius(t))"', 0),
 (r'"最高溫 \(Fmt.celsius(h))"', r'"Hottest \(Fmt.celsius(h))"', 0),
 (r'"溫度超過安全上限，已暫時交還系統控制"', r'"Temperature exceeded the safety limit; control was handed back to the system"', 0),
 (r'"韌體似乎沒有套用 Helper 的轉速。部分機型要等系統先啟動風扇後，手動控制才會生效。"', r'"The firmware doesn’t seem to apply the Helper’s speed. On some models manual control only takes effect after the system has started the fans."', 0),
 (r'"模式"', r'"Mode"', 0),
 (r'"由 macOS 韌體依溫度自行控制風扇。這是最安全的設定。"', r'"The macOS firmware controls the fans based on temperature. This is the safest setting."', 0),
 (r'"轉速"', r'"Speed"', 0),
 (r'"固定轉速需要 App 持續執行；App 結束 \(Int(HelperTiming.heartbeatTimeout)) 秒後會自動交還系統。"', r'"A fixed speed needs the app to keep running; \(Int(HelperTiming.heartbeatTimeout)) seconds after the app quits, control returns to the system."', 0),
 (r'"設定檔"', r'"Profile"', 0),
 (r'"安靜"', r'"Quiet"', 0), (r'"平衡"', r'"Balanced"', 0), (r'"效能"', r'"Performance"', 0), (r'"自訂"', r'"Custom"', 0),
 (r'"新增控制點"', r'"Add point"', 0), (r'"移除控制點"', r'"Remove point"', 0),
 (r'"溫度來源"', r'"Temperature source"', 0), (r'"取最高值"', r'"Hottest"', 0), (r'"遲滯"', r'"Hysteresis"', 0),
 (r'"變化速率上限"', r'"Max ramp rate"', 0), (r'"\(Int($0)) rpm/秒"', r'"\(Int($0)) rpm/s"', 0),
 (r'"只加不減"', r'"Only increase"', 0),
 (r'"永不低於系統要求的轉速（建議）"', r'"Never go below the speed the system asks for (recommended)"', 0),
 (r'"交還系統控制"', r'"Return to System Control"', 0), (r'"套用"', r'"Apply"', 0),
 (r'"溫度"', r'"Temperature"', 0), (r'"目前"', r'"Current"', 0), (r'"風扇曲線"', r'"Fan curve"', 0),
 (r'"\(Int($0.celsius))度 \(Int($0.fraction * 100))%"', r'"\(Int($0.celsius))° \(Int($0.fraction * 100))%"', 1),
 (r'joined(separator: "，")', r'joined(separator: ", ")', 9),
],
'App/Monitor/MonitorPanel.swift': [
 (r'"5 分"', r'"5 min"', 1), (r'"15 分"', r'"15 min"', 1), (r'"1 小時"', r'"1 hour"', 1),
 (r'"系統監控"', r'"System Monitor"', 0), (r'"一鍵優化"', r'"Optimize"', 0), (r'"磁碟分析"', r'"Disk Analysis"', 0),
 (r'"解除安裝"', r'"Uninstall"', 0), (r'"設定…"', r'"Settings…"', 0), (r'"Helper 診斷"', r'"Helper Diagnostics"', 0), (r'"結束"', r'"Quit"', 0),
 (r'"總計"', r'"Total"', 1), (r'"效能核心"', r'"Performance cores"', 1), (r'"節能核心"', r'"Efficiency cores"', 1),
 (r'"使用率"', r'"Usage"', 1), (r'"使用中"', r'"In use"', 1),
 (r'"可用 " + Fmt.bytes($0.availableBytes)', r'"\(Fmt.bytes($0.availableBytes)) free"', 1),
 (r'"讀 \(Fmt.rate($0.readBytesPerSecond))/s · 寫 \(Fmt.rate($0.writeBytesPerSecond))/s"', r'"Read \(Fmt.rate($0.readBytesPerSecond))/s · Write \(Fmt.rate($0.writeBytesPerSecond))/s"', 1),
 (r'"讀取"', r'"Read"', 1), (r'"寫入"', r'"Write"', 1), (r'"下載"', r'"Download"', 1), (r'"上傳"', r'"Upload"', 1),
 (r'"電量"', r'"Charge"', 1), (r'"CPU 晶片最高溫"', r'"Hottest CPU sensor"', 1),
 (r'"風扇 \($0.id)：\(Int($0.minRPM))–\(Int($0.maxRPM)) rpm · \($0.mode == .automatic ? "自動" : "手動")"', r'"Fan \($0.id): \(Int($0.minRPM))–\(Int($0.maxRPM)) rpm · \($0.mode == .automatic ? String(localized: "Auto") : String(localized: "Manual"))"', 1),
 (r'"轉速"', r'"Speed"', 1), (r'"風扇控制…"', r'"Fan Control…"', 0), (r'"整機"', r'"System"', 1),
 (r'"效能核心 \(Fmt.percent(p)) · 節能核心 \(Fmt.percent(e))"', r'"P-cores \(Fmt.percent(p)) · E-cores \(Fmt.percent(e))"', 1),
 (r'"正常"', r'"Normal"', 1), (r'"警告"', r'"Warning"', 1), (r'"嚴重"', r'"Critical"', 1),
 (r'"壓力：\(pressure) · 已壓縮 \(Fmt.memory(m.compressedBytes)) · Swap \(Fmt.memory(m.swapUsedBytes))"', r'"Pressure: \(pressure) · Compressed \(Fmt.memory(m.compressedBytes)) · Swap \(Fmt.memory(m.swapUsedBytes))"', 1),
 (r'"充電中"', r'"Charging"', 1), (r'"已接電源"', r'"On power adapter"', 1), (r'"使用電池"', r'"On battery"', 1),
 (r'"循環 \(b.cycleCount) 次"', r'"\(b.cycleCount) cycles"', 1), (r'"健康度 \(Fmt.percent(h))"', r'"Health \(Fmt.percent(h))"', 1),
 (r'"此系統未提供"', r'"not available"', 1), (r'"時間"', r'"Time"', 0), (r'"系列"', r'"Series"', 0),
 (r'"全部感測器（\(readings.count)）"', r'"All sensors (\(readings.count))"', 0),
],
'App/Monitor/MonitorSettings.swift': [
 (r'"記憶體"', r'"Memory"', 1), (r'"磁碟"', r'"Disk"', 1), (r'"網路"', r'"Network"', 1), (r'"電池"', r'"Battery"', 1),
 (r'"溫度"', r'"Temperature"', 1), (r'"風扇"', r'"Fans"', 1), (r'"功耗"', r'"Power"', 1),
 (r'"數字"', r'"Number"', 1), (r'"折線"', r'"Line"', 1), (r'"長條"', r'"Bar"', 1), (r'"圓環"', r'"Ring"', 1),
],
'App/Monitor/MonitorSettingsView.swift': [
 (r'"精簡顯示（名稱在上、數值在下）"', r'"Compact (name above value)"', 0), (r'"監控項目"', r'"Items"', 0),
 (r'"此機型不支援"', r'"Not supported on this Mac"', 1), (r'"樣式"', r'"Style"', 0), (r'"頻率"', r'"Interval"', 0),
 (r'"\(Int($0)) 秒"', r'"\(Int($0)) s"', 0),
],
'App/Optimize/AutoCleanModel.swift': [
 (r'"請在「系統設定 → 一般 → 登入項目」允許 MacHelper 在背景執行。"', r'"Allow MacHelper to run in the background in System Settings → General → Login Items."', 1),
 (r'"背景排程設定失敗：\(error.localizedDescription)"', r'"Couldn’t set up the background schedule: \(error.localizedDescription)"', 1),
 (r'"無法儲存設定：\(error.localizedDescription)"', r'"Couldn’t save settings: \(error.localizedDescription)"', 1),
 (r'"無法載入清理規則"', r'"Couldn’t load the cleaning rules"', 1),
 (r'"已清理 \(config.lastItemCount) 項。"', r'"Cleaned \(config.lastItemCount) items."', 1),
],
'App/Optimize/AutoCleanView.swift': [
 (r'"自動清理"', r'"Auto Clean"', 0),
 (r'"定期在背景清理「低風險」項目：App 快取、日誌、瀏覽器與開發工具快取。正在執行的 App 會略過，不會清空垃圾桶，也不需要開著 MacHelper。"', r'"Regularly cleans low-risk items in the background: app caches, logs, browser and developer tool caches. Running apps are skipped, the Trash is never emptied, and MacHelper doesn’t need to be open."', 0),
 (r'"啟用自動清理"', r'"Enable Auto Clean"', 0), (r'"頻率"', r'"Frequency"', 0), (r'"每天"', r'"Daily"', 0), (r'"每週"', r'"Weekly"', 0),
 (r'"直接刪除，不經過垃圾桶"', r'"Delete directly, skipping the Trash"', 0),
 (r'"清掉的快取會立刻釋放空間，無法從垃圾桶復原（這些都是 App 會自己重建的資料）。"', r'"Cleaned caches free space immediately and can’t be restored from the Trash (apps rebuild this data themselves)."', 0),
 (r'"清掉的項目會移到垃圾桶，要清空垃圾桶後才會真正釋放空間。"', r'"Cleaned items go to the Trash; the space is freed once you empty it."', 0),
 (r'"上次執行"', r'"Last Run"', 0),
 (r'"\(model.config.lastItemCount) 項 · 移到垃圾桶 \(Fmt.bytes(Int64(clamping: model.config.lastTrashedBytes))) · 已刪除 \(Fmt.bytes(Int64(clamping: model.config.lastFreedBytes)))"', r'"\(model.config.lastItemCount) items · \(Fmt.bytes(Int64(clamping: model.config.lastTrashedBytes))) to the Trash · \(Fmt.bytes(Int64(clamping: model.config.lastFreedBytes))) deleted"', 0),
 (r'"還沒有執行過"', r'"Hasn’t run yet"', 0),
 (r'"下次：約 \(next.formatted(date: .abbreviated, time: .shortened)) 之後"', r'"Next: after about \(next.formatted(date: .abbreviated, time: .shortened))"', 0),
 (r'"背景排程需要你在「登入項目」允許。"', r'"The background schedule needs your approval in Login Items."', 0),
 (r'"開啟登入項目"', r'"Open Login Items"', 0),
 (r'"排程也可以用指令執行：machelper autoclean --now"', r'"You can also run it from the command line: machelper autoclean --now"', 0),
 (r'"清理中…"', r'"Cleaning…"', 0), (r'"立即執行一次"', r'"Run Now"', 0), (r'"完成"', r'"Done"', 0),
],
'App/Optimize/OptimizeModel.swift': [
 (r'"加入"', r'"Add"', 1), (r'"App 快取"', r'"App Caches"', 1), (r'"日誌"', r'"Logs"', 1), (r'"瀏覽器"', r'"Browsers"', 1),
 (r'"開發工具"', r'"Developer Tools"', 1), (r'"垃圾桶"', r'"Trash"', 1), (r'"下載"', r'"Downloads"', 1), (r'"郵件"', r'"Mail"', 1),
 (r'"裝置備份"', r'"Device Backups"', 1), (r'"其他規則"', r'"Other Rules"', 1), (r'"清空垃圾桶"', r'"Empty Trash"', 1),
 (r'"已釋放 \(Fmt.bytes(Int64(clamping: freed)))"', r'"Freed \(Fmt.bytes(Int64(clamping: freed)))"', 1),
],
'App/Optimize/OptimizeView.swift': [
 (r'"正在掃描可清理的項目…"', r'"Scanning for items to clean…"', 1), (r'"正在清理…"', r'"Cleaning…"', 1),
 (r'"自動清理：開"', r'"Auto Clean: On"', 0), (r'"自動清理…"', r'"Auto Clean…"', 0),
 (r'"定期在背景清理低風險項目"', r'"Regularly clean low-risk items in the background"', 0), (r'"一鍵優化"', r'"Optimize"', 0),
 (r'"先掃描並列出可清理的項目。你看過、勾選之後才會清理；預設移到垃圾桶，可以復原。"', r'"Scan first to list what can be cleaned. Nothing is cleaned until you’ve reviewed and checked it; by default items go to the Trash and can be restored."', 0),
 (r'"開始掃描"', r'"Start Scan"', 0), (r'"維護工作"', r'"Maintenance"', 0), (r'"需要 Helper"', r'"Needs Helper"', 0),
 (r'"Helper 未啟用"', r'"Helper not enabled"', 0), (r'"這台 Mac 不適用"', r'"Not applicable on this Mac"', 0),
 (r'"已選 \(Fmt.bytes(Int64(clamping: model.selectedBytes)))，\(model.selectedTaskCount) 項維護工作"', r'"\(Fmt.bytes(Int64(clamping: model.selectedBytes))) selected, \(model.selectedTaskCount) maintenance tasks"', 0),
 (r'"目前只是預覽，按「清理」之前不會刪除任何東西。"', r'"This is only a preview; nothing is deleted until you click Clean."', 0),
 (r'"重新掃描"', r'"Rescan"', 0), (r'"清理…"', r'"Clean…"', 0),
 (r'"清理已選的 \(Fmt.bytes(Int64(clamping: model.selectedBytes)))？"', r'"Clean the selected \(Fmt.bytes(Int64(clamping: model.selectedBytes)))?"', 0),
 (r'"清理"', r'"Clean"', 0),
 (r'"移到垃圾桶：\(Fmt.bytes(Int64(clamping: model.selectedTrashBytes)))，刪錯了可以從垃圾桶拿回來。"', r'"Move to the Trash: \(Fmt.bytes(Int64(clamping: model.selectedTrashBytes))). Anything removed by mistake can be restored from the Trash."', 1),
 (r'"永久刪除：\(Fmt.bytes(Int64(clamping: model.selectedPermanentBytes)))，這是清空垃圾桶裡原本的東西，無法復原。"', r'"Delete permanently: \(Fmt.bytes(Int64(clamping: model.selectedPermanentBytes))). This empties what’s already in the Trash and can’t be undone."', 1),
 (r'"執行 \(model.selectedTaskCount) 項維護工作。"', r'"Run \(model.selectedTaskCount) maintenance tasks."', 1),
 (r'"每一項都會記錄在操作紀錄裡，之後可以查看。"', r'"Every item is recorded in the operation log so you can review it later."', 1),
 (r'"最近使用"', r'"Recently used"', 0),
 (r'"專案建置產物（\(Fmt.bytes(Int64(clamping: a.totalSize)))）"', r'"Project Build Artifacts (\(Fmt.bytes(Int64(clamping: a.totalSize))))"', 0),
 (r'"已略過 \(a.skipped.count) 項：含有 git 追蹤的檔案或巢狀 repository。"', r'"Skipped \(a.skipped.count) items: they contain git-tracked files or a nested repository."', 0),
 (r'"專案建置產物"', r'"Project Build Artifacts"', 0),
 (r'"加入你放專案的資料夾，就能找出 node_modules、target、.build 等可以重建的產物。"', r'"Add the folders where you keep projects to find rebuildable artifacts such as node_modules, target and .build."', 0),
 (r'"加入專案資料夾…"', r'"Add Project Folder…"', 0), (r'"清理完成"', r'"Cleaning Complete"', 0),
 (r'"移到垃圾桶"', r'"Moved to Trash"', 0), (r'"已永久釋放"', r'"Freed permanently"', 0), (r'"未處理"', r'"Not processed"', 0),
 (r'"\(model.failures.count) 項"', r'"\(model.failures.count) items"', 0),
 (r'"移到垃圾桶的空間要等清空垃圾桶後才會釋放。"', r'"Space used by items in the Trash is freed when you empty the Trash."', 0),
 (r'"清空垃圾桶"', r'"Empty Trash"', 0), (r'"未處理的項目"', r'"Items not processed"', 0),
 (r'"所有操作都記錄在 ~/Library/Logs/MacHelper/operations.jsonl"', r'"All operations are logged in ~/Library/Logs/MacHelper/operations.jsonl"', 0),
 (r'"再掃描一次"', r'"Scan Again"', 0), (r'"略過：\(reason)"', r'"Skipped: \(reason)"', 0),
 (r'"需要完整磁碟取用權限"', r'"Needs Full Disk Access"', 0), (r'"沒有可清理的項目"', r'"Nothing to clean"', 0), (r'"部分"', r'"Partial"', 0),
 (r'"低風險"', r'"Low risk"', 1), (r'"中風險"', r'"Medium risk"', 1), (r'"高風險"', r'"High risk"', 1),
],
'App/Shell/AppDelegate.swift': [
 (r'"MacHelper 系統監控"', r'"MacHelper System Monitor"', 1), (r'"MacHelper 設定"', r'"MacHelper Settings"', 1),
 (r'"風扇控制"', r'"Fan Control"', 1), (r'"磁碟分析"', r'"Disk Analysis"', 1), (r'"一鍵優化"', r'"Optimize"', 1),
 (r'"解除安裝 App"', r'"Uninstall Apps"', 1), (r'"Helper 診斷"', r'"Helper Diagnostics"', 1),
],
'App/Uninstall/UninstallModel.swift': [
 (r'"已解除安裝 \(plan.app.name)，\(Fmt.bytes(Int64(clamping: report.trashedBytes))) 已移到垃圾桶。"', r'"Uninstalled \(plan.app.name); \(Fmt.bytes(Int64(clamping: report.trashedBytes))) moved to the Trash."', 1),
 (r'"部分項目未處理（\(failed.count) 項）：\(failed.first?.message ?? "")"', r'"Some items weren’t processed (\(failed.count)): \(failed.first?.message ?? "")"', 1),
 (r'"已移到垃圾桶：\(Fmt.bytes(Int64(clamping: report.trashedBytes)))"', r'"Moved to the Trash: \(Fmt.bytes(Int64(clamping: report.trashedBytes)))"', 1),
],
'App/Uninstall/UninstallView.swift': [
 (r'"已移除 App 的殘留"', r'"Leftovers of Removed Apps"', 0), (r'"搜尋 App"', r'"Search Apps"', 0),
 (r'"名稱"', r'"Name"', 0), (r'"大小"', r'"Size"', 0), (r'"最久沒用"', r'"Least Recently Used"', 0),
 (r'"上次使用 \($0.formatted(date: .abbreviated, time: .omitted))"', r'"Last used \($0.formatted(date: .abbreviated, time: .omitted))"', 1),
 (r'"選擇要解除安裝的 App"', r'"Choose an App to Uninstall"', 0),
 (r'"會一併找出它在「資源庫」裡留下的快取、設定與資料，你可以逐項決定要不要刪。"', r'"MacHelper also finds the caches, settings and data it left behind, and you decide item by item what to delete."', 0),
 (r'"無法解除安裝：\(reason)"', r'"Can’t uninstall: \(reason)"', 0),
 (r'"\(app.name) 正在執行，請先結束。"', r'"\(app.name) is running. Quit it first."', 0),
 (r'"結束 \(app.name)"', r'"Quit \(app.name)"', 0),
 (r'"一併移除 App 資料（Application Support、Containers、~/.名稱：可能有你的文件、設定或登入資訊）"', r'"Also remove app data (Application Support, Containers, ~/.name: may contain your documents, settings or sign-in data)"', 0),
 (r'"\(item.evidence.title)，跟著「一併移除 App 資料」一起選"', r'"\(item.evidence.title); selected together with “Also remove app data”"', 1),
 (r'"在 Finder 中顯示"', r'"Show in Finder"', 0), (r'"找到但不會刪除"', r'"Found but Kept"', 0),
 (r'"系統層級（需要管理員權限，請手動移除）"', r'"System Level (needs an administrator; remove manually)"', 0),
 (r'"已選 \(Fmt.bytes(Int64(clamping: plan.selectedSize)))"', r'"\(Fmt.bytes(Int64(clamping: plan.selectedSize))) selected"', 0),
 (r'"解除安裝…"', r'"Uninstall…"', 0), (r'"解除安裝 \(app.name)？"', r'"Uninstall \(app.name)?"', 0), (r'"移到垃圾桶"', r'"Move to Trash"', 0),
 (r'"已選的 \(plan.items.filter(\.selected).count) 個項目（\(Fmt.bytes(Int64(clamping: plan.selectedSize)))）會移到垃圾桶，需要時可以拿回來。App Store 的 App 可能會要求輸入管理員密碼。"', r'"The \(plan.items.filter(\.selected).count) selected items (\(Fmt.bytes(Int64(clamping: plan.selectedSize)))) will be moved to the Trash, where you can get them back. App Store apps may ask for an administrator password."', 0),
 (r'"這些項目以 bundle ID 命名，但對應的 App 已經找不到；背景啟動項目則是它要啟動的程式已不存在。這是推測，請逐項確認後再勾選，預設全部不勾。"', r'"These items are named after a bundle ID whose app can no longer be found; for background items, the program they start no longer exists. This is a guess: review each item before checking it. Nothing is checked by default."', 0),
 (r'"重新搜尋"', r'"Search Again"', 0), (r'"移到垃圾桶…"', r'"Move to Trash…"', 0),
 (r'"把選取的殘留檔（\(Fmt.bytes(Int64(clamping: model.selectedOrphanBytes)))）移到垃圾桶？"', r'"Move the selected leftovers (\(Fmt.bytes(Int64(clamping: model.selectedOrphanBytes)))) to the Trash?"', 0),
 (r'"搜尋已移除 App 的殘留"', r'"Find Leftovers of Removed Apps"', 0),
],
'Sources/CleanEngine/AppUninstaller.swift': [
 (r'"App 本體"', r'"App bundle"', 1), (r'"快取"', r'"Caches"', 1), (r'"日誌"', r'"Logs"', 1), (r'"當機報告"', r'"Crash reports"', 1),
 (r'"視窗狀態"', r'"Saved window state"', 1), (r'"網頁資料"', r'"Web data"', 1), (r'"偏好設定"', r'"Preferences"', 1),
 (r'"背景啟動項目"', r'"Background items"', 1), (r'"指令（~/.local/bin）"', r'"Commands (~/.local/bin)"', 1),
 (r'"外掛與延伸功能"', r'"Plug-ins and extensions"', 1), (r'"App 資料（Application Support）"', r'"App data (Application Support)"', 1),
 (r'"沙盒容器（Containers）"', r'"Sandbox containers (Containers)"', 1), (r'"共用容器（Group Containers）"', r'"Shared containers (Group Containers)"', 1),
 (r'"家目錄裡的資料（~/.名稱）"', r'"Data in your home folder (~/.name)"', 1),
 (r'"bundle ID 相符"', r'"Bundle ID matches"', 1), (r'"App 內的輔助程式或延伸功能"', r'"Helper or extension inside the app"', 1),
 (r'"App 宣告的 App Group"', r'"App Group declared by the app"', 1), (r'"容器資訊指向這個 App"', r'"Container metadata names the app"', 1),
 (r'"執行的程式在 App 裡"', r'"Runs a program inside the app"', 1), (r'"Homebrew 清單列出"', r'"Listed by Homebrew"', 1),
 (r'"MacHelper 規則"', r'"MacHelper rule"', 1), (r'"相關的 bundle ID"', r'"Related bundle ID"', 1), (r'"同一個開發團隊"', r'"Same developer team"', 1),
 (r'"會用到 App 的資料"', r'"Uses the app’s data"', 1), (r'"依 App 名稱比對，請確認"', r'"Matched by app name, please check"', 1),
 (r'"依開發者名稱比對，請確認"', r'"Matched by developer name, please check"', 1), (r'"對應的 App 已不存在"', r'"Its app no longer exists"', 1),
 (r'"Apple 內建 App，由 macOS 管理"', r'"Built-in Apple app, managed by macOS"', 1), (r'"MacHelper 自己"', r'"MacHelper itself"', 1),
],
'Sources/CleanEngine/AutoClean.swift': [
 (r'"\(report.failures.count) 項未處理：\(report.failures.first?.message ?? "")"', r'"\(report.failures.count) items not processed: \(report.failures.first?.message ?? "")"', 1),
],
'Sources/CleanEngine/CleanScanner.swift': [
 (r'"\(app) 正在執行"', r'"\(app) is running"', 1), (r'"App 正在執行"', r'"App is running"', 1),
],
'Sources/CleanEngine/LeftoverFinder.swift': [
 (r'"MacHelper 規則：不屬於這個 App"', r'"MacHelper rule: doesn’t belong to this app"', 1),
 (r'"~/\((path as NSString).lastPathComponent) 屬於獨立安裝的指令列工具 \(lname)，不會跟著 App 刪除"', r'"~/\((path as NSString).lastPathComponent) belongs to the separately installed command-line tool \(lname) and isn’t removed with the app"', 1),
 (r'"是 git 儲存庫，可能是你自己的設定或專案"', r'"It’s a git repository, possibly your own settings or project"', 1),
 (r'"指令 \(Fmt.short(cmd, home: home)) 也在使用它，可能是另外安裝的指令列工具"', r'"The command \(Fmt.short(cmd, home: home)) also uses it; it may be a separately installed command-line tool"', 1),
],
'Sources/CleanEngine/Maintenance.swift': [
 (r'"重置 QuickLook 縮圖快取"', r'"Reset QuickLook thumbnail cache"', 1),
 (r'"清除預覽縮圖快取並重新載入 QuickLook 外掛，修正縮圖錯誤或過時。"', r'"Clears the preview thumbnail cache and reloads QuickLook plug-ins, fixing wrong or stale thumbnails."', 1),
 (r'"刪除無法使用的模擬器"', r'"Delete unavailable simulators"', 1),
 (r'"移除對應 runtime 已不存在的 iOS 模擬器（xcrun simctl delete unavailable）。"', r'"Removes iOS simulators whose runtime no longer exists (xcrun simctl delete unavailable)."', 1),
 (r'"重新啟動 Dock"', r'"Restart the Dock"', 1),
 (r'"Dock 或 Launchpad 圖示異常時有用。Dock 會閃一下後恢復。"', r'"Useful when Dock or Launchpad icons misbehave. The Dock flickers briefly, then comes back."', 1),
 (r'"重新啟動 Finder"', r'"Restart Finder"', 1),
 (r'"Finder 卡住或圖示異常時有用。進行中的拷貝會被中斷。"', r'"Useful when Finder hangs or shows wrong icons. Copies in progress are interrupted."', 1),
 (r'"重建 LaunchServices 資料庫"', r'"Rebuild the LaunchServices database"', 1),
 (r'"修正「打開方式」選單重複或錯誤。會重置檔案類型的預設 App，需要幾分鐘。"', r'"Fixes duplicate or wrong entries in the Open With menu. Resets default apps for file types and takes a few minutes."', 1),
 (r'"清除 DNS 快取"', r'"Flush the DNS cache"', 1),
 (r'"網域解析錯誤或剛改過 DNS 設定時有用。"', r'"Useful when name resolution goes wrong or right after changing DNS settings."', 1),
 (r'"釋放閒置記憶體"', r'"Free inactive memory"', 1),
 (r'"清空磁碟快取（purge）。macOS 本來就會自動管理，通常不需要；之後一段時間檔案讀取會變慢。"', r'"Purges the disk cache (purge). macOS manages this itself, so it’s rarely needed; file reads are slower for a while afterwards."', 1),
 (r'"執行系統例行維護腳本"', r'"Run periodic maintenance scripts"', 1),
 (r'"執行 daily / weekly / monthly 例行腳本（輪替與壓縮系統日誌、清理暫存）。"', r'"Runs the daily / weekly / monthly scripts (rotates and compresses system logs, cleans temporary files)."', 1),
 (r'"Homebrew 清理舊版本"', r'"Homebrew: remove old versions"', 1),
 (r'"移除已安裝套件的舊版本與過期下載（brew cleanup）。"', r'"Removes old versions of installed packages and stale downloads (brew cleanup)."', 1),
 (r'"Docker 清理"', r'"Docker cleanup"', 1),
 (r'"移除停止的容器、未使用的網路、懸空映像與建置快取（docker system prune -f）。需要 Docker 正在執行。"', r'"Removes stopped containers, unused networks, dangling images and build cache (docker system prune -f). Docker must be running."', 1),
],
}

# Strings that only exist on the English side (nested in replacements) and need a translation.
EXTRA = {'App': {'Auto': '自動', 'Manual': '手動'}}

INT_HINTS = ('.count', 'Count', 'f.id', '$0.id', 'v.localSnapshots', 'unreadableDirectories')


def parts(lit):
    """Split a Swift string literal (with quotes) into ['text', ('expr',), 'text', ...]."""
    s = lit[1:-1]
    out, buf, i = [], '', 0
    while i < len(s):
        if s.startswith('\\(', i):
            out.append(buf); buf = ''
            depth, j, in_str = 1, i + 2, False
            while j < len(s):
                c = s[j]
                if in_str:
                    if c == '\\': j += 1
                    elif c == '"': in_str = False
                elif c == '"': in_str = True
                elif c == '(': depth += 1
                elif c == ')':
                    depth -= 1
                    if depth == 0: break
                j += 1
            out.append((s[i + 2:j],))
            i = j + 1
            continue
        if s[i] == '\\' and i + 1 < len(s):
            buf += {'n': '\n', 't': '\t', '"': '"', '\\': '\\'}.get(s[i + 1], s[i + 1]); i += 2; continue
        buf += s[i]; i += 1
    out.append(buf)
    return out


def spec(expr):
    return '%lld' if expr.startswith('Int(') or any(expr.endswith(h) for h in INT_HINTS) else '%@'


def fmt(p, positions=None):
    text, n = '', 0
    for x in p:
        if isinstance(x, tuple):
            sp = spec(x[0])
            text += (sp[0] + f'{positions[n]}$' + sp[1:]) if positions else sp
            n += 1
        else:
            text += x.replace('%', '%%')
    return text


def catalog_pair(zh, en):
    pz, pe = parts(zh), parts(en)
    ez = [x[0] for x in pz if isinstance(x, tuple)]
    ee = [x[0] for x in pe if isinstance(x, tuple)]
    key = fmt(pe)
    positions = None
    if ez and ez != ee and sorted(ez) == sorted(ee):
        positions = [ee.index(e) + 1 for e in ez]
    elif ez and len(ez) == len(ee) and ez != ee:
        positions = None  # same order, expressions rewritten (nested literals): positional not needed
    # Specifier types follow the English expression at the same slot.
    if positions:
        zz = []
        n = 0
        for x in pz:
            if isinstance(x, tuple):
                zz.append((ee[positions[n] - 1],)); n += 1
            else:
                zz.append(x)
        value = fmt(zz, positions)
    else:
        zz, n = [], 0
        for x in pz:
            if isinstance(x, tuple):
                zz.append((ee[n] if n < len(ee) else x[0],)); n += 1
            else:
                zz.append(x)
        value = fmt(zz)
    return key, value


def main():
    catalogs = {'App': {}, 'CleanEngine': {}}
    for rel, entries in T.items():
        path = os.path.join(ROOT, rel)
        src = open(path, encoding='utf-8').read()
        module = 'CleanEngine' if rel.startswith('Sources/CleanEngine') else 'App'
        for zh, en, wrap in entries:
            if zh not in src:
                print(f'NOT FOUND in {rel}: {zh}', file=sys.stderr); continue
            if wrap == 9:
                src = src.replace(zh, en); continue
            new = en
            if wrap:
                new = f'String(localized: {en}, bundle: .module)' if module == 'CleanEngine' else f'String(localized: {en})'
            src = src.replace(zh, new)
            k, v = catalog_pair(zh, en)
            catalogs[module][k] = v
        open(path, 'w', encoding='utf-8').write(src)
    for module, extra in EXTRA.items():
        catalogs[module].update(extra)
    out = {'App': 'App/Resources/Localizable.xcstrings', 'CleanEngine': 'Sources/CleanEngine/Localizable.xcstrings'}
    for module, entries in catalogs.items():
        write_catalog(os.path.join(ROOT, out[module]), entries)
        print(f'{module}: {len(entries)} strings -> {out[module]}')


def write_catalog(path, entries):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    existing = {}
    if os.path.exists(path):
        existing = json.load(open(path, encoding='utf-8')).get('strings', {})
    for k, v in entries.items():
        existing[k] = {'localizations': {'zh-Hant': {'stringUnit': {'state': 'translated', 'value': v}}}}
    doc = {'sourceLanguage': 'en', 'strings': dict(sorted(existing.items())), 'version': '1.0'}
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(doc, f, ensure_ascii=False, indent=2)
        f.write('\n')


if __name__ == '__main__':
    main()
