#!/usr/bin/env bash
# gws gmail +watch で新着をストリーミング受信し、1 メールごとに taskflow を起動する
set -eo pipefail

ALIAS="${1:?Usage: watch-runner.sh <alias>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
set -a; source .env; set +a

_ALIAS_UPPER=$(printf '%s' "$ALIAS" | tr '[:lower:]' '[:upper:]')
_GWS_DIR_VAR="GMAIL_${_ALIAS_UPPER}_GWS_DIR"
export GOOGLE_WORKSPACE_CLI_CONFIG_DIR="${!_GWS_DIR_VAR:?${_GWS_DIR_VAR} is not set in .env}"

echo "[watch-runner] Starting watch for account: $ALIAS"

gws gmail +watch --project "${GOOGLE_WORKSPACE_PROJECT_ID:?set GOOGLE_WORKSPACE_PROJECT_ID in .env}" --format json \
  | while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      ENRICHED=$(printf '%s' "$line" | jq --arg a "$ALIAS" '. + {account: $a}' 2>/dev/null) || continue
      [[ -z "$ENRICHED" ]] && continue
      printf '%s' "$ENRICHED" | bash "$(dirname "${BASH_SOURCE[0]}")/triage.sh" "$ALIAS"
    done
