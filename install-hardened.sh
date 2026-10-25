#!/bin/bash
# ---------------------------------------------------------------------------
# OpenClaw hardening installer.
#
# You normally do NOT run this directly -- ./setup.sh calls it as its last step.
# Run it standalone only to repair or re-install the reliability layer on a Mac
# where the bot is already working. It does not install or configure OpenClaw
# itself.
#
# What it installs, all learned from ~3 weeks of real outages on Justin's Mac:
#   1. telegram-watchdog  -- auto-recovers the "gateway alive, poller silently
#                            wedged" failure. Without it, a transient network
#                            blip takes the bot offline until someone notices.
#   2. caffeinate agent   -- stops idle sleep. A sleeping Mac cannot poll.
#   3. bot-medic          -- one command to manually kick the gateway.
#
# Safe to re-run: every step is idempotent (agents are booted out first).
# ---------------------------------------------------------------------------
set -euo pipefail

GATEWAY_LABEL="ai.openclaw.gateway"
WATCHDOG_LABEL="ai.openclaw.telegram-watchdog"
CAFFEINATE_LABEL="ai.openclaw.caffeinate"

AGENTS_DIR="$HOME/Library/LaunchAgents"
LOGS_DIR="$HOME/Library/Logs/openclaw"
WATCHDOG_DIR="$HOME/.openclaw/watchdog"
BIN_DIR="$HOME/.openclaw/bin"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UID_NUM="$(id -u)"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$1"; }
die()  { printf '\033[1;31mxx\033[0m  %s\n' "$1" >&2; exit 1; }

# --- preflight -------------------------------------------------------------
[[ "$(uname -s)" == "Darwin" ]] || die "This installer is macOS-only."

command -v openclaw >/dev/null 2>&1 \
  || die "openclaw not found on PATH. Install it first:  npm install -g openclaw"

if [[ ! -f "$AGENTS_DIR/$GATEWAY_LABEL.plist" ]]; then
  die "$GATEWAY_LABEL.plist not found -- the bot itself isn't set up yet.
    Run ./setup.sh instead; it does the whole install and calls this script
    at the end. (If the bot IS already working, run 'openclaw gateway install'
    first, then re-run this.)"
fi

[[ -f "$SRC_DIR/telegram-watchdog.py" ]] \
  || die "telegram-watchdog.py missing from $SRC_DIR"

# python3 comes from the Command Line Tools; the plist pins /usr/bin/python3 so
# a later Homebrew python upgrade can't silently break the daemon.
[[ -x /usr/bin/python3 ]] \
  || die "/usr/bin/python3 missing. Run: xcode-select --install"

say "Preflight OK (openclaw $(openclaw --version 2>/dev/null | head -1))"

mkdir -p "$AGENTS_DIR" "$LOGS_DIR" "$WATCHDOG_DIR" "$BIN_DIR"

# --- 1. watchdog -----------------------------------------------------------
say "Installing Telegram watchdog"
install -m 0644 "$SRC_DIR/telegram-watchdog.py" "$WATCHDOG_DIR/telegram-watchdog.py"

cat > "$AGENTS_DIR/$WATCHDOG_LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$WATCHDOG_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>$WATCHDOG_DIR/telegram-watchdog.py</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>30</integer>
    <key>StandardOutPath</key>
    <string>$LOGS_DIR/telegram-watchdog.log</string>
    <key>StandardErrorPath</key>
    <string>$LOGS_DIR/telegram-watchdog.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
</dict>
</plist>
PLIST

# --- 2. caffeinate ---------------------------------------------------------
# -i prevents idle system sleep, -s prevents sleep on AC power. Together they
# keep the machine awake while the lid is OPEN. Lid-close (clamshell) sleep is
# a separate setting and needs sudo -- handled at the end.
say "Installing caffeinate agent (blocks idle sleep)"
cat > "$AGENTS_DIR/$CAFFEINATE_LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$CAFFEINATE_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/caffeinate</string>
        <string>-i</string>
        <string>-s</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOGS_DIR/caffeinate.log</string>
    <key>StandardErrorPath</key>
    <string>$LOGS_DIR/caffeinate.log</string>
