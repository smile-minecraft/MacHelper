# Swift 工具鏈的受限驗證套件

> 目前這台電腦的預設開發工具已切換至 Xcode 27.2，`verify_run` 可直接執行；本獨立套件保留為可跨環境重跑的最小隔離測試範例。

這個資料夾是一個獨立的 SwiftPM 套件，用來在受限驗證伺服器上編譯並測試真正的產品程式
`Sources/Metrics/DiskVolumes.swift`。`Sources/ProductCode/DiskVolumes.swift` 是指向該檔案的符號連結，
沒有複製的副本，所以產品檔案一改，這裡測試的就是新的實作。

測試只餵入假的 `MountedVolumeObservation` 與 `MountedVolumeFacts`，不會呼叫 `DiskVolumeSampler.sample()`，
不讀取真正的磁碟、使用者資料、偏好或其他服務。所有建置產物都留在這個資料夾的 `.build`（已列在 `.gitignore`），
不會寫入專案根目錄的 `.build`。

## 目前工具鏈的狀況

這台機器（macOS 27.2）的預設開發者目錄是 Command Line Tools：

| 項目 | 值 |
| --- | --- |
| `xcode-select -p` | `/Library/Developer/CommandLineTools` |
| CLT Swift | 6.4.0（`swiftlang-6.4.0.34.1`） |
| Xcode | 27.2（`/Volumes/Smile-Data/Applications/Xcode-27.2.0.app`） |
| Xcode Swift | 6.4.2（`swiftlang-6.4.2.1.9`） |

CLT 的 Swift 6.4.0 會把 `Package(...)` 編譯成已被取代的
`PackageDescription.Package.__allocating_init(...swiftLanguageVersions:...)`，但
`libPackageDescription.dylib` 沒有匯出這個符號（CLT 與 Xcode 的 dylib 匯出清單相同，都只有
`...swiftLanguageModes:...` 版本）。結果是任何 SwiftPM manifest 都在連結階段失敗：

```
error: '…': Invalid manifest
Undefined symbols for architecture arm64:
  "PackageDescription.Package.__allocating_init(… swiftLanguageVersions: …)"
```

Xcode 27.2 的 Swift 6.4.2 會選 `...swiftLanguageModes:...`，可以正常建置與執行測試。

因此 `verify_run(runner: "swift")` 目前一定失敗：它用 `/usr/bin/xcrun --find swift` 依
`xcode-select` 找到 CLT 的 swift，而且只接受 `--filter`、`--skip`、`-v`、`--verbose`、`--parallel`、
`--num-workers`；`--toolchain`、`--package-path`、`--scratch-path` 都會被拒絕，也沒有傳環境變數的參數。

## 可重跑的指令

在自己的 shell 執行（會自動設定 `DEVELOPER_DIR` 並呼叫 `swift test`）：

```sh
Tests/Verification/SwiftToolchain/run.sh
```

或自己指定工具鏈：

```sh
DEVELOPER_DIR=/Volumes/Smile-Data/Applications/Xcode-27.2.0.app/Contents/Developer \
  /usr/bin/swift test --package-path Tests/Verification/SwiftToolchain
```

在受限驗證伺服器上，用 `bun` 當啟動器（`run.sh` 會設定 `DEVELOPER_DIR`）：

```
verify_run(runner: "bun", script: "test", cwd: "Tests/Verification/SwiftToolchain")
```

也就是 `bun run test` → `bash run.sh` → Xcode 27.2 的 `swift test`。`bun` 在這裡只是啟動器，
被執行的仍然是 Swift 測試。

等 `swift` runner 能選到完整 Xcode 之後，可以直接改用：

```
verify_run(runner: "swift", cwd: "Tests/Verification/SwiftToolchain")
```

## 怎麼恢復 `swift` runner

1. 讓驗證伺服器進程帶 `DEVELOPER_DIR=/Volumes/Smile-Data/Applications/Xcode-27.2.0.app/Contents/Developer`
   重新啟動。伺服器的驗證環境白名單包含 `DEVELOPER_DIR`，所以不必改任何系統設定；但要改 MCP 的啟動設定，
   這次工作沒有動它。
2. 安裝與 Xcode 27.2 相符的 Command Line Tools（軟體更新或 `xcode-select --install`）。
3. 執行 `sudo xcode-select -s /Volumes/Smile-Data/Applications/Xcode-27.2.0.app/Contents/Developer`。

第 2、3 項都是全系統變更，這次沒有執行。

## 已驗證與未驗證

已驗證：

- Xcode 27.2 工具鏈可以在這個資料夾編譯符號連結的真實產品檔案，16 個測試、6 個 suite 全部通過。
- 故意移除「可用容量超過總容量要變成 nil」的規則後，測試會失敗（1 個測試、1 個 issue、exit 1），
  證明這些測試會分辨行為的對錯。

未驗證：

- CLT 工具鏈下的任何 SwiftPM 建置都無法進行，這是工具鏈本身的問題，不是這個套件的問題。
- 沒有測試 `DiskVolumeSampler.sample()`、Storage/GRDB、App、helper 或背景服務。
- 產品檔案改名或搬移時，這裡的符號連結會失效，建置會直接失敗。
