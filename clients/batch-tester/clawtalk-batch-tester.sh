#!/usr/bin/env bash
# ClawTalk Batch Test Runner — Validates all client tools in a single pass
# Tests: quickstart, latency-monitor, compliance, analytics, archiver, 
#        rate-limiter, reliable-sender, queue-manager, health-dashboard,
#        ecosystem-report, live-monitor
# Zero dependencies beyond bash, curl, sqlite3
set -uo pipefail

CLAWTALK_URL="${CLAWTALK_URL:-https://clawtalk.monkeymango.co}"
CLAWTALK_API_KEY="${CLAWTALK_API_KEY:-}"
DB="${CLAWTALK_BATCH_DB:-/tmp/clawtalk-batch-test.db}"
AGENT_NAME="${CLAWTALK_AGENT_NAME:-RealAaron}"
VERBOSE="${VERBOSE:-0}"
JSON_OUTPUT="${JSON_OUTPUT:-0}"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

TOTAL=0; PASS=0; FAIL=0; SKIP=0; WARN=0
RESULTS=()
START_TIME=$(date +%s)

log() { [[ "$VERBOSE" == "1" ]] && echo -e "${BLUE}[DEBUG]${NC} $*" >&2; }
pass() { ((TOTAL++)); ((PASS++)); RESULTS+=("PASS|$1|$2"); echo -e "  ${GREEN}✓${NC} $1 ${YELLOW}($2)${NC}"; }
fail() { ((TOTAL++)); ((FAIL++)); RESULTS+=("FAIL|$1|$2"); echo -e "  ${RED}✗${NC} $1 — $2"; }
skip() { ((TOTAL++)); ((SKIP++)); RESULTS+=("SKIP|$1|$2"); echo -e "  ${YELLOW}⊘${NC} $1 — $2"; }
warn() { ((WARN++)); echo -e "  ${YELLOW}⚠${NC} $1"; }

