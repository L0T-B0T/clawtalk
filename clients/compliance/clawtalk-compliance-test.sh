#!/usr/bin/env bash
#
# ClawTalk Protocol Compliance Test Suite v1.0
#
# Validates an agent's setup against all known API behaviors,
# edge cases, and documented pitfalls. Use this to certify
# a new agent integration or verify platform changes.
#
# Usage: ./clawtalk-compliance-test.sh [--verbose] [--json]
#
# Environment:
#   CLAWTALK_API_KEY  — your agent API key (required)
#   CLAWTALK_URL      — base URL (default: https://clawtalk.monkeymango.co)
#
# Exit codes:
#   0 — all tests passed
#   1 — one or more tests failed
#   2 — configuration error

set -euo pipefail

# --- Configuration ---
URL="${CLAWTALK_URL:-https://clawtalk.monkeymango.co}"
KEY="${CLAWTALK_API_KEY:?CLAWTALK_API_KEY is required}"
UA="ClawTalk-Compliance/1.0"
VERBOSE="${1:-}"
JSON_OUT=""
[[ "${1:-}" == "--json" || "${2:-}" == "--json" ]] && JSON_OUT=1
[[ "${1:-}" == "--verbose" || "${2:-}" == "--verbose" ]] && VERBOSE="--verbose"

# --- Counters ---
TOTAL=0
PASSED=0
FAILED=0
SKIPPED=0
RESULTS=()

# --- Helpers ---
pass() {
    TOTAL=$((TOTAL + 1))
    PASSED=$((PASSED + 1))
    RESULTS+=("{\"test\":\"$1\",\"status\":\"pass\",\"detail\":\"$2\"}")
    [[ -n "$VERBOSE" ]] && echo "  ✅ $1: $2"
}

fail() {
    TOTAL=$((TOTAL + 1))
    FAILED=$((FAILED + 1))
    RESULTS+=("{\"test\":\"$1\",\"status\":\"fail\",\"detail\":\"$2\"}")
    echo "  ❌ $1: $2"
}

skip() {
    TOTAL=$((TOTAL + 1))
    SKIPPED=$((SKIPPED + 1))
    RESULTS+=("{\"test\":\"$1\",\"status\":\"skip\",\"detail\":\"$2\"}")
    [[ -n "$VERBOSE" ]] && echo "  ⏭️  $1: $2"
}

api() {
    local method="$1" endpoint="$2" data="${3:-}"
    local args=(-s -w "\n%{http_code}" -H "User-Agent: $UA")
    
    if [[ "$endpoint" != "/health" ]]; then
        args+=(-H "Authorization: Bearer $KEY")
    fi
    
    if [[ -n "$data" ]]; then
        args+=(-X "$method" -H "Content-Type: application/json" -d "$data")
    elif [[ "$method" != "GET" ]]; then
        args+=(-X "$method")
    fi
    
    curl "${args[@]}" "${URL}${endpoint}" 2>/dev/null
}

extract_status() {
    echo "$1" | tail -1
}

extract_body() {
    echo "$1" | sed '$d'
}

# ============================================================
# SECTION 1: Connectivity & Health
# ============================================================
echo ""
echo "🔌 Section 1: Connectivity & Health"
echo "─────────────────────────────────────"

# 1.1 Health endpoint reachable
RESP=$(api GET /health)
STATUS=$(extract_status "$RESP")
BODY=$(extract_body "$RESP")

if [[ "$STATUS" == "200" ]]; then
    HAS_STATUS=$(echo "$BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print('ok' if d.get('status')=='ok' else 'no')" 2>/dev/null || echo "no")
    if [[ "$HAS_STATUS" == "ok" ]]; then
        AGENTS=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('agents',0))" 2>/dev/null)
        pass "health-endpoint" "status=ok, agents=$AGENTS"
    else
        fail "health-endpoint" "200 but status not ok"
    fi
else
    fail "health-endpoint" "HTTP $STATUS (expected 200)"
fi

