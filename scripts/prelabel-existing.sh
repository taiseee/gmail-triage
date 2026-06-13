#!/usr/bin/env bash
# 受信トレイの既存メール全件に LLM-Triage ラベルを付与する（LLM 不使用、一回限りのセットアップ用）
set -eo pipefail

ALIAS="${1:?Usage: prelabel-existing.sh <alias>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
set -a; source .env; set +a

_ALIAS_UPPER=$(printf '%s' "$ALIAS" | tr '[:lower:]' '[:upper:]')
_GWS_DIR_VAR="GMAIL_${_ALIAS_UPPER}_GWS_DIR"
export GOOGLE_WORKSPACE_CLI_CONFIG_DIR="${!_GWS_DIR_VAR:?${_GWS_DIR_VAR} is not set in .env}"

TRIAGE_LABEL="${GMAIL_TRIAGE_LABEL:-LLM-Triaged}"

# ラベルID取得（なければ作成、衝突時は再取得）
LABEL_ID=$(gws gmail users labels list --params '{"userId":"me"}' \
  | jq -r --arg n "$TRIAGE_LABEL" '.labels[]? | select(.name == $n) | .id' 2>/dev/null || true)

if [[ -z "$LABEL_ID" ]]; then
  echo "[prelabel] Creating Gmail label: $TRIAGE_LABEL"
  _CREATE_OUT=$(gws gmail users labels create \
    --params '{"userId":"me"}' \
    --json "{\"name\":\"$TRIAGE_LABEL\"}" 2>/dev/null || true)
  LABEL_ID=$(printf '%s' "$_CREATE_OUT" | jq -r '.id // empty' 2>/dev/null || true)
  if [[ -n "$LABEL_ID" ]]; then
    echo "[prelabel] Created label ID: $LABEL_ID"
  else
    echo "[prelabel] Label may already exist, re-fetching..."
    LABEL_ID=$(gws gmail users labels list --params '{"userId":"me"}' \
      | jq -r --arg n "$TRIAGE_LABEL" '.labels[]? | select(.name == $n) | .id' 2>/dev/null || true)
  fi
fi

if [[ -z "$LABEL_ID" ]]; then
  echo "[prelabel] ERROR: could not get or create label '$TRIAGE_LABEL'"
  exit 1
fi
echo "[prelabel] Using label ID: $LABEL_ID for $ALIAS"

# 受信トレイの全メールをページングで取得しラベル付与
PAGE_TOKEN=""
TOTAL=0

while true; do
  if [[ -n "$PAGE_TOKEN" ]]; then
    PARAMS="{\"userId\":\"me\",\"q\":\"in:inbox\",\"maxResults\":500,\"pageToken\":\"${PAGE_TOKEN}\"}"
  else
    PARAMS="{\"userId\":\"me\",\"q\":\"in:inbox\",\"maxResults\":500}"
  fi

  RESP=$(gws gmail users messages list --params "$PARAMS" 2>/dev/null || true)
  IDS=$(printf '%s' "$RESP" | jq -r '.messages[]?.id // empty' 2>/dev/null || true)

  if [[ -z "$IDS" ]]; then
    break
  fi

  BATCH_COUNT=$(printf '%s' "$IDS" | grep -c . || true)

  # batchModify で一括付与（非対応の場合は個別ループにフォールバック）
  IDS_JSON=$(printf '%s' "$IDS" | jq -R . | jq -sc .)
  if ! gws gmail users messages batchModify \
      --params '{"userId":"me"}' \
      --json "{\"ids\":${IDS_JSON},\"addLabelIds\":[\"${LABEL_ID}\"]}" > /dev/null 2>&1; then
    echo "[prelabel] batchModify unavailable, falling back to individual modify..."
    while IFS= read -r id; do
      [[ -z "$id" ]] && continue
      gws gmail users messages modify \
        --params "{\"userId\":\"me\",\"id\":\"$id\"}" \
        --json "{\"addLabelIds\":[\"$LABEL_ID\"]}" > /dev/null 2>&1 || true
    done <<< "$IDS"
  fi

  TOTAL=$((TOTAL + BATCH_COUNT))
  echo "[prelabel] Labeled $BATCH_COUNT messages (total: $TOTAL) for $ALIAS"

  PAGE_TOKEN=$(printf '%s' "$RESP" | jq -r '.nextPageToken // empty' 2>/dev/null || true)
  [[ -z "$PAGE_TOKEN" ]] && break
done

echo "[prelabel] Done. Total: $TOTAL messages labeled for $ALIAS"
