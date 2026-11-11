# idsh — iOS / iPadOS 版 DeepSeek Harness 实施计划

版本：0.2（已实现）
日期：2026-11-08（计划）/ 2026-11-11（实现状态）
目标设备：iPad Pro 11-inch (M4)，iPadOS 26.x；iPhone 作为“能跑就行”的附带目标
目标产物：可侧载的 `.ipa`（自用，不上 App Store）
许可证：GPL-3.0（因为链接 ish-arm64 / OpenMinis 的 GPL 代码）

> **实现状态（2026-11-10）**
> - 已在 iPad Pro 11-inch (M4) 模拟器上跑通：启动器 → iSH → dsh web → 自动进入 WKWebView 的 DSH UI。
> - 引擎重建为 `de124dd6` + 移除 `SAFETY-VALVE[futex]` / `SAFETY-VALVE[poll]`；`dsh web` 连续 25 分钟无退出。
> - iPad 为 DSH 桌面三栏布局，中文与图标正常（视觉验收通过）。
> - 插件安装已在 App 内验证；`pnpm` 由 npm 兼容 shim 承接（见 `Docs/RELEASE.md`），真实 pnpm 保留为 `pnpm.real`。
> - 启动模式：完整（约 82s）/ 极简 · 快（约 69s，`--patch fast.patch.yml` 关闭约 68 个非核心插件）；启动器与设置页可切换。
- 分享面板：Share Extension → App Group → `/workspace/inbox/<id>` → 预填 DSH 输入框（已实测）。
- 账号登录：DSH Web 宿主返回 `protocol`，确认不可用；设置页引导 API Key。
- 产物：`dist/idsh-unsigned.ipa`（341 MB，sha256 `8a88b623dc0bacb8f6e9d06e847044bf1cec33fd6dedccf5c23e8d0e45d0a9c5`，未签名）；构建脚本 `scripts/make-ipa.sh`。
> - 已知限制：未签名需自签安装；引擎 worker/zlib 缺陷未在引擎层修复；iPhone 不做移动端重排。

---

## 0. 结论先行

**推荐路线：Web 宿主路线。**

```text
SwiftUI 薄壳
 ├── RootfsManager            解压/校验 Alpine fakefs
 ├── ISHService                HarnessISH.xcframework（ish-arm64 引擎）
 │    └── iSH ARM64 Alpine 3.21
 │         ├── Node 22.23.4（musl/arm64）
 │         ├── dsh-supervisor（常驻）
 │         └── dsh web 127.0.0.1:8790
 ├── Launcher                  黑底原生启动器：状态/终端/插件/设置
 ├── WKWebView                 加载 DSH 同一套 Web 前端 → iPad 与 PC 完全相同
 ├── BackgroundKeepAlive      静音音频 + 定位(可选) + BGContinuedProcessingTask
 └── Live Activity             iOS 26 后台进度卡片
```

一句话：**不重写 DSH，也不重写 UI。** 把 DSH 的 Node Host 原样放进 iSH ARM64，把 DSH 的 Web 前端原样放进 WKWebView；我们只写“启动、保活、打包”三件事。

这样做的直接收益：

| 需求 | 结果 |
|---|---|
| iPad UI 与 PC 完全相同 | 同一份 `dsh-web-frontend`，天然 100% 相同 |
| 完整插件系统 | 同一套 Cordis Host + 同一套 Web 插件管理器 + Creator 预设 |
| 开箱即用 | rootfs 预烘焙 Node + DSH，首启只解压，不联网安装 |
| 后台运行 | ish-arm64 + OpenMinis 的 audio/continued 保活方案 |
| 可恢复性 | 原生启动器 + 探针；DSH 挂了也能重启/重置/看日志，不依赖插件 |
| 工程量 | 薄壳 + rootfs 流水线 + 打包脚本，不碰 DSH 业务代码 |

**最大风险不是“能不能跑”，而是“后台会不会被 iOS 杀”。** 本计划把后台验收设为 M2 硬门槛；如果 M2 失败，回退方案见 §11。

---

## 1. 需求拆解与验收口径

用户提出四条硬性验收，逐条落到可测试项：

### 1.1 后台运行能力（含 iOS 26 专属加强）

必须同时具备：

1. `UIBackgroundModes=audio` + `AVAudioSession(.playback)` + 1 秒零填充静音循环：iOS 上唯一能长期不 suspend 的公开能力。
2. `BGContinuedProcessingTask`（iOS 26.0+）：纯 CPU、不需要特殊 entitlement、免费 Apple ID 可用；用户在前台点击“后台加速”后提交，系统显示 Live Activity 进度，实测可跑约 45 分钟。
3. `beginBackgroundTask`：约 30 秒收尾窗口，用于保存状态、停止子进程。
4. `ISHKernel.beginBackgroundCPUGovernor`：10 Hz 采样 + 30/38/32 秒阈值 + 15%/3% 占空比，避免持续高 CPU 被 iOS 杀。
5. 可选持续定位：默认关闭；用户显式开启后才使用 `CLBackgroundActivitySession`，仅作为第二保活腿。
6. Live Activity：显示“DSH 后台运行”、已运行时间、当前任务摘要；不是保活本身，但它是 iOS 26 体验的一部分。

**验收**：锁屏后运行一个每分钟写时间戳的 guest 脚本 30 分钟，回前台后时间戳缺口不超过 20 秒；连续 3 次通过。iOS 26 上再测“后台加速”45 分钟。

### 1.2 开箱即用

- IPA 内置：Alpine 3.21 fakefs + Node 22.23.4（musl/arm64）+ DSH 0.2.2-rc.1 + pnpm + `dsh-supervisor` + 预生成的 `/root/.dsh/profiles/web`。
- 首启不执行 `npm install`、不下载 rootfs、不要求终端操作。
- 首启流程：解压 rootfs（约 380–480 MB zip）→ 启动 iSH → 启动 supervisor → 等 `dsh web` 打印 URL → 自动加载 WKWebView。
- 启动器只作为“启动过程页”存在：显示阶段与耗时；就绪后自动进入 DSH，不额外点“进入”。
- 冷启动目标：iPad 上 ≤ 90 秒进 UI（实测 guest 内 server 67 秒，含 WKWebView 首屏约 75–85 秒）；热启动（进程仍在后台）≤ 3 秒。

### 1.3 完整插件系统 + 创造模式

- 使用 DSH 原版 Web UI 的插件管理器：npm / git / link 安装、启停、配置、卸载。
- Host 半边跑在 guest Node 里；Client 半边跑在 WKWebView 的同一套 Web 前端里。
- Creator 预设原样保留：模型可在对话中 define/run/update/stop/undefine Cordis bundle，并通过 `plugin_manager` 安装。
- 预装 `pnpm`，避免插件安装时现下载包管理器。
- **原生 addon 全支持**，不再把 `.node` 当例外；纯 JS/TS 插件本来就跨平台，原生扩展才需要按平台/ABI 处理：
  - 所有能在 **Linux ARM64 / musl / Node 22 ABI 127** 上构建的 `.node` 插件，都能装、能加载、能调用。
  - rootfs 默认**不预装** `python3 make g++`（省 ~300MB）；遇到需要 `.node` 的插件时，用 `apk add python3 make g++` 按需安装，再让 agent 现场编译。
  - 有 `linux-arm64-musl` 预编译产物的包直接用；没有的从源码编译；只提供 macOS/Windows 二进制的包属于平台差异（PC 上同样不能跨 OS 运行），会在安装日志里给出明确包名和原因，不再静默失败。
  - 纯 JS/TS 插件：当然可用；只声明 `darwin` 但代码跨平台的，由 `pnpm patch`/profile patch 补 `linux` 声明。
  - **终端面板：可用**。`node-pty` 已在 guest 内用 Node 22 headers 编译通过（`build/Release/pty.node`，80,208 B）；PTY 的 `uv_tty_init` 需真机 App 内 TTY 复测，CLI 管道下报 EINVAL 是预期。
  - **Office/PDF 转换：独立问题，不影响插件安装**。`libreoffice-kit` 无 linux-arm64 原生库，wasm 又被 `--jitless` 禁用；v1 默认关闭 `office-to-pdf`，后续用 Alpine 的 `soffice` CLI 兜底。

**验收**：从 npm 安装一个纯 JS 插件 + 一个含 `.node` 的插件（`node-pty` 或 `better-sqlite3`）→ 重载 → 都能调用；用 Creator 生成一个 hello 插件 → 安装 → 运行；以上在 iPad 真机完成。

### 1.4 iPad UI 与 PC 完全相同

- WKWebView 加载 `http://127.0.0.1:8790/?token=...`，加载的就是 PC 版 `dsh-web-frontend/dist`。
- 主前端没有宽度断点（只有 `hover`、`pointer:coarse` 和局部日程插件的 `width<=767px`），所以 iPad 上天然是桌面布局。
- iPad 全屏、Stage Manager 缩放、硬件键盘、触控板、文件选择、下载、外链都走 WKWebView 原生能力。
- iPhone 不做专门布局；同一 UI 缩放显示，保证“能跑”，不保证“好用”。

**验收**：iPad 截图与 Mac 同窗口宽度截图并排比对，主区域、侧栏、输入框、工具卡片布局一致；外接键盘快捷键可用；Stage Manager 改变窗口宽度不崩。

### 1.5 启动器（新增需求）

启动器不是“加载动画”，而是 iOS 侧的控制台：

- 纯黑、极简，显示引擎/DSH/后台/端口/CPU/内存状态。
- 一键进入 DSH；DSH 内可回到启动器，DSH 不销毁。
- 终端：能进 Alpine shell，看日志、查 Node、装包。
- 简易插件管理器：列出已装插件、启停、打开 DSH 完整插件管理器。
- 基础设置：后台保活、Node 版本、端口、rootfs 重置、导出诊断。
- 探针必须是**原生**的，不能依赖 DSH 插件；桥接插件可选，不作为恢复路径。

**验收**：冷启动显示阶段进度；就绪后 1.2 秒内可进 DSH；DSH 内悬浮 `⌂` 可回启动器且会话不断；终端能执行 `node -v`；插件页能显示至少一个已装 bundle；杀掉 DSH 进程后启动器显示 failed 并可重启。

---

## 2. 参考项目取舍

| 项目 | 我们用它做什么 | 不做什么 |
|---|---|---|
| `ish-app/ish` | 只作为背景资料；上游是 i386/32-bit/4GB，跑不了 V8 | 不选为底座 |
| `emkey1/ish-AOK` | 参考 fork 维护方式与补丁组织 | 不作为运行引擎 |
| `OpenMinis/ish-arm64` | **核心引擎**：ARM64 guest、threaded-code 解释器、Node 22/24 适配（24.11.1 已实测）、fakefs、socket 直通 | 不直接用它的媒体 UI |
| `OpenMinis/OpenMinis` | **后台系统参考**：五条腿、CPU governor、ISHKernel/ISHShellExecutor、rootfs 打包 | 不整体 fork（媒体/相册/播放器太重） |
| `mxhm11cr/LinuxRunner` | 参考 rootfs 下载/安装 UX、可选 JIT 的产品化表达 | 不选为底座 |
| `liulingfei-1/deepseek-harness-ios` | **工程化参考**：`HarnessISH.xcframework` 构建脚本、iSH bridge 补丁、后台 Swift 实现、Info.plist/签名经验 | 不沿用它的 SwiftUI 原生 Agent UI（与“PC 同款 UI”冲突） |
| `deepseek-ai/deepseek-harness` | 直接被嵌入的 Host 与 Web 前端 | 不改业务代码 |