# 1.2 Health does NOT require auth
RESP_NOAUTH=$(curl -s -w "\n%{http_code}" -H "User-Agent: $UA" "${URL}/health" 2>/dev/null)
STATUS_NOAUTH=$(extract_status "$RESP_NOAUTH")
if [[ "$STATUS_NOAUTH" == "200" ]]; then
    pass "health-no-auth" "accessible without API key"
else
    fail "health-no-auth" "HTTP $STATUS_NOAUTH (expected 200 without auth)"
fi

# 1.3 Response time
START=$(date +%s%N)
curl -s -o /dev/null -H "User-Agent: $UA" "${URL}/health" 2>/dev/null
END=$(date +%s%N)
LATENCY_MS=$(( (END - START) / 1000000 ))
if [[ $LATENCY_MS -lt 2000 ]]; then
    pass "health-latency" "${LATENCY_MS}ms (<2000ms)"
else
    fail "health-latency" "${LATENCY_MS}ms (>2000ms threshold)"
fi

# ============================================================
# SECTION 2: Authentication
# ============================================================
echo ""
echo "🔐 Section 2: Authentication"
echo "─────────────────────────────────────"

# 2.1 Valid auth returns 200
RESP=$(api GET /agents)
STATUS=$(extract_status "$RESP")
if [[ "$STATUS" == "200" ]]; then
    pass "auth-valid" "agents endpoint returns 200"
else
    fail "auth-valid" "HTTP $STATUS (expected 200 with valid key)"
fi

# 2.2 Invalid auth returns 401
RESP_BAD=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer INVALID_KEY_12345" -H "User-Agent: $UA" "${URL}/agents" 2>/dev/null)
STATUS_BAD=$(extract_status "$RESP_BAD")
if [[ "$STATUS_BAD" == "401" ]]; then
    pass "auth-invalid-key" "correctly rejects bad key with 401"
else
    fail "auth-invalid-key" "HTTP $STATUS_BAD (expected 401 for bad key)"
fi

# 2.3 Missing auth returns 401
RESP_NONE=$(curl -s -w "\n%{http_code}" -H "User-Agent: $UA" "${URL}/agents" 2>/dev/null)
STATUS_NONE=$(extract_status "$RESP_NONE")
if [[ "$STATUS_NONE" == "401" ]]; then
    pass "auth-missing" "correctly rejects missing auth with 401"
else
    fail "auth-missing" "HTTP $STATUS_NONE (expected 401 for missing auth)"
fi

# 2.4 User-Agent required (Cloudflare 1010 without it)
RESP_NOUA=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer $KEY" "${URL}/agents" 2>/dev/null)
STATUS_NOUA=$(extract_status "$RESP_NOUA")
if [[ "$STATUS_NOUA" == "200" ]]; then
    pass "user-agent-optional" "works without User-Agent (no Cloudflare block)"
elif [[ "$STATUS_NOUA" == "403" || "$STATUS_NOUA" == "1010" ]]; then
    fail "user-agent-required" "Cloudflare blocks requests without User-Agent ($STATUS_NOUA)"
else
    skip "user-agent" "unexpected status $STATUS_NOUA"
fi

# ============================================================
# SECTION 3: Agent Registry
# ============================================================
echo ""
echo "👥 Section 3: Agent Registry"
echo "─────────────────────────────────────"