</dict>
</plist>
PLIST

# --- 3. bot-medic ----------------------------------------------------------
say "Installing bot-medic helper"
cat > "$BIN_DIR/bot-medic" <<'MEDIC'
#!/bin/bash
# The one command to bring the bot back when it goes silent.
echo "bot-medic: kickstarting the OpenClaw gateway..."
launchctl kickstart -k "gui/$(id -u)/ai.openclaw.gateway"
sleep 4

# Two different failures look identical from Telegram (bot just doesn't reply).
# A kickstart fixes a wedged poller but does nothing for an expired Claude
# login, so check the log for auth trouble and name the actual fix.
LOG="$HOME/Library/Logs/openclaw/gateway.log"
if [ -f "$LOG" ] && tail -80 "$LOG" | grep -qiE 'unauthorized|401|auth.*(failed|expired)|not logged in'; then
  echo
  echo "bot-medic: the log shows an AUTH problem -- a restart won't fix that."
  echo "bot-medic: your Claude login has probably expired. Run:"
  echo
  echo "    openclaw models auth login --provider anthropic --method cli --set-default"
  echo
  exit 0
fi

echo "bot-medic: done. Give it ~30 seconds, then message the bot."
echo "bot-medic: still quiet? Watch the log:"
echo "    tail -f ~/Library/Logs/openclaw/gateway.log"
MEDIC
chmod +x "$BIN_DIR/bot-medic"

ZSHRC="$HOME/.zshrc"
if ! grep -q 'alias bot-medic=' "$ZSHRC" 2>/dev/null; then
  printf '\n# OpenClaw: bring the bot back when it goes silent\nalias bot-medic="%s/bot-medic"\n' \
    "$BIN_DIR" >> "$ZSHRC"
  say "Added 'bot-medic' alias to ~/.zshrc (open a new terminal to use it)"
else
  say "bot-medic alias already present in ~/.zshrc"
fi

# --- load the agents -------------------------------------------------------
for label in "$WATCHDOG_LABEL" "$CAFFEINATE_LABEL"; do
  say "Loading $label"
  launchctl bootout  "gui/$UID_NUM/$label"                    2>/dev/null || true
  launchctl bootstrap "gui/$UID_NUM" "$AGENTS_DIR/$label.plist"
  launchctl enable   "gui/$UID_NUM/$label"                    2>/dev/null || true
done

# --- verify ----------------------------------------------------------------
echo
say "Verifying"
sleep 2
for label in "$GATEWAY_LABEL" "$WATCHDOG_LABEL" "$CAFFEINATE_LABEL"; do
  if launchctl print "gui/$UID_NUM/$label" >/dev/null 2>&1; then
    printf '    \033[1;32mok\033[0m   %s\n' "$label"
  else
    printf '    \033[1;31mFAIL\033[0m %s\n' "$label"
  fi
done

if pmset -g | grep -q 'SleepDisabled.*1'; then
  printf '    \033[1;32mok\033[0m   clamshell sleep disabled\n'
else
  warn "Clamshell (lid-close) sleep is ENABLED -- this is the DEFAULT, and for"
  warn "a laptop it's usually the right setting. Just know what it means:"
  warn "closing the lid puts the bot offline until you open it again."
  warn "The caffeinate agent above does NOT cover this; it only blocks idle"
  warn "sleep. Disabling clamshell sleep is a separate, manual step -- see"
  warn "the 'lid problem' section of the README first. Short version:"
  warn "this machine lives on a desk and stays plugged in."
fi

echo
say "Done. Logs live in $LOGS_DIR/"
echo "    gateway.log           -- the bot itself"
echo "    telegram-watchdog.log -- recovery daemon (look for KICKSTART lines)"
