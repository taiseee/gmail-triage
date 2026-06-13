#!/usr/bin/env bash
# 指定 Gmail 下書きを削除する
set -eo pipefail

DRAFT_ID="${1:?Usage: discard.sh <draft_id> <alias>}"
ALIAS="${2:?Usage: discard.sh <draft_id> <alias>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../../.."
set -a; source .env; set +a

_ALIAS_UPPER=$(printf '%s' "$ALIAS" | tr '[:lower:]' '[:upper:]')
_GWS_DIR_VAR="GMAIL_${_ALIAS_UPPER}_GWS_DIR"
export GOOGLE_WORKSPACE_CLI_CONFIG_DIR="${!_GWS_DIR_VAR:?${_GWS_DIR_VAR} is not set in .env}"

gws gmail users drafts delete \
  --params "{\"userId\": \"me\", \"id\": \"${DRAFT_ID}\"}"

echo "下書きを削除しました（draft:${DRAFT_ID}@${ALIAS}）"
