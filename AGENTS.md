# Gmail Triage

## 公開リポジトリとして守ること

このリポジトリは public repo なので、commit/push 前に個人情報や秘密情報が含まれていないことを必ず確認する。

- `.env`、トークン、APIキー、Cookie、認証情報、ローカルキャッシュ、ログ、Gmail本文、メールアドレス、アカウント名、個人のローカルパスを commit しない。
- private repo `taiseee/second-brain` の `workspace/automation/gmail_triage/` から変更を反映する場合は、公開可能なサブセットだけをこの repo に取り込む。
- private 側で Gmail triage を commit/push した場合は、この public repo にも対応する公開可能な変更を commit/push する。
- push 前に `rg -n` 等で秘密情報や個人情報が混入していないことを確認する。
