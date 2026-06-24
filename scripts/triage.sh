#!/usr/bin/env bash
# 1通のメール JSON (stdin) を受け取って judge → create_draft → notify を順に実行する
set -eo pipefail

ALIAS="${1:?Usage: triage.sh <alias>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
set -a; source .env; set +a

MAIL_JSON="$(cat)"

if [[ -z "$MAIL_JSON" ]] || ! printf '%s' "$MAIL_JSON" | jq -e . >/dev/null 2>&1; then
  echo "[triage] SKIP: empty or invalid JSON received"
  exit 0
fi

echo "[triage] Processing mail for account=$ALIAS: $(printf '%s' "$MAIL_JSON" | jq -r '.subject // "(no subject)"')"

# Step 1: 元メール文脈を抽出（後の agentic ステップおよび create-draft で使用）
THREAD_ID=$(printf '%s' "$MAIL_JSON" | jq -r '.threadId // ""')
MESSAGE_ID=$(printf '%s' "$MAIL_JSON" | jq -r '.id // ""')
SUBJECT=$(printf '%s' "$MAIL_JSON" | jq -r '.subject // ""')
FROM=$(printf '%s' "$MAIL_JSON" | jq -r '.from // ""')
RFC_MSGID=$(printf '%s' "$MAIL_JSON" | jq -r '.rfcMessageId // ""')
BODY=$(printf '%s' "$MAIL_JSON" | jq -r '.body // ""')

