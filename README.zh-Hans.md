<p align="center">
  <img src="docs/images/mascot.gif" width="240" alt="MacHelper 史莱姆：呼吸、挥手、跳跃、庆祝">
</p>

<h1 align="center">MacHelper</h1>

<p align="center">
  <b>完全在本地运行的 Mac 工具：系统监控、风扇控制、清理和磁盘分析，全部收在一个菜单栏 App 里。</b>
</p>

<p align="center">
  <a href="https://github.com/smile-minecraft/MacHelper/releases/latest"><img src="https://img.shields.io/github/v/release/smile-minecraft/MacHelper?label=release&color=5b8def" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-1f2430" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Apple%20Silicon-arm64-1f2430" alt="Apple Silicon">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-4cc38a" alt="MIT"></a>
</p>

<p align="center">
  <a href="README.md">English</a> · <a href="README.zh-Hant.md">繁體中文</a> · 简体中文 · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a>
</p>

<p align="center">
  <img src="docs/images/menubar.png" width="320" alt="菜单栏上的 MacHelper：CPU 折线、内存和温度">
</p>

<p align="center">
  <img src="docs/images/overview.png" width="860" alt="概览：健康分数、实时数值和最耗资源的 App">
</p>

<p align="center">
  <a href="#安装"><b>安装</b></a> ·
  <a href="#功能"><b>功能</b></a> ·
  <a href="#首次打开"><b>首次打开</b></a> ·
  <a href="#命令行"><b>命令行</b></a> ·
  <a href="#从源代码构建"><b>从源代码构建</b></a>
</p>

---

MacHelper 测量和存储的所有数据都留在你的 Mac 上：不需要账户、没有分析追踪，除了检查更新之外不联网。需要 macOS 14 或更高版本的 Apple Silicon Mac，以 MIT 许可证开源。

## 安装

```sh
brew install --cask smile-minecraft/tap/machelper
```

