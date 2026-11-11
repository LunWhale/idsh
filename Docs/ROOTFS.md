# Reproducing the guest rootfs

The release IPA embeds a prebuilt Alpine rootfs (`app/Resources/alpine-rootfs.zip`,
about 322 MB). It is **not** committed to git. This document describes how it was
produced so the build is reproducible.

## 1. Prerequisites

- macOS with Xcode command-line tools
- `meson`, `ninja`, LLVM (`ld.lld`, `clang`), `libarchive`
- Network access to Alpine mirrors and npm

```bash
brew install meson ninja llvm libarchive
```

## 2. Build the iSH command-line engine

We use the OpenMinis fork of iSH with an ARM64 guest backend. The App itself links
`app/Vendor/HarnessISH.xcframework`; the CLI is only needed to *populate* the rootfs.

```bash
git clone --recurse-submodules https://github.com/OpenMinis/ish-arm64.git
cd ish-arm64
meson setup build-arm64 -Dguest_arch=arm64 --buildtype=release
ninja -C build-arm64
./build-arm64/ish --help   # smoke test
```

The exact upstream revisions used for the shipped IPA are recorded in
`Docs/ISH-ENGINE-VALVES.md`.

## 3. Create an Alpine 3.21 fakefs

```bash
git clone --depth 1 https://github.com/OpenMinis/OpenMinis.git
cd OpenMinis
./deps/prepare_alpine_rootfs.sh 3.21
# -> deps/resources/alpine-rootfs/{data,meta.db}
# -> deps/resources/alpine-rootfs.zip
```

Important: fakefs has a `meta.db` index. Files copied into `data/` on the host
**after** `fakefsify` are invisible to the guest. Write files from inside the guest
(or rebuild the fakefs), otherwise `exec` will fail with `ENOENT`.

## 4. Boot and install the runtime

```bash
cd ish-arm64
./build-arm64/ish -f ../OpenMinis/deps/resources/alpine-rootfs /bin/sh
```

Inside the guest:

```sh
# DNS (the prepared image may not have it yet)
echo "nameserver 1.1.1.1" > /etc/resolv.conf

apk update
apk add --no-cache \
  nodejs=22.23.4-r0 npm bash git curl ca-certificates tzdata \
  tar xz patch

npm i -g pnpm@10 --no-audit --no-fund
npm i -g @deepseek-ai/dsh@0.2.2-rc.1 --ignore-scripts --no-audit --no-fund
```

`dsh` reports `EBADENGINE` on Node 22 (the package declares Node >= 24.9) but runs
correctly. Do not upgrade to Node 24: the V8 binary patches in this engine fork are
tuned for Node 22.

## 5. Apply the idsh customisations

Copy these files into the guest (use `base64 -d` or a bind mount; do not drop them
into the host `data/` directory):

| Source in this repo | Guest path |
|---|---|
| `patches/dsh-web-app-early-url.patch` | `/usr/local/share/idsh/dsh-web-app-early-url.patch` |
| `scripts/pnpm-npm-shim.js` | `/usr/local/bin/pnpm` (replace the symlink; real pnpm → `/usr/local/bin/pnpm.real`) |
| `scripts/dsh-supervisor.mjs` | applied by `RootfsPatch.bundle`, not baked into the zip |
| — | `/usr/local/bin/xdg-user-dir` (shim) |
| — | `/root/Documents/deepseek-harness/default-workspace` |

Apply the DSH patch inside the package root:

```sh
cd /usr/local/lib/node_modules/@deepseek-ai/dsh
patch -p1 < /usr/local/share/idsh/dsh-web-app-early-url.patch
```

`xdg-user-dir` shim (Alpine has no `xdg-user-dir`, and DSH uses it to create the
default workspace):

```sh
#!/bin/sh
case "$1" in
  DOCUMENTS) echo "$HOME/Documents" ;;
  *) echo "$HOME" ;;
esac
```

Then create `/usr/local/bin/dsh-update`:

```sh
#!/bin/sh
set -e
npm i -g @deepseek-ai/dsh@latest --ignore-scripts --no-audit --no-fund
cd /usr/local/lib/node_modules/@deepseek-ai/dsh
patch -p1 < /usr/local/share/idsh/dsh-web-app-early-url.patch || true
```

## 6. Trim and pack

Remove caches and the unused Node 24 copy if present:

```sh
rm -rf /root/.npm /tmp/* /opt/node24 /var/log/dsh.log
```

Exit the guest, then pack the fakefs **from the host**:

```bash
cd OpenMinis/deps/resources
zip -r -q -y -X alpine-rootfs.zip alpine-rootfs
```

Verify ZIP64 (more than 65,535 entries):

```bash
python3 - <<'PY'
import zipfile
z = zipfile.ZipFile('alpine-rootfs.zip')
print(len(z.infolist()))
PY
```

## 7. Wire it into the App

```bash
cp alpine-rootfs.zip app/Resources/alpine-rootfs.zip
```

Bump `installationVersion` in `app/Sources/ISHRootfsInstaller.swift` so existing
installs re-extract:

```swift
static let installationVersion = "idsh-alpine-3.21.0-aarch64-6"
```

Then rebuild the App. If you only changed files under `app/Resources/RootfsPatch.bundle`,
bump the `version` in its `manifest.plist` instead — the bridge applies that overlay
on every boot and skips it when the guest already has the same version.

## 8. Verify

```bash
./build-arm64/ish -f ../OpenMinis/deps/resources/alpine-rootfs /bin/sh -c '
  node -v; npm -v; pnpm -v; dsh --version; which patch; xdg-user-dir DOCUMENTS
'
```

Expected:

```text
v22.23.4
10.9.1
10.34.9 (or the shim, which prints npm's version)
0.2.2-rc.1
/usr/bin/patch
/root/Documents
```
