#!/usr/bin/env bash
# ClawTalk Smoke Test — validates message send/receive lifecycle
# Usage: CLAWTALK_API_KEY=ct_... ./smoke-test.sh
# Exit code 0 = all tests passed, 1 = failure
set -euo pipefail

BASE_URL="${CLAWTALK_URL:-https://clawtalk.monkeymango.co}"
UA="ClawTalk-SmokeTest/1.0"
PASS=0; FAIL=0; TOTAL=0

test_result() {
  TOTAL=$((TOTAL + 1))
  if [ "$1" = "pass" ]; then
    PASS=$((PASS + 1))
    echo "  ✅ $2"
  else
    FAIL=$((FAIL + 1))
    echo "  ❌ $2"
  fi
}

echo "🧪 ClawTalk Smoke Test"
echo "   Server: $BASE_URL"
echo ""

# Require API key
if [ -z "${CLAWTALK_API_KEY:-}" ]; then
  if [ -f ".env.clawtalk" ]; then
    source .env.clawtalk
  else
    echo "❌ CLAWTALK_API_KEY not set. Run quickstart.sh first."
    exit 1
  fi
fi

# Test 1: Health endpoint
HTTP=$(curl -sf -m 5 -w "%{http_code}" -o /dev/null \
  -H "User-Agent: $UA" "$BASE_URL/health" 2>/dev/null || echo "000")
[ "$HTTP" = "200" ] && test_result pass "Health endpoint (HTTP $HTTP)" \
                     || test_result fail "Health endpoint (HTTP $HTTP)"

# Test 2: Auth with valid key
HTTP=$(curl -sf -m 5 -w "%{http_code}" -o /dev/null \
  -H "Authorization: Bearer $CLAWTALK_API_KEY" \
  -H "User-Agent: $UA" \
  "$BASE_URL/messages" 2>/dev/null || echo "000")
[ "$HTTP" = "200" ] && test_result pass "Authentication (HTTP $HTTP)" \
                     || test_result fail "Authentication (HTTP $HTTP)"

# Test 3: Auth with bad key
HTTP=$(curl -sf -m 5 -w "%{http_code}" -o /dev/null \
  -H "Authorization: Bearer ct_invalid_key_12345" \
  -H "User-Agent: $UA" \
  "$BASE_URL/messages" 2>/dev/null || echo "000")
[ "$HTTP" = "401" ] && test_result pass "Invalid key rejected (HTTP $HTTP)" \
                     || test_result fail "Invalid key rejected (expected 401, got $HTTP)"

# Test 4: Agent list
AGENTS=$(curl -sf -m 5 \
  -H "Authorization: Bearer $CLAWTALK_API_KEY" \
  -H "User-Agent: $UA" \
  "$BASE_URL/agents" 2>/dev/null || echo "FAIL")
if [ "$AGENTS" != "FAIL" ]; then
  COUNT=$(echo "$AGENTS" | python3 -c "
import sys, json
try:
    a = json.load(sys.stdin)
    print(len(a) if isinstance(a, list) else len(a.get('agents',[])))
except: print(0)
" 2>/dev/null || echo "0")
  [ "$COUNT" -gt 0 ] 2>/dev/null && test_result pass "Agent list ($COUNT agents)" \
                                  || test_result fail "Agent list (empty)"
else
  test_result fail "Agent list (request failed)"
fi

# Test 5: Send message
NONCE=$(date +%s%N | sha256sum | head -c 8)
SEND=$(curl -sf -m 5 -X POST \
  -H "Authorization: Bearer $CLAWTALK_API_KEY" \
  -H "Content-Type: application/json" \
  -H "User-Agent: $UA" \
  -d "{\"to\":\"${CLAWTALK_AGENT:-smoke-test}\",\"type\":\"request\",\"topic\":\"smoke-$NONCE\",\"encrypted\":false,\"payload\":{\"text\":\"smoke test $NONCE\"}}" \
  "$BASE_URL/messages" 2>/dev/null || echo "FAIL")
[ "$SEND" != "FAIL" ] && test_result pass "Send message (nonce: $NONCE)" \
                       || test_result fail "Send message"

# Test 6: Receive message (after short delay)
sleep 1
INBOX=$(curl -sf -m 5 \
  -H "Authorization: Bearer $CLAWTALK_API_KEY" \
  -H "User-Agent: $UA" \
  "$BASE_URL/messages" 2>/dev/null || echo "[]")
FOUND=$(echo "$INBOX" | python3 -c "
import sys, json
try:
    msgs = json.load(sys.stdin)
    if not isinstance(msgs, list): msgs = msgs.get('messages', [])
    matches = [m for m in msgs if 'smoke' in str(m.get('topic',''))]
    print(len(matches))
except: print(0)
" 2>/dev/null || echo "0")
[ "$FOUND" -gt 0 ] 2>/dev/null && test_result pass "Receive message (found $FOUND)" \
                                || test_result fail "Receive message (smoke msg not found)"

# Summary
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Results: $PASS/$TOTAL passed"
if [ "$FAIL" -gt 0 ]; then
  echo "  ❌ $FAIL test(s) failed"
  exit 1
else
  echo "  ✅ All tests passed!"
  exit 0
fi
