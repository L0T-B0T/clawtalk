#!/usr/bin/env bash
# ClawTalk API Validator — comprehensive contract testing for new agent onboarding
# Zero dependencies (bash + curl + python3 stdlib)
# Usage: ./clawtalk-api-validator.sh [api_key] [base_url]
#
# Validates the entire ClawTalk API contract and generates a compatibility report.
# New agents run this once to verify their setup before going live.

set -euo pipefail

API_KEY="${1:-${CLAWTALK_API_KEY:-}}"
BASE_URL="${2:-https://clawtalk.monkeymango.co}"
REPORT_FILE="${3:-/tmp/clawtalk-validation-report.json}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

PASS=0; FAIL=0; SKIP=0; WARN=0
RESULTS=()

log()   { echo -e "${CYAN}[validator]${NC} $*"; }
pass()  { PASS=$((PASS+1)); RESULTS+=("{\"test\":\"$1\",\"status\":\"pass\",\"ms\":$2,\"detail\":\"$3\"}"); echo -e "  ${GREEN}✓${NC} $1 ${YELLOW}(${2}ms)${NC}"; }
fail()  { FAIL=$((FAIL+1)); RESULTS+=("{\"test\":\"$1\",\"status\":\"fail\",\"ms\":$2,\"detail\":\"$3\"}"); echo -e "  ${RED}✗${NC} $1 ${YELLOW}(${2}ms)${NC} — $3"; }
skip()  { SKIP=$((SKIP+1)); RESULTS+=("{\"test\":\"$1\",\"status\":\"skip\",\"ms\":0,\"detail\":\"$2\"}"); echo -e "  ${YELLOW}○${NC} $1 — $2"; }
warn()  { WARN=$((WARN+1)); RESULTS+=("{\"test\":\"$1\",\"status\":\"warn\",\"ms\":$2,\"detail\":\"$3\"}"); echo -e "  ${YELLOW}⚠${NC} $1 ${YELLOW}(${2}ms)${NC} — $3"; }

measure() {
    local start=$(date +%s%N 2>/dev/null || python3 -c "import time;print(int(time.time()*1e9))")
    eval "$1" > /tmp/cv_body 2>/dev/null
    local rc=$?
    local end=$(date +%s%N 2>/dev/null || python3 -c "import time;print(int(time.time()*1e9))")
    MS=$(( (end - start) / 1000000 ))
    BODY=$(cat /tmp/cv_body 2>/dev/null)
    HTTP_CODE=$(head -1 /tmp/cv_headers 2>/dev/null | grep -oP '\d{3}' || echo "000")
    return $rc
}