> `deepseek-harness-ios` 已经证明：iSH 里可以常驻 Node、可以跑 Cordis Host、可以用 `HarnessISH.xcframework` 在真机上 boot Alpine。我们复用它“怎么把引擎装进 App”的部分，丢掉它“用 SwiftUI 重做一遍 Agent”的部分。

---

## 3. 方案对比与选型

### 3.1 四条路线

| 路线 | 做法 | 优点 | 缺点 | 判定 |
|---|---|---|---|---|
| **A. Web 宿主（推荐）** | iSH + Node + `dsh web` + WKWebView | UI 与 PC 完全一致；插件系统原样；工程量最小 | 后台/性能受 iSH 限制；需要预烘焙 rootfs | **采用** |
| B. 原生 SwiftUI 移植 | 用 Swift 重写 Agent + 原生 UI | 性能最好；后台更可控 | UI 不可能与 PC 完全一致；插件 Client-half 要重写；工作量最大 | 不采用（已有项目可作 fallback） |
| C. 远程 Host | Mac/服务器跑 DSH，iPad 只做 WKWebView | 性能/插件 100% PC | 必须联网；不符合“本地自用” | 备选 |
| D. 原生嵌入 Node | 自己编 iOS arm64 Node，`--jitless` | 比 iSH 快一个数量级 | iOS 禁 `fork/exec`，bash/终端/子进程类插件全废；工程量大 | 不采用 |

### 3.2 为什么不是“直接把 OpenMinis 改一改”

OpenMinis 是完整媒体工作站：相册、播放器、文件 Provider、Metal、Android 端、大量 UI。我们要的只是：

- `ISHKernel` / `ISHShellExecutor` / `CurrentRoot`
- `BackgroundKeepAliveManager` 的五条腿
- CPU governor
- rootfs 打包脚本

所以采用“**新薄壳 + 复用引擎/后台代码**”，而不是 fork 整个 OpenMinis。这样升级引擎时冲突最小。

### 3.3 为什么不是“直接用 deepseek-harness-ios”

它的产品目标是“原生 SwiftUI Agent”，不是“DSH Web UI 容器”。复用它的 XCFramework 构建与后台代码即可；如果整体 fork，会继承大量原生 UI 和 Agent 实现，反而与需求 1.4 冲突。

### 3.4 项目捏合表（每个项目只取什么）

| 来源 | 取什么 | 不取什么 |
|---|---|---|
| `deepseek-ai/deepseek-harness` | `@deepseek-ai/dsh` Host、`dsh-web-frontend`、Cordis 插件系统、Creator 预设、`dsh web` | 不改业务代码；不嵌 Electron |
| `OpenMinis/ish-arm64` | ARM64 syscall 解释器、Node 22/24 适配、`fs/sock.c` 本机端口直通 | 不取它的媒体/相册/Android 端 |
| `OpenMinis/OpenMinis` | `ISHKernel` / `ISHShellExecutor`、CPU governor、五腿后台、rootfs 脚本 | 不取完整 App、不取播放器/Metal UI |
| `liulingfei-1/deepseek-harness-ios` | `HarnessISH.xcframework` 构建脚本、RootfsPatch overlay、`BGTaskScheduler` 配置、后台 Swift 实现 | 不取 SwiftUI Agent UI、不取它的 stdio JSON-RPC 产品架构 |
| `mxhm11cr/LinuxRunner` | rootfs 下载/安装 UX、可选 JIT 的取舍参考 | 不作为底座（体积大、目标不同） |
| `ish-app/ish` / `emkey1/ish-AOK` | 上游 syscall/线程/信号修复参考 | 上游 32-bit，不能直接跑 V8 |

一句话：**引擎用 ish-arm64，壳和后台抄 OpenMinis，XCFramework 流水线抄 deepseek-harness-ios，Host 和 UI 用 DSH 原版，LinuxRunner 只当 UX 参考。**

### 3.5 为什么不用 LinuxRunner 的 GPU 加速 / JIT

先把两个概念分开：

1. **GPU 加速不是给 Node 用的。** LinuxRunner 的 Metal 路径是 `guest Mesa/virgl → virglrenderer → ANGLE → Apple Metal`，只服务图形 API（Hyprland、FreeCAD 这类）。它能让桌面从 10 FPS 到 55–60 FPS，但不会让 V8、`npm install`、DSH 的 bash 工具变快。DSH 的界面在 WKWebView 里，本来就用 Apple GPU 合成；容器里再要一个 GPU 对我们是空转。
2. **JIT 是可选项，不是开箱即用的默认能力。** LinuxRunner 明确写“JIT is optional”，需要 iOS 允许可执行内存，通常要调试器/StikDebug 配合；它的性能文档也说明 JIT 对短任务可能更慢（Python 启动 198ms vs 171ms），微基准提升约 1.1–6×，且没有 Node/DSH 的真机数据。iOS 26 自签场景下不能把它当作稳定前提。

我们自己的实测是：ish-arm64 里 DSH 冷启动到可访问 **67 秒**，这已经是“能用”的边缘；LinuxRunner 的解释器相对它自己的旧版快约 1.1–1.3×（其官方微基准，不是与 ish-arm64 的对比），但换引擎意味着重新验证 Node 22/24、rootfs、socket、后台 governor、XCFramework 全链路，收益不足以抵消风险。

**决策**：v1 继续用 ish-arm64；**不安排任何性能对照试验**，LinuxRunner 只作为解释器/JIT 的资料，不进入主线。若 M1 实测冷启动 > 90 秒或 `npm install` 慢到不可接受，再单独评估优化解释器；不在计划里预留实验。

- 若真要 JIT，必须先证明“目标 iOS 26 设备 + 目标签名方式”能稳定拿到可执行内存；否则用户看到的就是“为什么我的加速按钮没生效”。
- GPU 只在未来做“外接显示器/桌面模式”时才有意义；v1 不需要。

---

## 4. 目标仓库结构

建议新仓库 `idsh`（当前工作区即可），GPL-3.0：

```text
idsh/
├── PLAN.md                          # 本文件
├── project.yml                      # XcodeGen 工程真源
├── App/
│   ├── IDSHApp.swift                # @main，Scene/生命周期
│   ├── RootView.swift               # 启动页 / WebView / 错误页
│   ├── Web/
│   │   ├── DSHWebView.swift         # WKWebView 封装
│   │   ├── WebCoordinator.swift     # 导航/文件选择/下载/外链
│   │   └── DesktopUserAgent.swift   # 可选桌面 UA
│   ├── Launcher/
│   │   ├── LauncherView.swift        # 黑底启动器主界面
│   │   ├── LauncherStatusCard.swift  # 引擎/DSH/后台状态
│   │   ├── LauncherActions.swift     # 终端/插件/设置/日志
│   │   ├── TerminalView.swift        # xterm.js + ISHKernel 桥
│   │   ├── PluginListView.swift      # 简易插件管理器
│   │   └── LauncherSettingsView.swift# 后台/引擎/重置/导出
│   ├── Bridge/
│   │   ├── NativeBridge.swift        # WKScriptMessageHandler "idsh"
│   │   └── TerminalBridge.swift      # 输入/输出/TTY resize
│   └── LiveActivity/                # 可选 target
├── Core/
│   ├── Kernel/
│   │   ├── ISHService.swift         # boot/execute/stop 封装
│   │   └── ISHBridge.h              # 如 XCFramework 已导出则不需要
│   ├── Rootfs/
│   │   ├── RootfsManager.swift      # 解压/校验/版本/重置
│   │   └── RootfsManifest.swift
│   ├── Server/
│   │   ├── DSHServerSupervisor.swift# 轮询 URL/状态、重启
│   │   ├── DSHLaunchURL.swift       # 解析 token URL
│   │   └── ServerLog.swift
│   ├── Background/
│   │   ├── BackgroundKeepAliveCoordinator.swift
│   │   ├── BackgroundAudioKeepAlive.swift
│   │   ├── BackgroundLocationKeepAlive.swift
│   │   ├── ContinuedProcessingController.swift
│   │   ├── BackgroundPreferences.swift
│   │   └── BackgroundRunJournal.swift
│   └── Diagnostics/
│       └── DiagnosticsExporter.swift
├── Resources/
│   ├── rootfs.zip
│   ├── PrivacyInfo.xcprivacy
│   └── Assets.xcassets
├── Vendor/
│   └── OpenMinisISH/                # 来自 deepseek-harness-ios 的构建脚本 + 补丁
│       ├── patches/
│       ├── meson/
│       └── README.md
├── plugins/
│   └── idsh-bridge/                  # 可选 DSH client 插件：返回启动器/状态
├── Scripts/
│   ├── fetch-upstreams.sh
│   ├── build-engine.sh              # XCFramework
│   ├── build-rootfs.sh              # Alpine + Node + DSH + supervisor
│   ├── make-ipa.sh
│   └── verify-device.sh
└── Docs/
    ├── ARCHITECTURE.md
    ├── BACKGROUND.md
    ├── PLUGINS.md
    └── EVIDENCE.md
```

说明：

- `Vendor/OpenMinisISH` 直接取 `deepseek-harness-ios` 的 `Vendor/OpenMinisISH` + `Scripts/build-ish-sandbox.sh`，固定上游 commit；不把 OpenMinis 整个仓库拖进来。
- `rootfs.zip` 是构建产物，不提交 Git LFS；用 `Scripts/build-rootfs.sh` 重现。
- `HarnessISH.xcframework` 也是构建产物，不入库；CI/本机生成。

---

## 5. 组件设计

### 5.1 引擎层：HarnessISH.xcframework

优先使用 `deepseek-harness-ios` 的 `Scripts/build-ish-sandbox.sh all`：

- 固定 OpenMinis `9cf3a855...`、ish-arm64 `de124dd6...`、Alpine 3.21.0。
- 产出 device + arm64 simulator 双切片 XCFramework。
- 内含 `libish`、`libish_emu`、`libfakefs`、`ISHKernel`、`ISHShellExecutor`、`CurrentRoot`。
- 已带补丁：guest 网络策略、DNS 路径、输出上限、ABI 偏移校验、进程 stdin 持久化、运行时健壮性。

如果该脚本在当前 Xcode 26.2 上失败，回退到我们已实测的 OpenMinis HEAD CLI 构建：

```sh
cd .ref/repos/OpenMinis/deps/ish
meson setup build-arm64-release -Dguest_arch=arm64 --buildtype=release
ninja -C build-arm64-release
# 产物：build-arm64-release/ish
```

