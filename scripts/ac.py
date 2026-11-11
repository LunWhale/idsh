#!/usr/bin/env python3
"""Read one acceptance field, refreshing the evidence when it is stale.

    python3 scripts/ac.py <field>            # truthy check
    python3 scripts/ac.py <field> <expected> # equality / numeric compare

The harness is expensive (it drives a simulator), so evidence is reused for
15 minutes; `stability_ok` forces the long run the first time it is asked for.
"""

from __future__ import annotations

import json
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EVIDENCE = ROOT / ".goal-gate" / "evidence" / "acceptance.json"
MAX_AGE = 15 * 60
LONG_FIELDS = {"stability_ok", "stability_restarts", "stability_window_seconds"}


def refresh(field: str) -> None:
    cmd = [sys.executable, str(ROOT / "scripts" / "verify_acceptance.py")]
    if field in LONG_FIELDS:
        cmd.append("--full")
    subprocess.run(cmd, cwd=ROOT, check=False, timeout=1500,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: ac.py <field> [expected]", file=sys.stderr)
        return 2
    field = sys.argv[1]
    expected = sys.argv[2] if len(sys.argv) > 2 else None

    fresh = EVIDENCE.is_file() and (time.time() - EVIDENCE.stat().st_mtime) < MAX_AGE
    if not fresh:
        refresh(field)

    try:
        data = json.loads(EVIDENCE.read_text())
    except (OSError, ValueError) as exc:
        print(f"evidence unreadable: {exc}", file=sys.stderr)
        return 1

    if field not in data:
        print(f"missing field: {field}", file=sys.stderr)
        return 1
    value = data[field]

    if expected is None:
        print(f"{field}={value!r}")
        return 0 if bool(value) else 1

    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if expected.startswith(">="):
            ok = float(value) >= float(expected[2:])
        elif expected.startswith("<="):
            ok = float(value) <= float(expected[2:])
        elif expected.startswith(">"):
            ok = float(value) > float(expected[1:])
        elif expected.startswith("<"):
            ok = float(value) < float(expected[1:])
        elif _is_num(expected):
            ok = float(value) == float(expected)
        else:
            ok = False
        print(f"{field}={value!r} expected {expected} -> {'ok' if ok else 'FAIL'}")
        return 0 if ok else 1

    ok = str(value) == expected
    print(f"{field}={value!r} expected {expected!r} -> {'ok' if ok else 'FAIL'}")
    return 0 if ok else 1


def _is_num(text: str) -> bool:
    try:
        float(text)
        return True
    except ValueError:
        return False


if __name__ == "__main__":
    sys.exit(main())