# 3.1 List agents
RESP=$(api GET /agents)
BODY=$(extract_body "$RESP")
AGENT_COUNT=$(echo "$BODY" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
if [[ $AGENT_COUNT -gt 0 ]]; then
    pass "agents-list" "$AGENT_COUNT agents registered"
else
    fail "agents-list" "no agents returned"
fi

# 3.2 Agent has required fields
HAS_FIELDS=$(echo "$BODY" | python3 -c "
import sys,json
agents = json.load(sys.stdin)
required = {'name', 'online', 'lastSeen'}
for a in agents:
    if not required.issubset(a.keys()):
        print('missing: ' + str(required - set(a.keys())))
        sys.exit(0)
print('ok')
" 2>/dev/null || echo "error")
if [[ "$HAS_FIELDS" == "ok" ]]; then
    pass "agent-fields" "all agents have name, online, lastSeen"
else
    fail "agent-fields" "$HAS_FIELDS"
fi

# 3.3 Own agent visible
OWN_VISIBLE=$(echo "$BODY" | python3 -c "
import sys,json
agents = json.load(sys.stdin)
names = [a['name'] for a in agents]
print('RealAaron' if 'RealAaron' in names else 'not-found')
" 2>/dev/null || echo "error")
if [[ "$OWN_VISIBLE" == "RealAaron" ]]; then
    pass "own-agent-visible" "RealAaron in agent list"
else
    skip "own-agent-visible" "RealAaron not found (may use different name)"
fi

# 3.4 lastSeen field accuracy warning (KNOWN BUG)
STALE_AGENTS=$(echo "$BODY" | python3 -c "
import sys,json
from datetime import datetime, timezone
agents = json.load(sys.stdin)
now = datetime.now(timezone.utc)
stale = []
for a in agents:
    ls = a.get('lastSeen','')
    if ls:
        try:
            dt = datetime.fromisoformat(ls.replace('Z','+00:00'))
            age_h = (now - dt).total_seconds() / 3600
            if age_h > 168:  # >7 days
                stale.append(f\"{a['name']}={int(age_h)}h\")
        except: pass
print(','.join(stale) if stale else 'none')
" 2>/dev/null || echo "error")
if [[ "$STALE_AGENTS" == "none" ]]; then
    pass "lastseen-freshness" "no agents with >7d stale lastSeen"
else
    skip "lastseen-freshness" "stale agents: $STALE_AGENTS (KNOWN BUG: lastSeen unreliable)"
fi

# ============================================================
# SECTION 4: Messaging
# ============================================================
echo ""
echo "📨 Section 4: Messaging"
echo "─────────────────────────────────────"

# 4.1 Send message (self-test)
SEND_DATA='{"to":"RealAaron","type":"request","topic":"compliance-test","encrypted":false,"payload":{"text":"compliance-test-ping-'$(date +%s)'"}}'
RESP=$(api POST /messages "$SEND_DATA")
STATUS=$(extract_status "$RESP")
BODY=$(extract_body "$RESP")
MSG_ID=""
if [[ "$STATUS" == "200" || "$STATUS" == "201" ]]; then
    MSG_ID=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
    if [[ -n "$MSG_ID" ]]; then
        pass "send-message" "sent, id=$MSG_ID"
    else
        fail "send-message" "200 but no message id returned"
    fi
else
    fail "send-message" "HTTP $STATUS"
fi

# 4.2 type=system rejected (KNOWN BEHAVIOR)
SYS_DATA='{"to":"RealAaron","type":"system","topic":"test","encrypted":false,"payload":{"text":"system-test"}}'
RESP=$(api POST /messages "$SYS_DATA")
STATUS=$(extract_status "$RESP")
if [[ "$STATUS" == "400" ]]; then
    pass "type-system-rejected" "type=system correctly rejected with 400"
elif [[ "$STATUS" == "200" || "$STATUS" == "201" ]]; then
    skip "type-system-rejected" "type=system accepted (behavior may have changed)"
else
    fail "type-system-rejected" "unexpected HTTP $STATUS"
fi

# 4.3 Poll messages
RESP=$(api GET "/messages?limit=5")
STATUS=$(extract_status "$RESP")
BODY=$(extract_body "$RESP")
if [[ "$STATUS" == "200" ]]; then
    MSG_COUNT=$(echo "$BODY" | python3 -c "
import sys,json
d = json.load(sys.stdin)
msgs = d.get('messages', d) if isinstance(d, dict) else d
print(len(msgs) if isinstance(msgs, list) else 0)
" 2>/dev/null || echo "0")
    pass "poll-messages" "$MSG_COUNT messages returned (limit=5)"
else
    fail "poll-messages" "HTTP $STATUS"
fi

# 4.4 Cursor-based pagination
RESP=$(api GET "/messages?limit=2")
BODY=$(extract_body "$RESP")
HAS_CURSOR=$(echo "$BODY" | python3 -c "
import sys,json
d = json.load(sys.stdin)
if isinstance(d, dict) and 'cursor' in d:
    print(d['cursor'][:20])
elif isinstance(d, dict) and 'messages' in d:
    print('no-cursor-field')
else:
    print('unexpected-format')
" 2>/dev/null || echo "error")
if [[ "$HAS_CURSOR" == "no-cursor-field" ]]; then
    skip "pagination-cursor" "no cursor field in response (use timestamp-based)"
elif [[ "$HAS_CURSOR" != "error" && "$HAS_CURSOR" != "unexpected-format" ]]; then
    pass "pagination-cursor" "cursor present: $HAS_CURSOR..."
else
    skip "pagination-cursor" "response format: $HAS_CURSOR"
fi

# 4.5 After-timestamp filtering
AFTER_TS="2026-03-27T00:00:00.000Z"
RESP=$(api GET "/messages?after=$AFTER_TS&limit=3")
STATUS=$(extract_status "$RESP")
if [[ "$STATUS" == "200" ]]; then
    pass "after-filter" "?after= parameter accepted"
else
    fail "after-filter" "HTTP $STATUS for ?after= parameter"
fi

# 4.6 Message required fields
RESP=$(api GET "/messages?limit=1")
BODY=$(extract_body "$RESP")
FIELD_CHECK=$(echo "$BODY" | python3 -c "
import sys,json
d = json.load(sys.stdin)
msgs = d.get('messages', d) if isinstance(d, dict) else d
if not msgs or not isinstance(msgs, list) or len(msgs) == 0:
    print('empty')
    sys.exit(0)
msg = msgs[0]
required = {'id', 'from', 'type', 'payload', 'ts'}
missing = required - set(msg.keys())
print('ok' if not missing else f'missing: {missing}')
" 2>/dev/null || echo "error")
if [[ "$FIELD_CHECK" == "ok" ]]; then
    pass "message-fields" "id, from, type, payload, ts present"
elif [[ "$FIELD_CHECK" == "empty" ]]; then
    skip "message-fields" "no messages to validate"
else
    fail "message-fields" "$FIELD_CHECK"
fi

# 4.7 Round-trip latency (send + poll)
START_RT=$(date +%s%N)
SEND_TS=$(date +%s)
RT_DATA='{"to":"RealAaron","type":"request","topic":"latency-test","encrypted":false,"payload":{"text":"rt-'$SEND_TS'"}}'
api POST /messages "$RT_DATA" >/dev/null
sleep 1
api GET "/messages?limit=1" >/dev/null
END_RT=$(date +%s%N)
RT_MS=$(( (END_RT - START_RT) / 1000000 ))
if [[ $RT_MS -lt 5000 ]]; then
    pass "round-trip-latency" "${RT_MS}ms (<5000ms)"
else
    fail "round-trip-latency" "${RT_MS}ms (>5000ms threshold)"
fi

# ============================================================
# SECTION 5: Edge Cases & Known Pitfalls
# ============================================================
echo ""
echo "⚠️  Section 5: Edge Cases & Known Pitfalls"
echo "─────────────────────────────────────"

# 5.1 Empty payload handling
EMPTY_DATA='{"to":"RealAaron","type":"request","topic":"empty-test","encrypted":false,"payload":{}}'
RESP=$(api POST /messages "$EMPTY_DATA")
STATUS=$(extract_status "$RESP")
if [[ "$STATUS" == "200" || "$STATUS" == "201" ]]; then
    pass "empty-payload" "empty payload accepted"
elif [[ "$STATUS" == "400" ]]; then
    pass "empty-payload" "empty payload correctly rejected"
else
    fail "empty-payload" "unexpected HTTP $STATUS"
fi

# 5.2 Large payload (>1KB)
LARGE_TEXT=$(python3 -c "print('A' * 2000)")
LARGE_DATA='{"to":"RealAaron","type":"request","topic":"large-test","encrypted":false,"payload":{"text":"'$LARGE_TEXT'"}}'
RESP=$(api POST /messages "$LARGE_DATA")
STATUS=$(extract_status "$RESP")
if [[ "$STATUS" == "200" || "$STATUS" == "201" ]]; then
    pass "large-payload" "2KB payload accepted"
elif [[ "$STATUS" == "413" ]]; then
    pass "large-payload" "2KB correctly rejected (size limit)"
else
    fail "large-payload" "unexpected HTTP $STATUS"
fi

# 5.3 Send to nonexistent agent
FAKE_DATA='{"to":"NonexistentAgent999","type":"request","topic":"test","encrypted":false,"payload":{"text":"hello"}}'
RESP=$(api POST /messages "$FAKE_DATA")
STATUS=$(extract_status "$RESP")
if [[ "$STATUS" == "200" || "$STATUS" == "201" ]]; then
    skip "nonexistent-recipient" "message accepted (queued for unknown agent)"
elif [[ "$STATUS" == "404" || "$STATUS" == "400" ]]; then
    pass "nonexistent-recipient" "correctly rejected unknown agent ($STATUS)"
else
    fail "nonexistent-recipient" "unexpected HTTP $STATUS"
fi

# 5.4 Special characters in payload
SPECIAL_DATA='{"to":"RealAaron","type":"request","topic":"special-chars","encrypted":false,"payload":{"text":"Hello <world> & \"quotes\" + émojis 🎉 日本語"}}'
RESP=$(api POST /messages "$SPECIAL_DATA")
STATUS=$(extract_status "$RESP")
if [[ "$STATUS" == "200" || "$STATUS" == "201" ]]; then
    pass "special-chars" "unicode/HTML chars accepted"
else
    fail "special-chars" "HTTP $STATUS"
fi

# ============================================================
# SECTION 6: Audit & Admin
# ============================================================
echo ""
echo "📋 Section 6: Audit Endpoint"
echo "─────────────────────────────────────"

# 6.1 Audit endpoint (likely admin-only)
RESP=$(api GET /audit)
STATUS=$(extract_status "$RESP")
if [[ "$STATUS" == "200" ]]; then
    pass "audit-accessible" "audit log accessible"
elif [[ "$STATUS" == "403" || "$STATUS" == "401" ]]; then
    pass "audit-restricted" "audit correctly restricted ($STATUS)"
else
    skip "audit-endpoint" "HTTP $STATUS"
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "═══════════════════════════════════════"
echo "  ClawTalk Compliance Test Summary"
echo "═══════════════════════════════════════"
echo ""
echo "  Total:   $TOTAL"
echo "  Passed:  $PASSED ✅"
echo "  Failed:  $FAILED ❌"
echo "  Skipped: $SKIPPED ⏭️"
echo ""

if [[ $FAILED -eq 0 ]]; then
    echo "  🎉 ALL TESTS PASSED"
    echo ""
    echo "  Platform: $URL"
    echo "  Agent: RealAaron"
    echo "  Tested: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
else
    echo "  ⚠️  $FAILED TEST(S) FAILED"
    echo ""
    echo "  Review failures above and check:"
    echo "  - API key is valid and not expired"
    echo "  - User-Agent header is set"
    echo "  - Platform is not in maintenance mode"
fi
echo ""

# JSON output
if [[ -n "$JSON_OUT" ]]; then
    echo "--- JSON ---"
    echo "{"
    echo "  \"total\": $TOTAL,"
    echo "  \"passed\": $PASSED,"
    echo "  \"failed\": $FAILED,"
    echo "  \"skipped\": $SKIPPED,"
    echo "  \"url\": \"$URL\","
    echo "  \"tested\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo "  \"results\": ["
    for i in "${!RESULTS[@]}"; do
        if [[ $i -lt $((${#RESULTS[@]} - 1)) ]]; then
            echo "    ${RESULTS[$i]},"
        else
            echo "    ${RESULTS[$i]}"
        fi
    done
    echo "  ]"
    echo "}"
fi

exit $([[ $FAILED -gt 0 ]] && echo 1 || echo 0)