但 CLI 构建只用于 rootfs 烘焙；iOS App 仍应使用 XCFramework（含 bridge 与设备切片）。

**引擎能力边界（必须写进 UI/文档）**：

- Node 被硬注入：`--jitless --no-lazy --no-expose-wasm --max-old-space-size=512 --no-concurrent-marking --no-concurrent-recompilation --no-lazy-compile-dispatcher --predictable`。
- 无 TurboFan、无 Wasm、单线程、堆上限 512 MB。
- Node 启动在 Mac 上 0.4–1.0 秒；iPad 上预计 3–8 秒；DSH 冷启动实测 **67 秒**（iSH 解释器 + 1.2GB rootfs + 656 包），不是 8–25 秒。
- 纯计算比原生慢 10–30×；I/O 密集（模块加载）也偏慢，但比计算好。
- `child_process` / bash 可用，这是容器路线相对“原生嵌入 Node”的最大优势。
- 无 Docker/namespace/GPU。

### 5.2 rootfs 层

基线：Alpine 3.21 aarch64 minirootfs + fakefsify + **Node 22.23.4 musl/arm64**（Alpine 3.21 官方包，DSH 全链路实测，ABI 127）。

预装包（v1，默认不含编译链）：

```sh
apk add --no-cache \
  bash git curl ca-certificates tzdata xz
```

编译链是**可选包**，不占默认 IPA：

```sh
# 只有遇到需要源码编译的 .node 插件时才装
apk add --no-cache python3 make g++ xz
```

Node 22（Alpine 3.21 官方包；这是已跑通 DSH 的基线）：

```sh
apk add --no-cache nodejs=22.23.4-r0 npm
node -v        # v22.23.4
npm -v         # 10.9.1
```

DSH（用 Node 22 的 npm 安装到 `/usr/local`；依赖预先烘焙，不在设备上全量解析）：

```sh
export npm_config_prefix=/usr/local
export npm_config_nodedir=/usr
/usr/bin/npm i -g --ignore-scripts --no-audit --no-fund \
  @deepseek-ai/dsh@0.2.2-rc.1 pnpm@11.28.5
```

> DSH 自身依赖先用 `--ignore-scripts` 安装以保证可重复；随后单独编译 `node-pty`：
> ```sh
> cd /usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/node-pty
> /usr/bin/node /usr/lib/node_modules/npm/node_modules/node-gyp/bin/node-gyp.js rebuild --nodedir=/usr
> ```
> 插件安装**不再**忽略 scripts；`node-gyp` 用同一套 headers 现场编译。sherpa/office 的平台专属安装脚本即使失败也不影响 DSH 启动。

预生成 profile：

```sh
export HOME=/root
export DSH_HOME=/root/.dsh
export DSH_PERMISSION_MODE=danger-full-access
export DSH_TELEMETRY_DISABLED=1
dsh web --host 127.0.0.1 --port 8790 --no-open
# 等 URL 打印后 Ctrl-C；profile 已生成
```

生成的 `/root/.dsh/profiles/web/package.json` 默认 bundles：

```json
{
  "name": "dsh-profile-web",
  "private": true,
  "dependencies": {},
  "dsh": {
    "profile": {
      "bundles": [
        "@deepseek-ai/dsh-base",
        "@deepseek-ai/dsh-web-app"
      ]
    }
  }
}
```

**关键坑（已实测）**：`prepare_alpine_rootfs.sh` 在 fakefsify 之后往宿主 `data/` 写 `resolv.conf`、`profile`，这些新文件不会进入 fakefs 的 `meta.db`，guest 里看不到。正确顺序是：

1. 解压 minirootfs 到临时目录；
2. 写入 `/etc/resolv.conf`、`/etc/apk/repositories`、`/etc/profile.d/dsh.sh`；
3. 执行 `fakefsify`；
4. 再用 guest 安装包（guest 的写入会进 meta.db）；
5. 或者直接在 guest 内创建这些文件。

rootfs 体积预算：

| 内容 | 约 |
|---|---|
| Alpine 基础 | 9 MB |
| Node 22.23.4 + npm | ~110 MB（Alpine 官方包） |
| DSH + 依赖 | ~760 MB（瘦身后；完整安装 953 MB） |
| pnpm store / 缓存 | 50–120 MB |
| 编译工具链（可选） | ~300 MB（python3/make/g++/headers；默认不装） |
| 总计（未压缩，不含工具链） | 约 1.0–1.2 GB（清 cache + 瘦身后） |
| IPA 压缩后 | 约 320–420 MB |

#### 5.2.1 rootfs 烘焙的两条路径

**路径 1（首选，已验证构建链）**：在 macOS 上启动 ish CLI，挂载 fakefs，在 guest 内执行 `apk` 和 `npm i -g`。优点是所有写入都进 `meta.db`，文件权限/符号链接正确；缺点是 iSH 解释器下 `npm` 安装 451 MB 可能耗时 30–90 分钟（一次性）。

**路径 2（路径 1 失败/太慢时）**：在 macOS 上用 npm/pnpm 以 linux-arm64-musl 为目标预装依赖树，再把 `node_modules` 复制进 fakefs。命令示例：

```sh
npm install --ignore-scripts --no-audit --no-fund \
  --os=linux --cpu=arm64 --libc=musl \
  @deepseek-ai/dsh@0.2.2-rc.1
```

注意：

- 只复制纯 JS 包；任何 `.node` 都可能带 darwin 二进制，必须在 guest 内删除或替换。
- `--ignore-scripts` 必须保留，避免在 macOS 上编译原生模块。
- 复制后要在 guest 内跑一次 `node -e "require('@deepseek-ai/dsh')"` 验证模块图；fakefs 对硬链接/符号链接敏感，必要时用 `cp -aL` 展开符号链接。
- 这条路径不保证 `pnpm` 的 store 结构；插件安装仍建议用路径 1 的 rootfs。

安装完成后务必在 guest 内执行 `npm cache clean --force` 并删除 `/root/.npm`，否则会多出 150–250 MB 缓存。

**rootfs 瘦身（实测必做）**：Linux 版 npm 会装上 macOS 上不会装的平台包，rootfs 会从 1.2 GB 起步。删掉以下目录可省约 200 MB，且不影响 v1 功能：

| 路径 | 大小 | 原因 |
|---|---|---|
| `.../dsh/node_modules/@deepseek-ai/libreoffice-kit-wasm` | ~152 MB | `--jitless` 禁用 Wasm；Office 改用 `soffice` 或禁用 |
| `.../dsh/node_modules/sherpa-onnx-linux-arm64` | ~39 MB | glibc-only；如要语音，后续从源码编译 musl 版 |
| `.../dsh/node_modules/@img/sharp-*` 非 linux-arm64 变体 | ~10–20 MB | 只保留 musl/arm64 |

> `node-pty` **保留并编译**（约 32 MB），终端面板从 v1 起可用；编译产物在 `build/Release/pty.node`，80,208 B。

瘦身后目标：`usr/local` 约 0.9–1.1 GB（含 Node 22，不含编译工具链），rootfs 约 1.0–1.2 GB，IPA 约 320–420 MB。工具链默认不装；需要编译 `.node` 时再 `apk add`，不占默认体积。

**路径 3（保底）**：把 DSH 依赖树打成 tar，首启解压到 `/root/.dsh`；但这会让 IPA 变大且首启变慢，只在路径 1/2 都失败时使用。

### 5.3 启动链

```text
App 启动
  │
  ├─ 1. RootfsManager.installIfNeeded()
  │     解压 Resources/rootfs.zip → Application Support/IDSH/rootfs/{data,meta.db}
  │     校验 meta.db、data/bin/sh、data/usr/bin/node
  │     设置 NSFileProtectionCompleteUntilFirstUserAuthentication
  │     排除 iCloud 备份
  │
  ├─ 2. ISHService.boot()
  │     ISHKernel.shared.boot(withRootPath: rootfsURL)
  │     安装 die handler / 崩溃处理
  │     mount fakefs → PID 1 → 设备节点 → procfs/devpts → DNS → TTY
  │
  ├─ 3. ISHService.startSupervisor()
  │     executeCommand("/usr/bin/node /usr/local/bin/dsh-supervisor.mjs")
  │     保持返回的 handle；超时/退出时重启
  │
  ├─ 4. DSHServerSupervisor.waitForURL()
  │     轮询 rootfs/data/tmp/dsh.url
  │     解析 `dsh web: http://127.0.0.1:8790/?token=...`
  │
  ├─ 5. WKWebView.load(url)
  │     首次带 ?token=；服务端 303 + Set-Cookie
  │     后续 reload 靠 cookie
  │
  └─ 6. 进入前台 → 显示 DSH
```

**为什么用 supervisor 而不是直接 `dsh web`**：

- `dsh web` 的 token 每次进程随机，必须从 stdout 解析；
- 服务崩溃后要自动重启；
- 需要把 URL/状态写成文件，供原生轮询；
- 需要固定 `DSH_HOME`、`DSH_PERMISSION_MODE`、`HOME`；
- 需要日志轮转。

### 5.4 `dsh-supervisor`（Node 实现）

不用 shell 解析日志——rootfs 里的 `tail`/`head` 不一定有，且 `dsh` 的 URL 可能被 ANSI 包裹。用一个 ~171 行的 Node 脚本做 supervisor，原生只读 `/tmp/dsh.url` 与 `/tmp/dsh.state`（fakefs 里 `/var/run` 是符号链接，宿主路径不好直接读；`/tmp` 是真实目录）。

**必须打 DSH 启动补丁**（`patches/dsh-web-app-early-url.patch`）：

- 原逻辑要等 `loader.await()` + `auditStartupEntries()` 才打印 URL；在 iSH 上实测 server 已经监听并返回 401，但 URL 2 分钟不出现（audit 在 fakefs 上极慢）。
- 补丁把 `announceReady()` 提前到 `apply` 里直接调用，并 `writeFileSync("/tmp/dsh.url", authenticatedUrl, { mode: 0o600 })`。
- 这样 supervisor/原生不必解析 stdout；stdout 的 `dsh web:` 只作兜底。
- 补丁在 rootfs 构建时 `patch -p1 < patches/dsh-web-app-early-url.patch`，不要手改 node_modules。


```js
#!/usr/bin/env node
// /usr/local/bin/dsh-supervisor.mjs
import { spawn } from 'node:child_process';
import { appendFileSync, mkdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:net';
import { setTimeout as sleep } from 'node:timers/promises';

const HOME = '/root';
const PORT0 = Number(process.env.DSH_PORT || 8790);
const URL_FILE = '/tmp/dsh.url';
const STATE_FILE = '/tmp/dsh.state';
const LOG_FILE = '/var/log/dsh.log';
const DSH_BIN = process.env.DSH_BIN || '/usr/local/bin/dsh';
const HEALTH_MS = 30_000;
const START_TIMEOUT_MS = 120_000;

mkdirSync('/var/run', { recursive: true });
mkdirSync('/var/log', { recursive: true });

let port = PORT0;
let child = null;
let readyUrl = null;
let rapidFail = 0;
let stopping = false;
let restartTimer = null;

function log(line) {
  const s = `[${new Date().toISOString()}] ${line}\n`;
  const st = (() => { try { return statSync(LOG_FILE).size; } catch { return 0; } })();
  if (st > 5 * 1024 * 1024) rmSync(LOG_FILE, { force: true });
  appendFileSync(LOG_FILE, s);
}

function writeAtomic(path, text) {
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, text);
  renameSync(tmp, path);
}

