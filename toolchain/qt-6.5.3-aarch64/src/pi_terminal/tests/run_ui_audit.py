#!/usr/bin/env python3
"""Run --ui-audit with an isolated temporary administrator.

The UI audit needs a logged-in admin for settings/browser/taskbar checks.
CTest used to launch the app with the developer's real home and no users,
so every audit stopped at the login screen.  This wrapper creates a throwaway
XDG profile, initializes one admin, then starts the audit with auto-login.
"""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("binary")
    parser.add_argument("output")
    args = parser.parse_args()
    binary = Path(args.binary).resolve()
    output = Path(args.output).resolve()
    with tempfile.TemporaryDirectory(prefix="orpi-ui-audit-") as raw:
        state = Path(raw)
        env = os.environ.copy()
        for key, sub in (("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"),
                         ("XDG_CACHE_HOME", "cache"), ("XDG_STATE_HOME", "state")):
            env[key] = str(state / sub)
            Path(env[key]).mkdir(parents=True, exist_ok=True)
        env["ORANGE_PI_AUTO_LOGIN"] = "246810"
        env["QTWEBENGINE_DISABLE_SANDBOX"] = "1"
        env.setdefault("QTWEBENGINE_CHROMIUM_FLAGS",
                       "--disable-gpu --disable-dev-shm-usage --no-sandbox --disable-software-rasterizer")
        init = subprocess.run(
            [str(binary), "--init-admin", "Audit Admin", "--init-pin-stdin"],
            input=b"246810\n", stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            env=env, timeout=30)
        if init.returncode != 0:
            sys.stderr.write(init.stdout.decode("utf-8", "replace"))
            return init.returncode
        result = subprocess.run([str(binary), "--ui-audit", str(output)],
                                env=env, timeout=240)
        return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
