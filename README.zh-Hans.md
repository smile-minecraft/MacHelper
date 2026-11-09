# MacHelper

[English](README.md) · [繁體中文](README.zh-Hant.md) · 简体中文 · [日本語](README.ja.md) · [한국어](README.ko.md) · [Español](README.es.md)

适用于 macOS 14 及更高版本的一站式 Mac 工具，所有数据都留在你的 Mac 上：风扇控制、菜单栏系统监控、一键清理、磁盘分析、App 卸载和启动项管理。以 MIT 许可证开源。

## 功能

- **菜单栏监控**：CPU（性能核心与能效核心）、GPU、内存压力、磁盘与网络速度、温度、风扇、功耗和电池，每一项都可以选择文字、折线、柱状或圆环显示。也会列出最占 CPU 和内存的进程。
- **历史记录**：每分钟一条平均值，默认保留 7 天，可在「设置 → 通用 → 数据管理」改为 1、3、7、14 或 30 天。可以查看最近 1 小时、24 小时和 7 天。
- **可选的进程、传感器与核心历史**：默认关闭，在「设置 → 通用 → 数据管理」分别打开。进程历史只记录进程名称、CPU 和内存用量，不记录路径、命令行参数或用户名，每分钟只保留 CPU 和内存各前 10 名。
- **通知**：CPU 温度过高、内存压力过大、磁盘空间不足时提醒你。
- **风扇控制**：自动、固定转速或温度曲线（安静、平衡、性能、自定义），「只升不降」模式、硬性安全上限，并可根据正在运行的 App 或电源自动切换配置。通过会验证调用者签名的 root Helper 执行。
- **一键清理**：先预览再清理。低风险的缓存和日志直接删除，中高风险的项目移到废纸篓。有受保护路径、永不清理列表、操作日志、维护任务、项目构建产物清理，以及低风险项目的定时自动清理。
- **磁盘分析**：旭日图和矩形树图、可按类型和时间筛选的最大文件、重复文件（能识别 APFS 克隆和硬链接）、与上次扫描相比的变化，以及一次移到废纸篓的收集区。
- **空间建议**：找出半年以上没用过的大文件和看起来异常膨胀的文件夹，并在图表上标出来。
- **App 卸载**：用 Bundle ID、内嵌 Helper、权限、容器信息、launchd 所有者、Homebrew zap 列表和各 App 规则找出 App 留下的东西，仅凭名称匹配到的项目会标出来让你确认。也能找出已删除 App 的残留文件。
- **启动项**：你的 Launch Agent（停用、启用、移除）、所有用户的 Agent 和系统 Daemon，并标出所属 App 和已经失效的项目。
- **Homebrew 更新**：更新用 Homebrew 安装的 App。
- **自动更新**：后台检查并下载新版本，安装前询问。
- **安全检查**：读取 Gatekeeper、FileVault、防火墙、系统完整性保护、自动安全更新和 XProtect 的状态（只读取，不会更改）。
- **命令行工具**：所有功能都能用命令操作，方便自动化和 AI Agent 使用。默认只预览，每个命令都支持 `--json`。运行 `machelper guide` 查看概览，`machelper <命令> --help` 查看各命令说明。
- **AI Agent Skill**：可以为 Claude Code 和 Codex 安装 Skill，让它们安全地使用 MacHelper：一律先预览，删除前一定先问你。
- **语言**：英文、繁体中文、简体中文、日文、韩文和西班牙文。可在「设置 → 通用 → 语言」指定，不跟随系统语言。

## 安装

从 [Releases](https://github.com/smile-minecraft/MacHelper/releases) 下载 `MacHelper-<版本>.dmg`，把 MacHelper 拖到「应用程序」。也可以用 Homebrew：

```sh
brew install --cask smile-minecraft/tap/machelper
```

MacHelper 已使用 Developer ID 签名并通过 Apple 公证，可以直接打开。风扇控制和系统清理需要 Helper，MacHelper 询问时请到 **系统设置 → 通用 → 登录项** 允许。

想看到整个磁盘，请在 **系统设置 → 隐私与安全性 → 完全磁盘访问权限** 中打开 MacHelper。即使打开了，受系统完整性保护或属于其他用户的文件夹仍然无法读取，这是 macOS 的保护，属于正常现象。

每个版本下载文件的校验值在发布页的 `SHA256SUMS.txt` 中。

## 从源代码构建

需要 Xcode 16 或更高版本和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。

```sh
xcodegen generate
scripts/install.sh          # Release 构建 → /Applications/MacHelper.app，然后重新打开
swift test                  # Swift 包的单元测试
```

签名、项目结构、发布流程和翻译方法请看[英文 README](README.md)。

## 许可证

MIT，见 [LICENSE](LICENSE)。
