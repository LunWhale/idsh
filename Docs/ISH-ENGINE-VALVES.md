# idsh 引擎定制：移除 iSH 的两条「空闲自杀阀」

## 结论（一句话）

App 内 `dsh web` 每约 **105 秒**以 `exit code=0 signal=null` 退出，根因是 iOS bridge 里
iSH guest 内核自带的两条 idle "safety valve" 会对**没有控制 TTY**的进程组调用
`do_exit_group(0)`；Node 事件循环空闲时只做 `epoll_pwait/futex/nanosleep`，而这三个
系统调用恰好不刷新"进展"时间戳，于是一个**完全健康**的 `dsh web` 服务器被判定为空闲并杀掉。
现在已从引擎源码移除两条阀门的击杀行为，重建 `HarnessISH.xcframework`，App 内进程已稳定
运行 25 分钟以上无重启。

## 证据链

### 1. 现象

iPad App 的 `.../alpine-rootfs/data/var/log/dsh.log`：

```
[09:20:40] ready: 127.0.0.1:8790
[09:22:25] child exit code=0 signal=null
[09:23:47] ready: 127.0.0.1:8790
...
```

周期 100–125 秒，累计 18+ 次。`var/log/dsh-exit.log` 只有 `START pid=...`，
**没有任何** SIGNAL / STDIN end / beforeExit / EXIT 记录 → 退出发生在 C 层，JS 层不可见。

### 2. 决定性证据

以 `SIMCTL_CHILD_ISH_EXEC_TRACE=1 xcrun simctl launch ... com.brooks.idsh` 启动，
抓 `xcrun simctl spawn <UDID> log stream --predicate 'process == "idsh"'`：

```
SAFETY-VALVE[futex]: pid=12 stalled 180s in futex_wait(uaddr=0x8002894 val=2), 8 threads, no children → exit_group
```

紧随其后 `child exit code=0 signal=null`。阀门打印受 `ish_exec_trace()` 门控
（读环境变量 `ISH_EXEC_TRACE`，进程内 static 缓存，仅宿主启动时读一次），所以 App
默认日志里看不到这一行。

### 3. 为什么 macOS CLI 复现不出来

macOS 下用 `/bin/sh -c` 启动时进程组**有控制终端**（`group->tty != NULL`），
两条阀的前置条件都不成立；App 内 `ISHShellExecutor` 用 pipe 做 stdin/stdout，
**没有控制 TTY**，阀门生效。这解释了早期「引擎不杀进程」的误判。

### 4. 版本差异

| 项 | commit | 含 futex 阀 |
| --- | --- | --- |
| 上游修复 | `4227c5c8` "fix(futex): stop exit_group'ing processes after a 180s untimed futex wait; log it instead" | 否 |
| 参考项目锁定 revision | `de124dd6` | 是 |
| 当前 ish-arm64 checkout | `0fd17a13` | 否 |

App 链接的 `HarnessISH.xcframework` 由 `de124dd6` 构建，`strings libHarnessISH.a` 可见
三条阀门字符串 → 必须重建 framework。

上游 `4227c5c8` 的 commit message 记载了同一类误杀：**任何 Go 程序**启动约 180 秒后
无输出、无 panic、exit status 0 地死掉（一次性删掉了阀门，因为「判定单个线程 stuck
不等于进程 stuck」）。我们的 Node 场景与之完全同构。

## 改动

新增 `build/idsh-engine-fixes.py`，在 vendor 补丁之后、`meson setup` 之前，对提取出的
ish-arm64 源码树做两处修改：

1. **`kernel/futex.c`** — 移除 `SAFETY-VALVE[futex]` 的 `do_exit_group(0)`
   （`timeout == NULL && stall_count >= 1800`，即 1800 × 100ms = 180s，
   条件 `live > 1 && !has_live_children`）。保留一次性诊断输出，
   改为无门控的 `[idsh] FUTEX-STALL: ...; not killed`。与上游 `4227c5c8` 语义一致。

2. **`fs/poll.c`** — 移除 `SAFETY-VALVE[poll]` 的 `do_exit_group(0)`
   （`current->pid != 1 && current->group->tty == NULL && idle_s >= 60`）。
   上游为了 CLI 场景保留了这条阀（那里有 TTY 豁免），但 iOS bridge 永远没有 TTY，
   所以这里必须一并移除。同样保留 `[idsh] POLL-IDLE: ...; not killed` 诊断。

`kernel/exit.c` 的 `SAFETY-VALVE[exit]`（`do_exit_group` 等线程退出超时后强制杀）
**保留不动**——它属于 `do_exit_group` 的清理路径，不是本次杀手。

### 构建接线

`Scripts/build-ish-sandbox.sh`（vendor 仓库内的副本）在应用完 `0007-persistent-process-stdin.patch`
之后新增：

```bash
if [ -n "${ISH_ENGINE_FIX_SCRIPT:-}" ]; then
  /usr/bin/python3 "$ISH_ENGINE_FIX_SCRIPT" "$source_dir"
fi
```

重建命令：

```bash
cd idsh
ISH_ENGINE_FIX_SCRIPT=$PWD/build/idsh-engine-fixes.py \
ISH_KEEP_BUILD_DIR=1 \
  bash .ref/repos/deepseek-harness-ios/Scripts/build-ish-sandbox.sh libraries
```

产物：`.ref/repos/deepseek-harness-ios/Vendor/OpenMinisISH/Artifacts/HarnessISH.xcframework`
（两个 slice 都过 ObjC + Swift smoke 测试），再覆盖到 `app/Vendor/HarnessISH.xcframework`
（旧版备份为 `app/Vendor/HarnessISH.xcframework.prev-valve`）。

## 验证

| 检查 | 结果 |
| --- | --- |
| 旧 framework `strings \| grep SAFETY-VALVE` | 4 条（exit×2、futex、poll） |
| 新 framework `strings \| grep SAFETY-VALVE` | 2 条（只剩 exit×2） |
| 新 framework 含 `[idsh] FUTEX-STALL` / `[idsh] POLL-IDLE` | 是 |
| xcframework ObjC/Swift smoke（device + simulator） | 通过 |
| iPad App 内 `child exit` 计数 | 修复后 **0 次**（此前每 ~105s 一次） |
| iPad App 连续运行 | **>25 分钟**无重启，`127.0.0.1:8790` 持续 LISTEN |
| iPad 上 DSH UI | 正常渲染，PC 三栏布局，中文正常 |

## 复现要点

- guest 内直接改文件不会被 fakefs 索引：必须用 `base64 -d >` 在 guest 内写，
  或重建 rootfs。宿主 `data/` 里手动放文件，guest 视图看不到。
- 早期曾尝试的两个「运行时绕过」都无效，不要重走：
  1. 在 `dsh` 的 `bin.js` 里注入 20 秒一次的 `statSync('/')` keepalive
     （`stat` 属于会刷新 `last_progress_ns` 的 syscall）——只覆盖 dsh 自身的进程组，
     掩盖不了 supervisor 与其子进程的其余路径，App 内仍然 ~104 秒退出。
  2. 在 guest 内打开 `/dev/ptmx` 试图取得控制 TTY —— `open('/dev/tty')` 返回
     `EIO`、`/dev/console` 返回 `ENODEV`，guest 里没有 `/dev/pts/` 条目，
     也没有 `script`/`util-linux`。`group->tty` 由 `fs/tty.c:120-122` 在
     `TIOCSCTTY_` 时设置，guest 侧拿不到。
- 唯一可靠路径就是重建 framework。
