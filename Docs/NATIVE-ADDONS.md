# 原生 `.node` 插件支持

> 结论：**支持**。iSH 是 ARM64 用户态 Linux 兼容层，不是“只能跑 JS 的沙盒”。guest 里的 ARM64 `.node` 由 iSH 解释执行，Node 的 `process.dlopen` / N-API 可用；不需要 iOS JIT，也不吃 W^X。

本文记录 2026-11-08 在 `.ref/repos/OpenMinis/deps/resources/alpine-rootfs` 里的实测结果，以及打包时应该固化的安装路径。

## 0. 先分清三种“插件”

DSH 插件不是一种东西，跨平台能力要分层看：

1. **纯 JS/TS 的 Cordis bundle**：Host 半边跑在 Node 里，Client 半边跑在 WKWebView 里；不依赖 `.node`、不调用 macOS/Windows 专属命令。**这种插件与操作系统无关**，Mac 上写的拿到 Linux/ARM64 上照样跑。
2. **含 `.node` 原生扩展的插件**：`.node` 是编译后的共享库，格式和 ABI 绑定 OS + CPU 架构 + libc + Node ABI。macOS 的 Mach-O 不能进 Linux，glibc 的 `.so` 不能进 Alpine musl，x86_64 不能进 arm64；但**同平台的源码可以在设备上重编**。
3. **调用 OS 专属 API/命令的插件**：比如 `osascript`、`pbcopy`、Cocoa、Windows Registry。这类不是二进制格式问题，是代码本身依赖某个 OS 的接口。

所以“Mac 插件能不能在 Linux 用”取决于它属于哪一层；绝大多数 DSH 插件是第 1 层，答案是**能**。

## 1. 已验证

| 项 | 命令 | 结果 |
|---|---|---|
| Node 22 | `apk add nodejs=22.23.4-r0 npm` | `v22.23.4`，ABI **127**，arm64 |
| DSH | `/usr/bin/node /usr/local/bin/dsh --version` | `0.2.2-rc.1`（stdout 在 iSH 下需 `fs.writeSync` 才可靠） |
| DSH server | `dsh web --host 127.0.0.1 --port 8792 --no-open` | 401/303/200 + `/tmp/dsh.url` 可用 |
| 手写 N-API | `g++ -shared -fPIC -I/usr/include/node -o hello.node hello.c` | `require()` 返回 **42** |
| node-pty | `node-gyp rebuild --nodedir=/usr` | `build/Release/pty.node`，80,208 B；Node 22 `require` 退出码 0 |
| node-addon-system | `require(.../bin/musl/system.node)` | 加载成功，导出 `tryLock`（72,264 B；Node 22/24 均可） |

说明：CLI 管道里 `node-pty` 的 `pty.spawn` 会报 `uv_tty_init EINVAL`，因为没有分配 TTY；这不是加载失败，真机 App 的终端面板需要复测 PTY 分配。

## 2. 为什么能加载

- `.node` 是 **guest 的 ARM64 共享库**，由 guest 的 musl `dlopen` 加载；iSH 解释其中的 ARM64 指令，和解释 `/bin/sh`、`node` 本身是同一条路径。
- Node 的 `--jitless` 只禁用 V8 的 JIT 和 Wasm，不禁用 `dlopen` 原生扩展。
- 不依赖 iOS 的 `dynamic-codesigning` / `get-task-allow`；自签 IPA 可用。

## 3. 唯一真正的边界

不是“`.node` 不支持”，而是 **平台**：

- 只提供 `darwin-arm64` / `win32-x64` 二进制的插件，不能在 Linux/ARM64 上加载；PC 上也不能把 macOS 插件装进 Windows，这是插件自己的平台绑定。
- 调用 Cocoa、Windows API、iOS 私有框架的插件，必须重写成 Linux 可编译的版本，或由原生 Swift 侧另做桥；这类是少数。
- 只要插件有源码、且只依赖 POSIX/Linux 能提供的库，就能在设备上 `node-gyp` 编译。

## 4. 打包时的固定配置

### rootfs

```sh
apk add --no-cache \
  bash git curl ca-certificates tzdata xz

# Node 22（Alpine 3.21 官方包）
apk add --no-cache nodejs=22.23.4-r0 npm
node -v   # v22.23.4
```

### DSH 安装

```sh
export PATH=/usr/local/bin:$PATH
export npm_config_prefix=/usr/local
export npm_config_nodedir=/usr

/usr/bin/npm i -g --ignore-scripts --no-audit --no-fund \
  @deepseek-ai/dsh@0.2.2-rc.1 pnpm@11.28.5

# 单独编译 node-pty，避免 DSH 安装时被可选原生依赖拖死
cd /usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/node-pty
/usr/bin/node /usr/lib/node_modules/npm/node_modules/node-gyp/bin/node-gyp.js \
  rebuild --nodedir=/usr
```

### `.npmrc` / 环境

```ini
nodedir=/usr
build_from_source=true
```

`pnpm` 11 默认拦截 build scripts；插件安装时必须走 UI 的 `allowBuilds` 审批，或在 profile 的 `pnpm-workspace.yaml` 里加 `onlyBuiltDependencies`。不要默认全局 `dangerouslyAllowAllBuilds`。

## 5. 插件安装器行为

1. 读 `package.json`，判断是否含 `binding.gyp` / `prebuilds` / `install` 脚本。
2. 优先找 `linux-arm64-musl` 或 `linux-arm64` + ABI 127 的预编译 `.node`；没有预编译时，提示安装 `python3 make g++`（或自动 `apk add`）再编。
3. 没有预编译 → `node-gyp rebuild --nodedir=/usr`。
4. 编译失败 → 把 stderr 写入插件安装日志，UI 显示包名 + 缺失的库/头文件；不静默回退。
5. 只有 `darwin`/`win32` 二进制 → 明确显示“平台不匹配”，并给出源码构建建议。

## 6. 待补的真机验证

- [ ] `better-sqlite3` 从源码编译并 `require`（按需，不阻塞默认 IPA）。
- [ ] `sharp` 加载 `@img/sharp-linuxmusl-arm64`（按需）。
- [x] `@deepseek-ai/node-addon-system` 的 `bin/musl/system.node` 在 Node 22 下加载（导出 `tryLock`）。
- [ ] `node-pty` 在 App 的 TTY 里 `pty.spawn` 成功（不是管道）。
- [ ] DSH 插件管理器安装一个含 `.node` 的真实插件，重启后仍可加载。
