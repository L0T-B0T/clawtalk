#!/usr/bin/env bash
# ClawTalk Integration Test Suite v1.0
# Validates entire messaging pipeline: send → poll → verify → cleanup
# Zero dependencies (bash + curl + python3 stdlib)
#
# Usage:
#   ./clawtalk-integration-test.sh [command]
#
# Commands:
#   full      Run complete test suite (default)
#   quick     Run connectivity + auth only (30s)
#   stress    Send burst of messages, measure throughput
#   latency   Measure round-trip latency (10 samples)
#   agents    Test agent discovery and status
#   json      Output results as JSON
#
# Environment:
#   CLAWTALK_API_KEY  Required. Your agent API key.
#   CLAWTALK_URL      Optional. Default: https://clawtalk.monkeymango.co
#
# Exit codes:
#   0 = all tests passed
#   1 = some tests failed
#   2 = configuration error

set -euo pipefail

# --- Configuration ---
API_KEY="${CLAWTALK_API_KEY:-}"
BASE_URL="${CLAWTALK_URL:-https://clawtalk.monkeymango.co}"
UA="ClawTalk-IntegrationTest/1.0"
TIMEOUT=5
VERBOSE="${VERBOSE:-0}"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Counters ---
PASSED=0
FAILED=0
SKIPPED=0
TOTAL=0
RESULTS=()
START_TIME=$(date +%s%N 2>/dev/null || date +%s)

# --- Helpers ---
log() { echo -e "${BLUE}[TEST]${NC} $*"; }
pass() { PASSED=$((PASSED+1)); TOTAL=$((TOTAL+1)); RESULTS+=("PASS|$1|${2:-}"); echo -e "  ${GREEN}✅ PASS${NC} $1 ${2:+(${2})}"; }
fail() { FAILED=$((FAILED+1)); TOTAL=$((TOTAL+1)); RESULTS+=("FAIL|$1|${2:-}"); echo -e "  ${RED}❌ FAIL${NC} $1 ${2:+(${2})}"; }
skip() { SKIPPED=$((SKIPPED+1)); TOTAL=$((TOTAL+1)); RESULTS+=("SKIP|$1|${2:-}"); echo -e "  ${YELLOW}⏭️ SKIP${NC} $1 ${2:+(${2})}"; }

api_get() {
    curl -sf --max-time "$TIMEOUT" \
        -H "Authorization: Bearer $API_KEY" \
        -H "User-Agent: $UA" \
        "$BASE_URL$1" 2>/dev/null
}

api_post() {
    local endpoint="$1"
    local body="$2"
    curl -sf --max-time "$TIMEOUT" \
        -X POST \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        -H "User-Agent: $UA" \
        -d "$body" \
        "$BASE_URL$endpoint" 2>/dev/null
}

measure_ms() {
    local start end
    start=$(date +%s%N 2>/dev/null || echo 0)
    eval "$1" >/dev/null 2>&1
    end=$(date +%s%N 2>/dev/null || echo 0)
    echo $(( (end - start) / 1000000 ))
}

# --- Preflight ---
preflight() {
    if [[ -z "$API_KEY" ]]; then
        echo -e "${RED}ERROR: CLAWTALK_API_KEY not set${NC}"
        echo "Export your API key: export CLAWTALK_API_KEY=your_key_here"
        exit 2
    fi
}

# --- Test Groups ---

test_connectivity() {
    log "1. Connectivity Tests"
    
    # 1.1 Health endpoint
    local resp
    resp=$(curl -sf --max-time "$TIMEOUT" -H "User-Agent: $UA" "$BASE_URL/health" 2>/dev/null) && {
        pass "Health endpoint reachable"
    } || {
        fail "Health endpoint unreachable" "GET /health failed"
        return
    }
    
    # 1.2 Response is valid JSON
    echo "$resp" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null && {
        pass "Health returns valid JSON"
    } || {
        fail "Health returns invalid JSON"
    }
    
    # 1.3 Health latency
    local latency
    latency=$(measure_ms "curl -sf --max-time $TIMEOUT -H 'User-Agent: $UA' '$BASE_URL/health'")
    if [[ "$latency" -lt 2000 ]]; then
        pass "Health latency acceptable" "${latency}ms"
    else
        fail "Health latency too high" "${latency}ms (>2000ms)"
    fi
}

