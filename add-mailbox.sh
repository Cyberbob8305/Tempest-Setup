#!/bin/zsh
# Connect one mailbox to Claude Code (read + draft only).
# Usage: ./add-mailbox.sh <name> <imap-host> <login> [from-address] [display-name]
#   ./add-mailbox.sh icloud-mail imap.mail.me.com you@icloud.com
#   ./add-mailbox.sh work-mail imap.gmail.com you@yourcompany.com
set -e
NAME=$1 HOST=$2 LOGIN=$3 FROM=${4:-$3} DISPLAY=${5:-""}
[[ -z $NAME || -z $HOST || -z $LOGIN ]] && { sed -n '2,6p' $0; exit 1; }

if ! command -v uv >/dev/null && [[ ! -x ~/.local/bin/uv ]]; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
fi
UV=$(command -v uv || echo ~/.local/bin/uv)

mkdir -p ~/.claude/mail-mcp
cp "${0:A:h}/mail_mcp.py" ~/.claude/mail-mcp/mail_mcp.py

echo "Paste the app-specific password for $LOGIN (it won't show as you type):"
security add-generic-password -U -s "claude-mail-$LOGIN" -a "$LOGIN" -w

claude mcp remove --scope user "$NAME" >/dev/null 2>&1 || true
claude mcp add --scope user "$NAME" \
  -e MAIL_IMAP_HOST="$HOST" -e MAIL_USER="$LOGIN" -e MAIL_FROM_ADDR="$FROM" -e MAIL_FROM_NAME="$DISPLAY" \
  -- "$UV" run --script ~/.claude/mail-mcp/mail_mcp.py

echo "Testing login..."
"$UV" run --with mcp python -c "
import os, imaplib, subprocess
pw = subprocess.run(['security','find-generic-password','-s','claude-mail-$LOGIN','-a','$LOGIN','-w'],capture_output=True,text=True).stdout.strip()
c = imaplib.IMAP4_SSL('$HOST', 993); c.login('$LOGIN', pw); print('Login OK:', '$LOGIN'); c.logout()"
echo "Done. Restart Claude Code, then run /mcp to see $NAME."
