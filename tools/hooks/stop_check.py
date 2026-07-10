#!/usr/bin/env python3
"""Stop hook: surface ledger-gate violations before the turn ends.

Runs `ledger check`; if it fails, blocks the stop once (exit 2, so Claude keeps
going to fix the drift) and shows the violations. The stop_hook_active guard
prevents an infinite loop — on the retry it allows the stop.

FAIL-OPEN: any error allows the stop (exit 0).
"""
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0
    if data.get("stop_hook_active"):
        return 0  # already re-entered once — don't loop
    try:
        r = subprocess.run(
            [sys.executable, str(ROOT / "tools" / "ledger.py"), "check"],
            capture_output=True, text=True, cwd=str(ROOT),
        )
    except Exception:
        return 0  # fail-open
    if r.returncode != 0:
        sys.stderr.write("Ledger gate is dirty — fix before finishing:\n")
        sys.stderr.write(r.stdout + r.stderr)
        return 2  # block stop once so Claude fixes it
    return 0


if __name__ == "__main__":
    sys.exit(main())
