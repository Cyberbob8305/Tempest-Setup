#!/usr/bin/env python3
"""
OpenClaw Telegram watchdog (Part 2 / Layer 2 of Preston's ops handoff).

Runs as a long-lived DAEMON loop (not a launchd timer, because macOS throttles
timers while a laptop sleeps on battery). Every CHECK_INTERVAL seconds it looks
for the failure mode where the gateway process stays alive but its Telegram
poller has silently wedged, and issues a single `launchctl kickstart` to cleanly
re-attach it. Also kickstarts if the gateway's port is not listening.

Detection is deliberately conservative: it only acts when a wedge has persisted
past GRACE seconds, it will not kickstart more than once per COOLDOWN seconds
(so it can never enter a restart loop), and it will not kickstart when Telegram
itself is unreachable from this host (a kickstart cannot fix a dead network --
we simply wait and fire the moment connectivity returns).

Wedge taxonomy (this is the crux -- the previous version got it wrong):
  * TROUBLE markers  -- the poller failed, stopped, or is churning its transport.
  * ATTEMPT markers  -- a start was *attempted*. These are NOT proof of health:
                        they fire on every restart, so treating them as "healthy"
                        masked real wedges (e.g. an "ingress started" logged 11ms
                        after a restart, immediately followed by a dropped lease).
  * HEALTHY markers  -- proof the poller actually moved traffic (Inbound message).
The poller is wedged when the newest TROUBLE marker is newer than the newest
ATTEMPT-or-HEALTHY marker and has persisted past the grace window. During a
genuinely healthy-but-quiet period the newest event is an ATTEMPT (the last
successful start), so this never false-fires.
"""

import os
import re
import socket
import subprocess
import sys
import time
from datetime import datetime, timezone

GATEWAY_LABEL = "ai.openclaw.gateway"
GATEWAY_PORT = 18789
LOG_PATH = os.path.expanduser("~/Library/Logs/openclaw/gateway.log")
STATE_PATH = os.path.expanduser("~/.openclaw/watchdog/.last-kick")

CHECK_INTERVAL = 60    # seconds between checks (was 300 -- detect the wedge fast)
GRACE = 90             # a wedge must persist this long before we act
COOLDOWN = 240         # never kickstart more often than this (loop guard)
TAIL_LINES = 400       # how much of the log to scan each cycle

TELEGRAM_HOST = "api.telegram.org"

# A start was *attempted* or traffic actually flowed. Both push the "last known
# progress" timestamp forward, so a newer TROUBLE marker means real regression.
OK_MARKERS = ("starting provider", "polling ingress started", "Inbound message")

# The poller failed, stopped, or is thrashing its transport. Any of these being
# the newest poller event (past grace) means it needs a clean re-attach.
TROUBLE_MARKERS = (
    "restarting (reason:",
    "released stopped Telegram polling lease",
    "ingress failed",              # e.g. "isolated polling ingress failed: ENETUNREACH"
    "closing stale transport",
    "rebuilding transport",
)

# Matches the leading ISO-8601 timestamp, e.g. 2026-07-09T22:04:14.884-06:00
TS_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}[+-]\d{2}:\d{2})")


def log(msg):
    stamp = datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")
    print("%s [watchdog] %s" % (stamp, msg), flush=True)


def parse_ts(line):
    m = TS_RE.match(line)
    if not m:
        return None
    try:
        return datetime.fromisoformat(m.group(1))
    except ValueError:
        return None


def read_tail(path, n):
    try:
        with open(path, "r", errors="replace") as fh:
            return fh.readlines()[-n:]
    except OSError:
        return []


def port_listening(port):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=3):
            return True
    except OSError:
        return False


def telegram_reachable():
    """True if this host can open a TLS socket to Telegram's API edge.

    Used as a gate: if the network is down there is nothing a kickstart can fix,
    so we defer rather than burn the cooldown on a futile restart. The wedge will
    still be sitting in the log next cycle, so we fire promptly once this returns.
    """
    try:
        with socket.create_connection((TELEGRAM_HOST, 443), timeout=6):
            return True
    except OSError:
        return False


def poller_wedged(lines, now):
    """True if the newest poller event is an un-recovered trouble state."""
    last_ok = None
    last_trouble = None
    for line in lines:
        ts = parse_ts(line)
        if ts is None:
            continue
        if any(mark in line for mark in TROUBLE_MARKERS):
            last_trouble = ts
        elif any(mark in line for mark in OK_MARKERS):
            last_ok = ts
    if last_trouble is None:
        return False
    # A successful start/inbound at or after the last trouble -> recovered fine.
    if last_ok is not None and last_ok >= last_trouble:
        return False
    # Only act once the wedge has persisted past the grace window.
    return (now - last_trouble).total_seconds() > GRACE


def last_kick_ts():
    try:
        with open(STATE_PATH) as fh:
            return float(fh.read().strip())
    except (OSError, ValueError):
        return 0.0


def record_kick():
    try:
        with open(STATE_PATH, "w") as fh:
            fh.write(str(time.time()))
    except OSError:
        pass


def kickstart(reason, require_network=True):
    if time.time() - last_kick_ts() < COOLDOWN:
        log("wedge detected (%s) but within cooldown; skipping" % reason)
        return
    if require_network and not telegram_reachable():
        log("wedge detected (%s) but %s unreachable; deferring until network returns"
            % (reason, TELEGRAM_HOST))
        return
    uid = os.getuid()
    target = "gui/%d/%s" % (uid, GATEWAY_LABEL)
    log("KICKSTART -> %s (reason: %s)" % (target, reason))
    try:
        subprocess.run(["launchctl", "kickstart", "-k", target],
                       check=False, timeout=30)
        record_kick()
    except Exception as exc:  # noqa: BLE001 - never let the daemon die
        log("kickstart failed: %r" % exc)


def check_once():
    if not port_listening(GATEWAY_PORT):
        # Port down means the whole gateway crashed; restart regardless of network.
        kickstart("port %d not listening" % GATEWAY_PORT, require_network=False)
        return
    lines = read_tail(LOG_PATH, TAIL_LINES)
    if not lines:
        log("warning: gateway log empty/unreadable at %s" % LOG_PATH)
        return
    now = datetime.now(timezone.utc).astimezone()
    if poller_wedged(lines, now):
        kickstart("telegram poller wedged (no recovery after trouble)")


def main():
    log("started (interval=%ss grace=%ss cooldown=%ss log=%s)"
        % (CHECK_INTERVAL, GRACE, COOLDOWN, LOG_PATH))
    while True:
        try:
            check_once()
        except Exception as exc:  # noqa: BLE001 - keep the loop alive no matter what
            log("check error: %r" % exc)
        time.sleep(CHECK_INTERVAL)


if __name__ == "__main__":
    sys.exit(main())
