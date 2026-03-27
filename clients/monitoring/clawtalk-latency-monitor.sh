#!/usr/bin/env bash
#
# ClawTalk Latency & Reliability Monitor
# Measures message delivery latency, API response times, and platform health
# Usage: ./clawtalk-latency-monitor.sh [--full] [--json]
#
# Requires: CLAWTALK_API_KEY environment variable
# Output: Human-readable report (or JSON with --json flag)
#

set -euo pipefail

BASE_URL="${CLAWTALK_BASE_URL:-https://clawtalk.monkeymango.co}"
AGENT_NAME="${CLAWTALK_AGENT_NAME:-RealAaron}"
OUTPUT_JSON=false
FULL_TEST=false
RESULTS_DIR="${CLAWTALK_RESULTS_DIR:-/tmp/clawtalk-monitor}"

for arg in "$@"; do
  case "$arg" in
    --json) OUTPUT_JSON=true ;;
    --full) FULL_TEST=true ;;
    --help|-h)
      echo "Usage: $0 [--full] [--json]"
      echo "  --full   Run extended tests (send test message, measure round-trip)"
      echo "  --json   Output results as JSON"
      exit 0
      ;;
  esac
done

mkdir -p "$RESULTS_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Timing helper
time_ms() {
  local start end
  start=$(date +%s%N 2>/dev/null || python3 -c "import time; print(int(time.time()*1e9))")
  eval "$1"
  end=$(date +%s%N 2>/dev/null || python3 -c "import time; print(int(time.time()*1e9))")
  echo $(( (end - start) / 1000000 ))
}

# API call with timing
api_call() {
  local method="$1" endpoint="$2" data="${3:-}"
  local url="${BASE_URL}${endpoint}"
  local start_ns end_ns
  
  start_ns=$(python3 -c "import time; print(int(time.time()*1e9))")
  
  if [ "$method" = "GET" ]; then
    RESPONSE=$(curl -s -w "\n%{http_code}" \
      -H "Authorization: Bearer $CLAWTALK_API_KEY" \
      -H "User-Agent: ClawTalk-Monitor/1.0" \
      "$url" 2>/dev/null)
  else
    RESPONSE=$(curl -s -w "\n%{http_code}" \
      -X "$method" \
      -H "Authorization: Bearer $CLAWTALK_API_KEY" \
      -H "Content-Type: application/json" \
      -H "User-Agent: ClawTalk-Monitor/1.0" \
      -d "$data" \
      "$url" 2>/dev/null)
  fi
  
  end_ns=$(python3 -c "import time; print(int(time.time()*1e9))")
  
  HTTP_CODE=$(echo "$RESPONSE" | tail -1)
  HTTP_BODY=$(echo "$RESPONSE" | sed '$d')
  LATENCY_MS=$(( (end_ns - start_ns) / 1000000 ))
}

# Results accumulator
declare -a TEST_RESULTS=()
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

record() {
  local name="$1" status="$2" latency="$3" detail="${4:-}"
  TEST_RESULTS+=("${name}|${status}|${latency}|${detail}")
  case "$status" in
    PASS) PASS_COUNT=$((PASS_COUNT + 1)) ;;
    FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
    WARN) WARN_COUNT=$((WARN_COUNT + 1)) ;;
  esac
}

# ============================================================
# Test 1: Health endpoint
# ============================================================
api_call GET "/health"
if [ "$HTTP_CODE" = "200" ]; then
  AGENTS_COUNT=$(echo "$HTTP_BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('agents',0))" 2>/dev/null || echo "?")
  record "health" "PASS" "$LATENCY_MS" "status=ok, agents=${AGENTS_COUNT}"
else
  record "health" "FAIL" "$LATENCY_MS" "http=${HTTP_CODE}"
fi

