#!/usr/bin/env bash
# 未処理メールをポーリングし、triage 後に処理済みラベルを付与する
set -eo pipefail

ALIAS="${1:?Usage: poll.sh <alias>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
set -a; source .env; set +a

_ALIAS_UPPER=$(printf '%s' "$ALIAS" | tr '[:lower:]' '[:upper:]')
_GWS_DIR_VAR="GMAIL_${_ALIAS_UPPER}_GWS_DIR"
export GOOGLE_WORKSPACE_CLI_CONFIG_DIR="${!_GWS_DIR_VAR:?${_GWS_DIR_VAR} is not set in .env}"

TRIAGE_LABEL="${GMAIL_TRIAGE_LABEL:-LLM-Triaged}"
REPLY_LABEL="${GMAIL_REPLY_LABEL:-要返信}"
CHECK_LABEL="${GMAIL_CHECK_LABEL:-要確認}"

# ラベルID解決ヘルパー（1回のリスト取得をキャッシュ、なければ作成・衝突時は再取得）
_ALL_LABELS=""
resolve_label_id() {
  local name="$1" id create_out
  id=$(printf '%s' "$_ALL_LABELS" | jq -r --arg n "$name" '.labels[]? | select(.name == $n) | .id' 2>/dev/null || true)
  if [[ -z "$id" ]]; then
    create_out=$(gws gmail users labels create \
      --params '{"userId":"me"}' \
      --json "{\"name\":\"$name\"}" 2>/dev/null || true)
    id=$(printf '%s' "$create_out" | jq -r '.id // empty' 2>/dev/null || true)
    if [[ -z "$id" ]]; then
      _ALL_LABELS=$(gws gmail users labels list --params '{"userId":"me"}' 2>/dev/null || true)
      id=$(printf '%s' "$_ALL_LABELS" | jq -r --arg n "$name" '.labels[]? | select(.name == $n) | .id' 2>/dev/null || true)
    fi
  fi
  printf '%s' "$id"
}

_ALL_LABELS=$(gws gmail users labels list --params '{"userId":"me"}' 2>/dev/null || true)
TRIAGED_ID=$(resolve_label_id "$TRIAGE_LABEL")
REPLY_ID=$(resolve_label_id "$REPLY_LABEL")
CHECK_ID=$(resolve_label_id "$CHECK_LABEL")

if [[ -z "$TRIAGED_ID" ]]; then
  echo "[poll] ERROR: could not get or create label '$TRIAGE_LABEL'"
  exit 1
fi

# 未処理メールを取得（受信トレイかつ処理済みラベルなし）
MSG_IDS=$(gws gmail users messages list \
  --params "{\"userId\":\"me\",\"q\":\"in:inbox -label:${TRIAGE_LABEL}\",\"maxResults\":20}" \
  2>/dev/null \
  | jq -r '.messages[]?.id // empty' 2>/dev/null)

if [[ -z "$MSG_IDS" ]]; then
  echo "[poll] No unprocessed messages for $ALIAS"
  exit 0
fi

while IFS= read -r MSG_ID; do
  [[ -z "$MSG_ID" ]] && continue

  # フルメッセージ取得
  MSG_JSON=$(gws gmail users messages get \
    --params "{\"userId\":\"me\",\"id\":\"$MSG_ID\",\"format\":\"full\"}" \
    2>/dev/null) || { echo "[poll] ERROR: failed to get message $MSG_ID"; continue; }

  # ヘッダーから subject / from を抽出してトップレベルに追加
  SUBJECT=$(printf '%s' "$MSG_JSON" \
    | jq -r '.payload.headers[]? | select(.name == "Subject") | .value' | head -1)
  FROM=$(printf '%s' "$MSG_JSON" \
    | jq -r '.payload.headers[]? | select(.name == "From") | .value' | head -1)
  RFC_MSGID=$(printf '%s' "$MSG_JSON" \
    | jq -r '.payload.headers[]? | select(.name | ascii_downcase == "message-id") | .value' | head -1)

  # テキスト本文を抽出（マルチパート対応）
  BODY=$(printf '%s' "$MSG_JSON" \
    | jq -r '(.payload.parts[]? | select(.mimeType == "text/plain") | .body.data) // (.payload.body.data) // ""' \
    | base64 -d 2>/dev/null || true)

  TRIAGE_JSON=$(printf '%s' "$MSG_JSON" | jq \
    --arg acc "$ALIAS" \
    --arg subj "$SUBJECT" \
    --arg from "$FROM" \
    --arg rfcmid "$RFC_MSGID" \
    --arg body "$BODY" \
    '. + {account: $acc, subject: $subj, from: $from, rfcMessageId: $rfcmid, body: $body}')

  # LLM-Triaged を先付与（重複処理防止。失敗しても再処理しない）
  gws gmail users messages modify \
    --params "{\"userId\":\"me\",\"id\":\"$MSG_ID\"}" \
    --json "{\"addLabelIds\":[\"$TRIAGED_ID\"]}" > /dev/null \
    || { echo "[poll] WARNING: failed to pre-label $MSG_ID, skipping"; continue; }

  # triage 実行（exit code でカテゴリ判定）
  rc=0
  printf '%s' "$TRIAGE_JSON" | bash "$SCRIPT_DIR/triage.sh" "$ALIAS" || rc=$?
  case "$rc" in
    0)  echo "[poll] Labeled $MSG_ID (none)" ;;
    10) gws gmail users messages modify \
          --params "{\"userId\":\"me\",\"id\":\"$MSG_ID\"}" \
          --json "{\"addLabelIds\":[\"$REPLY_ID\"]}" > /dev/null \
          && echo "[poll] Labeled $MSG_ID (reply)" ;;
    11) gws gmail users messages modify \
          --params "{\"userId\":\"me\",\"id\":\"$MSG_ID\"}" \
          --json "{\"addLabelIds\":[\"$CHECK_ID\"]}" > /dev/null \
          && echo "[poll] Labeled $MSG_ID (check)" ;;
    12) echo "[poll] Labeled $MSG_ID (spam - awaiting confirmation)" ;;
    *)
      echo "[poll] WARNING: triage failed ($rc) for $MSG_ID (already pre-labeled, no retry)"
      ;;
  esac

done <<< "$MSG_IDS"
