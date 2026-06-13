#!/usr/bin/env bash
# judge JSON を受け取り、Gmail 下書きを作成して結果 JSON を出力する
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
set -a; source .env; set +a

input="$(cat)"

ACCOUNT=$(printf '%s' "$input" | jq -r '.account')
THREAD_ID=$(printf '%s' "$input" | jq -r '.threadId')
RFC_MSGID=$(printf '%s' "$input" | jq -r '.rfcMessageId // ""')
FROM=$(printf '%s' "$input" | jq -r '.from // ""')
SUBJECT=$(printf '%s' "$input" | jq -r '.subject // ""')
DRAFT_BODY=$(printf '%s' "$input" | jq -r '.draft')

_ALIAS_UPPER=$(printf '%s' "$ACCOUNT" | tr '[:lower:]' '[:upper:]')
_GWS_DIR_VAR="GMAIL_${_ALIAS_UPPER}_GWS_DIR"
export GOOGLE_WORKSPACE_CLI_CONFIG_DIR="${!_GWS_DIR_VAR:?${_GWS_DIR_VAR} is not set in .env}"

# 件名に "Re: " がなければ付与し、RFC 2047 (Base64) でエンコード（文字化け防止）
[[ "$SUBJECT" != Re:* ]] && SUBJECT="Re: ${SUBJECT}"
SUBJECT_ENC="=?UTF-8?B?$(printf '%s' "$SUBJECT" | base64 | tr -d '\n')?="

# RFC 2822 形式のメール本文を base64 エンコードして下書きを作成
RAW_MESSAGE=$(printf 'To: %s\nSubject: %s\nIn-Reply-To: %s\nReferences: %s\nContent-Type: text/plain; charset=UTF-8\n\n%s' \
  "$FROM" "$SUBJECT_ENC" "$RFC_MSGID" "$RFC_MSGID" "$DRAFT_BODY" \
  | base64 | tr '+/' '-_' | tr -d '=\n')

RESULT=$(gws gmail users drafts create \
  --params '{"userId": "me"}' \
  --json "{\"message\": {\"raw\": \"${RAW_MESSAGE}\", \"threadId\": \"${THREAD_ID}\"}}")

DRAFT_ID=$(printf '%s' "$RESULT" | jq -r '.id')
PREVIEW=$(printf '%s' "$DRAFT_BODY" | head -c 1500)

# ラベル名を取得（通知タグ用）
LABEL_KEY="GMAIL_$(printf '%s' "$ACCOUNT" | tr '[:lower:]' '[:upper:]')_LABEL"
LABEL="${!LABEL_KEY:-$ACCOUNT}"

printf '%s' "$input" | jq \
  --arg id "$DRAFT_ID" \
  --arg label "$LABEL" \
  --arg preview "$PREVIEW" \
  '. + {draftId: $id, label: $label, preview: $preview}'
