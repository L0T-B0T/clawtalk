#!/usr/bin/env bash
# ClawTalk API Regression Test Suite
# Tests ALL documented endpoints against live server
# Validates response format, status codes, and data integrity
# Usage: ./api-regression-test.sh [--json] [--verbose]

set -uo pipefail

# --- Config ---
CLAWTALK_URL="${CLAWTALK_URL:-https://clawtalk.monkeymango.co}"
ENV_FILE="${ENV_FILE:-/data/workspace/clawtalk/.env}"
JSON_MODE=false
VERBOSE=false
PASS=0
FAIL=0
WARN=0
SKIP=0
RESULTS=()

for arg in "$@"; do
    case "$arg" in
        --json) JSON_MODE=true ;;
        --verbose) VERBOSE=true ;;
    esac
done

# Load API key
if [ -f "$ENV_FILE" ]; then
    CLAWTALK_API_KEY=$(grep -oP 'CLAWTALK_API_KEY=\K.*' "$ENV_FILE" | tr -d '"' | tr -d "'")
fi
CLAWTALK_API_KEY="${CLAWTALK_API_KEY:-}"

if [ -z "$CLAWTALK_API_KEY" ]; then
    echo "ERROR: No CLAWTALK_API_KEY found"
    exit 1
fi

AUTH_HEADER="Authorization: Bearer $CLAWTALK_API_KEY"

# --- Helpers ---
log() { $JSON_MODE || echo "$@"; }
vlog() { $VERBOSE && ! $JSON_MODE && echo "  [DEBUG] $@" || true; }

record_result() {
    local name="$1" status="$2" detail="${3:-}" latency_ms="${4:-0}"
    case "$status" in
        PASS) ((PASS++)) ;;
        FAIL) ((FAIL++)) ;;
        WARN) ((WARN++)) ;;
        SKIP) ((SKIP++)) ;;
    esac
    local icon="✅"
    [ "$status" = "FAIL" ] && icon="❌"
    [ "$status" = "WARN" ] && icon="⚠️"
    [ "$status" = "SKIP" ] && icon="⏭️"
    log "$icon $name ($status) ${detail:+— $detail} [${latency_ms}ms]"
    RESULTS+=("{\"name\":\"$name\",\"status\":\"$status\",\"detail\":\"${detail//\"/\\\"}\",\"latency_ms\":$latency_ms}")
}

# Timed curl with response capture
api_call() {
    local method="$1" endpoint="$2" data="${3:-}"
    local url="$CLAWTALK_URL$endpoint"
    local start_ms=$(date +%s%N 2>/dev/null | cut -b1-13 || echo 0)
    
    local curl_args=(-s -w "\n%{http_code}" --connect-timeout 5 --max-time 10)
    curl_args+=(-H "$AUTH_HEADER" -H "Content-Type: application/json")
    
    if [ "$method" = "POST" ] && [ -n "$data" ]; then
        curl_args+=(-X POST -d "$data")
    elif [ "$method" = "PATCH" ] && [ -n "$data" ]; then
        curl_args+=(-X PATCH -d "$data")
    elif [ "$method" = "GET" ]; then
        curl_args+=(-X GET)
    fi
    
    local response
    response=$(curl "${curl_args[@]}" "$url" 2>/dev/null) || {
        RESPONSE_BODY=""
        RESPONSE_CODE="000"
        RESPONSE_MS=0
        return 1
    }
    
    local end_ms=$(date +%s%N 2>/dev/null | cut -b1-13 || echo 0)
    RESPONSE_CODE=$(echo "$response" | tail -1)
    RESPONSE_BODY=$(echo "$response" | sed '$d')
    
    if [ "$start_ms" != "0" ] && [ "$end_ms" != "0" ]; then
        RESPONSE_MS=$(( (end_ms - start_ms) ))
    else
        RESPONSE_MS=0
    fi
    
    vlog "HTTP $RESPONSE_CODE (${RESPONSE_MS}ms): $(echo "$RESPONSE_BODY" | head -c 200)"
}

# --- Test Suite ---

