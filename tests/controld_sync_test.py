#!/usr/bin/env python3
# Test tcc-sync/tuxedo-tlp-controld-sync end to end with fakes: a gdbus that replays
# tlp-pd ActiveProfile changes, a busctl that reports the current profile, and a
# controld socket that records ACTIVATE commands.
#
# Usage: python3 -I tests/controld_sync_test.py
#
# SPDX-License-Identifier: MIT

import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

# SYNC_SCRIPT points the tests at another copy, e.g. an older version to check they catch a bug.
SCRIPT = os.environ.get("SYNC_SCRIPT") or os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "tcc-sync", "tuxedo-tlp-controld-sync")
SETTLE = 1.5

GDBUS = """#!/bin/sh
# Replay "<delay> <profile>" lines from $FAKE_EVENTS as tlp-pd property changes.
while read -r delay profile; do
    sleep "$delay"
    printf '%s\\n' "$profile" > "$FAKE_STATE"
    printf "%s ('net.hadess.PowerProfiles', {'ActiveProfile': <'%s'>}, @as [])\\n" \\
        "/net/hadess/PowerProfiles: org.freedesktop.DBus.Properties.PropertiesChanged" "$profile"
done < "$FAKE_EVENTS"
exec sleep 60
"""

BUSCTL = """#!/bin/sh
printf '{"type":"s","data":"%s"}\\n' "$(cat "$FAKE_STATE")"
"""


class FakeControld(threading.Thread):
    def __init__(self, path, active):
        super().__init__(daemon=True)
        self.active = active
        self.activations = []   # (seconds since start, profile)
        self.t0 = time.monotonic()
        self.srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.srv.bind(path)
        self.srv.listen()

    def run(self):
        while True:
            try:
                conn, _ = self.srv.accept()
            except OSError:
                return
            with conn:
                cmd = conn.makefile().readline().strip()
                if cmd.startswith("ACTIVATE "):
                    self.active = cmd[len("ACTIVATE "):]
                    self.activations.append((time.monotonic() - self.t0, self.active))
                    conn.sendall(b"OK\n")
                else:
                    conn.sendall((json.dumps({"active": self.active}) + "\n").encode())


class ControldSyncTest(unittest.TestCase):
    def run_sync(self, start, events, active, duration):
        """Start in TLP profile `start`, replay `events` [(delay, profile)], return activations."""
        with tempfile.TemporaryDirectory() as tmp:
            bindir = os.path.join(tmp, "bin")
            os.mkdir(bindir)
            for name, body in (("gdbus", GDBUS), ("busctl", BUSCTL)):
                path = os.path.join(bindir, name)
                with open(path, "w") as f:
                    f.write(body)
                os.chmod(path, 0o755)
            state = os.path.join(tmp, "state")
            with open(state, "w") as f:
                f.write(start + "\n")
            with open(os.path.join(tmp, "events"), "w") as f:
                f.writelines(f"{d} {p}\n" for d, p in events)
            ctl = FakeControld(os.path.join(tmp, "ctl.sock"), active)
            ctl.start()
            env = dict(os.environ,
                       PATH=bindir + os.pathsep + os.environ["PATH"],
                       FAKE_STATE=state,
                       FAKE_EVENTS=os.path.join(tmp, "events"),
                       CONTROLD_SOCK=os.path.join(tmp, "ctl.sock"),
                       SETTLE_DELAY=str(SETTLE),
                       POLL_INTERVAL="3600")
            proc = subprocess.Popen([sys.executable, "-I", SCRIPT], env=env,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                    start_new_session=True)
            try:
                time.sleep(duration)
            finally:
                # Kill the whole group: the fake gdbus child holds the output pipe open.
                os.killpg(proc.pid, signal.SIGTERM)
                out, _ = proc.communicate(timeout=10)
                ctl.srv.close()
            self.log = out
            return ctl.activations

    def test_start_applies_the_current_profile(self):
        acts = self.run_sync("performance", [], "Quiet", 1.0)
        self.assertEqual([p for _, p in acts], ["High Performance"], self.log)

    def test_start_is_quiet_when_already_in_sync(self):
        acts = self.run_sync("balanced", [], "Quiet", 1.0)
        self.assertEqual(acts, [], self.log)

    def test_single_change_applies_after_settling(self):
        acts = self.run_sync("balanced", [(0.5, "power-saver")], "Quiet", 0.5 + SETTLE + 1.5)
        self.assertEqual([p for _, p in acts], ["Max Energy Save"], self.log)
        self.assertGreaterEqual(acts[0][0], 0.5 + SETTLE - 0.2, self.log)

    def test_flapping_applies_once_after_it_stops(self):
        flips = [(0.4, p) for p in ("performance", "balanced", "performance", "balanced",
                                    "performance")]
        last_flip = sum(d for d, _ in flips)
        acts = self.run_sync("balanced", flips, "Quiet", last_flip + SETTLE + 1.5)
        self.assertEqual([p for _, p in acts], ["High Performance"], self.log)
        self.assertGreaterEqual(acts[0][0], last_flip + SETTLE - 0.2, self.log)

    def test_flapping_back_to_the_start_changes_nothing(self):
        flips = [(0.4, "performance"), (0.4, "balanced")]
        acts = self.run_sync("balanced", flips, "Quiet", 0.8 + SETTLE + 1.5)
        self.assertEqual(acts, [], self.log)


if __name__ == "__main__":
    unittest.main(verbosity=2)