function setState(s) { writeAtomic(STATE_FILE, `${s}\n`); }
function setUrl(u) { readyUrl = u; writeAtomic(URL_FILE, `${u}\n`); }
function clearUrl() { readyUrl = null; rmSync(URL_FILE, { force: true }); }

async function pickPort() {
  for (let p = PORT0; p < PORT0 + 20; p += 1) {
    const ok = await new Promise((resolve) => {
      const srv = createServer();
      srv.once('error', () => resolve(false));
      srv.once('listening', () => srv.close(() => resolve(true)));
      srv.listen(p, '127.0.0.1');
    });
    if (ok) return p;
  }
  return PORT0;
}

function scheduleRestart(delay) {
  if (stopping || restartTimer) return;
  restartTimer = setTimeout(() => {
    restartTimer = null;
    start().catch((e) => { log(`start failed: ${e.message}`); scheduleRestart(30_000); });
  }, delay);
}

async function start() {
  port = await pickPort();
  setState('starting');
  clearUrl();
  child = spawn(DSH_BIN, ['web', '--host', '127.0.0.1', '--port', String(port), '--no-open'], {
    env: {
      ...process.env,
      HOME,
      DSH_HOME: `${HOME}/.dsh`,
      DSH_PERMISSION_MODE: 'danger-full-access',
      DSH_TELEMETRY_DISABLED: '1',
      PATH: `/usr/local/bin:/usr/bin:/bin`,
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  let buf = '';
  const onData = (d) => {
    const text = d.toString('utf8').replace(/\x1b\[[0-9;]*m/g, '');
    buf += text;
    const m = buf.match(/dsh web:\s*(https?:\/\/\S+)/);
    if (m && !readyUrl) {
      setUrl(m[1].trim());
      setState('ready');
      rapidFail = 0;
      log(`ready: ${new URL(m[1]).host}`);
    }
    if (text.trim()) log(text.trimEnd());
  };
  child.stdout.on('data', onData);
  child.stderr.on('data', onData);

  // 首选：DSH 启动补丁把 authenticatedUrl 写进 /tmp/dsh.url；stdout 解析只是兜底。
  // URL 出现时 server 可能还没 accept，先 probe 一次再置 ready。
  let checking = false;
  const poll = setInterval(async () => {
    if (readyUrl || checking) return;
    checking = true;
    try {
      const u = readFileSync(URL_FILE, 'utf8').trim();
      if (!u.startsWith('http://') && !u.startsWith('https://')) return;
      const res = await fetch(u, { redirect: 'manual', signal: AbortSignal.timeout(3_000) });
      if (res.status >= 200 && res.status < 500) {
        setUrl(u);
        setState('ready');
        rapidFail = 0;
        log(`ready(file): ${new URL(u).host}`);
      }
    } catch {}
    finally { checking = false; }
  }, 500);

  const started = Date.now();
  const timer = setInterval(() => {
    if (readyUrl) { clearInterval(timer); clearInterval(poll); return; }
    if (Date.now() - started > START_TIMEOUT_MS) {
      log('start timeout; killing child');
      child.kill('SIGKILL');
      clearInterval(timer);
      clearInterval(poll);
    }
  }, 1000);

  child.on('exit', (code, signal) => {
    clearInterval(timer);
    clearInterval(poll);
    clearUrl();
    setState('restarting');
    log(`child exit code=${code} signal=${signal}`);
    child = null;
    if (stopping) return;
    rapidFail += 1;
    scheduleRestart(rapidFail >= 5 ? 30_000 : 2_000);
  });

  child.on('error', (e) => {
    log(`spawn error: ${e.message}`);
    child = null;
    if (stopping) return;
    rapidFail += 1;
    scheduleRestart(rapidFail >= 5 ? 30_000 : 2_000);
  });
}

async function health() {
  if (!readyUrl) return;
  try {
    const res = await fetch(readyUrl, { redirect: 'manual', signal: AbortSignal.timeout(10_000) });
    if (res.status >= 200 && res.status < 400) return;
    log(`health status=${res.status}`);
  } catch (e) {
    log(`health error: ${e.message}`);
  }
  // 连续失败才重启，避免一次抖动杀 Host
  const fails = (health.fails = (health.fails || 0) + 1);
  if (fails >= 3) {
    health.fails = 0;
    log('health failed 3x; restarting');
    child?.kill('SIGKILL');
  }
}

process.on('SIGTERM', () => { stopping = true; child?.kill('SIGTERM'); process.exit(0); });
process.on('SIGINT', () => { stopping = true; child?.kill('SIGTERM'); process.exit(0); });

start().catch((e) => { log(`initial start failed: ${e.message}`); scheduleRestart(30_000); });
setInterval(health, HEALTH_MS).unref();
```

原生侧只读 `dsh.url` / `dsh.state`，不依赖固定端口；`pickPort()` 会从 8790 起找空闲端口，URL 里自然体现实际端口。

**为什么要 Node 而不是 sh**：

- `dsh` 输出是行缓冲+ANSI，Node 能可靠拼包、去色、正则。
- 不需要 rootfs 装 `coreutils`、`grep`、`sed`、`tail`。
- 可以做健康检查、原子写、日志轮转、端口递增。
- 代价是多一个 ~20MB RSS 的 Node 进程；相对 512MB V8 可接受。

**注意**：

- supervisor 本身不 fork 多个 `dsh`；只保留一个实例。
- 健康检查失败 3 次才重启，避免 `dsh` 忙时误杀。
- `fetch` 对 `http://127.0.0.1` 不触发 ATS（guest 侧 Node 不受 ATS 约束）。
- 如果 `dsh` 退出时 URL 文件还在，先删；原生看到文件消失即显示启动器。

### 5.5 原生 `ISHService`

职责：

- 持有 `ISHKernel` 单例与安全退出。
- `boot()` 在后台队列执行，主线程只更新进度；`ISHKernel.boot` 内部可能需要主线程，按 XCFramework 示例调整。
- `executeCommand` 返回的 handle 必须保留，避免被 ARC 释放导致进程被杀。
- 提供 `stopServer()`、`restartServer()`、`guestCPU()`、`guestMemory()`。
- App 进入后台时调用 `beginBackgroundCPUGovernor`；回前台 `endBackgroundCPUGovernor`。
- 监听 `ISHKernel` 的 exit notification，更新状态。

**不要**在 Swift 层重复实现 `mount_root`/`do_execve`；XCFramework 的 bridge 已封装。只有 bridge 缺 API 时，才按 `Docs/ISH_SANDBOX_PORT.md` 的 boot order 打补丁。

### 5.6 认证与 WebView

DSH 的认证行为（已实测）：

- `dsh web` 启动打印 `dsh web: http://127.0.0.1:<port>/?token=<43字符>`。
- 首次 `GET /?token=` 返回 303，`Set-Cookie: dsh-auth-...=v1...; Max-Age=2592000; HttpOnly; SameSite=Strict`。
- 之后无 token 的 `/` 靠 cookie 返回 200 HTML。
- cookie 绑定 `authority`（host:port），所以端口不能变；变了就重新用新 URL 载入。
- token 每次进程随机，没有 env/flag 固定；必须从 stdout 解析。
- 无 token 请求返回 401 + 文案“dsh web authentication required; reopen the URL printed by dsh web.”。

WebView 策略：

- `WKWebsiteDataStore.default()` 持久化 cookie。
- 首次 `load(URLRequest(url: launchURL))`；不要把 token 存日志。
- 失败/401/空白时：重新读 `dsh.url`；如果 URL 变化，重新 `load`；如果服务没起来，重启 supervisor。
- 回前台：如果 `webView.url` 为空或页面显示断线，`reload()`；DSH 客户端自身会重连 WS。
- 绝不做“去掉 token 的裸 127.0.0.1 访问”，否则 401。

### 5.7 后台详细设计

#### 5.7.1 五条腿

| 腿 | API | 作用 | 默认 |
|---|---|---|---|
| 静音音频 | `AVAudioEngine` + `AVAudioPlayerNode` + `UIBackgroundModes=audio` | **主保活**，可长期不 suspend | 开 |
| 持续定位 | `CLLocationManager` + `CLBackgroundActivitySession` | 第二保活，耗电/隐私 | 关（用户显式开） |
| Continued Processing | `BGContinuedProcessingTask`（iOS 26） | 45 分钟“加速”，系统 UI 可见 | 用户点按 |
| 有限后台任务 | `beginBackgroundTask` | 30 秒收尾 | 自动 |
| Live Activity | ActivityKit | 展示状态，不保活 | 开 |

#### 5.7.2 静音音频

参数（来自 OpenMinis / Harness Mobile 实测）：

- `AVAudioSession`：`.playback`，`.mixWithOthers`，`setActive(true)`。
- 1 秒、44.1 kHz、单声道、全零 `AVAudioPCMBuffer`，`.loops`。
- `mainMixerNode.outputVolume = 0.001`（不要 0，某些路由会优化掉）。
- 健康检查：`engine.isRunning && player.isPlaying`；失败重试 3 次，退避 0.5 秒。
- 进入后台 1.5 秒后才启动，避免与媒体播放冲突；回前台 1.5 秒防抖后停止。
- 注册 `AVAudioSession.interruptionNotification`、`mediaServicesWereResetNotification`，恢复时重建 engine。

#### 5.7.3 CPU governor

直接调用 `ISHKernel` 的：

```objc
- (void)beginBackgroundCPUGovernor;
- (void)endBackgroundCPUGovernor;
- (NSDictionary *)backgroundCPUGovernorStatus;
```

常量（已核对 OpenMinis）：

```text
GOV_CADENCE_NS        = 100 ms
GOV_SLOTS             = 601
GOV_RATE_LOOKBACK     = 10
GOV_SOFT_CPU_S        = 30.0
GOV_HARD_CPU_S        = 38.0
GOV_RED_EXIT_CPU_S    = 32.0
GOV_YELLOW_MIN_DUTY   = 0.15
GOV_RED_DUTY          = 0.03
GOV_PREDICT_S         = 1.0
GOV_STARTUP_CAP_NS    = 2 s
GOV_LOG_INTERVAL_NS   = 5 s
```

机制：`ish_set_timer_tick_hook` + `g_throttle_ratio_q16` + `gov_poke_all_tasks`，10 Hz 闭环。**不要**简单固定 80% 占空比；iOS 会在几十秒内杀掉。

#### 5.7.4 iOS 26 Continued Processing

Info.plist：

```xml
<key>UIBackgroundModes</key>
<array>
  <string>audio</string>
  <string>processing</string>
  <string>fetch</string>
</array>
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
  <string>com.brooks.idsh.continued.*</string>
</array>
<key>NSAppTransportSecurity</key>
<dict>
  <key>NSAllowsLocalNetworking</key>
  <true/>
  <key>NSAllowsArbitraryLoads</key>
  <false/>
</dict>
<key>UIFileSharingEnabled</key>
<true/>
<key>LSSupportsOpeningDocumentsInPlace</key>
<true/>
<key>NSSupportsLiveActivities</key>
<true/>
<key>UIRequiresFullScreen</key>
<false/>
<key>UIApplicationSupportsIndirectInputEvents</key>
<true/>
```

> 绝不要加 `WKAppBoundDomains`：它会禁用 JS bridge 并限制本地导航。`127.0.0.1` 在 ATS 下属于 local networking；`NSAllowsArbitraryLoads` 保持 false，模型 API 走 HTTPS。

代码要点：

```swift
let request = BGContinuedProcessingTaskRequest(
    identifier: "com.brooks.idsh.continued.\(runID.uuidString.lowercased())",
    title: "DSH 后台运行",
    subtitle: "Agent 正在执行"
)
request.strategy = .fail
try BGTaskScheduler.shared.submit(request)
```

- 必须在 `BGTaskScheduler.shared.register` 注册同 identifier；iOS 26 支持 `prefix.*` 通配。
- 必须在 App 前台、由用户动作触发提交；不能在 `didEnterBackground` 里偷偷提交。
- `task.progress.totalUnitCount = 100`；每 2 秒更新；不更新会被 expire。
- `expirationHandler` 里停止 guest 任务/保存状态，`setTaskCompleted(success:false)`。
- 时长有硬上限（实测约 45 分钟）；不是无限后台。
- `UIBackgroundModes=processing` 免费证书可用；不需要付费 entitlement。

#### 5.7.5 生命周期

```text
scenePhase .background:
  - 保存当前 URL/状态
  - beginBackgroundTask（30s）
  - 启动 audio keepalive（1.5s 后）
  - 如果用户开启“强化后台” → 启动 location
  - 如果当前有 Agent 任务且用户允许 → 提交 continued（仅 iOS 26）
  - beginBackgroundCPUGovernor

scenePhase .active:
  - endBackgroundCPUGovernor
  - 停止 continued（如果还在）
  - 1.5s 后停止 audio/location
  - 重新读 URL；必要时 reload WebView
```

### 5.8 UI 设计：启动器 + DSH

#### 5.8.0 先回答：启动器要不要做成 DSH 插件？

**不要。启动器必须是原生 iOS 层，不能是 DSH 插件。**

原因不是“插件不好”，而是层级不对：

- DSH 插件跑在 guest 的 Node 进程里；DSH 没起来、Node 崩了、rootfs 坏了，插件也不存在，正好在最需要“重试/重置/看日志”的时候失效。
- 插件可以被 `cordis.patch.yml` 禁用、被用户卸载、被一次坏安装搞坏；“不可卸载”在用户态没有真正的强制力。
- 探针要读 `/tmp/dsh.state`、探测 401、启动/停止 iSH、管理后台和 rootfs——这些都在原生侧，插件没有权限。
- 启动器是“BIOS/引导器”，插件是“操作系统里的应用”。不能让应用来负责引导。

**正确做法**：原生启动器 + 一个**可选的 DSH 桥接插件**。

- 桥接插件只做两件事：在 DSH 侧边栏加“返回启动器”，以及把 DSH 内部状态回传给原生。
- 它装不装都不影响启动、恢复、终端、设置；原生永远保留一个悬浮的 `⌂` 兜底入口。
- 这样既满足“DSH 里有地方回退”，又不会把恢复能力押在插件上。

#### 5.8.1 信息架构

```text
原生启动器（黑底）
├── 进入 DSH            → WKWebView（同一个 DSH Web 前端）
├── 终端                → xterm.js + ISHKernel TTY
├── 插件                → 已装列表 / 启停 / 打开 DSH 插件管理器
├── 设置                → 后台、引擎、rootfs、日志、关于
└── 状态                 → 引擎 / DSH / 端口 / CPU / 内存 / 后台模式
```

DSH 内：

```text
WKWebView
├── 原生悬浮 ⌂（始终可用，可关闭）
└── 可选 idsh-bridge 插件（侧边栏“返回启动器”）
```

#### 5.8.2 启动器视觉

纯黑、无渐变、无插画，只用字重/间距/1px 边框区分层级：

```text
┌──────────────────────────────────────────────┐
│  idsh                                 ● 运行中 │
│                                              │
│  DeepSeek Harness                            │
│  Alpine 3.21 · Node 22.23.4 · DSH 0.2.2-rc.1 │
│                                              │
│  ┌────────────────────────────────────────┐  │
│  │              进入 DSH                   │  │
│  └────────────────────────────────────────┘  │
│  冷启动 67s · 端口 8790 · 后台 音频 + 加速    │
│                                              │
│  ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐ │
│  │  终端  │ │  插件  │ │  设置  │ │  日志  │ │
│  └────────┘ └────────┘ └────────┘ └────────┘ │
│                                              │
│  后台保活   ● 音频   ○ 定位   ● iOS 26 加速   │
│  CPU 12%  内存 412MB  已运行 00:12:34         │
└──────────────────────────────────────────────┘
```

规格：

- 背景 `#000000`；卡片 `#0A0A0A`；描边 `#1E1E1E`；主文字 `#F5F5F5`；次文字 `#8A8A8A`；强调色只用一个（琥珀 `#F5A623` 或青绿 `#7BE0B8`，二选一，不混用）。
- 字体：SF Pro Display；数字/端口/耗时用 SF Mono；不要自定义装饰字体。
- 圆角 16pt；主按钮高 56pt；四个快捷入口最小 72×64pt；iPad 内容最大宽度 720pt 居中，iPhone 贴边 20pt。
- 图标只用 SF Symbols 线性版；不画拟物图标。
- 动效只保留 150–200ms 的淡入/数字变化；不做弹跳、粒子、发光。

状态机：

| 状态 | 顶部 | 主按钮 | 说明 |
|---|---|---|---|
| `extracting` | 首次准备 | 进度条 | 解压 rootfs；显示 MB/总 MB |
| `booting` | 启动 Linux | 进度条 | iSH boot + PID 1 |
| `starting` | 启动 DSH | 进度条/可取消 | supervisor + dsh web |
| `ready` | 运行中 | 进入 DSH | 显示端口、耗时 |
| `degraded` | 服务不稳定 | 重试/重启 | 健康检查失败 |
| `failed` | 启动失败 | 重试/重置/日志 | 显示错误码与最后一行日志 |
| `stopped` | 已停止 | 启动 | 用户手动停止 |

#### 5.8.3 原生探针（不是插件）

`LauncherModel`（`@MainActor`）持有 `RuntimePhase`，`RuntimeProbe` 每秒做一次轻量检查：

1. 读 `rootfs/data/tmp/dsh.state`：`starting` / `ready` / `failed`。
2. 读 `rootfs/data/tmp/dsh.url`：拿到实际端口与 token；**不在 UI/日志里显示 token**。
3. 对 `http://127.0.0.1:<port>/` 做 `URLSession` 探测：期望 401；对带 token URL 期望 303；带 cookie 期望 200。
4. 连续 30 秒失败或 3 次重启失败 → `degraded/failed`，显示“重启 DSH / 导出日志”。
5. 进程/内存：`getGuestProcessCount:anonBytes:`，超过 600MB 提示“内存紧张”。

探针只依赖原生文件系统 + HTTP，不依赖 DSH 内部任何插件；DSH 完全挂掉也能显示错误并重置。

#### 5.8.4 启动与回退流程

- App 启动 → 立即显示启动器（不白屏），同时后台 boot；若 `autoEnterDSH=true` 且上次是 ready，就绪后 1.2 秒淡入 DSH。
- 首次启动：显示“首次准备运行时（约 380–480 MB）”，不要求用户进终端。
- 从 DSH 返回启动器：WKWebView 不销毁，DSH/supervisor 继续跑；启动器显示“运行中”，再点“进入 DSH”是瞬时的。
- 启动器里“停止 DSH”：只停 supervisor/DSH，不停 iSH；需要“完全停止”时再停 iSH。
- 崩溃恢复：`dsh-supervisor` 自动重启；原生发现 3 次失败 → 显示错误页，提供“重置 rootfs”（二次确认）。

#### 5.8.5 终端

- 入口：启动器“终端”；全屏 sheet，黑底，等宽字体。
- 实现：本地 `terminal.html` + vendored xterm.js（不联网、不走 CDN），通过 `TerminalBridge` 连 `ISHKernel` 的 TTY：
  - 输出：`ISHKernel` 的 stdout/stderr 回调 → `evaluateJavaScript("term.write(...)")`；
  - 输入：`term.onData` → `ISHKernel.sendInput:`；
  - 尺寸：`term.onResize` → `setTerminalSize:rows:`；
  - 启动：`/bin/bash -l`；退出后显示“会话结束，重新打开”。
- 键盘条：`Ctrl`、`Esc`、`Tab`、`↑`、`↓`、`⌘`（外接键盘时隐藏）。
- 快捷命令（按钮，不是自动执行）：
  - `node -v && dsh --version`
  - `tail -50 /var/log/dsh.log`
  - `cat /tmp/dsh.state`
  - `apk info nodejs`
- 终端是 root shell，首次进入显示一次警告；不把 token 打进屏幕历史。
- 如果 `ISHKernel` 的交互 PTY 接口在 XCFramework 里不完整，v1 先退化为“命令控制台”（输入一行、流式输出），v1.1 补完整 PTY；不阻塞主线。

#### 5.8.6 简易插件管理器

启动器里的“插件”不是重写 DSH 插件系统，而是三层：

1. **只读总览**：读 `/root/.dsh/profiles/web/package.json` 的 `dsh.profile.bundles` 与 `cordis.patch.yml`，列出名称、版本、来源（npm/git/link）、启用/禁用。
2. **轻操作**：启用/禁用（改 `cordis.patch.yml`）、重启 DSH、打开插件目录、复制诊断信息。
3. **安装/卸载**：v1 直接深链到 DSH 原版插件管理器（同一套 Web UI，功能完整）；M3 再评估用 `dsh-plugin-manager` 的 API 做原生安装表单。

这样既满足“启动器里有简易管理器”，又避免在原生侧重实现一遍 pnpm 解析、平台校验、build script 审批——那才是最容易出错的部分。

插件页必须显示一条固定提示：

> 纯 JS/TS 插件直接安装；带 `.node` 的插件会现场编译（首次可能慢，需允许 build scripts），失败时显示包名与缺失库；只有 macOS/Windows 专属二进制会提示平台不匹配。Office/PDF 单独说明。

“创造模式”入口：打开 DSH 并新建一个 Creator 会话；不另做一套创建 UI。

#### 5.8.7 设置

分组，全部原生黑底：

**后台**
- 静音音频保活（默认开；关掉可能被 suspend）
- 持续定位（默认关；说明耗电/隐私）
- iOS 26 后台加速（默认开；说明 45 分钟量级）
- 自动进入 DSH（默认开）
- 崩溃自动重启（默认开）
- 低电量模式降级提示（默认开）

**引擎**
- Node 22.23.4（默认，已全链路实测）/ Node 24.11.1（实验项，DSH 启动未闭合）
- DSH 端口（默认 8790，自动回退）
- rootfs 版本 / 重置 rootfs（二次确认）
- 清理 npm/pnpm 缓存
- 导出诊断包（日志、版本、设备、最近 200 行，不含 token）

**界面**
- 悬浮 `⌂` 按钮（默认开）
- 页面缩放（90%/100%/110%，只影响 WKWebView）
- 桌面 UA（默认开）
- 保持屏幕常亮（默认关）

**关于**
- 版本、构建号、上游 commit、GPL-3.0 源码入口、第三方许可。

#### 5.8.8 从 DSH 返回启动器

两条路，互为兜底：

1. **原生悬浮 `⌂`**（始终存在）：36×36 半透明胶囊，位于左上安全区下方；点按回启动器，长按弹出“重启 DSH / 导出日志 / 后台设置”。4 秒无操作淡到 35% 透明度，不消失；可在设置里关闭。
2. **可选 `idsh-bridge` 插件**：在 DSH 侧边栏加“返回启动器”和“运行状态”两个条目；通过 `window.webkit.messageHandlers.idsh.postMessage({ action: "home" })` 调原生。插件卸载后原生 `⌂` 仍在。

不让返回依赖网页路由，也不让返回依赖插件；这是启动器作为“宿主”的底线。

#### 5.8.9 iPad / iPhone

- iPad：启动器最大宽度 720pt 居中；DSH 全屏；Stage Manager 缩放；硬件键盘/触控板原生支持；四方向。
- iPhone：启动器单列；终端全屏；DSH 可启动、可滚动、可输入，但不承诺紧凑布局（用户已说 iOS 无所谓）。
- `UIRequiresFullScreen=false`；`UIApplicationSupportsIndirectInputEvents=true`。
- 安全区：DSH WebView 贴满；iPhone 灵动岛遮挡时只加原生 `additionalSafeAreaInsets` 兜底。

#### 5.8.10 文件与链接

- `<input type=file>`：`WKUIDelegate.runOpenPanelWith` → `UIDocumentPickerViewController`，`asCopy: true`，允许多选。
- 下载：`WKDownloadDelegate` → `Documents/IDSH/Downloads`，完成后分享面板。
- 外链：非 `127.0.0.1` 的 http(s) 用 `UIApplication.shared.open`。
- `mailto:` / `tel:` / `itms-services:` 交给系统。
- OAuth 弹窗：v1 交给 Safari，回跳用 URL scheme。

### 5.9 插件系统详细设计

#### 5.9.1 为什么能装 PC 插件

DSH 插件是 Cordis bundle，分两半：

- **Host half**：Node 进程里的 `@deepseek-ai/dsh-*` 插件，跑在 guest Node。
- **Client half**：Web 前端里的 `dsh-client-ui-*`，跑在 WKWebView。

因为我们两边都原样运行，所以纯 JS/TS 插件与 PC 完全一致；插件管理器、市场、Creator 预设也完全一致。

#### 5.9.2 预装与缓存

- 预装 `pnpm@11.28.5`。
- 首次启动前，在 rootfs 烘焙阶段预热：
  - `pnpm store add` 常用包（可选）；
  - DSH 自身依赖已在全局 `node_modules`；
  - 插件安装时 pnpm 仍需要网络；离线时只能装已缓存包。
- `pnpm` 的 `node-linker` 默认 isolated；在 fakefs 上硬链接可能失败，建议在 profile 的 `.npmrc` 设置：

```ini
node-linker=hoisted
package-import-method=copy
```

  `copy` 比硬链接慢，但 fakefs 对硬链接支持不稳定；先用 copy 保证正确。

- 原生插件编译环境（写进 `/root/.npmrc` 与 supervisor 的 env）：
  ```ini
  nodedir=/usr
  build_from_source=true
  ```
- pnpm 11 默认拦截依赖的 build scripts；插件安装时走 UI 的 `allowBuilds` 审批，或在 profile 的 `pnpm-workspace.yaml` 里加 `onlyBuiltDependencies`。不要为了省事全局 `dangerouslyAllowAllBuilds`，除非用户明确选择“信任所有插件”。
- `node-gyp` 需要 `python3 make g++`；默认不预装，遇到需要编译的插件时再 `apk add python3 make g++`。编译失败时保留 `build/` 与 stderr，供诊断导出。

#### 5.9.3 平台声明

DSH 插件管理器会校验 `dsh.bundle.platforms`，guest 里 `process.platform === "linux"`、`process.arch === "arm64"`。

- 纯 JS 插件一般声明 `["linux","darwin","win32"]` 或不限制 → 可装。
- 只声明 `darwin` 的插件会被标记 `unsupported-platform`；可以在插件仓库里加 `linux` 声明（如果代码确实跨平台），或在本机 patch `platforms`。
- 含 `.node` 的插件：声明 linux 的，按下面的 ABI 规则编译/加载；只声明 darwin/win32 但含原生二进制的，属于平台差异，安装日志会点名包和原因，不再一概拒绝。

#### 5.9.4 Creator 模式

- 使用 DSH 原版 Creator preset；`plugin_manager` 工具已启用。
- 测试用例：让模型创建一个“hello”bundle，包含一个 client UI 面板 + 一个 host tool；安装后重载可见。
- 注意：Creator 生成的 bundle 如果依赖 npm 包，安装仍走 pnpm；网络/时间与 PC 类似，只是慢。

#### 5.9.5 原生 addon：全支持方案（Linux/ARM64 边界）

**结论先给：`.node` 不是边界。** ish-arm64 是解释器，不依赖 iOS JIT；guest 里的 ARM64 `.node` 由 iSH 解释执行，`dlopen`/N-API 可用。完整命令与失败矩阵见 [Docs/NATIVE-ADDONS.md](Docs/NATIVE-ADDONS.md)。我们已在 guest 内实测：

- 手写 N-API addon：`g++ -shared -fPIC -I/usr/include/node` → `require()` 返回 `42`；Node 22 通过（Node 24 也能编译，但运行时未采用）。
- `node-pty@1.2.0-beta.15`：`node-gyp rebuild --nodedir=/usr` 成功产出 `build/Release/pty.node`（80,208 B）；CLI 管道下 `uv_tty_init` 报 EINVAL 是“没有 TTY”，不是加载失败。
- DSH 本体在 Node 24.11.1 下**未跑通**：`dsh web` 无 URL 文件，`dsh-web-app` 的 `apply` 未执行；Node 24 只保留为普通运行时/ABI 实验，不作为默认。

| 依赖 | 用途 | 方案 | 结论 |
|---|---|---|---|
| `node-pty` | 终端/PTY | 烘焙时编译，产物随 rootfs 带走 | v1 可用（PTY 真机复测） |
| `better-sqlite3` | SQLite 插件 | 优先 `linux-arm64-musl` 预编译；否则源码编译（SQLite 较大，慢） | 支持 |
| `sharp` | 图片处理 | `@img/sharp-linuxmusl-arm64` 预编译 | 支持 |
| `@deepseek-ai/node-addon-system` | DSH 原生桥 | npm 自带 `bin/musl/system.node`；已验证 `require` 成功，导出 `tryLock` | 支持（已验证） |
| `sherpa-onnx-node` | 语音识别 | 官方只有 glibc；从源码用 cmake 构建 musl/arm64 | 源码可做，体积大；不阻塞 v1 |
| `koffi` | FFI | koffi 有 linux-arm64；DSH 自身只在 Windows 分支加载 | 支持 |
| `libreoffice-kit` | Office | 无 linux-arm64 原生库；wasm 被 `--jitless` 禁用 | 走 Alpine `soffice` CLI 兜底 |

**安装器策略**：

1. rootfs 默认不装编译链；需要时 `apk add python3 make g++`（约 300 MB），再让 agent 现场编译。
2. 插件安装**允许 build scripts**：`npm_config_nodedir=/usr`、`npm_config_build_from_source=true` 仅在预编译缺失时启用。
3. 先探测 `linux-arm64-musl` 预编译；命中直接用；未命中走 `node-gyp`；编译失败把 stderr 写进插件安装日志，并在 UI 显示“包名 + 缺失的库/头文件”，不静默。
4. 纯 JS 但只声明 `darwin` 的插件，用 `pnpm patch`/profile patch 补 `linux`；含原生二进制的必须真编译，不能只改声明。
5. “所有插件”的准确边界：**所有 Linux ARM64 可构建的插件**。macOS/Windows 专属二进制（调用 Cocoa/Windows API）在 Linux 上本来就不能运行，PC 跨 OS 也一样；这不是 iSH 阉割，而是插件自身的平台绑定。

#### 5.9.6 `idsh-bridge`：可选，不是启动器本体

`plugins/idsh-bridge/` 是一个**纯 Client-half** 的 Cordis bundle，职责只有两个：

- 在 DSH 侧边栏加“返回启动器”；
- 在 DSH 内显示一个轻量状态 chip（引擎/后台/端口），点击可回启动器。

实现方式：

- `client.js` 里通过 DSH 的 client slot 注册一个侧边栏条目；
- 点击时 `window.webkit.messageHandlers.idsh.postMessage({ action: "home" })`；
- 原生 `NativeBridge` 收到后把 WKWebView 降下去，显示启动器。

边界：

- 它**不参与** boot、rootfs、supervisor、后台、探针；
- 它**不是**“不可卸载”的；卸载后原生 `⌂` 仍然可用；
- 如果 DSH 的 client slot API 在 0.2.2-rc.1 上不稳定，v1 可以只保留原生 `⌂`，把 bridge 插件放到 M3.5；不要为了一个返回按钮阻塞主线。
- 它是“体验增强”，不是“恢复路径”。

### 5.10 构建与 IPA

#### 5.10.1 工程

用 XcodeGen，`project.yml` 为真源：

- Target `IDSH`：iOS 18.0+，Swift 6，arm64。
- Target `IDSHLiveActivity`：Widget Extension，iOS 26 条件可用。
- Framework：`HarnessISH.xcframework`（embed false，静态链接）。
- 依赖：`AVFoundation`、`BackgroundTasks`、`ActivityKit`、`WebKit`、`SystemConfiguration`、`libsqlite3.tbd`、`libresolv.tbd`。
- Info.plist 由 `project.yml` 生成。

#### 5.10.2 签名

- Bundle ID 占位：`com.brooks.idsh`；团队占位：`TEAM_ID`。
- 自用推荐：
  - 免费 Apple ID：Xcode 直接安装，7 天有效；SideStore 可自动续签。
  - 付费开发者账号：Ad Hoc，1 年有效。
  - TrollStore 不支持 iOS 26（17.0.1+），不要考虑。
- App Store 不是目标：GPL + 后台音频 + 动态插件都会触发审核问题。

#### 5.10.3 打包

```sh
xcodebuild -project IDSH.xcodeproj \
  -scheme IDSH \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/IDSH.xcarchive \
  archive

xcodebuild -exportArchive \
  -archivePath build/IDSH.xcarchive \
  -exportPath build/ipa \
  -exportOptionsPlist ExportOptions.plist
```

`ExportOptions.plist`：

```xml
<key>method</key><string>development</string>
<key>signingStyle</key><string>automatic</string>
<key>stripSwiftSymbols</key><true/>
<key>compileBitcode</key><false/>
```

产物：`build/ipa/IDSH.ipa`，约 380–480 MB。

#### 5.10.4 构建顺序

```text
1. Scripts/fetch-upstreams.sh          # 固定 commit，拉 OpenMinis/ish-arm64
2. Scripts/build-engine.sh             # XCFramework
3. Scripts/build-rootfs.sh             # Alpine + Node + DSH + supervisor + zip
4. xcodegen generate                   # 生成 IDSH.xcodeproj
5. xcodebuild archive / exportArchive  # IPA
```

---

## 6. 里程碑与工期

按“1 名开发者 + AI 辅助”估算，单位为工作日；不含等待 Apple 签名/网络的时间。

### M0 — 可行性闭环（2–3 天）

目标：在 macOS 上证明“iSH 里能装 DSH 并拿到带 token 的 URL”。

- [x] 编译 ish-arm64 CLI（已成功）。
- [x] 生成 Alpine 3.21 fakefs（已成功）。
- [x] guest 内 `apk add nodejs=22.23.4-r0`（历史基线，90 MiB）。
- [x] guest 内 `npm i -g @deepseek-ai/dsh@0.2.2-rc.1`（成功：656 包，9 分钟，`NPM:0`）。
- [x] guest 内 `dsh web` 监听 127.0.0.1；无 token 401、token 303、cookie 200；冷启动 67 秒。
- [x] Node 22.23.4 全链路：`dsh web` 401/303/200、冷启动 67 秒、supervisor 可跑。
- [ ] Node 24.11.1 的 DSH web 启动未闭合（`dsh-web-app` 未 apply、无 URL）；普通 Node 24 与 hello addon 可用。
- [x] 手写 N-API addon 在 Node 22 下用 `/usr/include/node` 编译并 `require()` 成功（返回 42）。
- [x] `node-pty` 用 Node 22 headers 编译成功（`pty.node`，80,208 B）。
- [ ] 用 `HarnessISH.xcframework` 在真机 boot 同一 rootfs（模拟器不可用，见 §11）。

**Exit**：CLI 侧 `dsh web` + token + 200；XCFramework 能 boot 并执行 `/bin/true`。

### M0.5 — 原生 addon 按需闭环（遇到再编，不阻塞）

目标：把“`.node` 按需编译”做成可重复的路径；默认不装工具链，遇到再处理，不阻塞 M1。

- [ ] `better-sqlite3` 在 guest 内编译/加载；记录耗时与内存峰值。
- [ ] `sharp` 用 `linuxmusl-arm64` 预编译加载；验证 ABI 127。
- [x] `@deepseek-ai/node-addon-system` 的 `bin/musl/system.node` 在 Node 22 下加载（导出 `tryLock`）。
- [ ] 用 DSH 原版插件管理器安装一个含 `.node` 的测试插件；确认 build scripts 未被 pnpm 11 拦截，或已走 `allowBuilds` 审批。
- [ ] 把 `npm_config_nodedir`、`allowBuilds`、预编译探测写进 rootfs 的 `.npmrc` 和插件安装说明。
- [ ] 失败路径：无源码、只有 macOS/Windows 二进制、编译缺库；三种错误都能在日志里定位到包名。

**Exit**：三个原生包（`node-pty`、`better-sqlite3`、`sharp`）在 guest 内全部 `require` 成功；一个 DSH 插件从安装到调用跑通。

### M1 — iOS 薄壳 + 启动器（3–4 天）

目标：iPad 上打开 App，先看到黑底启动器；进入后看到与 PC 同布局的 DSH。

- [ ] `RootfsManager` 解压/校验。
- [ ] `ISHService` boot + `dsh-supervisor`。
- [ ] `DSHServerSupervisor` 读 URL，做 401/303 probe。
- [ ] `LauncherView`：状态卡、进入按钮、终端/插件/设置/日志四个入口。
- [ ] `WKWebView` 加载并完成 token 登录。
- [ ] 原生悬浮 `⌂` 回启动器；DSH 不销毁。
- [ ] 终端 v1：命令控制台或完整 TTY（按 XCFramework 接口决定）。
- [ ] 插件页 v1：只读列表 + 启停 + 打开 DSH 插件管理器。
- [ ] 设置页 v1：后台开关、端口、重置 rootfs、导出日志。
- [ ] 真机 iPad 截图。

**Exit**：冷启动 ≤ 90 秒进 DSH；启动器可进终端并执行 `node -v`；从 DSH 回启动器后会话不断；UI 与 Mac 同布局；无崩溃。

### M2 — 后台（2–3 天，硬门槛）

- [ ] 静音音频保活；锁屏 30 分钟不 suspend。
- [ ] `beginBackgroundCPUGovernor` 生效。
- [ ] 30 秒 `beginBackgroundTask` 收尾。
- [ ] iOS 26 `BGContinuedProcessingTask` + Live Activity。
- [ ] 前台/后台切换不丢服务、不重复启动。
- [ ] 低电量模式/热压力降级提示。

**Exit**：锁屏 30 分钟 guest 脚本时间戳缺口 < 20 秒；continued 45 分钟任务不中断；连续 3 次。

如果 M2 失败，暂停后续，先解决后台（见 §11），不要先做插件/打包。

### M3 — rootfs 预烘焙与插件（3–4 天）

- [ ] rootfs 内置 Node/DSH/pnpm/supervisor，首启零网络。
- [ ] profile 预生成；`cordis.patch.yml` 可调。
- [ ] 插件管理器安装纯 JS 插件成功。
- [ ] 安装含 `.node` 的插件成功：build scripts 被允许，`node-gyp` 用 `/usr/include/node` headers。
- [ ] `node-pty` / `better-sqlite3` / `sharp` 至少各一个真实调用通过。
- [ ] Creator 模式生成并安装 hello 插件。
- [ ] Office 关闭时给出提示；终端可用，不再降级。
- [ ] 插件安装耗时/磁盘/内存记录；失败日志含包名与缺失库。

**Exit**：断网首启进 UI；纯 JS 插件与原生插件安装/启用/卸载全链路；Creator 全链路。

### M4 — 打包与验收（2 天）

- [ ] `xcodebuild archive` + IPA。
- [ ] Xcode / Apple Configurator / SideStore 安装。
- [ ] 完整验收清单（§8）。
- [ ] 文档：构建、安装、已知限制、GPL 声明。

**Exit**：iPad 上安装 IPA，按 §8 全过；重启设备后仍可启动。

### M5 — 可选增强（3–5 天）

- AOT 镜像（Node 启动加速）。
- 自动检测 Agent 忙碌 → 自动提交 continued。
- 外接显示器 / 多窗口。
- 插件离线缓存。
- iPhone 紧凑布局插件（不改变 PC 布局）。

---

## 7. 测试计划

### 7.1 测试矩阵

| 层级 | 环境 | 用途 |
|---|---|---|
| CLI | macOS arm64 + ish CLI | rootfs/Node/DSH 快速回归 |
| 模拟器 | iOS 26.3 arm64 | UI/启动/网络；不能验证后台 |
| 真机 | iPad Pro 11 M4，iPadOS 26.x | 后台/性能/签名/插件 |
| 真机 | iPhone（可选） | 可用性冒烟 |

### 7.2 后台测试脚本

在 guest 里：

```sh
i=0
while [ $i -lt 360 ]; do
  date +%s >> /root/bg-heartbeat.txt
  i=$((i+1))
  sleep 10
done
```

通过 DSH 的 bash 工具启动，然后锁屏 30 分钟。回前台后：

```sh
wc -l /root/bg-heartbeat.txt
awk 'NR>1 && $1-prev>20 {print "GAP", prev, $1} {prev=$1}' /root/bg-heartbeat.txt
```

要求：行数 ≥ 170，无 GAP。

### 7.3 认证测试

```sh
# 宿主/CLI 侧
curl -i "http://127.0.0.1:8790/" | head -5          # 期望 401
curl -i "http://127.0.0.1:8790/?token=$TOKEN" | head -8  # 期望 303 + Set-Cookie
curl -i -b "dsh-auth-...=..." "http://127.0.0.1:8790/" | head -3  # 期望 200
```

### 7.4 插件测试

- 安装一个纯 JS 插件（npm 包名以实际为准）。
- 重载 WebView，确认 client UI 出现。
- 调用 host tool，确认 guest Node 执行。
- Creator：对话生成 hello bundle → `plugin_manager` 安装 → 启用。

### 7.5 UI 对比

- iPad 横屏 1194×834（或 Stage Manager 自定义宽度）截图。
- Mac 浏览器同宽度截图。
- 对比：侧栏宽度、主区 padding、输入框位置、工具卡片、字体层级。
- 记录差异；若仅字体渲染差异，接受；若布局断点差异，修 CSS/UA。

### 7.6 稳定性

- 连续 1 小时对话 + 工具调用；内存 < 1.2 GB。
- `kill -9` guest Node；supervisor 2 秒内重启；WebView 自动/手动重连。
- 旋转、Stage Manager 拖拽、外接键盘、锁屏/解锁各 20 次。
- 低电量模式、热压力提示。

---

## 8. 验收清单（Definition of Done）

> 全部在 iPad Pro 11-inch (M4)，iPadOS 26.x 真机完成；模拟器不算。

1. [ ] IPA 可安装、可启动；重启设备后仍可启动。
2. [ ] 冷启动 ≤ 90 秒进入 DSH；热启动 ≤ 3 秒。
2a. [ ] 启动器显示阶段/端口/后台状态；终端可执行 `node -v`；插件页能列出已装 bundle。
2b. [ ] DSH 内悬浮 `⌂` 可回启动器，返回后会话/滚动位置不丢；卸载 `idsh-bridge` 后仍可返回。
3. [ ] 断网首启可进入 UI（模型请求除外）。
4. [ ] DSH 登录态正常；无 token 时 401，带 token 303，cookie 后 200。
5. [ ] iPad 布局与 Mac 同宽度一致（§7.5）。
6. [ ] 硬件键盘可输入；触控板可滚动/点击；Stage Manager 缩放不崩。
7. [ ] 文件上传/下载可用；外链跳 Safari。
8. [ ] 锁屏 30 分钟 heartbeat 无 >20 秒缺口（连续 3 次）。
9. [ ] iOS 26 后台加速 45 分钟任务不中断；Live Activity 显示/结束正常。
10. [ ] 低电量/热压力下有降级提示，不崩溃。
11. [ ] 纯 JS 插件安装/启用/卸载；Creator 生成并安装。
11a. [ ] 含 `.node` 的插件安装成功，重启后仍可加载；`node-pty`、`better-sqlite3`、`sharp` 至少各一个真实调用。
12. [ ] 原生插件编译失败时，UI/日志给出包名、缺失库/头文件和下一步，不静默失败；Office 关闭有说明。
13. [ ] 服务崩溃后自动重启；WebView 可恢复。
14. [ ] 1 小时会话内存 < 1.2 GB；无 jetsam。
15. [ ] 日志可导出且不含 token/API Key。
16. [ ] GPL 声明、上游 commit、补丁、构建脚本齐全。

---

## 9. 风险与回退

| 风险 | 概率 | 影响 | 缓解 | 触发回退 |
|---|---|---|---|---|
| iOS 后台仍 suspend | 中高 | 核心需求失败 | audio + location + continued + governor；M2 硬门槛 | 用原生 Harness Mobile（SwiftUI）作为 fallback，牺牲 UI 一致 |
| Node 24 与 DSH/iSH 兼容性未闭合 | 中 | DSH 启动无 URL | 默认 Node 22（全链路已过）；Node 24 仅作实验，修好 URL 再切 | 远程 Host（Mac/服务器）+ WKWebView |
| DSH 插件装不上（pnpm/fakefs） | 中 | 需求 3 失败 | `node-linker=hoisted`、`package-import-method=copy`、预缓存 | 预装插件包，Creator 仅本地 bundle |
| 内存 512 MB 不够 | 中 | OOM/崩溃 | 限制上下文、定期重启、监控；iPad 8GB | 降级到原生 Swift Agent |
| 引擎 XCFramework 构建失败 | 中 | 阻塞 | 用已实测 OpenMinis CLI/ISHKernel 直接集成；device-only | 改用 OpenMinis 工程裁剪 |
| 性能太慢 | 高 | 体验差 | 常驻 Host、预烘焙、避免 npm 安装、AOT 二期 | 远程 Host 或原生 |
| `.node` 插件装不上 | 低 | 部分插件不可用 | 预装编译链 + 允许 scripts + prebuild 兜底；失败日志点名包名 | 只有 macOS/Windows 专属 API 的插件无法支持（平台差异，非 iSH 限制） |
| Office 不可用 | 高 | 文档预览缺失 | 禁用 office-to-pdf 或提示 | 外接转换服务（可选） |
| 签名 7 天过期 | 高 | 需重签 | SideStore/付费账号 | 文档说明 |
| GPL 合规 | 低 | 法律 | 附源码/补丁/许可证；自用 | 不分发 |

### 9.1 后台失败的兜底

如果 M2 证明 audio 也被杀（例如 iPadOS 26 更激进）：

1. 先检查是否误用了 `AVAudioSession` 类别/模式；用 `.playback` + `.mixWithOthers`，不要 `.ambient`。
2. 检查 Info.plist `UIBackgroundModes=audio` 是否真的进包（`plutil -p`）。
3. 用 Console.app 看 `RunningBoard`/`jetsam` 日志。
4. 加 continued + Live Activity；continued 到期后如果 audio 也被杀，只能接受“后台有限”。
5. 最终 fallback：**远程 Host**（Mac 常开）或**原生 SwiftUI Agent**。这两条都能保证功能，但分别牺牲离线和 UI 一致性。

### 9.2 Node 版本策略

- **默认 Node 22.23.4（musl/arm64，ABI 127）**：DSH 0.2.2-rc.1 全链路实测——`dsh web` 401/303/200、冷启动 67 秒、supervisor 可跑；`node-pty` 与 `node-addon-system` 均加载成功。
- **Node 24.11.1 是实验项，不是默认**：普通 Node 24 能跑 HTTP server，hello N-API addon 也能编译；但 `dsh web` 在 iSH 下未进入 `dsh-web-app` 的 `apply`，没有 URL 文件。修好这条链路之前不切默认。
- **原生插件 ABI 策略**：默认运行时是 Node 22 → 用 `/usr/include/node` 现场重编（`node-gyp`/`cmake`）；N-API 稳定的预编译 `.node` 可直接加载；只有 Node 24 ABI 137 的预编译包需要源码重编。纯 JS 插件不受影响。
- 判定标准：`node -v` + `dsh web` 401/303/200 + 一次 agent 工具调用 + `node-pty`/`better-sqlite3` 至少一个加载。全过才发布默认。
- 不要用 `--ignore-scripts` 安装插件；DSH 自身依赖可以 `--ignore-scripts` 装完再单独 `node-gyp rebuild` `node-pty`。

---

## 10. 立即可执行的下一步（按顺序）

1. **guest 内 DSH 已验证**：`dsh --version` → `0.2.2-rc.1`；`dsh web` 401/303/200；supervisor 能置 ready 并写 URL。保留 rootfs 作为烘焙基线。
2. **生成 `HarnessISH.xcframework`**：
   ```sh
   cd .ref/repos/deepseek-harness-ios
   ./Scripts/fetch-upstreams.sh
   ./Scripts/build-ish-sandbox.sh all
   ```
   若失败，先用我们已构建的 `ish` CLI 继续 rootfs，不阻塞。
3. **写 `Scripts/build-rootfs.sh`**：Node 22.23.4 + DSH + pnpm + 预编译 `node-pty` 产物，产出 `rootfs.zip`（编译链按需另装，不进默认包）；同时做 §5.2.1 的瘦身。
4. **M0.5 按需做**：默认不装编译链；遇到需要源码编译的 `.node` 插件时，再 `apk add` 工具链并让 agent 编译。
5. **建 `IDSH` 工程**：先只做 boot + supervisor + WKWebView，跑通 UI。
6. **做启动器 v1**：`LauncherView` + 悬浮 `⌂` + 终端 + 插件只读页 + 设置页；这是 M1 的一部分，不要拖到 M3。
7. **M2 后台**：先 audio，再 governor，再 continued。
8. **M3 插件**：装一个纯 JS 插件 + 一个原生插件 + Creator；再决定 `idsh-bridge` 是否值得做。
9. **M4 打包**：IPA + 验收。

---

## 11. 需要用户拍板的点

这些不影响先开工，但会影响最终配置：

1. **Bundle ID / 开发者团队**：计划用 `com.brooks.idsh` + `TEAM_ID` 占位。
2. **签名方式**：免费 Apple ID（7 天，SideStore）还是付费 Ad Hoc（1 年）？
3. **iPhone**：只保证“能跑”，还是要专门做紧凑布局？（后者会偏离 PC 同款 UI）
4. **后台定位**：是否允许作为第二保活腿？默认关闭，开启会增加耗电和隐私提示。
5. **插件范围**：已按你的要求定为“全装”，含 `.node` 现场编译；唯一例外是插件自身调用 macOS/Windows 专属 API 的二进制（在任何 Linux 上都跑不了，属于平台差异）。是否允许 `danger-full-access`？自用建议是。
6. **Office/Python**：是否值得为 100–200 MB 体积换 Office/脚本能力？v1 建议不装；不影响插件。
7. **IPA 分发**：只自己装，还是要给第二台设备/朋友？后者涉及 GPL 源码分发。

---

## 12. 已实测证据（截至 2026-11-08）

| 项 | 结果 |
|---|---|
| macOS | 26.3 (25D125)，Xcode 26.2，iOS SDK 26.2 |
| iSH CLI 构建 | `meson setup build-arm64-release -Dguest_arch=arm64 --buildtype=release && ninja -C build-arm64-release` 成功，`[100/100] Linking target ish` |
| Alpine boot | `./ish -f alpine-rootfs /bin/sh -c 'uname -m'` → `aarch64` |
| Alpine 版本 | 3.21.0 |
| 网络 | 补 `/etc/resolv.conf` 后 `apk update` 成功，25265 packages |
| Node 安装 | `apk add nodejs=22.23.4-r0 npm ...` 成功；`node -v` → `v22.23.4`，`npm -v` → `10.9.1`；rootfs 90 MiB |
| DSH macOS | Node 22.23.2 + `dsh web` 打印 `http://127.0.0.1:49998/?token=...`；401/303/cookie/200 均验证 |
| DSH 包 | `@deepseek-ai/dsh@0.2.2-rc.1`，451 MB node_modules，6 个 `.node`（均 darwin） |
| guest DSH 安装 | `npm i -g` 成功：`added 656 packages in 9m`，`NPM:0`，`dsh --version` → `0.2.2-rc.1`；仅 EBADENGINE 警告（要求 Node ≥24.9，实际 22.23.4）；Node 22 已足够跑通 |
| guest DSH web | `dsh web` 在 guest 内监听 127.0.0.1；无 token 401，带 token 303 + cookie，带 cookie 200；冷启动到 URL **67 秒** |
| Node 22 | `apk add nodejs=22.23.4-r0`：`v22.23.4`、ABI 127、arm64 |
| Node 24（实验） | `node-v24.11.1-linux-arm64-musl` 解压即跑：`v24.11.1`、ABI 137；普通 HTTP server 可用；DSH web 未闭合 |
| Node 24 + DSH | **未通过**：`dsh web` 无 URL 文件，`dsh-web-app` 的 `apply` 未执行；不作为默认 |
| N-API addon | 手写 `hello.c` 用 `g++ -shared -fPIC -I/usr/include/node` 编译，Node 22 `require()` 返回 42 |
| node-pty | `node-gyp rebuild --nodedir=/usr` 成功，`build/Release/pty.node` 80,208 B；Node 22 `require` 通过；CLI 管道下 `uv_tty_init EINVAL` 是缺少 TTY |
| guest 启动补丁 | 原版要等 audit，URL 2 分钟不出；补丁改为立即 `announceReady()` 并写 `/tmp/dsh.url` 后，67 秒可用；见 `patches/dsh-web-app-early-url.patch` |
| guest 运行噪音 | `FUTEX-STALL ... 180s, 8 threads` 会打印，但 server 仍可用；未观察到崩溃 |
| supervisor | guest 内 `dsh-supervisor.mjs` 跑通：`/tmp/dsh.state` → `ready`，`/tmp/dsh.url` 写入实际端口；base 401、token 303 |
| 端口回退 | 8790 被占用时 supervisor 自动选 8791；native 必须读 URL，不能硬编码端口 |
| 前端 | 无宽度断点；iPad 天然桌面布局 |
| 后台 | OpenMinis 五条腿 + governor 常量已核对；`BGContinuedProcessingTask` 文档行为已核对 |
| 设备 | iPad Pro 11-inch (M4) 已配对；iPad Pro 12.9 5th 不可用 |
| 现有项目 | `liulingfei-1/deepseek-harness-ios` 已 clone，XCFramework 构建脚本/补丁/后台代码可复用 |

> 待补：`HarnessISH.xcframework` 真机 boot、iPad 真机首启、后台 30 分钟、原生插件真实安装、WKWebView 首屏时间。

---

## 13. 一句话总结

**用 ish-arm64 当“Linux 运行时”，用 DSH 原版当“应用”，用 WKWebView 当“屏幕”，用静音音频 + CPU governor + iOS 26 continued 当“后台”。**

技术可行性已经过半；真正的决战是 M2 后台。先别写插件市场、别做 iPhone 美化、别碰 AOT；把“iPad 锁屏 30 分钟任务不断”跑通，再谈其他。
