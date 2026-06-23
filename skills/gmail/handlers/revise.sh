#!/usr/bin/env bash
# ユーザー指示(stdin)に従って Gmail 下書きを改稿し、更新後のプレビューを stdout に出力する
set -eo pipefail

DRAFT_ID="${1:?Usage: revise.sh <draft_id> <alias>}"
ALIAS="${2:?Usage: revise.sh <draft_id> <alias>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../../.."
set -a; source .env; set +a

USER_INSTRUCTION="$(cat)"

# 現在の本文を取得
CURRENT_BODY=$(bash "$SCRIPT_DIR/revise-fetch.sh" "$DRAFT_ID" "$ALIAS" \
  | jq -r '.current_body')

# revise.txt のプレースホルダーを Python で安全に置換（多行テキスト対応）
FULL_PROMPT=$(python3 -c "
import sys
template = open('prompts/revise.txt').read()
result = template.replace('{{user_instruction}}', sys.argv[1])
result = result.replace('{{current_body}}', sys.argv[2])
sys.stdout.write(result)
" "$USER_INSTRUCTION" "$CURRENT_BODY")

# codex でリライト
NEW_BODY=$(printf '%s' "$FULL_PROMPT" \
  | codex exec --dangerously-bypass-approvals-and-sandbox --ephemeral \
      "上記の指示に従って改稿後の本文のみを出力してください。" \
      2>/dev/null \
  | sed 's/^```[a-z]*//; s/```$//' \
  | tr -d '\r')

if [[ -z "$NEW_BODY" ]]; then
  echo "[revise] ERROR: codex returned empty output" >&2
  exit 1
fi

# 下書きへ反映（stderr に結果を出力してbotのログへ）
printf '%s' "$NEW_BODY" | bash "$SCRIPT_DIR/revise-apply.sh" "$DRAFT_ID" "$ALIAS" >&2

# プレビュー出力（bot が Discord に表示する）
printf '%s' "$NEW_BODY" | head -c 300
