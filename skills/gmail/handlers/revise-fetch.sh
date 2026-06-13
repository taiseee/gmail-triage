#!/usr/bin/env bash
# 元下書き本文を取得し、revise.txt + 本文 を JSON で出力する（OpenClaw LLM ステップへのインプット）
set -eo pipefail

DRAFT_ID="${1:?Usage: revise-fetch.sh <draft_id> <alias>}"
ALIAS="${2:?Usage: revise-fetch.sh <draft_id> <alias>}"
USER_INSTRUCTION="${3:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../../.."
set -a; source .env; set +a

_ALIAS_UPPER=$(printf '%s' "$ALIAS" | tr '[:lower:]' '[:upper:]')
_GWS_DIR_VAR="GMAIL_${_ALIAS_UPPER}_GWS_DIR"
export GOOGLE_WORKSPACE_CLI_CONFIG_DIR="${!_GWS_DIR_VAR:?${_GWS_DIR_VAR} is not set in .env}"

CURRENT_BODY=$(gws gmail users drafts get \
  --params "{\"userId\": \"me\", \"id\": \"${DRAFT_ID}\", \"format\": \"full\"}" \
  | jq -r '.message.payload.parts[]? | select(.mimeType == "text/plain") | .body.data // empty' \
  | base64 -d 2>/dev/null \
  || gws gmail users drafts get \
       --params "{\"userId\": \"me\", \"id\": \"${DRAFT_ID}\", \"format\": \"full\"}" \
       | jq -r '.message.payload.body.data // empty' \
       | base64 -d)

jq -n \
  --arg instruction "$USER_INSTRUCTION" \
  --arg body "$CURRENT_BODY" \
  --arg draft_id "$DRAFT_ID" \
  --arg alias "$ALIAS" \
  '{user_instruction: $instruction, current_body: $body, draft_id: $draft_id, alias: $alias}'
