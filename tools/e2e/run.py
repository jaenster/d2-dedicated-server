#!/usr/bin/env python3
"""Clientless E2E test runner for the realmd realm server.

Runs each named scenario against a live realmd on localhost (ports 6112-6115),
prints a summary, and exits non-zero if any implemented scenario fails.

If no realmd is listening on the bnet port, and REALMD_BIN points at a realmd
binary, this runner will start its own realmd (fs store) for the duration of
the run and stop it afterwards. Otherwise it assumes one is already running.

Env:
  REALMD_BIN          path to a realmd binary to auto-start (optional)
  REALMD_DATA_DIR     data dir for the auto-started realmd (default temp)
  REALMD_HEALTH_PORT  health port for the auto-started realmd (default 18080)
"""
import os
import socket
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from realmclient import HOST, BNET_PORT  # noqa: E402
from scenarios import SCENARIOS  # noqa: E402


def _port_open(host, port, timeout=0.3):
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def _wait_port(host, port, deadline_s=10.0):
    end = time.time() + deadline_s
    while time.time() < end:
        if _port_open(host, port):
            return True
        time.sleep(0.1)
    return False


def maybe_start_realmd():
    """Return (proc, logfile) if we started one, else (None, None)."""
    if _port_open(HOST, BNET_PORT):
        print(f"using existing realmd on {HOST}:{BNET_PORT}")
        return None, None

    realmd_bin = os.environ.get("REALMD_BIN")
    if not realmd_bin:
        print(f"ERROR: nothing listening on {HOST}:{BNET_PORT} and REALMD_BIN unset.",
              file=sys.stderr)
        print("Start realmd manually or set REALMD_BIN to auto-start one.",
              file=sys.stderr)
        sys.exit(2)

    data_dir = os.environ.get("REALMD_DATA_DIR") or tempfile.mkdtemp(prefix="e2e-realmd-")
    health_port = os.environ.get("REALMD_HEALTH_PORT", "18080")
    env = dict(os.environ, REALMD_DATA_DIR=data_dir, REALMD_HEALTH_PORT=health_port)
    log = open(os.path.join(tempfile.gettempdir(), "e2e-realmd.log"), "wb")
    print(f"starting realmd: {realmd_bin} (data_dir={data_dir}, health={health_port})")
    proc = subprocess.Popen([realmd_bin], env=env, stdout=log, stderr=subprocess.STDOUT)
    if not _wait_port(HOST, BNET_PORT, 10.0):
        proc.terminate()
        print("ERROR: realmd did not start listening in time.", file=sys.stderr)
        sys.exit(2)
    return proc, log


def main():
    proc, log = maybe_start_realmd()
    results = []
    try:
        for fn in SCENARIOS:
            res = fn()
            print(res)
            results.append(res)
    finally:
        if proc is not None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
            if log:
                log.close()

    npass = sum(1 for r in results if r.status == "PASS")
    nfail = sum(1 for r in results if r.status == "FAIL")
    nskip = sum(1 for r in results if r.status == "SKIP")
    print(f"\nsummary: {npass} passed, {nfail} failed, {nskip} skipped "
          f"({len(results)} total)")
    sys.exit(1 if nfail else 0)


if __name__ == "__main__":
    main()
