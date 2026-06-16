#!/usr/bin/env bash
# =====================================================================
# Kiro Gateway - deploy the Opus 422 "system-role" fix (macOS/Linux/WSL)
#
# Run INSIDE the kiro-gateway folder your gateway runs from:
#   PROXY_API_KEY=yourkey bash deploy_fix.sh
# Your existing .env / credentials.json are reused automatically.
# =====================================================================
set -euo pipefail

FORK_URL="${FORK_URL:-https://github.com/aditya55496/kiro-gateway.git}"
BRANCH="${BRANCH:-fix/anthropic-system-role-hoisting}"
BASE_URL="${BASE_URL:-http://localhost:8000}"
API_KEY="${PROXY_API_KEY:-}"

echo "==> 1/5  Fetching the fix from your fork..."
git remote | grep -qx fork || git remote add fork "$FORK_URL"
git fetch fork "$BRANCH"
git checkout -B opus-fix "fork/$BRANCH"

echo "==> 2/5  Verifying the patch is in the source..."
grep -q "normalize_request_message_roles" kiro/models_anthropic.py \
  && echo "    OK - patch present." || { echo "FAIL: patch not found."; exit 1; }

echo "==> 3/5  Rebuilding & restarting (clean, no cache)..."
if [ -f docker-compose.yml ]; then
  docker compose down || true
  docker compose build --no-cache
  docker compose up -d
else
  echo "    No docker-compose.yml -> run 'python main.py' yourself after this."
fi

echo "==> 4/5  Waiting for the gateway..."
for i in $(seq 1 20); do
  curl -sf -o /dev/null "$BASE_URL/health" && break || sleep 1
done

echo "==> 5/5  Verifying Opus 'system-in-array' payload is accepted..."
if [ -z "$API_KEY" ]; then echo "    Set PROXY_API_KEY to run the live check."; exit 0; fi
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/v1/messages/count_tokens" \
  -H "x-api-key: $API_KEY" -H "content-type: application/json" \
  -d '{"model":"claude-opus-4-8","messages":[{"role":"user","content":"hi"},{"role":"system","content":"x"}]}')
if [ "$code" = "422" ]; then
  echo "    HTTP 422 -> STILL OLD CODE: a stale container/process is answering on $BASE_URL."
else
  echo "    HTTP $code (not 422) -> FIX IS LIVE. Opus will work in Claude Code."
fi