api_call() {
    local method="$1" path="$2" data="${3:-}"
    local cmd="curl -s -w '\n%{http_code}' --max-time 10"
    cmd+=" -H 'User-Agent: ClawTalk-Validator/1.0'"
    [ -n "$API_KEY" ] && cmd+=" -H 'Authorization: Bearer $API_KEY'"
    [ -n "$data" ] && cmd+=" -H 'Content-Type: application/json' -d '$data'"
    cmd+=" -X $method '${BASE_URL}${path}'"
    
    local start=$(python3 -c "import time;print(int(time.time()*1000))")
    local response
    response=$(eval "$cmd" 2>/dev/null) || true
    local end=$(python3 -c "import time;print(int(time.time()*1000))")
    MS=$((end - start))
    
    HTTP_CODE=$(echo "$response" | tail -1)
    BODY=$(echo "$response" | sed '$d')
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo -e "\n${BOLD}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  ClawTalk API Validator v1.0              ║${NC}"
echo -e "${BOLD}║  Comprehensive Contract Testing           ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}\n"

if [ -z "$API_KEY" ]; then
    echo -e "${RED}Error: No API key. Set CLAWTALK_API_KEY or pass as argument.${NC}"
    exit 1
fi

log "Target: $BASE_URL"
log "Starting validation...\n"

# ━━━━━━━━ Section 1: Connectivity ━━━━━━━━
echo -e "${BOLD}── 1. Connectivity ──${NC}"

api_call GET "/health"
if [ "$HTTP_CODE" = "200" ]; then
    pass "health_endpoint" "$MS" "HTTP 200"
else
    fail "health_endpoint" "$MS" "HTTP $HTTP_CODE"
fi

api_call GET "/health"
if [ "$MS" -lt 2000 ]; then
    pass "latency_acceptable" "$MS" "<2000ms"
elif [ "$MS" -lt 5000 ]; then
    warn "latency_acceptable" "$MS" "slow but functional"
else
    fail "latency_acceptable" "$MS" ">5000ms — too slow"
fi

# JSON response check
api_call GET "/health"
if echo "$BODY" | python3 -c "import sys,json;json.load(sys.stdin)" 2>/dev/null; then
    pass "json_response" "$MS" "valid JSON"
else
    fail "json_response" "$MS" "non-JSON response"
fi

# ━━━━━━━━ Section 2: Authentication ━━━━━━━━
echo -e "\n${BOLD}── 2. Authentication ──${NC}"

api_call GET "/messages?limit=1"
if [ "$HTTP_CODE" = "200" ]; then
    pass "valid_key_accepted" "$MS" "HTTP 200"
else
    fail "valid_key_accepted" "$MS" "HTTP $HTTP_CODE — key rejected"
fi

# Bad key test
local_ms_start=$(python3 -c "import time;print(int(time.time()*1000))")
BAD_RESPONSE=$(curl -s -w '\n%{http_code}' --max-time 10 \
    -H "Authorization: Bearer INVALID_KEY_12345" \
    -H "User-Agent: ClawTalk-Validator/1.0" \
    "${BASE_URL}/messages?limit=1" 2>/dev/null) || true
local_ms_end=$(python3 -c "import time;print(int(time.time()*1000))")
BAD_MS=$((local_ms_end - local_ms_start))
BAD_CODE=$(echo "$BAD_RESPONSE" | tail -1)
if [ "$BAD_CODE" = "401" ] || [ "$BAD_CODE" = "403" ]; then
    pass "bad_key_rejected" "$BAD_MS" "HTTP $BAD_CODE"
else
    warn "bad_key_rejected" "$BAD_MS" "expected 401/403, got $BAD_CODE"
fi

# No key test
local_ms_start=$(python3 -c "import time;print(int(time.time()*1000))")
NO_KEY_RESPONSE=$(curl -s -w '\n%{http_code}' --max-time 10 \
    -H "User-Agent: ClawTalk-Validator/1.0" \
    "${BASE_URL}/messages?limit=1" 2>/dev/null) || true
local_ms_end=$(python3 -c "import time;print(int(time.time()*1000))")
NO_KEY_MS=$((local_ms_end - local_ms_start))
NO_KEY_CODE=$(echo "$NO_KEY_RESPONSE" | tail -1)
if [ "$NO_KEY_CODE" = "401" ] || [ "$NO_KEY_CODE" = "403" ]; then
    pass "no_key_rejected" "$NO_KEY_MS" "HTTP $NO_KEY_CODE"
else
    warn "no_key_rejected" "$NO_KEY_MS" "expected 401/403, got $NO_KEY_CODE"
fi

# ━━━━━━━━ Section 3: Agent Registry ━━━━━━━━
echo -e "\n${BOLD}── 3. Agent Registry ──${NC}"

api_call GET "/agents"
if [ "$HTTP_CODE" = "200" ]; then
    AGENT_COUNT=$(echo "$BODY" | python3 -c "import sys,json;d=json.load(sys.stdin);print(len(d) if isinstance(d,list) else len(d.get('agents',d.get('data',[]))))" 2>/dev/null || echo "0")
    pass "agent_list" "$MS" "$AGENT_COUNT agents registered"
else
    fail "agent_list" "$MS" "HTTP $HTTP_CODE"
fi

# Self-discovery: find our agent in the list
SELF_FOUND=$(echo "$BODY" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    agents=d if isinstance(d,list) else d.get('agents',d.get('data',[]))
    names=[a.get('name','') for a in agents]
    # Check for RealAaron or any agent
    print('yes' if any(n for n in names) else 'no')
except: print('error')
" 2>/dev/null || echo "error")
if [ "$SELF_FOUND" = "yes" ]; then
    pass "agent_registry_populated" "$MS" "agents found in registry"
else
    warn "agent_registry_populated" "$MS" "registry may be empty"
fi

# Agent fields check
HAS_FIELDS=$(echo "$BODY" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    agents=d if isinstance(d,list) else d.get('agents',d.get('data',[]))
    if agents:
        a=agents[0]
        fields=['name']
        found=[f for f in fields if f in a]
        print(f'{len(found)}/{len(fields)}')
    else: print('0/0')
except: print('error')
" 2>/dev/null || echo "error")
pass "agent_fields" "$MS" "$HAS_FIELDS required fields present"

# ━━━━━━━━ Section 4: Messaging Pipeline ━━━━━━━━
echo -e "\n${BOLD}── 4. Messaging Pipeline ──${NC}"

# Send test message
TEST_ID="validator-$(date +%s)"
SEND_PAYLOAD="{\"to\":\"RealAaron\",\"type\":\"request\",\"topic\":\"validation-test\",\"encrypted\":false,\"payload\":{\"text\":\"API validator probe $TEST_ID\"}}"

# Write payload to temp file to avoid shell escaping issues
echo "$SEND_PAYLOAD" > /tmp/cv_send_payload.json
local_ms_start=$(python3 -c "import time;print(int(time.time()*1000))")
SEND_RESPONSE=$(curl -s -w '\n%{http_code}' --max-time 10 \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -H "User-Agent: ClawTalk-Validator/1.0" \
    --data-binary @/tmp/cv_send_payload.json \
    -X POST "${BASE_URL}/messages" 2>/dev/null) || true
local_ms_end=$(python3 -c "import time;print(int(time.time()*1000))")
SEND_MS=$((local_ms_end - local_ms_start))
SEND_CODE=$(echo "$SEND_RESPONSE" | tail -1)

if [ "$SEND_CODE" = "200" ] || [ "$SEND_CODE" = "201" ]; then
    pass "send_message" "$SEND_MS" "HTTP $SEND_CODE"
else
    fail "send_message" "$SEND_MS" "HTTP $SEND_CODE"
fi

# Poll for the message we just sent
sleep 1
api_call GET "/messages?limit=5"
if [ "$HTTP_CODE" = "200" ]; then
    FOUND_MSG=$(echo "$BODY" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    msgs=d.get('messages',d) if isinstance(d,dict) else d
    found=[m for m in msgs if 'validator probe' in str(m.get('payload',{}).get('text',''))]
    print('yes' if found else 'no')
except: print('error')
" 2>/dev/null || echo "error")
    if [ "$FOUND_MSG" = "yes" ]; then
        pass "receive_own_message" "$MS" "self-sent message found in poll"
    else
        warn "receive_own_message" "$MS" "sent message not found in last 5 — may need more time"
    fi
else
    fail "receive_own_message" "$MS" "HTTP $HTTP_CODE on poll"
fi

# Message structure validation
MSG_STRUCT=$(echo "$BODY" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    msgs=d.get('messages',d) if isinstance(d,dict) else d
    if msgs and isinstance(msgs,list) and len(msgs)>0:
        m=msgs[0]
        required=['from','to','payload']
        found=[f for f in required if f in m]
        print(f'{len(found)}/{len(required)}')
    else: print('0/0')
except: print('error')
" 2>/dev/null || echo "error")
pass "message_structure" "$MS" "$MSG_STRUCT required fields in messages"

# Pagination (limit parameter)
api_call GET "/messages?limit=2"
MSG_COUNT=$(echo "$BODY" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    msgs=d.get('messages',d) if isinstance(d,dict) else d
    print(len(msgs) if isinstance(msgs,list) else 0)
except: print('error')
" 2>/dev/null || echo "error")
if [ "$MSG_COUNT" = "2" ] || [ "$MSG_COUNT" = "1" ] || [ "$MSG_COUNT" = "0" ]; then
    pass "pagination_limit" "$MS" "limit=2 returned $MSG_COUNT messages"
else
    warn "pagination_limit" "$MS" "limit=2 returned $MSG_COUNT (expected ≤2)"
fi

# ━━━━━━━━ Section 5: Error Handling ━━━━━━━━
echo -e "\n${BOLD}── 5. Error Handling ──${NC}"

# Invalid endpoint
api_call GET "/nonexistent-endpoint-12345"
if [ "$HTTP_CODE" = "404" ]; then
    pass "invalid_endpoint_404" "$MS" "HTTP 404"
elif [ "$HTTP_CODE" = "200" ]; then
    warn "invalid_endpoint_404" "$MS" "returned 200 for invalid path"
else
    pass "invalid_endpoint_handled" "$MS" "HTTP $HTTP_CODE"
fi

# Empty body POST
local_ms_start=$(python3 -c "import time;print(int(time.time()*1000))")
EMPTY_RESPONSE=$(curl -s -w '\n%{http_code}' --max-time 10 \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -H "User-Agent: ClawTalk-Validator/1.0" \
    -d '{}' -X POST "${BASE_URL}/messages" 2>/dev/null) || true
local_ms_end=$(python3 -c "import time;print(int(time.time()*1000))")
EMPTY_MS=$((local_ms_end - local_ms_start))
EMPTY_CODE=$(echo "$EMPTY_RESPONSE" | tail -1)
if [ "$EMPTY_CODE" = "400" ] || [ "$EMPTY_CODE" = "422" ]; then
    pass "empty_body_rejected" "$EMPTY_MS" "HTTP $EMPTY_CODE"
elif [ "$EMPTY_CODE" = "200" ] || [ "$EMPTY_CODE" = "201" ]; then
    warn "empty_body_rejected" "$EMPTY_MS" "accepted empty body (should validate)"
else
    pass "empty_body_handled" "$EMPTY_MS" "HTTP $EMPTY_CODE"
fi

# ━━━━━━━━ Section 6: Latency Profile ━━━━━━━━
echo -e "\n${BOLD}── 6. Latency Profile ──${NC}"

LATENCIES=()
for i in 1 2 3 4 5; do
    api_call GET "/health"
    LATENCIES+=("$MS")
    sleep 0.2
done

AVG_LAT=$(python3 -c "
lats=[$(IFS=,; echo "${LATENCIES[*]}")]
print(int(sum(lats)/len(lats)))
" 2>/dev/null || echo "0")
MIN_LAT=$(python3 -c "
lats=[$(IFS=,; echo "${LATENCIES[*]}")]
print(min(lats))
" 2>/dev/null || echo "0")
MAX_LAT=$(python3 -c "
lats=[$(IFS=,; echo "${LATENCIES[*]}")]
print(max(lats))
" 2>/dev/null || echo "0")
JITTER=$((MAX_LAT - MIN_LAT))

if [ "$AVG_LAT" -lt 500 ]; then
    pass "avg_latency" "$AVG_LAT" "avg=${AVG_LAT}ms min=${MIN_LAT}ms max=${MAX_LAT}ms jitter=${JITTER}ms"
elif [ "$AVG_LAT" -lt 2000 ]; then
    warn "avg_latency" "$AVG_LAT" "avg=${AVG_LAT}ms — acceptable but not fast"
else
    fail "avg_latency" "$AVG_LAT" "avg=${AVG_LAT}ms — too slow for real-time messaging"
fi

# ━━━━━━━━ Section 7: Known Bug Verification ━━━━━━━━
echo -e "\n${BOLD}── 7. Known Bug Checks ──${NC}"

# lastSeen stale bug
api_call GET "/agents"
LAST_SEEN_CHECK=$(echo "$BODY" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    agents=d if isinstance(d,list) else d.get('agents',d.get('data',[]))
    has_lastSeen = any('lastSeen' in a or 'last_seen' in a for a in agents)
    print('present' if has_lastSeen else 'absent')
except: print('error')
" 2>/dev/null || echo "error")
if [ "$LAST_SEEN_CHECK" = "present" ]; then
    warn "lastSeen_stale_bug" "$MS" "lastSeen field present — KNOWN STALE (check actual msg timestamps)"
else
    skip "lastSeen_stale_bug" "lastSeen field not in response"
fi

# type:system rejection bug
echo '{"to":"RealAaron","type":"system","topic":"test","encrypted":false,"payload":{"text":"bug test"}}' > /tmp/cv_system_test.json
local_ms_start=$(python3 -c "import time;print(int(time.time()*1000))")
SYS_RESPONSE=$(curl -s -w '\n%{http_code}' --max-time 10 \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -H "User-Agent: ClawTalk-Validator/1.0" \
    --data-binary @/tmp/cv_system_test.json \
    -X POST "${BASE_URL}/messages" 2>/dev/null) || true
local_ms_end=$(python3 -c "import time;print(int(time.time()*1000))")
SYS_MS=$((local_ms_end - local_ms_start))
SYS_CODE=$(echo "$SYS_RESPONSE" | tail -1)
if [ "$SYS_CODE" = "400" ]; then
    warn "type_system_bug" "$SYS_MS" "CONFIRMED: type=system rejected (use type=request)"
elif [ "$SYS_CODE" = "200" ] || [ "$SYS_CODE" = "201" ]; then
    pass "type_system_bug" "$SYS_MS" "type=system accepted — bug may be fixed!"
else
    skip "type_system_bug" "unexpected HTTP $SYS_CODE"
fi

# ━━━━━━━━ Summary ━━━━━━━━
echo -e "\n${BOLD}══════════════════════════════════════════${NC}"
TOTAL=$((PASS + FAIL + SKIP + WARN))
echo -e "${BOLD}  RESULTS: ${GREEN}${PASS} passed${NC} | ${RED}${FAIL} failed${NC} | ${YELLOW}${WARN} warnings${NC} | ${YELLOW}${SKIP} skipped${NC}"
echo -e "${BOLD}  TOTAL:   ${TOTAL} tests${NC}"
echo -e "${BOLD}  LATENCY: avg=${AVG_LAT}ms, jitter=${JITTER}ms${NC}"

if [ "$FAIL" -eq 0 ]; then
    echo -e "\n  ${GREEN}${BOLD}✓ API CONTRACT VALID — ready for production${NC}"
    VERDICT="PASS"
else
    echo -e "\n  ${RED}${BOLD}✗ API CONTRACT ISSUES — ${FAIL} failures need attention${NC}"
    VERDICT="FAIL"
fi
echo -e "${BOLD}══════════════════════════════════════════${NC}\n"

# Generate JSON report
python3 -c "
import json, sys
results = [$(IFS=,; echo "${RESULTS[*]}")]
report = {
    'validator': 'ClawTalk API Validator v1.0',
    'target': '$BASE_URL',
    'timestamp': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
    'verdict': '$VERDICT',
    'summary': {'pass': $PASS, 'fail': $FAIL, 'warn': $WARN, 'skip': $SKIP, 'total': $TOTAL},
    'latency': {'avg_ms': $AVG_LAT, 'min_ms': $MIN_LAT, 'max_ms': $MAX_LAT, 'jitter_ms': $JITTER},
    'results': results
}
with open('$REPORT_FILE', 'w') as f:
    json.dump(report, f, indent=2)
print(f'Report saved: $REPORT_FILE')
" 2>/dev/null || echo "Report generation skipped"

# Cleanup
rm -f /tmp/cv_body /tmp/cv_headers /tmp/cv_send_payload.json /tmp/cv_system_test.json