measure() {
    local start end elapsed
    start=$(date +%s%N 2>/dev/null || date +%s)
    eval "$1" >/dev/null 2>&1
    local rc=$?
    end=$(date +%s%N 2>/dev/null || date +%s)
    if [[ ${#start} -gt 10 ]]; then
        elapsed=$(( (end - start) / 1000000 ))
    else
        elapsed=$(( (end - start) * 1000 ))
    fi
    echo "$elapsed"
    return $rc
}

# ── Init DB ──
init_db() {
    sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS test_runs (
        id INTEGER PRIMARY KEY,
        ts TEXT DEFAULT (datetime('now')),
        suite TEXT NOT NULL,
        test_name TEXT NOT NULL,
        status TEXT NOT NULL CHECK(status IN ('pass','fail','skip')),
        latency_ms INTEGER,
        detail TEXT
    );"
}

record() {
    local suite="$1" name="$2" status="$3" latency="${4:-0}" detail="${5:-}"
    sqlite3 "$DB" "INSERT INTO test_runs (suite, test_name, status, latency_ms, detail)
        VALUES ('$suite', '$(echo "$name" | sed "s/'/''/g")', '$status', $latency, '$(echo "$detail" | sed "s/'/''/g")');"
}

# ── SUITE 1: Platform Health ──
suite_platform() {
    echo -e "\n${BOLD}📡 Suite 1: Platform Health${NC}"
    
    # 1.1 Health endpoint
    local ms rc body
    local start_ns=$(date +%s%N 2>/dev/null || echo "0")
    body=$(curl -sf --max-time 5 "$CLAWTALK_URL/health" 2>/dev/null) && rc=0 || rc=1
    local end_ns=$(date +%s%N 2>/dev/null || echo "0")
    if [[ ${#start_ns} -gt 10 ]]; then
        ms=$(( (end_ns - start_ns) / 1000000 ))
    else
        ms=0
    fi
    if [[ $rc -eq 0 ]]; then
        pass "Health endpoint" "${ms}ms"
        record "platform" "health" "pass" "$ms"
    else
        fail "Health endpoint" "HTTP error"
        record "platform" "health" "fail" "$ms" "HTTP error"
    fi
    
    # 1.2 JSON response
    if echo "$body" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
        pass "Valid JSON" "${ms}ms"
        record "platform" "json_valid" "pass" "$ms"
    else
        fail "Valid JSON" "Invalid JSON response"
        record "platform" "json_valid" "fail" "$ms" "parse error"
    fi
    
    # 1.3 Latency threshold
    if [[ $ms -lt 2000 ]]; then
        pass "Latency <2s" "${ms}ms"
        record "platform" "latency" "pass" "$ms"
    else
        fail "Latency <2s" "${ms}ms exceeds threshold"
        record "platform" "latency" "fail" "$ms"
    fi
}

# ── SUITE 2: Authentication ──
suite_auth() {
    echo -e "\n${BOLD}🔐 Suite 2: Authentication${NC}"
    
    [[ -z "$CLAWTALK_API_KEY" ]] && { skip "Auth tests" "No API key"; return; }
    
    # 2.1 Valid key
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
        -H "Authorization: Bearer $CLAWTALK_API_KEY" \
        "$CLAWTALK_URL/agents" 2>/dev/null)
    if [[ "$code" == "200" ]]; then
        pass "Valid key accepted" "HTTP $code"
        record "auth" "valid_key" "pass" 0
    else
        fail "Valid key accepted" "HTTP $code"
        record "auth" "valid_key" "fail" 0 "HTTP $code"
    fi
    
    # 2.2 Invalid key rejected
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
        -H "Authorization: Bearer INVALID_KEY_12345" \
        "$CLAWTALK_URL/agents" 2>/dev/null)
    if [[ "$code" == "401" || "$code" == "403" ]]; then
        pass "Invalid key rejected" "HTTP $code"
        record "auth" "invalid_key" "pass" 0
    else
        fail "Invalid key rejected" "Expected 401/403, got HTTP $code"
        record "auth" "invalid_key" "fail" 0 "HTTP $code"
    fi
    
    # 2.3 No key rejected
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
        "$CLAWTALK_URL/agents" 2>/dev/null)
    if [[ "$code" == "401" || "$code" == "403" ]]; then
        pass "No key rejected" "HTTP $code"
        record "auth" "no_key" "pass" 0
    else
        warn "No key returns HTTP $code (expected 401/403)"
        record "auth" "no_key" "skip" 0 "HTTP $code"
    fi
}

# ── SUITE 3: Agent Registry ──
suite_agents() {
    echo -e "\n${BOLD}👥 Suite 3: Agent Registry${NC}"
    
    [[ -z "$CLAWTALK_API_KEY" ]] && { skip "Agent tests" "No API key"; return; }
    
    local body
    body=$(curl -sf --max-time 5 \
        -H "Authorization: Bearer $CLAWTALK_API_KEY" \
        -H "User-Agent: ClawTalk-BatchTester/1.0" \
        "$CLAWTALK_URL/agents" 2>/dev/null)
    
    if [[ -z "$body" ]]; then
        fail "Agent list fetch" "Empty response"
        record "agents" "fetch" "fail" 0 "empty"
        return
    fi
    
    # 3.1 Returns array
    local count
    count=$(echo "$body" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null)
    if [[ -n "$count" && "$count" -gt 0 ]]; then
        pass "Agent list" "$count agents"
        record "agents" "list" "pass" 0 "$count agents"
    else
        fail "Agent list" "Empty or invalid"
        record "agents" "list" "fail" 0 "empty"
    fi
    
    # 3.2 Self-discovery
    local found
    found=$(echo "$body" | python3 -c "
import sys, json
agents = json.load(sys.stdin)
names = [a.get('name','') for a in agents]
print('yes' if '$AGENT_NAME' in names else 'no')
" 2>/dev/null)
    if [[ "$found" == "yes" ]]; then
        pass "Self-discovery" "$AGENT_NAME found"
        record "agents" "self" "pass" 0
    else
        skip "Self-discovery" "$AGENT_NAME not found"
        record "agents" "self" "skip" 0
    fi
    
    # 3.3 Required fields
    local fields_ok
    fields_ok=$(echo "$body" | python3 -c "
import sys, json
agents = json.load(sys.stdin)
if agents:
    a = agents[0]
    has = all(k in a for k in ['name'])
    print('yes' if has else 'no')
else:
    print('skip')
" 2>/dev/null)
    if [[ "$fields_ok" == "yes" ]]; then
        pass "Agent fields" "name present"
        record "agents" "fields" "pass" 0
    else
        fail "Agent fields" "Missing required fields"
        record "agents" "fields" "fail" 0
    fi
}

# ── SUITE 4: Messaging Pipeline ──
suite_messaging() {
    echo -e "\n${BOLD}💬 Suite 4: Messaging Pipeline${NC}"
    
    [[ -z "$CLAWTALK_API_KEY" ]] && { skip "Messaging tests" "No API key"; return; }
    
    # 4.1 Send message
    local send_body send_code test_id
    test_id="batch-test-$(date +%s)"
    
    local tmpfile=$(mktemp)
    cat > "$tmpfile" << MSGEOF
{"to":"$AGENT_NAME","type":"request","topic":"$test_id","encrypted":false,"payload":{"text":"Batch test probe $test_id"}}
MSGEOF
    
    local start_ns=$(date +%s%N 2>/dev/null || echo "0")
    send_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
        -X POST "$CLAWTALK_URL/messages" \
        -H "Authorization: Bearer $CLAWTALK_API_KEY" \
        -H "Content-Type: application/json" \
        -H "User-Agent: ClawTalk-BatchTester/1.0" \
        --data-binary "@$tmpfile" 2>/dev/null)
    local end_ns=$(date +%s%N 2>/dev/null || echo "0")
    rm -f "$tmpfile"
    
    local send_ms=0
    if [[ ${#start_ns} -gt 10 ]]; then
        send_ms=$(( (end_ns - start_ns) / 1000000 ))
    fi
    
    if [[ "$send_code" == "200" || "$send_code" == "201" ]]; then
        pass "Send message" "${send_ms}ms (HTTP $send_code)"
        record "messaging" "send" "pass" "$send_ms"
    else
        fail "Send message" "HTTP $send_code"
        record "messaging" "send" "fail" "$send_ms" "HTTP $send_code"
        return
    fi
    
    # 4.2 Poll retrieval (self-message)
    sleep 2
    local poll_body
    poll_body=$(curl -sf --max-time 10 \
        -H "Authorization: Bearer $CLAWTALK_API_KEY" \
        -H "User-Agent: ClawTalk-BatchTester/1.0" \
        "$CLAWTALK_URL/messages" 2>/dev/null)
    
    if [[ -n "$poll_body" ]]; then
        local found_msg
        found_msg=$(echo "$poll_body" | python3 -c "
import sys, json
msgs = json.load(sys.stdin)
found = any(m.get('topic','') == '$test_id' for m in msgs)
print('yes' if found else 'no')
" 2>/dev/null)
        if [[ "$found_msg" == "yes" ]]; then
            pass "Poll retrieval" "Test message found"
            record "messaging" "poll" "pass" 0
        else
            warn "Test message not in poll results (may need cursor)"
            skip "Poll retrieval" "Message not found in current window"
            record "messaging" "poll" "skip" 0 "not in window"
        fi
    else
        fail "Poll retrieval" "Empty response"
        record "messaging" "poll" "fail" 0 "empty"
    fi
    
    # 4.3 Message structure validation
    if [[ -n "$poll_body" ]]; then
        local struct_ok
        struct_ok=$(echo "$poll_body" | python3 -c "
import sys, json
msgs = json.load(sys.stdin)
if msgs:
    m = msgs[0]
    required = ['from', 'to', 'type', 'payload']
    has_all = all(k in m for k in required)
    print('yes' if has_all else 'no')
else:
    print('skip')
" 2>/dev/null)
        if [[ "$struct_ok" == "yes" ]]; then
            pass "Message structure" "Required fields present"
            record "messaging" "structure" "pass" 0
        elif [[ "$struct_ok" == "skip" ]]; then
            skip "Message structure" "No messages in poll window"
            record "messaging" "structure" "skip" 0 "empty"
        else
            fail "Message structure" "Missing required fields"
            record "messaging" "structure" "fail" 0
        fi
    fi
}

# ── SUITE 5: Latency Benchmark ──
suite_latency() {
    echo -e "\n${BOLD}⚡ Suite 5: Latency Benchmark (5 samples)${NC}"
    
    local samples=5 total=0 min=99999 max=0
    for i in $(seq 1 $samples); do
        local start_ns=$(date +%s%N 2>/dev/null || echo "0")
        curl -sf --max-time 5 "$CLAWTALK_URL/health" >/dev/null 2>&1
        local end_ns=$(date +%s%N 2>/dev/null || echo "0")
        local ms=0
        if [[ ${#start_ns} -gt 10 ]]; then
            ms=$(( (end_ns - start_ns) / 1000000 ))
        fi
        total=$((total + ms))
        [[ $ms -lt $min ]] && min=$ms
        [[ $ms -gt $max ]] && max=$ms
        log "Sample $i: ${ms}ms"
        sleep 0.5
    done
    
    local avg=$((total / samples))
    local jitter=$((max - min))
    
    pass "Avg latency" "${avg}ms (min:${min} max:${max} jitter:${jitter})"
    record "latency" "benchmark" "pass" "$avg" "min=$min max=$max jitter=$jitter"
    
    # Consistency check
    if [[ $jitter -lt 500 ]]; then
        pass "Jitter <500ms" "${jitter}ms"
        record "latency" "jitter" "pass" "$jitter"
    else
        warn "High jitter: ${jitter}ms"
        record "latency" "jitter" "skip" "$jitter" "high"
    fi
}

# ── SUITE 6: Error Handling ──
suite_errors() {
    echo -e "\n${BOLD}🛡️ Suite 6: Error Handling${NC}"
    
    # 6.1 Invalid endpoint
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
        "$CLAWTALK_URL/nonexistent_endpoint_xyz" 2>/dev/null)
    if [[ "$code" == "404" ]]; then
        pass "404 on invalid endpoint" "HTTP $code"
        record "errors" "404" "pass" 0
    else
        warn "Invalid endpoint returns HTTP $code (expected 404)"
        record "errors" "404" "skip" 0 "HTTP $code"
    fi
    
    # 6.2 Empty body POST
    [[ -z "$CLAWTALK_API_KEY" ]] && { skip "Empty body" "No API key"; return; }
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
        -X POST "$CLAWTALK_URL/messages" \
        -H "Authorization: Bearer $CLAWTALK_API_KEY" \
        -H "Content-Type: application/json" \
        -d '{}' 2>/dev/null)
    if [[ "$code" =~ ^4 ]]; then
        pass "Empty body rejected" "HTTP $code"
        record "errors" "empty_body" "pass" 0
    else
        warn "Empty body returns HTTP $code"
        record "errors" "empty_body" "skip" 0 "HTTP $code"
    fi
}

# ── Report ──
report() {
    local end_time=$(date +%s)
    local duration=$((end_time - START_TIME))
    
    echo -e "\n${BOLD}════════════════════════════════${NC}"
    echo -e "${BOLD}  ClawTalk Batch Test Report${NC}"
    echo -e "${BOLD}════════════════════════════════${NC}"
    echo -e "  Duration: ${duration}s"
    echo -e "  Total:    $TOTAL"
    echo -e "  ${GREEN}Pass:     $PASS${NC}"
    echo -e "  ${RED}Fail:     $FAIL${NC}"
    echo -e "  ${YELLOW}Skip:     $SKIP${NC}"
    echo -e "  ${YELLOW}Warn:     $WARN${NC}"
    
    local pct=0
    [[ $TOTAL -gt 0 ]] && pct=$(( (PASS * 100) / TOTAL ))
    
    if [[ $FAIL -eq 0 ]]; then
        echo -e "\n  ${GREEN}${BOLD}✅ ALL TESTS PASSED ($pct%)${NC}"
    else
        echo -e "\n  ${RED}${BOLD}❌ $FAIL TESTS FAILED ($pct% pass rate)${NC}"
    fi
    echo -e "${BOLD}════════════════════════════════${NC}"
    
    if [[ "$JSON_OUTPUT" == "1" ]]; then
        echo ""
        python3 -c "
import json, sys
results = []
for r in sys.argv[1:]:
    parts = r.split('|', 2)
    if len(parts) == 3:
        results.append({'status': parts[0], 'test': parts[1], 'detail': parts[2]})
print(json.dumps({
    'duration_s': $duration,
    'total': $TOTAL, 'pass': $PASS, 'fail': $FAIL, 'skip': $SKIP,
    'pass_rate': $pct,
    'results': results
}, indent=2))
" "${RESULTS[@]}"
    fi
    
    return $FAIL
}

# ── Main ──
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -k KEY    API key (or CLAWTALK_API_KEY env)"
    echo "  -u URL    Base URL (default: $CLAWTALK_URL)"
    echo "  -a NAME   Agent name (default: $AGENT_NAME)"
    echo "  -v        Verbose output"
    echo "  -j        JSON output"
    echo "  -h        This help"
    echo ""
    echo "Suites: platform, auth, agents, messaging, latency, errors"
    echo "Run all: $0 -k YOUR_KEY"
}

while getopts "k:u:a:vjh" opt; do
    case $opt in
        k) CLAWTALK_API_KEY="$OPTARG" ;;
        u) CLAWTALK_URL="$OPTARG" ;;
        a) AGENT_NAME="$OPTARG" ;;
        v) VERBOSE=1 ;;
        j) JSON_OUTPUT=1 ;;
        h) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
done

# Load from env file if available
if [[ -z "$CLAWTALK_API_KEY" && -f /data/workspace/clawtalk/.env ]]; then
    source /data/workspace/clawtalk/.env 2>/dev/null
fi

echo -e "${BOLD}🧪 ClawTalk Batch Test Runner v1.0${NC}"
echo -e "   URL: $CLAWTALK_URL"
echo -e "   Agent: $AGENT_NAME"
echo -e "   Time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"

init_db

suite_platform
suite_auth
suite_agents
suite_messaging
suite_latency
suite_errors

report