# ブロックリスト/アローリスト確認（ローカル txt ファイルで判定）
if printf '%s' "$FROM" | grep -q '<'; then
  FROM_ADDR=$(printf '%s' "$FROM" | sed 's/.*<\([^>]*\)>.*/\1/' | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
else
  FROM_ADDR=$(printf '%s' "$FROM" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
fi

if [[ -n "$FROM_ADDR" ]] && [[ -f data/blocklist.txt ]] && grep -Fxq "$FROM_ADDR" data/blocklist.txt; then
  echo "[triage] BLOCK: $FROM_ADDR is in blocklist, skipping"
  exit 0
fi

ALLOWLISTED=0
if [[ -n "$FROM_ADDR" ]] && [[ -f data/allowlist.txt ]] && grep -Fxq "$FROM_ADDR" data/allowlist.txt; then
  ALLOWLISTED=1
fi

# Step 2: 分類 — codex exec でワンショット推論（category + reason のみ出力）
CLASSIFY_PROMPT="$(cat prompts/decide.txt)

受信メール情報:
${MAIL_JSON}"
if [[ "$ALLOWLISTED" -eq 1 ]]; then
  CLASSIFY_PROMPT="${CLASSIFY_PROMPT}

注意: 送信者 ${FROM_ADDR} はユーザーが「迷惑メールではない」と確認済みです。spam には分類しないこと。"
fi

RAW_JUDGE=$(printf '%s' "$CLASSIFY_PROMPT" \
  | codex exec --dangerously-bypass-approvals-and-sandbox --ephemeral \
      -m gpt-5.4-mini -c model_reasoning_effort=low \
      "上記の指示に従って JSON のみを出力してください。" \
      2>/dev/null)

# コードブロック除去して JSON パース（subject はメール由来の値で補完）
JUDGE_JSON=$(printf '%s' "$RAW_JUDGE" \
  | sed 's/^```[a-z]*//; s/```$//' \
  | tr -d '\r' \
  | jq --arg acc "$ALIAS" --arg tid "$THREAD_ID" --arg mid "$MESSAGE_ID" --arg subj "$SUBJECT" \
      '. + {account: $acc, threadId: $tid, messageId: $mid, subject: $subj}' \
  2>/dev/null)

if [[ -z "$JUDGE_JSON" ]]; then
  echo "[triage] ERROR: judge failed to produce valid JSON. Raw output: $RAW_JUDGE"
  exit 1
fi

CATEGORY=$(printf '%s' "$JUDGE_JSON" | jq -r '.category // "none"')
REASON=$(printf '%s' "$JUDGE_JSON" | jq -r '.reason // ""')

# アローリスト送信者は spam 判定を無効化（決定論的ガード）
# LLM がプロンプト注意文を無視して spam と返しても通知しない
if [[ "$ALLOWLISTED" -eq 1 ]] && [[ "$CATEGORY" == "spam" ]]; then
  echo "[triage] ALLOWLIST: $FROM_ADDR is allowlisted, overriding spam -> none (skip)"
  CATEGORY="none"
fi

case "$CATEGORY" in
  reply)
    echo "[triage] category=reply: $REASON"
    # Step 3: codex で返信本文を自律生成（読み取り専用ツール使用・本文のみ出力）
    REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
    ACCOUNT_DIRS_LIST=$(printenv | grep '^GMAIL_[A-Z]*_GWS_DIR=' || true | while IFS='=' read -r k v; do
      alias_name=$(printf '%s' "$k" | sed 's/GMAIL_\([A-Z]*\)_GWS_DIR/\1/' | tr '[:upper:]' '[:lower:]')
      printf '  %s: %s\n' "$alias_name" "$v"
    done)
    DRAFT_PROMPT="$(cat prompts/draft-reply.txt)

---
件名: ${SUBJECT}
送信者: ${FROM}
アカウント: ${ALIAS}

本文:
${BODY}

カレンダーアカウント設定:
${ACCOUNT_DIRS_LIST}"
    AGY_RAW=$(printf '%s' "$DRAFT_PROMPT" \
      | codex exec --dangerously-bypass-approvals-and-sandbox --ephemeral \
            -m gpt-5.4-mini -c model_reasoning_effort=low \
            "上記の指示に従い、<<<BODY>>>...<<<END>>>マーカーで囲んで返信本文のみを出力してください。" \
            2>/dev/null || true)
    # マーカー間のみ抽出。見つからない場合（タイムアウト含む）は通知せず終了
    if ! printf '%s' "$AGY_RAW" | grep -q '<<<BODY>>>'; then
      echo "[triage] SKIP: codex did not return <<<BODY>>> marker (timed out or failed)" >&2
      exit 0
    fi
    DRAFT_BODY=$(printf '%s' "$AGY_RAW" \
      | sed -n '/<<<BODY>>>/,/<<<END>>>/p' \
      | grep -v '<<<' | tr -d '\r')
    if [[ -z "$DRAFT_BODY" ]]; then
      echo "[triage] SKIP: body between markers was empty" >&2
      exit 0
    fi
    # Step 4: create_draft（To/Subject RFC2047/スレッド付き下書きを決定論的に作成）
    CREATE_INPUT=$(printf '%s' "$MAIL_JSON" | jq \
      --arg acc "$ALIAS" \
      --arg tid "$THREAD_ID" \
      --arg rfcmid "$RFC_MSGID" \
      --arg from "$FROM" \
      --arg subj "$SUBJECT" \
      --arg draft "$DRAFT_BODY" \
      --arg body "$BODY" \
      '{account:$acc, threadId:$tid, rfcMessageId:$rfcmid, from:$from, subject:$subj, draft:$draft, body:$body}')
    DRAFT_RESULT=$(printf '%s' "$CREATE_INPUT" | bash "$SCRIPT_DIR/create-draft.sh")
    DRAFT_ID=$(printf '%s' "$DRAFT_RESULT" | jq -r '.draftId // ""')
    if [[ -z "$DRAFT_ID" ]]; then
      echo "[triage] ERROR: create_draft failed. Result: $DRAFT_RESULT"
      exit 1
    fi
    # Step 5: notify（ベストエフォート — 下書き作成済みなので失敗してもリトライしない）
    printf '%s' "$DRAFT_RESULT" | bash "$SCRIPT_DIR/notify.sh" \
      || echo "[triage] WARNING: notify failed (draft already created)"
    echo "[triage] Done. draft:${DRAFT_ID}@${ALIAS}"
    exit 10
    ;;
  check)
    echo "[triage] category=check: $REASON"
    # notify のみ（下書きなし）— 失敗時は exit 1 で次回リトライ
    NOTIFY_JSON=$(printf '%s' "$JUDGE_JSON" | jq --arg kind "check" '. + {kind: $kind}')
    NOTIFY_RESULT=$(printf '%s' "$NOTIFY_JSON" | bash "$SCRIPT_DIR/notify.sh" 2>/dev/null || true)
    if [[ "$NOTIFY_RESULT" != "ok" ]]; then
      echo "[triage] ERROR: notify failed: ${NOTIFY_RESULT:-connection refused}" >&2
      exit 1
    fi
    echo "[triage] Done. check notified for ${ALIAS}"
    exit 11
    ;;
  spam)
    echo "[triage] category=spam: $REASON"
    NOTIFY_JSON=$(printf '%s' "$JUDGE_JSON" | jq \
      --arg kind "spam" \
      --arg from "$FROM" \
      --arg mid "$MESSAGE_ID" \
      '. + {kind: $kind, from: $from, messageId: $mid}')
    NOTIFY_RESULT=$(printf '%s' "$NOTIFY_JSON" | bash "$SCRIPT_DIR/notify.sh" 2>/dev/null || true)
    if [[ "$NOTIFY_RESULT" != "ok" ]]; then
      echo "[triage] ERROR: notify failed: ${NOTIFY_RESULT:-connection refused}" >&2
      exit 1
    fi
    echo "[triage] Done. spam notified for ${ALIAS}"
    exit 12
    ;;
  *)
    echo "[triage] category=none: $REASON"
    exit 0
    ;;
esac
