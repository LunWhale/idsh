# idsh 构建与侧载说明

## v0.1.4（2026-11-14）

设备 slice 也换用新 ish-arm64 引擎并保留 futex/poll 阀门修复，与模拟器 slice 一致；iOS 26.3 iPhone 17 Pro 模拟器实测 DSH 启动、模型列表、真实 API 对话与 95 秒后台存活均正常。IPA 仍为未签名。


## v0.1.3（2026-11-14）

改用 Debian 13 + glibc Node 24.11.1 rootfs，修复 DSH 0.2.2 首次聊天触发 iSH 引擎 SIGILL 的问题；同时启用 TLS 1.2（iSH fakefs 下 TLS 1.3 会 bad record mac）与 TCP DNS（`options use-vc`）。首次启动解压/冷启动时间与 v0.1.2 接近。


## v0.1.2（2026-11-12）

新增：DSH 设置页的「打开配置文件」在 iOS 宿主重定向到 App 内配置编辑器，不再报“无法打开配置文件”。

## v0.1.1（2026-11-11）

启动进度条、性能 HUD、App 内配置文件编辑器、启动期间后台准备与断点续解压、强制流式 fetch polyfill（修 undici/WebAssembly 导致的 API 断流）。

## 产物

- `dist/idsh-unsigned.ipa`（约 291 MB，未签名，sha256 `3aa47c77811e0c905d63959da4e351bbe7a8d0d98b34ce2d9d086d4c4b5937af`）
- 构建脚本：`scripts/make-ipa.sh`
- 目标：iPad Pro 11-inch (M4)，最低 iOS 18.0；已在 iPadOS 26.3 模拟器验证

## 本机构建

```bash
cd idsh
bash scripts/make-ipa.sh
```

依赖：

- Xcode 26.2（iOS SDK 26.2）
- `app/Resources/alpine-rootfs.zip`（Debian 13 + Node 24.11.1 + DSH 0.2.2-rc.1 + npm/pnpm shim）
- `app/Vendor/HarnessISH.xcframework`（引擎已移除 futex/poll 空闲自杀阀）

## 签名与安装

当前 IPA **未签名**，因为这台机器上没有可用的 iOS App Development 描述文件
（Xcode 账号登录失败，`~/Library/MobileDevice/Provisioning Profiles` 为空）。
两种做法：

1. **SideStore / AltStore / Sideloadly**：用免费 Apple ID 重签后再装，7 天有效。
2. **Xcode 真机运行**：打开 `app/idsh.xcodeproj`，在 Signing & Capabilities 里选择
   自己的 Team（使用你自己的 Apple Development 证书），
   连接 iPad 后直接 Run，再 Product → Archive → Export 出签名 IPA。

> TrollStore 不支持 iOS 17.0.1+，iOS 26 上不可用。

## 2026-11-10 更新（B-01/B-02/B-03）

- **分享面板（B-03）**：新增 `idsh-share` Share Extension；系统分享里选 idsh 后，
  文件落到 App Group，主 App 提供「发送到新会话 / 发送到当前会话 / 仅保存到 /workspace」。
  文件经 `/workspace` bind mount 进入 guest，并自动把路径预填进 DSH 输入框。
- **DSH 更新（B-01）**：设置页有「DSH 更新」区块，显示当前/最新版本；
  rootfs 内 `/usr/local/bin/dsh-update` 执行 `npm i -g @deepseek-ai/dsh@latest`，
  再重打 early-url 补丁并重启 DSH。
- **登录（B-02）**：已定位为 DSH Web 宿主缺少交互式登录回调：
  `dsh-deepseek-account-platform/lib/index.js:859` 的 `prompt: () => Promise.reject(new PlatformAuthError("protocol"))`，
  服务端日志为 `[deepseek-account] sign-in failed { errorCode: 'protocol' }`。
  因此账号 OAuth 登录在当前 Web 宿主下不可用；App 设置页已提示改用 API Key。
- rootfs v5 增加 `xdg-user-dir` shim 与默认工作区，修复首启「无法创建默认工作区」。

## 首次启动

1. App 启动后显示 `idsh` 启动器（黑底）。
2. 首次运行解压 `alpine-rootfs.zip`（约 1.1 GB，1–2 分钟）。
3. 自动启动 iSH → 启动 `dsh-supervisor.mjs` → `dsh web 127.0.0.1:8790`。
4. 冷启动约 90–150 秒；启动器显示 `DSH 已就绪` 后自动进入 WKWebView 的 DSH UI。

## 启动模式

启动器底部和设置页都有「完整 / 极简 · 快」切换，切换后自动重启 DSH：

- **完整**：加载全部 Cordis 插件（办公文档、自动化任务、子代理、网页工具、日程等）。
- **极简 · 快**：supervisor 在 `dsh web` 后追加
  `--patch /usr/local/share/idsh/fast.patch.yml`，按 row id 关闭约 68 个非核心插件，
  保留会话、工作区、文件、核心工具、终端和插件管理器。实测 iSH CLI 内约 50 秒
  （完整约 66 秒），iPad 模拟器内约 69 秒（完整约 82 秒）。
- 极简模式只影响启动时加载的插件，不改 rootfs、不改已安装插件；
  切回完整模式并重启即可恢复全部能力。`RootfsPatch.bundle` v6 负责把
  `fast.patch.yml` 与新版 `dsh-supervisor.mjs` 写入 guest。

## 插件系统

- DSH 的 `plugin_manager` 通过 `pnpm` 安装插件；本 rootfs 的 `/usr/local/bin/pnpm`
  是一个 **npm 兼容 shim**（`scripts/pnpm-npm-shim.js`），把 `pnpm add/remove/install`
  翻译成 npm 命令；真实 pnpm 10.34.9 保留在 `/usr/local/bin/pnpm.real`。
- 原因：旧引擎（`de124dd6`）在 worker 线程下的 zlib 断言会让 pnpm 的 tarball
  worker 崩溃；npm 不走该 worker，因此可稳定安装。
- 已在 App 内验证：`dsh plugin --profile web add dsh-plugin-upgrader` →
  `added 4 packages`，`dsh plugin list` 可见 `dsh-plugin-upgrader@1.8.0`，
  profile 的 `package.json` 与 `dsh.profile.bundles` 均正确更新。
- 纯 JS / npm 包插件可用；依赖 pnpm workspace 专有行为或原生 addon 的插件仍可能失败。

## 后台

- 静音音频（`UIBackgroundModes=audio`）+ 可选定位 + iOS 26 `BGContinuedProcessingTask`
  + 过期前 `beginBackgroundTask` 收尾 + Live Activity。
- 后台时启用 CPU governor（duty cycle 0.55）；回前台关闭。
- 已验证：移除引擎自杀阀后，`dsh web` 在 App 内连续 25 分钟无退出，RSS 245–310 MB。

## 已知限制

- iPhone 竖屏是桌面级 UI，未做移动端重排（需求以 iPad 为主）。
- DeepSeek 账号登录在沙箱内可能失败，建议用 API Key。
- 引擎仍为 `de124dd6` 基线（已移除两条自杀阀），worker 线程 zlib 缺陷未在引擎层修复，
  由 npm shim 绕过。
- 未签名 IPA 需要自签后才能安装。
