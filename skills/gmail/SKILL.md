# Gmail Draft Skill

Gmail 下書きの確認・改稿・削除を Discord 上から操作するスキルです。

## アカウント指定形式

`draft:<id>@<alias>` の形式で下書きとアカウントを指定します。
- `<alias>` は `.env` の `GMAIL_ACCOUNTS` に登録されているエイリアス（例: `personal`, `univ`, `work`）
- `<id>` は triage 通知に含まれる Draft ID

## Discord bot によるボタン操作（主な操作経路）

返信が必要なメールの通知には「送信」「改稿」ボタンが付く。

- **送信**: クリックで直接 `handlers/send.sh` が実行され、Gmail 下書きを即送信。LLM 不使用・決定論的。
- **改稿**: クリックするとモーダルが開く → 自由文で指示 → `handlers/revise.sh` が codex でリライト → 下書き反映。

## テキストコマンド一覧（任意）

### send draft:\<id\>@\<alias\>

指定した下書きを送信します。

**handler**: `handlers/send.sh <id> <alias>`

### show draft:\<id\>@\<alias\>

指定した下書きの本文を返します。

**handler**: `handlers/show.sh <id> <alias>`

### revise

triage 通知メッセージへの返信として自由文で指示するだけで改稿します。

例:
- 「もっと丁寧に書いて」
- 「要点だけ3行にまとめて」
- 「英語で書き直して」

**handler**:
1. `handlers/revise-fetch.sh <draft_id> <alias>` で元本文を取得
2. `handlers/revise.sh` が `prompts/revise.txt` に沿って codex で改稿
3. `handlers/revise-apply.sh <draft_id> <alias>` で改稿結果を Gmail 下書きに反映

### discard draft:\<id\>@\<alias\>

指定した下書きを削除します。

**handler**: `handlers/discard.sh <id> <alias>`

## 内部の注意事項

- すべての handler は `.env` の `GMAIL_<ALIAS>_GWS_DIR` から `GOOGLE_WORKSPACE_CLI_CONFIG_DIR` を解決してから `gws` を呼ぶこと
- handler は `workspace/automation/gmail_triage/` を working directory として起動される