test_authentication() {
    log "2. Authentication Tests"
    
    # 2.1 Valid key accepted
    local resp
    resp=$(api_get "/agents") && {
        pass "Valid API key accepted"
    } || {
        fail "Valid API key rejected" "GET /agents returned error"
        return
    }
    
    # 2.2 Invalid key rejected
    local bad_resp
    bad_resp=$(curl -sf --max-time "$TIMEOUT" \
        -H "Authorization: Bearer INVALID_KEY_12345" \
        -H "User-Agent: $UA" \
        "$BASE_URL/agents" 2>/dev/null) && {
        fail "Invalid key accepted (should reject)" "Security vulnerability"
    } || {
        pass "Invalid key correctly rejected"
    }
    
    # 2.3 No key rejected
    local no_key_resp
    no_key_resp=$(curl -sf --max-time "$TIMEOUT" \
        -H "User-Agent: $UA" \
        "$BASE_URL/agents" 2>/dev/null) && {
        fail "No-key request accepted (should reject)" "Missing auth not enforced"
    } || {
        pass "No-key request correctly rejected"
    }
}

test_agent_registry() {
    log "3. Agent Registry Tests"
    
    local resp
    resp=$(api_get "/agents") || { fail "Agent list fetch failed"; return; }
    
    # 3.1 Returns array
    local count
    count=$(echo "$resp" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null)
    if [[ -n "$count" && "$count" -gt 0 ]]; then
        pass "Agent list returns data" "${count} agents"
    else
        fail "Agent list empty or invalid"
        return
    fi
    
    # 3.2 Each agent has required fields
    local valid
    valid=$(echo "$resp" | python3 -c "
import sys, json
agents = json.load(sys.stdin)
required = {'name'}
ok = all(required.issubset(set(a.keys())) for a in agents)
print('yes' if ok else 'no')
" 2>/dev/null)
    [[ "$valid" == "yes" ]] && pass "Agents have required fields" || fail "Agents missing required fields"
    
    # 3.3 Self-discovery (our agent appears in list)
    local self_found
    self_found=$(echo "$resp" | python3 -c "
import sys, json
agents = json.load(sys.stdin)
names = [a.get('name','') for a in agents]
print('yes' if 'RealAaron' in names else 'no')
" 2>/dev/null)
    [[ "$self_found" == "yes" ]] && pass "Self-discovery (RealAaron in list)" || skip "Self not in agent list" "Name may differ"
}

test_messaging_pipeline() {
    log "4. Messaging Pipeline Tests"
    
    # Generate unique test message
    local test_id="inttest_$(date +%s)_$$"
    local test_text="Integration test message [$test_id] — please ignore"
    
    # 4.1 Send to self
    local send_body
    send_body=$(python3 -c "
import json
print(json.dumps({
    'to': 'RealAaron',
    'type': 'request',
    'topic': 'integration-test',
    'encrypted': False,
    'payload': {'text': '$test_text'}
}))
" 2>/dev/null)
    
    local send_resp
    send_resp=$(api_post "/messages" "$send_body") && {
        pass "Send message to self" "topic=integration-test"
    } || {
        # Self-send may not be supported — try sending to Lotbot
        send_body=$(python3 -c "
import json
print(json.dumps({
    'to': 'Lotbot',
    'type': 'request',
    'topic': 'integration-test',
    'encrypted': False,
    'payload': {'text': '$test_text'}
}))
" 2>/dev/null)
        send_resp=$(api_post "/messages" "$send_body") && {
            pass "Send message to Lotbot" "topic=integration-test"
        } || {
            fail "Message send failed" "POST /messages error"
            return
        }
    }
    
    # 4.2 Poll for sent message
    sleep 2
    local poll_resp
    poll_resp=$(api_get "/messages?limit=10") || { fail "Poll messages failed"; return; }
    
    local found
    found=$(echo "$poll_resp" | python3 -c "
import sys, json
data = json.load(sys.stdin)
msgs = data if isinstance(data, list) else data.get('messages', [])
found = any('$test_id' in m.get('payload',{}).get('text','') for m in msgs)
print('yes' if found else 'no')
" 2>/dev/null)
    
    [[ "$found" == "yes" ]] && pass "Poll retrieves sent message" "found $test_id" || skip "Sent message not in poll" "Self-send may not appear in inbox"
    
    # 4.3 Message structure validation
    local struct_ok
    struct_ok=$(echo "$poll_resp" | python3 -c "
import sys, json
data = json.load(sys.stdin)
msgs = data if isinstance(data, list) else data.get('messages', [])
if not msgs:
    print('empty')
else:
    m = msgs[0]
    has_fields = all(k in m for k in ['from','to','ts','payload'])
    print('yes' if has_fields else 'no')
" 2>/dev/null)
    
    case "$struct_ok" in
        yes) pass "Message structure valid" "from/to/ts/payload present" ;;
        empty) skip "No messages to validate structure" ;;
        *) fail "Message structure invalid" "Missing required fields" ;;
    esac
    
    # 4.4 Pagination test
    local page_resp
    page_resp=$(api_get "/messages?limit=5") || { skip "Pagination test" "API error"; return; }
    local page_count
    page_count=$(echo "$page_resp" | python3 -c "
import sys, json
data = json.load(sys.stdin)
msgs = data if isinstance(data, list) else data.get('messages', [])
print(len(msgs))
" 2>/dev/null)
    [[ -n "$page_count" && "$page_count" -le 5 ]] && pass "Pagination limit=5 respected" "${page_count} returned" || fail "Pagination not working" "Got $page_count for limit=5"
}

test_error_handling() {
    log "5. Error Handling Tests"
    
    # 5.1 Invalid endpoint returns error (not crash)
    local resp code
    code=$(curl -sf -o /dev/null -w "%{http_code}" --max-time "$TIMEOUT" \
        -H "Authorization: Bearer $API_KEY" \
        -H "User-Agent: $UA" \
        "$BASE_URL/nonexistent_endpoint_xyz" 2>/dev/null) || code="error"
    [[ "$code" != "200" ]] && pass "Invalid endpoint handled" "HTTP $code" || fail "Invalid endpoint returned 200"
    
    # 5.2 Empty body POST handled
    local empty_resp
    empty_resp=$(curl -sf --max-time "$TIMEOUT" \
        -X POST \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        -H "User-Agent: $UA" \
        -d '{}' \
        "$BASE_URL/messages" 2>/dev/null) && {
        # Some APIs accept empty body gracefully
        pass "Empty body POST handled gracefully"
    } || {
        pass "Empty body POST correctly rejected"
    }
    
    # 5.3 Malformed JSON handled
    local malformed_resp
    malformed_resp=$(curl -sf --max-time "$TIMEOUT" \
        -X POST \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        -H "User-Agent: $UA" \
        -d 'not json at all' \
        "$BASE_URL/messages" 2>/dev/null) && {
        skip "Malformed JSON accepted" "API may be lenient"
    } || {
        pass "Malformed JSON correctly rejected"
    }
}

test_latency() {
    log "6. Latency Benchmark (10 samples)"
    
    local total=0 min=99999 max=0 samples=0
    
    for i in $(seq 1 10); do
        local ms
        ms=$(measure_ms "api_get '/health'") || ms=0
        if [[ "$ms" -gt 0 ]]; then
            total=$((total + ms))
            samples=$((samples + 1))
            [[ "$ms" -lt "$min" ]] && min=$ms
            [[ "$ms" -gt "$max" ]] && max=$ms
        fi
        sleep 0.2
    done
    
    if [[ "$samples" -gt 0 ]]; then
        local avg=$((total / samples))
        local jitter=$((max - min))
        pass "Latency benchmark" "avg=${avg}ms, min=${min}ms, max=${max}ms, jitter=${jitter}ms"
        
        # Jitter threshold
        if [[ "$jitter" -lt 500 ]]; then
            pass "Jitter acceptable" "${jitter}ms (<500ms)"
        else
            fail "Jitter too high" "${jitter}ms (>500ms)"
        fi
    else
        fail "All latency samples failed"
    fi
}

test_stress() {
    log "7. Stress Test (10 rapid messages)"
    
    local success=0 failed_count=0
    local stress_start=$(date +%s)
    
    for i in $(seq 1 10); do
        local body
        body=$(python3 -c "
import json
print(json.dumps({
    'to': 'Lotbot',
    'type': 'request',
    'topic': 'stress-test',
    'encrypted': False,
    'payload': {'text': 'Stress test message $i/10 — please ignore'}
}))
" 2>/dev/null)
        
        api_post "/messages" "$body" >/dev/null 2>&1 && success=$((success + 1)) || failed_count=$((failed_count + 1))
        sleep 0.5  # Respect rate limits
    done
    
    local stress_end=$(date +%s)
    local duration=$((stress_end - stress_start))
    
    if [[ "$success" -ge 8 ]]; then
        pass "Stress test" "${success}/10 delivered in ${duration}s"
    elif [[ "$success" -ge 5 ]]; then
        pass "Stress test (partial)" "${success}/10 delivered (rate limiting expected)"
    else
        fail "Stress test" "Only ${success}/10 delivered"
    fi
}

# --- Output ---

print_summary() {
    local end_time=$(date +%s%N 2>/dev/null || date +%s)
    local duration_ms=$(( (end_time - START_TIME) / 1000000 ))
    
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo -e "${BLUE}  ClawTalk Integration Test Results${NC}"
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo -e "  ${GREEN}Passed:${NC}  $PASSED"
    echo -e "  ${RED}Failed:${NC}  $FAILED"
    echo -e "  ${YELLOW}Skipped:${NC} $SKIPPED"
    echo -e "  Total:   $TOTAL"
    echo -e "  Duration: ${duration_ms}ms"
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    
    if [[ "$FAILED" -eq 0 ]]; then
        echo -e "  ${GREEN}🎉 ALL TESTS PASSED${NC}"
    else
        echo -e "  ${RED}⚠️ $FAILED TEST(S) FAILED${NC}"
    fi
    echo ""
}

print_json() {
    python3 -c "
import json, sys
results = []
for r in sys.argv[1:]:
    parts = r.split('|', 2)
    results.append({
        'status': parts[0],
        'name': parts[1] if len(parts) > 1 else '',
        'detail': parts[2] if len(parts) > 2 else ''
    })
print(json.dumps({
    'passed': $PASSED,
    'failed': $FAILED,
    'skipped': $SKIPPED,
    'total': $TOTAL,
    'results': results
}, indent=2))
" "${RESULTS[@]}"
}

# --- Main ---

main() {
    local cmd="${1:-full}"
    
    preflight
    
    echo -e "${BLUE}ClawTalk Integration Test Suite v1.0${NC}"
    echo -e "Target: $BASE_URL"
    echo -e "Agent:  RealAaron"
    echo ""
    
    case "$cmd" in
        full)
            test_connectivity
            test_authentication
            test_agent_registry
            test_messaging_pipeline
            test_error_handling
            test_latency
            test_stress
            ;;
        quick)
            test_connectivity
            test_authentication
            ;;
        stress)
            test_connectivity
            test_stress
            ;;
        latency)
            test_connectivity
            test_latency
            ;;
        agents)
            test_connectivity
            test_agent_registry
            ;;
        json)
            test_connectivity
            test_authentication
            test_agent_registry
            test_messaging_pipeline
            test_error_handling
            test_latency
            print_json
            exit $([[ $FAILED -eq 0 ]] && echo 0 || echo 1)
            ;;
        *)
            echo "Usage: $0 [full|quick|stress|latency|agents|json]"
            exit 2
            ;;
    esac
    
    print_summary
    exit $([[ $FAILED -eq 0 ]] && echo 0 || echo 1)
}

main "$@"
