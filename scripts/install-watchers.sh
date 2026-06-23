#!/usr/bin/env bash
# GMAIL_ACCOUNTS の各エイリアスに対して poll plist を生成・登録する
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$SCRIPT_DIR/.."
cd "$REPO_DIR"
set -a; source .env; set +a

# --- コマンドパスをインストール時に解決 ---
# node: .env の NODE_CMD > which node > フォールバック
NODE_CMD="${NODE_CMD:-$(which node 2>/dev/null || echo "node")}"
# codex: .env の CODEX_CMD > which codex > フォールバック
CODEX_CMD="${CODEX_CMD:-$(which codex 2>/dev/null || echo "codex")}"

# 各コマンドの親ディレクトリを PATH に追加（重複は除く）
_add_dir() {
  local dir
  dir="$(dirname "$1" 2>/dev/null)"
  case ":${INSTALL_PATH}:" in
    *":$dir:"*) ;;
    *) INSTALL_PATH="${dir}${INSTALL_PATH:+:${INSTALL_PATH}}" ;;
  esac
}
INSTALL_PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
_add_dir "$CODEX_CMD"
_add_dir "$NODE_CMD"

# ----------------------------------------

TEMPLATE="$REPO_DIR/launchd/com.automation.gmail-triage.poll.plist.template"
IFS=',' read -ra ACCOUNTS <<< "$GMAIL_ACCOUNTS"

LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
mkdir -p "$LAUNCH_AGENTS_DIR"

for ALIAS in "${ACCOUNTS[@]}"; do
  PLIST="${LAUNCH_AGENTS_DIR}/com.automation.gmail-triage.poll.${ALIAS}.plist"
  sed \
    -e "s|__ALIAS__|${ALIAS}|g" \
    -e "s|__REPO_DIR__|${REPO_DIR}|g" \
    -e "s|__PATH__|${INSTALL_PATH}|g" \
    "$TEMPLATE" > "$PLIST"
  echo "Registering poller for $ALIAS ..."
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  echo "  OK: $PLIST"
done

BOT_TEMPLATE="$REPO_DIR/launchd/com.automation.gmail-triage.bot.plist.template"
BOT_PLIST="${LAUNCH_AGENTS_DIR}/com.automation.gmail-triage.bot.plist"
sed \
  -e "s|__REPO_DIR__|${REPO_DIR}|g" \
  -e "s|__NODE_CMD__|${NODE_CMD}|g" \
  -e "s|__PATH__|${INSTALL_PATH}|g" \
  "$BOT_TEMPLATE" > "$BOT_PLIST"
echo "Registering Discord bot notifier ..."
launchctl bootstrap "gui/$(id -u)" "$BOT_PLIST"
echo "  OK: $BOT_PLIST"

echo ""
echo "=== Pollers registered for: $GMAIL_ACCOUNTS ==="
echo "=== Discord bot notifier registered ==="
