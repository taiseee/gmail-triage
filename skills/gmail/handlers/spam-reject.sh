#!/usr/bin/env bash
# 迷惑メール候補を却下: allowlist.txt にアドレスを追記する
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../../.."

input="$(cat)"
FROM=$(printf '%s' "$input" | jq -r '.from // ""')

# メールアドレスのみ抽出（小文字）
if printf '%s' "$FROM" | grep -q '<'; then
  FROM_ADDR=$(printf '%s' "$FROM" | sed 's/.*<\([^>]*\)>.*/\1/' | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
else
  FROM_ADDR=$(printf '%s' "$FROM" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
fi

# allowlist.txt に追記（重複なし）
if [[ -n "$FROM_ADDR" ]] && ! grep -Fxq "$FROM_ADDR" data/allowlist.txt 2>/dev/null; then
  echo "$FROM_ADDR" >> data/allowlist.txt
fi

echo "アローリストに追加しました: $FROM_ADDR"