也可以从 [Releases](https://github.com/smile-minecraft/MacHelper/releases/latest) 下载 `MacHelper-<版本>.dmg`，把 MacHelper 拖到「应用程序」。每个版本都使用 Developer ID 签名并通过 Apple 公证，可以直接打开。下载文件的校验值在发布页的 `SHA256SUMS.txt` 中。

MacHelper 会自己保持最新：后台检查到新版本时，侧边栏、菜单栏面板和设置页会出现 **更新到 x.y.z** 按钮，点按后才会安装。更新窗口会用 App 当前的语言显示更新内容。

## 功能

<table>
  <tr>
    <td width="50%" valign="top">
      <h3>监控</h3>
      <img src="docs/images/monitor.png" alt="监控：CPU、GPU、内存、温度、风扇和功耗图表，附警戒线">
      <p>CPU（性能核心与能效核心）、GPU、内存压力、温度、风扇、功耗、电池、磁盘和网络速度。实时图表和每分钟一条的历史记录，可看 1 小时、24 小时或 7 天，内存和温度有警戒线。菜单栏的每一项都能选文字、折线、柱状、条形、圆环、方块、热度胶囊或双线显示。</p>
    </td>
    <td width="50%" valign="top">
      <h3>健康检查</h3>
      <img src="docs/images/health.png" alt="健康检查：分数、最近 24 小时的数值和可用空间变化">
      <p>根据最近几小时的历史、可用空间和后台项目算出健康分数，并说明扣分原因和建议做法。另外会只读检查 Gatekeeper、FileVault、防火墙、系统完整性保护、自动安全更新和 XProtect。</p>
    </td>
  </tr>
  <tr>
    <td colspan="2" valign="top">
      <h3>磁盘分析</h3>
      <img src="docs/images/disk.png" alt="磁盘分析：个人文件夹的旭日图和最大的文件夹">
      <p>旭日图和矩形树图（点任何文件夹都会直接进入）、可按种类和时间筛选的最大文件、重复文件（能识别 APFS 克隆和硬链接）、与上次扫描相比的变化，以及找出长期未用大文件和异常膨胀文件夹的空间建议。把项目拖到收集篮，就能一次移到废纸篓。</p>
    </td>
  </tr>
</table>

| | |
|---|---|
| **风扇控制** | 自动、固定转速或温度曲线（安静、平衡、性能、自定义），「只升不降」模式、硬性安全上限，并可根据正在运行的 App 或电源自动切换配置。 |
| **一键优化** | 先预览再清理：低风险的缓存直接删除，中高风险的项目移到废纸篓。有受保护路径、永不清理列表、操作记录、维护任务、项目构建产物清理和定时自动清理。 |
| **卸载 App** | 用 Bundle ID、内嵌 Helper、权限、容器信息、launchd 所有者、Homebrew zap 列表和各 App 规则找出 App 留下的东西。只靠名称匹配到的项目会标出来让你确认，也能找出已删除 App 的残留文件。 |
| **启动项目** | 你的 Launch Agent（停用、启用、移除）、所有用户的 Agent 和系统 Daemon，并标出所属 App 和已经失效的项目。 |
| **Homebrew 更新** | 更新用 Homebrew 安装的 App。 |
| **AI Agent Skill** | 为 Claude Code 和 Codex 安装 Skill，让它们安全地使用 MacHelper：一律先预览，删除前一定先问你。 |
| **通知** | CPU 温度过高、内存压力过大、磁盘空间不足时提醒你。 |
| **可选的历史记录** | 进程、传感器和核心历史默认关闭。进程历史只记录名称、CPU 和内存（不记录路径、参数或用户名），保留 1 到 30 天。 |
| **史莱姆** | 吉祥物会跟着 Mac 的状态变色（蓝、黄、红），对点按、指针悬停和拖动有反应，也会回应过热或清理完成等事件。会遵守「减弱动态效果」和 VoiceOver。 |
| **语言** | 英文、繁体中文、简体中文、日文、韩文和西班牙文。可在「设置 → 通用 → 语言」指定，不跟随系统语言。 |

## 首次打开

MacHelper 会一次一个地引导你打开两项权限。两项都是可选的，其他功能不需要它们也能使用。

1. **完全磁盘访问权限**让磁盘分析和清理能看到受保护的位置，例如「邮件」下载项和其他 App 的缓存。请到 **系统设置 → 隐私与安全性 → 完全磁盘访问权限** 打开 MacHelper，引导窗口会自动检测。受系统完整性保护的文件夹即使打开了也无法读取，磁盘分析会另外列出。
2. **Helper** 是一个小型的 root 后台程序，负责风扇控制、系统缓存与日志清理、系统后台项目和系统进程用量。引导窗口会帮你安装、打开 **系统设置 → 通用 → 登录项与扩展** 让你允许，并确认它有响应。它会验证每个调用者的代码签名。Helper 未启用时，点按侧边栏底部的 **设置 Helper…** 可以再打开引导。

## 命令行

App 内附 `machelper` 命令（Homebrew 会帮你创建链接）。每个命令默认只预览，也都支持 `--json`，适合写脚本或让 AI Agent 使用。运行 `machelper guide` 查看概览，`machelper <命令> --help` 查看各命令说明。

```sh
machelper status --json                 # 当前所有数值
machelper clean                         # 预览会清理的项目
machelper clean --max-risk low --yes    # 只清理低风险项目
```

## 从源代码构建

需要 Xcode 16 或更高版本和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。

```sh
xcodegen generate
scripts/install.sh          # Release 构建 → /Applications/MacHelper.app，然后重新打开
swift test                  # Swift 包的单元测试
```

签名、项目结构、截图制作、发布流程（包括各语言的更新说明）和翻译方法请看[英文 README](README.md)。

## 许可证

MIT，见 [LICENSE](LICENSE)。
