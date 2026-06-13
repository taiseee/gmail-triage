# Gmail Triage

Gmail の受信メールを LLM で自動分類し、返信下書きを生成して Discord に通知する自動化システム。

## 概要

```
Gmail 受信 → poll.sh (5分ごと) → triage.sh → blocklist確認 → スキップ（通知なし）
                                             → allowlist確認 → LLM 分類 (spam 除外)
                                             → LLM 分類
                                                  ├── reply  → 下書き自動生成 → Discord 通知 (送信/改稿ボタン付き)
                                                  ├── check  → Discord 通知 (確認を促す)
                                                  ├── spam   → Discord 通知 (ブロック確認ボタン付き)
                                                  └── none   → スキップ
```

複数の Gmail アカウント（personal / univ / work など）を同時に監視できる。

## 依存関係

| ツール | 用途 |
|--------|------|
| [`gws`](https://github.com/taisei-m/gws) | Gmail API 操作 (メッセージ取得・ラベル付け・下書き作成) |
| `agy` (antigravity CLI) | LLM 推論（分類・返信文生成） |
| `node` / `npm` | Discord bot (notifier.js) |
| `launchctl` | macOS LaunchAgent によるポーラー・bot の常駐起動 |
| `jq`, `curl`, `base64` | シェルスクリプト内のデータ処理 |

## ディレクトリ構成

```
gmail_triage/
├── .env                   # 環境変数（gitignore 済み）
├── .env.example           # 設定テンプレート
├── scripts/
│   ├── poll.sh            # メールポーリング・ラベル付与
│   ├── triage.sh          # LLM 分類 + 下書き生成 + 通知
│   ├── notify.sh          # Discord bot への HTTP 通知
│   ├── create-draft.sh    # Gmail 下書き作成
│   ├── install-watchers.sh   # LaunchAgent 登録
│   ├── uninstall-watchers.sh # LaunchAgent 解除
│   └── prelabel-existing.sh  # 既存メールへの初期ラベル付け
├── bot/
│   └── notifier.js        # Discord bot (送信/改稿/スパムブロックボタン)
├── skills/gmail/
│   ├── SKILL.md           # Discord コマンド仕様
│   └── handlers/          # ボタン操作ハンドラー
│       ├── send.sh        # 下書き送信
│       ├── show.sh        # 下書き表示
│       ├── revise.sh      # 下書き改稿 (agy)
│       ├── discard.sh     # 下書き削除
│       ├── spam-confirm.sh  # スパムブロック実行
│       └── spam-reject.sh   # スパム判定を却下
├── prompts/
│   ├── decide.txt         # 分類プロンプト
│   ├── draft-reply.txt    # 返信文生成プロンプト
│   └── revise.txt         # 改稿プロンプト
├── launchd/               # LaunchAgent plist テンプレート
├── data/
│   ├── blocklist.txt      # 迷惑メールとして登録したアドレス（1行1アドレス）
│   └── allowlist.txt      # 通常メールとして確認済みのアドレス（1行1アドレス）
└── logs/                  # poll・bot のログ出力先
```

## 初期設定

### 1. 環境変数を設定する

```bash
cp .env.example .env
```

`.env` を編集して以下を設定する:

```bash
# 監視するアカウント名（カンマ区切り）
GMAIL_ACCOUNTS=personal,univ,work

# GCP プロジェクト ID（gws gmail +watch に使用）
GOOGLE_WORKSPACE_PROJECT_ID=your-project-id

# Discord 通知先
DISCORD_CHANNEL_ID=000000000000000000
DISCORD_BOT_USER_ID=000000000000000000
DISCORD_NOTIFY_BOT_TOKEN=Bot_xxxxxxxxxxxxxxxxxxxx

# アカウント別の gws 設定ディレクトリ
GMAIL_PERSONAL_GWS_DIR=/path/to/personal-gws-config
GMAIL_UNIV_GWS_DIR=/path/to/univ-gws-config
GMAIL_WORK_GWS_DIR=/path/to/work-gws-config

# Discord 通知時の表示名（省略可）
GMAIL_PERSONAL_LABEL=Personal
GMAIL_UNIV_LABEL=University
GMAIL_WORK_LABEL=Work
```

### 2. Discord bot をセットアップする

1. [Discord Developer Portal](https://discord.com/developers/applications) で Bot を作成
2. 「Bot」タブ → Token をコピーして `DISCORD_NOTIFY_BOT_TOKEN` に設定
3. 「OAuth2」→「Bot」スコープ + `Send Messages` / `Use Slash Commands` 権限でサーバーに招待
4. 通知先チャンネルの ID を `DISCORD_CHANNEL_ID` に設定

### 3. bot の依存パッケージをインストールする

```bash
cd bot
npm install
cd ..
```

### 4. LaunchAgent を登録する（常駐起動）

```bash
bash scripts/install-watchers.sh
```

これにより以下が登録される:
- `com.automation.gmail-triage.poll.<alias>` — 各アカウントのポーラー（5分ごと）
- `com.automation.gmail-triage.bot` — Discord bot

### 5. 既存メールに処理済みラベルを付ける（初回のみ）

初回実行時、受信トレイの既存メールがすべて未処理として検出されるのを防ぐ:

```bash
bash scripts/prelabel-existing.sh
```

## 起動・停止

```bash
# 登録（install-watchers.sh 実行後、launchctl が自動起動する）

# 手動で停止
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.automation.gmail-triage.poll.personal.plist

# 再起動
launchctl kickstart gui/$(id -u)/com.automation.gmail-triage.poll.personal

# 全エージェントを解除
bash scripts/uninstall-watchers.sh
```

## 分類ロジック

`prompts/decide.txt` のプロンプトに基づいて LLM が以下のカテゴリに分類する:

| カテゴリ | 説明 | 処理 |
|----------|------|------|
| `reply`  | 個人から返信を求められているメール | 下書きを自動生成して Discord 通知 |
| `check`  | 返信不要だが把握すべき重要通知 | Discord 通知のみ |
| `spam`   | 迷惑メール・不要メール（就活スカウト含む） | 確認ボタン付きで Discord 通知 |
| `none`   | スキップしてよいもの | 何もしない |

`data/blocklist.txt` に一致する送信者は LLM 分類前にスキップ（通知なし）。  
`data/allowlist.txt` に一致する送信者は spam に分類されない（LLM が spam 判定しても `none` に格下げしてスキップ）。

## Discord での操作

### 返信下書き通知（reply）

- **送信** ボタン: `handlers/send.sh` を実行して下書きを即送信
- **改稿** ボタン: モーダルに指示を入力 → `handlers/revise.sh` が agy でリライト → 下書きに反映

### スパム候補通知（spam）

- **迷惑メールに設定** ボタン: `handlers/spam-confirm.sh` を実行して `data/blocklist.txt` に追記 + 現メッセージを SPAM フォルダへ移動
- **違う（通常メール）** ボタン: `handlers/spam-reject.sh` を実行して `data/allowlist.txt` に追記

### テキストコマンド（任意）

```
show draft:<id>@<alias>      # 下書き本文を表示
discard draft:<id>@<alias>   # 下書きを削除
```

## ログ確認

```bash
# ポーラーのログ
tail -f logs/poll-personal.log
tail -f logs/poll-personal.err

# Discord bot のログ
tail -f logs/bot.log
tail -f logs/bot.err
```

## Gmail ラベル

処理後に以下のラベルが自動付与される:

| ラベル | 意味 |
|--------|------|
| `LLM-Triaged` | 処理済み（再処理防止） |
| `要返信` | reply カテゴリ |
| `要確認` | check カテゴリ |

ラベル名は `.env` の `GMAIL_TRIAGE_LABEL` / `GMAIL_REPLY_LABEL` / `GMAIL_CHECK_LABEL` で変更可能（省略時は上記デフォルト値）。
