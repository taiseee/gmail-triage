#!/usr/bin/env bash
# triage 結果（下書き作成 or 確認必要）を Discord に通知する
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
set -a; source .env; set +a

input="$(cat)"

KIND=$(printf '%s' "$input" | jq -r '.kind // "draft"')
ACCOUNT=$(printf '%s' "$input" | jq -r '.account')
SUBJECT=$(printf '%s' "$input" | jq -r '.subject')
THREAD_ID=$(printf '%s' "$input" | jq -r '.threadId // ""')

# 表示ラベル: .label フィールド → GMAIL_<ACCOUNT>_LABEL 環境変数 → ACCOUNT にフォールバック
LABEL=$(printf '%s' "$input" | jq -r '.label // empty')
if [[ -z "$LABEL" ]]; then
  _LABEL_VAR="GMAIL_$(printf '%s' "$ACCOUNT" | tr '[:lower:]' '[:upper:]')_LABEL"
  LABEL="${!_LABEL_VAR:-$ACCOUNT}"
fi

case "$KIND" in
  check)
    REASON=$(printf '%s' "$input" | jq -r '.reason // ""')
    TEXT="[${LABEL}] 要確認: ${SUBJECT}"
    GMAIL_URL="https://mail.google.com/mail/u/0/#all/${THREAD_ID}"
    PAYLOAD=$(jq -n \
      --arg text "$TEXT" \
      --arg kind "$KIND" \
      --arg account "$ACCOUNT" \
      --arg subject "$SUBJECT" \
      --arg reason "$REASON" \
      --arg gmailUrl "$GMAIL_URL" \
      '{text: $text, kind: $kind, draftId: "", account: $account, subject: $subject, reason: $reason, gmailUrl: $gmailUrl}')
    ;;
  spam)
    MSG_ID=$(printf '%s' "$input" | jq -r '.messageId // ""')
    FROM=$(printf '%s' "$input" | jq -r '.from // ""')
    REASON=$(printf '%s' "$input" | jq -r '.reason // ""')
    TEXT="[${LABEL}] 迷惑メール候補: ${SUBJECT}"
    GMAIL_URL="https://mail.google.com/mail/u/0/#all/${THREAD_ID}"
    PAYLOAD=$(jq -n \
      --arg text "$TEXT" \
      --arg kind "$KIND" \
      --arg account "$ACCOUNT" \
      --arg subject "$SUBJECT" \
      --arg from "$FROM" \
      --arg messageId "$MSG_ID" \
      --arg reason "$REASON" \
      --arg gmailUrl "$GMAIL_URL" \
      '{text:$text, kind:$kind, account:$account, subject:$subject, from:$from, messageId:$messageId, reason:$reason, gmailUrl:$gmailUrl}')
    ;;
  *)
    DRAFT_ID=$(printf '%s' "$input" | jq -r '.draftId')
    FROM=$(printf '%s' "$input" | jq -r '.from // ""')
    ORIGINAL_BODY=$(printf '%s' "$input" | jq -r '.body // ""')
    DRAFT_BODY=$(printf '%s' "$input" | jq -r '.draft // .preview // ""')
    TEXT="[${LABEL}] 下書き作成: ${SUBJECT}"
    GMAIL_URL="https://mail.google.com/mail/u/0/#drafts/${THREAD_ID}"
    PAYLOAD=$(jq -n \
      --arg text "$TEXT" \
      --arg kind "$KIND" \
      --arg draftId "$DRAFT_ID" \
      --arg account "$ACCOUNT" \
      --arg subject "$SUBJECT" \
      --arg from "$FROM" \
      --arg originalBody "$ORIGINAL_BODY" \
      --arg draftBody "$DRAFT_BODY" \
      --arg gmailUrl "$GMAIL_URL" \
      '{text:$text, kind:$kind, draftId:$draftId, account:$account,
        subject:$subject, from:$from, originalBody:$originalBody, draftBody:$draftBody, gmailUrl:$gmailUrl}')
    ;;
esac

curl -s -X POST "http://127.0.0.1:${NOTIFY_PORT:-8787}/notify" \
  -H 'Content-Type: application/json' \
  -d "$PAYLOAD"
