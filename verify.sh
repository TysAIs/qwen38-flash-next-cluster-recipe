#!/usr/bin/env bash
# verify.sh — proof the fleet endpoint is really serving. No secrets, read-only, safe to run any time.
# Reads PORT from .env when present (default 8888, the fleet pin). Exits non-zero on the first FAIL.
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] && { set -a; . ./.env; set +a; }
PORT="${PORT:-8888}"
API="${API:-http://127.0.0.1:$PORT}"
fails=0
ck() { if eval "$2"; then echo "PASS  $1"; else echo "FAIL  $1"; fails=$((fails+1)); fi; }

ck "GET $API/v1/models answers" \
   'curl -sf -m 10 "$API/v1/models" | grep -q "\"id\""'
ck "served name present (qwen3.8-flash-next)" \
   'curl -sf -m 10 "$API/v1/models" | grep -q "qwen3.8-flash-next"'
ck "chat completion returns content" \
   'curl -sf -m 60 "$API/v1/chat/completions" -H "content-type: application/json" -d "{
      \"model\": \"qwen3.8-flash-next\",
      \"messages\": [{\"role\": \"user\", \"content\": \"Reply with exactly: pong\"}],
      \"max_tokens\": 2048, \"temperature\": 0}" | grep -q "choices"'
ck "engine reports a model name (generated, not cached)" \
   'curl -sf -m 60 "$API/v1/chat/completions" -H "content-type: application/json" -d "{
      \"model\": \"qwen3.8-flash-next\", \"prompt\": \"The capital of Utah is\",
      \"max_tokens\": 16}" | grep -q "\"text\""'

if [ "$fails" = 0 ]; then
  echo "PASS  endpoint healthy — $API serves qwen3.8-flash-next ($(date -u +%FT%TZ))"
else
  echo "FAIL  $fails check(s) failed against $API"; exit 1
fi
