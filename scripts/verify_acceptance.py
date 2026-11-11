#!/usr/bin/env python3
"""idsh acceptance harness.

Produces `.goal-gate/evidence/acceptance.json` with one boolean per acceptance
criterion, so the goal gate can fail closed on facts rather than opinions.

Usage:
    python3 scripts/verify_acceptance.py            # fast: ipa + runtime + ui + plugins
    python3 scripts/verify_acceptance.py --full     # + 6 minute stability window
    python3 scripts/verify_acceptance.py --rebuild  # rebuild the simulator app first
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import time
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
IPA = ROOT / "dist" / "idsh-unsigned.ipa"
EVIDENCE = ROOT / ".goal-gate" / "evidence" / "acceptance.json"
DEFAULT_UDID = "33B4B579-9D51-4021-8B7C-69B46A91E03A"
BUNDLE_ID = "com.brooks.idsh"

UI_MARKERS = ["探索未至之境", "选择工作区", "标准模式"]


def run(cmd: list[str], timeout: int = 120, check: bool = False) -> subprocess.CompletedProcess:
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if check and p.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd)} -> {p.returncode}\n{p.stdout}\n{p.stderr}")
    return p


def udid() -> str:
    return os.environ.get("IDSH_UDID", DEFAULT_UDID)


def simctl(*args: str, timeout: int = 120) -> subprocess.CompletedProcess:
    return run(["xcrun", "simctl", *args], timeout=timeout)


def guest_data_dir() -> Path | None:
    """Rootfs of the *installed* app, not "the newest directory that looks right".

    Several data containers linger after reinstalls; only the one CoreSimulator
    reports for the bundle id is the live one.
    """
    got = simctl("get_app_container", udid(), BUNDLE_ID, "data")
    if got.returncode != 0:
        return None
    data = Path(got.stdout.strip())
    d = data / "Library/Application Support/HarnessMobile/iSH/alpine-rootfs/data"
    return d if (d / "var/log").is_dir() else None


def caches_dir(guest: Path) -> Path:
    # .../Application/<UUID>/Library/Caches
    return guest.parents[4] / "Caches"


# ---------------------------------------------------------------- IPA checks


def check_ipa() -> dict:
    out: dict = {"ipa_exists": IPA.is_file(), "ipa_bytes": 0}
    if not out["ipa_exists"]:
        return out
    out["ipa_bytes"] = IPA.stat().st_size
    out["ipa_sha256"] = run(["shasum", "-a", "256", str(IPA)]).stdout.split()[0]

    with zipfile.ZipFile(IPA) as z:
        names = z.namelist()
        out["has_payload_binary"] = "Payload/idsh.app/idsh" in names
        out["has_rootfs"] = "Payload/idsh.app/alpine-rootfs.zip" in names
        out["has_engine"] = any(n.startswith("Payload/idsh.app/Frameworks/") for n in names)
        if out["has_payload_binary"]:
            tmp = Path("/tmp/idsh-accept-binary")
            tmp.parent.mkdir(exist_ok=True)
            with z.open("Payload/idsh.app/idsh") as src, open(tmp, "wb") as dst:
                shutil.copyfileobj(src, dst)

    if out["has_payload_binary"] and Path("/tmp/idsh-accept-binary").is_file():
        f = run(["file", "/tmp/idsh-accept-binary"]).stdout
        out["binary_is_arm64_macho"] = ("Mach-O 64-bit" in f and "arm64" in f)
        lc = run(["otool", "-l", "/tmp/idsh-accept-binary"]).stdout
        # otool prints the symbolic name on newer SDKs and the numeric
        # PLATFORM_IOS (2) on older ones; accept either.
        out["binary_platform_ios"] = bool(
            re.search(r"platform\s+(IOS|2)\b", lc) and "LC_BUILD_VERSION" in lc
        )
        out["binary_min_os"] = _min_os(lc)

    with zipfile.ZipFile(IPA) as z:
        with z.open("Payload/idsh.app/Info.plist") as fh:
            info = plistlib.load(fh)
        out["bundle_id"] = info.get("CFBundleIdentifier")
        out["min_os"] = info.get("MinimumOSVersion")
        out["background_modes"] = info.get("UIBackgroundModes", [])
    return out


def _min_os(otool_out: str) -> str | None:
    m = re.search(r"minos\s+([0-9.]+)", otool_out)
    return m.group(1) if m else None


# ------------------------------------------------------------ runtime checks


def reboot_app() -> None:
    simctl("terminate", udid(), BUNDLE_ID)
    time.sleep(1)
    simctl("launch", udid(), BUNDLE_ID)


def wait_ready(guest: Path, launched_at: float, limit: int = 300) -> float | None:
    """Ready only counts when the state file was written after this launch."""
    state = guest / "tmp/dsh.state"
    start = time.time()
    while time.time() - start < limit:
        try:
            if state.read_text().strip() == "ready" and state.stat().st_mtime >= launched_at:
                return round(time.time() - start, 1)
        except OSError:
            pass
        time.sleep(2)
    return None


def eval_js(guest: Path, js: str, limit: int = 90) -> str | None:
    """Evaluate JS in the live page.

    The web view only exists after the launcher navigates, so the first probes
    land on nothing; keep re-posting with a changing suffix so the inbox
    watcher treats each attempt as new.
    """
    caches = caches_dir(guest)
    inbox = caches / "idsh-eval-in.js"
    outbox = caches / "idsh-eval-out.txt"
    start = time.time()
    attempt = 0
    while time.time() - start < limit:
        attempt += 1
        try:
            outbox.unlink()
        except OSError:
            pass
        inbox.write_text(f"{js}\n/* probe {attempt} */")
        deadline = time.time() + 6
        while time.time() < deadline:
            try:
                text = outbox.read_text()
                if text.strip():
                    return text
            except OSError:
                pass
            time.sleep(0.5)
    return None


def run_guest_cmd(guest: Path, cmd: str, limit: int = 240, tag: str | None = None) -> str | None:
    """Run one shell line in the guest.

    Each call gets a unique tag so a stale outbox from an earlier command can
    never satisfy this one (two commands share the same file).
    """
    caches = caches_dir(guest)
    inbox = caches / "idsh-cmd-in.txt"
    outbox = caches / "idsh-cmd-out.txt"
    tag = tag or f"T{int(time.time() * 1000) % 1000000}"
    try:
        outbox.unlink()
    except OSError:
        pass
    inbox.write_text(f"echo IDSH_BEGIN_{tag}\n{cmd}\necho IDSH_END_{tag}:$?\n")
    start = time.time()
    while time.time() - start < limit:
        try:
            text = outbox.read_text()
            if f"IDSH_END_{tag}:" in text:
                return text
        except OSError:
            pass
        time.sleep(2)
    try:
        return outbox.read_text()
    except OSError:
        return None


def restart_count(guest: Path) -> int:
    log = guest / "var/log/dsh.log"
    try:
        return log.read_text(errors="replace").count("child exit code=")
    except OSError:
        return -1


def check_runtime(guest: Path, full: bool) -> dict:
    out: dict = {}
    boot = simctl("bootstatus", udid(), "-b", timeout=300)
    out["simulator_booted"] = boot.returncode == 0

    restarts_before = restart_count(guest)
    launched_at = time.time()
    # The state file survives a terminate, so make it stale-proof by requiring
    # a fresh mtime rather than just the value "ready".
    try:
        (guest / "tmp/dsh.state").unlink()
    except OSError:
        pass
    reboot_app()
    out["ready_seconds"] = wait_ready(guest, launched_at)
    out["guest_ready"] = out["ready_seconds"] is not None

    text = eval_js(
        guest,
        "JSON.stringify({txt:(document.body.innerText||'').slice(0,4000),"
        "w:innerWidth,h:innerHeight,cols:document.querySelectorAll('[data-slot=\"root\"]').length})",
    )
    out["ui_probe_raw"] = (text or "")[:2000]
    body = text or ""
    out["ui_markers"] = {m: (m in body) for m in UI_MARKERS}
    out["ui_all_markers"] = all(out["ui_markers"].values())
    m = re.search(r'"w":(\d+),"h":(\d+)', body)
    out["ui_width"] = int(m.group(1)) if m else None

    if full:
        window = 360
        time.sleep(window)
        restarts_after = restart_count(guest)
        out["stability_window_seconds"] = window
        out["stability_restarts"] = restarts_after - restarts_before
        out["stability_ok"] = out["stability_restarts"] == 0
    return out


def check_plugins(guest: Path) -> dict:
    out: dict = {}
    install = run_guest_cmd(
        guest,
        "cd /root && dsh plugin --profile web add dsh-plugin-upgrader 2>&1 | tail -8",
        limit=420,
    )
    listing = run_guest_cmd(guest, "cd /root && dsh plugin --profile web list 2>&1 | tail -20", limit=180)
    out["plugin_install_tail"] = (install or "")[-1200:]
    out["plugin_list_tail"] = (listing or "")[-1200:]
    out["plugin_listed"] = "dsh-plugin-upgrader" in (listing or "")
    out["plugin_install_tail"] = (install or "")[-1500:]
    out["plugin_install_called"] = "IDSH_END_" in (install or "")
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--full", action="store_true", help="include the 6 minute stability window")
    ap.add_argument("--rebuild", action="store_true", help="rebuild the simulator app first")
    args = ap.parse_args()

    result: dict = {"generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "udid": udid()}
    result.update(check_ipa())

    guest = guest_data_dir()
    result["guest_found"] = guest is not None
    if guest is None:
        result["guest_ready"] = False
        result["ui_all_markers"] = False
        result["plugin_listed"] = False
        result["stability_ok"] = False
    else:
        if args.rebuild:
            build = run(
                ["xcodebuild", "-project", "app/idsh.xcodeproj", "-scheme", "idsh",
                 "-configuration", "Debug", "-destination", f"id=com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M4-16GB",
                 "-derivedDataPath", "/tmp/idsh-dd", "build"],
                timeout=900,
            )
            result["rebuilt"] = build.returncode == 0
        result.update(check_runtime(guest, args.full))
        result.update(check_plugins(guest))

    EVIDENCE.parent.mkdir(parents=True, exist_ok=True)
    EVIDENCE.write_text(json.dumps(result, indent=2, ensure_ascii=False))
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