# ============================================================
# Test 2: Agent registry
# ============================================================
api_call GET "/agents"
if [ "$HTTP_CODE" = "200" ]; then
  AGENT_INFO=$(echo "$HTTP_BODY" | python3 -c "
import sys, json
agents = json.load(sys.stdin)
online = sum(1 for a in agents if a.get('online'))
total = len(agents)
names = ', '.join(a['name'] for a in agents)
print(f'{online}/{total} online: {names}')
" 2>/dev/null || echo "parse error")
  record "agents" "PASS" "$LATENCY_MS" "$AGENT_INFO"
else
  record "agents" "FAIL" "$LATENCY_MS" "http=${HTTP_CODE}"
fi

# ============================================================
# Test 3: Message polling
# ============================================================
api_call GET "/messages"
if [ "$HTTP_CODE" = "200" ]; then
  MSG_COUNT=$(echo "$HTTP_BODY" | python3 -c "
import sys, json
data = json.load(sys.stdin)
msgs = data if isinstance(data, list) else data.get('messages', [])
print(len(msgs))
" 2>/dev/null || echo "?")
  record "poll" "PASS" "$LATENCY_MS" "${MSG_COUNT} messages in inbox"
else
  record "poll" "FAIL" "$LATENCY_MS" "http=${HTTP_CODE}"
fi

# ============================================================
# Test 4: Auth validation (bad key should get 401)
# ============================================================
BAD_RESPONSE=$(curl -s -w "\n%{http_code}" \
  -H "Authorization: Bearer ct_INVALID_KEY_12345" \
  -H "User-Agent: ClawTalk-Monitor/1.0" \
  "${BASE_URL}/messages" 2>/dev/null)
BAD_CODE=$(echo "$BAD_RESPONSE" | tail -1)
if [ "$BAD_CODE" = "401" ]; then
  record "auth-reject" "PASS" "0" "invalid key correctly rejected"
else
  record "auth-reject" "WARN" "0" "expected 401, got ${BAD_CODE}"
fi

# ============================================================
# Test 5: Latency consistency (3 rapid health pings)
# ============================================================
LATENCIES=""
for i in 1 2 3; do
  api_call GET "/health"
  LATENCIES="${LATENCIES}${LATENCY_MS} "
  sleep 0.5
done
AVG_LATENCY=$(echo "$LATENCIES" | python3 -c "
import sys
vals = [int(x) for x in sys.stdin.read().split() if x]
avg = sum(vals) / len(vals) if vals else 0
jitter = max(vals) - min(vals) if vals else 0
print(f'{avg:.0f}ms avg, {jitter}ms jitter ({\" \".join(str(v) for v in vals)})')
" 2>/dev/null || echo "?")

MAX_LAT=$(echo "$LATENCIES" | python3 -c "import sys; vals=[int(x) for x in sys.stdin.read().split() if x]; print(max(vals) if vals else 0)")
if [ "$MAX_LAT" -lt 2000 ]; then
  record "latency-consistency" "PASS" "$MAX_LAT" "$AVG_LATENCY"
elif [ "$MAX_LAT" -lt 5000 ]; then
  record "latency-consistency" "WARN" "$MAX_LAT" "$AVG_LATENCY"
else
  record "latency-consistency" "FAIL" "$MAX_LAT" "$AVG_LATENCY"
fi

# ============================================================
# Test 6 (--full only): Send self-message round-trip
# ============================================================
if $FULL_TEST; then
  PROBE_ID="probe-$(date +%s)"
  PROBE_TS=$(python3 -c "import time; print(int(time.time()*1000))")
  
  api_call POST "/messages" "{
    \"to\": \"${AGENT_NAME}\",
    \"type\": \"request\",
    \"topic\": \"latency-probe\",
    \"encrypted\": false,
    \"payload\": {\"text\": \"PROBE ${PROBE_ID}\", \"probe_ts\": ${PROBE_TS}}
  }"
  SEND_LATENCY=$LATENCY_MS
  
  if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
    # Wait and poll
    sleep 1
    api_call GET "/messages?since=${PROBE_TS}"
    RECV_TS=$(python3 -c "import time; print(int(time.time()*1000))")
    RTT=$(( RECV_TS - PROBE_TS ))
    
    FOUND=$(echo "$HTTP_BODY" | python3 -c "
import sys, json
data = json.load(sys.stdin)
msgs = data if isinstance(data, list) else data.get('messages', [])
found = any('${PROBE_ID}' in json.dumps(m) for m in msgs)
print('yes' if found else 'no')
" 2>/dev/null || echo "no")
    
    if [ "$FOUND" = "yes" ]; then
      record "round-trip" "PASS" "$RTT" "send=${SEND_LATENCY}ms, total_rtt=${RTT}ms"
    else
      record "round-trip" "WARN" "$RTT" "message sent but not found in poll (${RTT}ms)"
    fi
  else
    record "round-trip" "FAIL" "$SEND_LATENCY" "send failed: http=${HTTP_CODE}"
  fi
fi

# ============================================================
# Output
# ============================================================

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

if $OUTPUT_JSON; then
  echo "{"
  echo "  \"timestamp\": \"${TIMESTAMP}\","
  echo "  \"base_url\": \"${BASE_URL}\","
  echo "  \"agent\": \"${AGENT_NAME}\","
  echo "  \"summary\": {\"pass\": ${PASS_COUNT}, \"fail\": ${FAIL_COUNT}, \"warn\": ${WARN_COUNT}},"
  echo "  \"tests\": ["
  FIRST=true
  for result in "${TEST_RESULTS[@]}"; do
    IFS='|' read -r name status latency detail <<< "$result"
    $FIRST || echo ","
    FIRST=false
    echo -n "    {\"name\": \"${name}\", \"status\": \"${status}\", \"latency_ms\": ${latency}, \"detail\": \"${detail}\"}"
  done
  echo ""
  echo "  ]"
  echo "}"
else
  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║   ClawTalk Latency & Reliability Report  ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  Timestamp: ${TIMESTAMP}"
  echo -e "  Endpoint:  ${BASE_URL}"
  echo -e "  Agent:     ${AGENT_NAME}"
  echo ""
  
  for result in "${TEST_RESULTS[@]}"; do
    IFS='|' read -r name status latency detail <<< "$result"
    case "$status" in
      PASS) ICON="${GREEN}✅${NC}" ;;
      FAIL) ICON="${RED}❌${NC}" ;;
      WARN) ICON="${YELLOW}⚠️${NC}" ;;
    esac
    printf "  ${ICON} %-22s %5sms  %s\n" "$name" "$latency" "$detail"
  done
  
  echo ""
  echo -e "  ────────────────────────────────────────"
  TOTAL=$((PASS_COUNT + FAIL_COUNT + WARN_COUNT))
  echo -e "  Results: ${GREEN}${PASS_COUNT} pass${NC} / ${YELLOW}${WARN_COUNT} warn${NC} / ${RED}${FAIL_COUNT} fail${NC} (${TOTAL} total)"
  
  if [ "$FAIL_COUNT" -gt 0 ]; then
    echo -e "  Status:  ${RED}UNHEALTHY${NC}"
  elif [ "$WARN_COUNT" -gt 0 ]; then
    echo -e "  Status:  ${YELLOW}DEGRADED${NC}"
  else
    echo -e "  Status:  ${GREEN}HEALTHY${NC}"
  fi
  echo ""
fi

# Save results for historical tracking
echo "${TIMESTAMP}|${PASS_COUNT}|${FAIL_COUNT}|${WARN_COUNT}" >> "${RESULTS_DIR}/history.csv"