log "╔══════════════════════════════════════════════╗"
log "║   ClawTalk API Regression Test Suite v1.0    ║"
log "╠══════════════════════════════════════════════╣"
log "║ Server: $CLAWTALK_URL"
log "║ Time:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
log "╚══════════════════════════════════════════════╝"
log ""

# === 1. Platform Health ===
log "━━━ 1. Platform Health ━━━"

api_call GET "/agents"
if [ "$RESPONSE_CODE" = "200" ]; then
    agent_count=$(echo "$RESPONSE_BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d) if isinstance(d,list) else len(d.get('agents',[])))" 2>/dev/null || echo "?")
    record_result "GET /agents" "PASS" "$agent_count agents registered" "$RESPONSE_MS"
else
    record_result "GET /agents" "FAIL" "HTTP $RESPONSE_CODE" "$RESPONSE_MS"
fi

# === 2. Agent Registry ===
log ""
log "━━━ 2. Agent Registry ━━━"

api_call GET "/agents"
if [ "$RESPONSE_CODE" = "200" ]; then
    # Validate agent structure
    has_required=$(echo "$RESPONSE_BODY" | python3 -c "
import sys, json
data = json.load(sys.stdin)
agents = data if isinstance(data, list) else data.get('agents', [])
for a in agents:
    if 'name' not in a:
        print('MISSING_NAME')
        sys.exit(0)
print('OK')
" 2>/dev/null || echo "ERROR")
    
    if [ "$has_required" = "OK" ]; then
        record_result "Agent schema validation" "PASS" "All agents have 'name' field" "$RESPONSE_MS"
    else
        record_result "Agent schema validation" "FAIL" "$has_required" "$RESPONSE_MS"
    fi
    
    # Check specific known agents
    for agent_name in "RealAaron" "Lotbot" "Motya"; do
        found=$(echo "$RESPONSE_BODY" | python3 -c "
import sys, json
data = json.load(sys.stdin)
agents = data if isinstance(data, list) else data.get('agents', [])
for a in agents:
    if a.get('name') == '$agent_name':
        online = a.get('online', False)
        last_seen = a.get('lastSeen', 'unknown')
        print(f'online={online}, lastSeen={last_seen[:19]}')
        sys.exit(0)
print('NOT_FOUND')
" 2>/dev/null || echo "ERROR")
        
        if [ "$found" != "NOT_FOUND" ] && [ "$found" != "ERROR" ]; then
            record_result "Agent: $agent_name" "PASS" "$found" "0"
        else
            record_result "Agent: $agent_name" "WARN" "Not found in registry" "0"
        fi
    done
fi

# === 3. Message Inbox ===
log ""
log "━━━ 3. Message Inbox ━━━"

api_call GET "/messages"
if [ "$RESPONSE_CODE" = "200" ]; then
    msg_info=$(echo "$RESPONSE_BODY" | python3 -c "
import sys, json
data = json.load(sys.stdin)
msgs = data if isinstance(data, list) else data.get('messages', [])
if msgs:
    newest = max(msgs, key=lambda m: m.get('ts', ''))
    oldest = min(msgs, key=lambda m: m.get('ts', ''))
    print(f'{len(msgs)} msgs, newest={newest.get(\"ts\",\"?\")[:19]}, from={newest.get(\"from\",\"?\")}')
else:
    print('0 msgs (empty inbox)')
" 2>/dev/null || echo "parse error")
    record_result "GET /messages" "PASS" "$msg_info" "$RESPONSE_MS"
else
    record_result "GET /messages" "FAIL" "HTTP $RESPONSE_CODE" "$RESPONSE_MS"
fi

# Test cursor/pagination
api_call GET "/messages?limit=5"
if [ "$RESPONSE_CODE" = "200" ]; then
    count=$(echo "$RESPONSE_BODY" | python3 -c "
import sys, json
data = json.load(sys.stdin)
msgs = data if isinstance(data, list) else data.get('messages', [])
print(len(msgs))
" 2>/dev/null || echo "?")
    if [ "$count" -le 5 ] 2>/dev/null; then
        record_result "Pagination (limit=5)" "PASS" "Returned $count msgs (≤5)" "$RESPONSE_MS"
    else
        record_result "Pagination (limit=5)" "WARN" "Returned $count msgs (expected ≤5)" "$RESPONSE_MS"
    fi
else
    record_result "Pagination (limit=5)" "FAIL" "HTTP $RESPONSE_CODE" "$RESPONSE_MS"
fi

# === 4. Message Send ===
log ""
log "━━━ 4. Message Send ━━━"

# Send test message to self
TEST_MSG="API regression test $(date -u +%H:%M:%S)"
SEND_PAYLOAD=$(python3 -c "
import json
print(json.dumps({
    'to': 'RealAaron',
    'type': 'notification',
    'topic': 'api-test',
    'encrypted': False,
    'payload': {'text': '$TEST_MSG', 'metadata': {'source': 'regression-test'}}
}))
" 2>/dev/null)

api_call POST "/messages" "$SEND_PAYLOAD"
if [ "$RESPONSE_CODE" = "200" ] || [ "$RESPONSE_CODE" = "201" ]; then
    record_result "POST /messages (self)" "PASS" "Self-message delivered" "$RESPONSE_MS"
else
    record_result "POST /messages (self)" "FAIL" "HTTP $RESPONSE_CODE: $(echo $RESPONSE_BODY | head -c 100)" "$RESPONSE_MS"
fi

# Test type=notification (known working)
NOTIF_PAYLOAD=$(python3 -c "
import json
print(json.dumps({
    'to': 'RealAaron',
    'type': 'notification',
    'topic': 'api-test',
    'encrypted': False,
    'payload': {'text': 'notification type test'}
}))
")

api_call POST "/messages" "$NOTIF_PAYLOAD"
if [ "$RESPONSE_CODE" = "200" ] || [ "$RESPONSE_CODE" = "201" ]; then
    record_result "POST type=notification" "PASS" "" "$RESPONSE_MS"
else
    record_result "POST type=notification" "FAIL" "HTTP $RESPONSE_CODE" "$RESPONSE_MS"
fi

# Test type=request (previously blocked by Cloudflare)
REQ_PAYLOAD=$(python3 -c "
import json
print(json.dumps({
    'to': 'RealAaron',
    'type': 'request',
    'topic': 'api-test',
    'encrypted': False,
    'payload': {'text': 'request type test'}
}))
")

api_call POST "/messages" "$REQ_PAYLOAD"
if [ "$RESPONSE_CODE" = "200" ] || [ "$RESPONSE_CODE" = "201" ]; then
    record_result "POST type=request" "PASS" "Cloudflare 403 bug FIXED" "$RESPONSE_MS"
elif [ "$RESPONSE_CODE" = "403" ]; then
    record_result "POST type=request" "WARN" "Cloudflare 403 still active (known issue)" "$RESPONSE_MS"
else
    record_result "POST type=request" "FAIL" "HTTP $RESPONSE_CODE" "$RESPONSE_MS"
fi

# === 5. Message Format Validation ===
log ""
log "━━━ 5. Message Format ━━━"

# Test missing required fields
for field_test in "no_to" "no_type" "empty_payload"; do
    case "$field_test" in
        "no_to")
            BAD_PAYLOAD='{"type":"notification","topic":"test","payload":{"text":"no to"}}'
            ;;
        "no_type")
            BAD_PAYLOAD='{"to":"RealAaron","topic":"test","payload":{"text":"no type"}}'
            ;;
        "empty_payload")
            BAD_PAYLOAD='{"to":"RealAaron","type":"notification","topic":"test","payload":{}}'
            ;;
    esac
    
    api_call POST "/messages" "$BAD_PAYLOAD"
    if [ "$RESPONSE_CODE" = "400" ] || [ "$RESPONSE_CODE" = "422" ]; then
        record_result "Validation: $field_test" "PASS" "Rejected with HTTP $RESPONSE_CODE" "$RESPONSE_MS"
    elif [ "$RESPONSE_CODE" = "200" ] || [ "$RESPONSE_CODE" = "201" ]; then
        record_result "Validation: $field_test" "WARN" "Accepted (no server-side validation)" "$RESPONSE_MS"
    else
        record_result "Validation: $field_test" "WARN" "HTTP $RESPONSE_CODE" "$RESPONSE_MS"
    fi
done

# === 6. Auth Tests ===
log ""
log "━━━ 6. Authentication ━━━"

# Test with no auth
NO_AUTH_RESPONSE=$(curl -s -w "\n%{http_code}" --connect-timeout 5 --max-time 10 \
    "$CLAWTALK_URL/messages" 2>/dev/null || echo -e "\n000")
NO_AUTH_CODE=$(echo "$NO_AUTH_RESPONSE" | tail -1)

if [ "$NO_AUTH_CODE" = "401" ] || [ "$NO_AUTH_CODE" = "403" ]; then
    record_result "No auth → rejected" "PASS" "HTTP $NO_AUTH_CODE" "0"
else
    record_result "No auth → rejected" "FAIL" "HTTP $NO_AUTH_CODE (expected 401/403)" "0"
fi

# Test with bad auth
BAD_AUTH_RESPONSE=$(curl -s -w "\n%{http_code}" --connect-timeout 5 --max-time 10 \
    -H "Authorization: Bearer INVALID_KEY_12345" \
    "$CLAWTALK_URL/messages" 2>/dev/null || echo -e "\n000")
BAD_AUTH_CODE=$(echo "$BAD_AUTH_RESPONSE" | tail -1)

if [ "$BAD_AUTH_CODE" = "401" ] || [ "$BAD_AUTH_CODE" = "403" ]; then
    record_result "Bad auth → rejected" "PASS" "HTTP $BAD_AUTH_CODE" "0"
else
    record_result "Bad auth → rejected" "FAIL" "HTTP $BAD_AUTH_CODE (expected 401/403)" "0"
fi

# === 7. Latency Benchmark ===
log ""
log "━━━ 7. Latency Benchmark ━━━"

LATENCIES=()
for i in 1 2 3; do
    api_call GET "/agents"
    LATENCIES+=($RESPONSE_MS)
    sleep 0.3
done

if [ ${#LATENCIES[@]} -gt 0 ]; then
    AVG_MS=0
    MAX_MS=0
    for lat in "${LATENCIES[@]}"; do
        AVG_MS=$((AVG_MS + lat))
        [ "$lat" -gt "$MAX_MS" ] && MAX_MS=$lat
    done
    AVG_MS=$((AVG_MS / ${#LATENCIES[@]}))
    
    if [ "$AVG_MS" -lt 500 ]; then
        record_result "Latency (3-sample avg)" "PASS" "avg=${AVG_MS}ms, max=${MAX_MS}ms" "$AVG_MS"
    elif [ "$AVG_MS" -lt 2000 ]; then
        record_result "Latency (3-sample avg)" "WARN" "avg=${AVG_MS}ms (>500ms)" "$AVG_MS"
    else
        record_result "Latency (3-sample avg)" "FAIL" "avg=${AVG_MS}ms (>2000ms)" "$AVG_MS"
    fi
fi

# === Summary ===
log ""
log "╔══════════════════════════════════════════════╗"
log "║              TEST SUMMARY                    ║"
log "╠══════════════════════════════════════════════╣"
TOTAL=$((PASS + FAIL + WARN + SKIP))
log "║ ✅ PASS: $PASS"
log "║ ❌ FAIL: $FAIL"
log "║ ⚠️  WARN: $WARN"
log "║ ⏭️  SKIP: $SKIP"
log "║ 📊 TOTAL: $TOTAL"
log "╠══════════════════════════════════════════════╣"

if [ "$FAIL" -eq 0 ]; then
    log "║ 🟢 ALL CRITICAL TESTS PASSED"
    EXIT_CODE=0
else
    log "║ 🔴 $FAIL CRITICAL FAILURE(S)"
    EXIT_CODE=1
fi
log "╚══════════════════════════════════════════════╝"

# JSON output
if $JSON_MODE; then
    echo "{"
    echo "  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo "  \"server\": \"$CLAWTALK_URL\","
    echo "  \"pass\": $PASS,"
    echo "  \"fail\": $FAIL,"
    echo "  \"warn\": $WARN,"
    echo "  \"skip\": $SKIP,"
    echo "  \"total\": $TOTAL,"
    echo "  \"results\": [$(IFS=,; echo "${RESULTS[*]}")]"
    echo "}"
fi

exit $EXIT_CODE
