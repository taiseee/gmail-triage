#!/usr/bin/env bash
# GMAIL_ACCOUNTS の各エイリアスに対して poll plist を生成・登録する
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$SCRIPT_DIR/.."
cd "$REPO_DIR"
set -a; source .env; set +a

TEMPLATE="$REPO_DIR/launchd/com.automation.gmail-triage.poll.plist.template"
IFS=',' read -ra ACCOUNTS <<< "$GMAIL_ACCOUNTS"

LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
mkdir -p "$LAUNCH_AGENTS_DIR"

for ALIAS in "${ACCOUNTS[@]}"; do
  PLIST="${LAUNCH_AGENTS_DIR}/com.automation.gmail-triage.poll.${ALIAS}.plist"
  sed \
    -e "s|__ALIAS__|${ALIAS}|g" \
    -e "s|__REPO_DIR__|${REPO_DIR}|g" \
    "$TEMPLATE" > "$PLIST"
  echo "Registering poller for $ALIAS ..."
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  echo "  OK: $PLIST"
done

BOT_TEMPLATE="$REPO_DIR/launchd/com.automation.gmail-triage.bot.plist.template"
BOT_PLIST="${LAUNCH_AGENTS_DIR}/com.automation.gmail-triage.bot.plist"
sed -e "s|__REPO_DIR__|${REPO_DIR}|g" "$BOT_TEMPLATE" > "$BOT_PLIST"
echo "Registering Discord bot notifier ..."
launchctl bootstrap "gui/$(id -u)" "$BOT_PLIST"
echo "  OK: $BOT_PLIST"

echo ""
echo "=== Pollers registered for: $GMAIL_ACCOUNTS ==="
echo "=== Discord bot notifier registered ==="
