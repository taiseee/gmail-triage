#!/usr/bin/env bash
# 迷惑メール確定: blocklist.txt に追記し、現メッセージを SPAM に移動する
set -eo pipefail

MSG_ID="${1:?Usage: spam-confirm.sh <message_id> <alias>}"
ALIAS="${2:?Usage: spam-confirm.sh <message_id> <alias>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../../.."
set -a; source .env; set +a

input="$(cat)"
FROM=$(printf '%s' "$input" | jq -r '.from // ""')

_ALIAS_UPPER=$(printf '%s' "$ALIAS" | tr '[:lower:]' '[:upper:]')
_GWS_DIR_VAR="GMAIL_${_ALIAS_UPPER}_GWS_DIR"
export GOOGLE_WORKSPACE_CLI_CONFIG_DIR="${!_GWS_DIR_VAR:?${_GWS_DIR_VAR} is not set in .env}"

# FROM が空なら Gmail から取得（bot 再起動で spamCandidates が失われたケースのフォールバック）
if [[ -z "$FROM" ]]; then
  MSG_JSON=$(gws gmail users messages get \
    --params "{\"userId\":\"me\",\"id\":\"$MSG_ID\",\"format\":\"metadata\",\"metadataHeaders\":[\"From\"]}" \
    2>/dev/null || true)
  FROM=$(printf '%s' "$MSG_JSON" \
    | jq -r '.payload.headers[]? | select(.name == "From") | .value' 2>/dev/null \
    | head -1)
fi

# メールアドレスのみ抽出（小文字）
if printf '%s' "$FROM" | grep -q '<'; then
  FROM_ADDR=$(printf '%s' "$FROM" | sed 's/.*<\([^>]*\)>.*/\1/' | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
else
  FROM_ADDR=$(printf '%s' "$FROM" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
fi

# blocklist.txt に追記（重複なし）
if [[ -n "$FROM_ADDR" ]] && ! grep -Fxq "$FROM_ADDR" data/blocklist.txt 2>/dev/null; then
  echo "$FROM_ADDR" >> data/blocklist.txt
fi

# 現在のメッセージを SPAM に移動
gws gmail users messages modify \
  --params "{\"userId\":\"me\",\"id\":\"$MSG_ID\"}" \
  --json '{"addLabelIds":["SPAM"],"removeLabelIds":["INBOX"]}' > /dev/null

echo "迷惑メールに設定しました: $FROM_ADDR"
