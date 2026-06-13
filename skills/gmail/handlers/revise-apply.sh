#!/usr/bin/env bash
# OpenClaw が生成した改稿テキスト（stdin）で Gmail 下書きを更新する
set -eo pipefail

DRAFT_ID="${1:?Usage: revise-apply.sh <draft_id> <alias>}"
ALIAS="${2:?Usage: revise-apply.sh <draft_id> <alias>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../../.."
set -a; source .env; set +a

_ALIAS_UPPER=$(printf '%s' "$ALIAS" | tr '[:lower:]' '[:upper:]')
_GWS_DIR_VAR="GMAIL_${_ALIAS_UPPER}_GWS_DIR"
export GOOGLE_WORKSPACE_CLI_CONFIG_DIR="${!_GWS_DIR_VAR:?${_GWS_DIR_VAR} is not set in .env}"

NEW_BODY="$(cat)"

# 既存のメタ情報（subject / threadId / messageId）を取得して引き継ぐ
EXISTING=$(gws gmail users drafts get \
  --params "{\"userId\": \"me\", \"id\": \"${DRAFT_ID}\", \"format\": \"full\"}")

SUBJECT=$(printf '%s' "$EXISTING" \
  | jq -r '.message.payload.headers[]? | select(.name == "Subject") | .value' \
  | head -1)
THREAD_ID=$(printf '%s' "$EXISTING" | jq -r '.message.threadId')
IN_REPLY_TO=$(printf '%s' "$EXISTING" \
  | jq -r '.message.payload.headers[]? | select(.name == "In-Reply-To") | .value' \
  | head -1)

RAW_MESSAGE=$(printf 'Subject: %s\nIn-Reply-To: %s\nReferences: %s\nContent-Type: text/plain; charset=UTF-8\n\n%s' \
  "$SUBJECT" "$IN_REPLY_TO" "$IN_REPLY_TO" "$NEW_BODY" \
  | base64 | tr '+/' '-_' | tr -d '=\n')

gws gmail users drafts update \
  --params "{\"userId\": \"me\", \"id\": \"${DRAFT_ID}\"}" \
  --json "{\"message\": {\"raw\": \"${RAW_MESSAGE}\", \"threadId\": \"${THREAD_ID}\"}}" \
  > /dev/null

echo "下書きを更新しました（draft:${DRAFT_ID}@${ALIAS}）"
