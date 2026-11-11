# Corresponding source

`idsh` is distributed under GPL-3.0 because the app links GPL-3.0 code from
iSH / ish-arm64 and OpenMinis. This page lists where each part comes from.

## This repository

- `app/` — SwiftUI launcher, WKWebView host, share extension, background keeper,
  rootfs installer.
- `scripts/dsh-supervisor.mjs` — guest-side supervisor.
- `scripts/pnpm-npm-shim.js` — pnpm → npm compatibility layer.
- `build/idsh-engine-fixes.py` — our engine modifications (remove the 60 s poll
  and 180 s futex idle-kill valves; waitpid EINTR fix).
- `patches/dsh-web-app-early-url.patch` — DSH web-app URL announcement patch.
- `app/Resources/RootfsPatch.bundle/` — guest overlay (streaming fetch polyfill,
  supervisor, minimal-mode patch).

## Engine

- iSH ARM64 fork: <https://github.com/OpenMinis/ish-arm64>
  Base commit used for the shipped framework: `de124dd66124a15239cea1465164f74980ada245`.
- OpenMinis iOS bridge and build harness:
  <https://github.com/OpenMinis/OpenMinis> at
  `9cf3a855fecd27bb5735b84cacbd56852a3ab8dd`.
- Reference XCFramework build pipeline:
  <https://github.com/liulingfei-1/deepseek-harness-ios>, pinned revisions in
  `Dependencies/upstreams.lock.json`; the scripts apply seven bridge patches
  (network policy, ABI offsets, persistent stdin, runtime robustness, …).
- Our additional changes are the two functions in `build/idsh-engine-fixes.py`
  plus the build-time invocation documented in `Docs/ISH-ENGINE-VALVES.md`.

To rebuild the framework, point `ISH_ENGINE_FIX_SCRIPT` at
`build/idsh-engine-fixes.py` and run the `libraries` action of that build
pipeline.

## Rootfs

Alpine Linux 3.21.0 aarch64, Node.js 22.23.4, npm 10.9.1, pnpm 10.34.9, and
`@deepseek-ai/dsh@0.2.2-rc.1` installed from npm. Reproduction steps, including
the guest-side patch and shims, are in `Docs/ROOTFS.md`.

## DSH

DeepSeek Harness is MIT-licensed: <https://github.com/deepseek-ai/deepseek-harness>.
It is installed inside the guest rootfs at build time; this repository does not
vendor its source.
