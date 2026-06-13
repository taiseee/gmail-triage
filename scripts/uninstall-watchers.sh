#!/usr/bin/env bash
# 各アカウントの poll plist を launchd から解除する
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
set -a; source .env; set +a

IFS=',' read -ra ACCOUNTS <<< "$GMAIL_ACCOUNTS"

LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"

for ALIAS in "${ACCOUNTS[@]}"; do
  PLIST="${LAUNCH_AGENTS_DIR}/com.automation.gmail-triage.poll.${ALIAS}.plist"
  if launchctl list "com.automation.gmail-triage.poll.${ALIAS}" &>/dev/null; then
    launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || \
      launchctl bootout "gui/$(id -u)/com.automation.gmail-triage.poll.${ALIAS}"
    echo "Unregistered: $ALIAS"
  else
    echo "Not running: $ALIAS (skipped)"
  fi
done

BOT_PLIST="${LAUNCH_AGENTS_DIR}/com.automation.gmail-triage.bot.plist"
if launchctl list "com.automation.gmail-triage.bot" &>/dev/null; then
  launchctl bootout "gui/$(id -u)" "$BOT_PLIST" 2>/dev/null || \
    launchctl bootout "gui/$(id -u)/com.automation.gmail-triage.bot"
  echo "Unregistered: Discord bot notifier"
else
  echo "Not running: Discord bot notifier (skipped)"
fi
