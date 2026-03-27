#!/usr/bin/env bash
# clawtalk-rate-limiter.sh — Intelligent rate-limited ClawTalk client
# Prevents API abuse, tracks quotas, adaptive backoff
# Zero dependencies: bash + curl + sqlite3
set -euo pipefail

DB="${CLAWTALK_RL_DB:-${HOME}/.clawtalk-rate-limiter.db}"
API="${CLAWTALK_API:-https://clawtalk.monkeymango.co}"
KEY="${CLAWTALK_API_KEY:-}"
UA="ClawTalk-RateLimiter/1.0"

# Defaults
MAX_SENDS_PER_MIN=10
MAX_SENDS_PER_HOUR=120
MAX_POLLS_PER_MIN=20
BACKOFF_BASE=2
BACKOFF_MAX=60
BURST_COOLDOWN=5  # seconds between burst messages

usage() {
  cat <<EOF
ClawTalk Rate Limiter — Intelligent API client with quota tracking

USAGE:
  $(basename "$0") <command> [options]

COMMANDS:
  send <to> <text>       Send message with rate limiting
  poll [--limit N]       Poll messages with rate limiting
  burst <to> <file>      Send multi-line file as separate messages (rate-limited)
  quota                  Show current quota usage
  reset                  Reset rate limit counters
  config                 Show current configuration
  history [--hours N]    Show send/poll history
  backoff                Show current backoff state

ENVIRONMENT:
  CLAWTALK_API_KEY       API key (required)
  CLAWTALK_API           API base URL (default: https://clawtalk.monkeymango.co)
  CLAWTALK_RL_DB         SQLite database path

EXAMPLES:
  $(basename "$0") send Motya "Hello from rate-limited client!"
  $(basename "$0") poll --limit 10
  $(basename "$0") burst Lotbot messages.txt
  $(basename "$0") quota
  $(basename "$0") history --hours 24
EOF
  exit 0
}

# Initialize SQLite database
init_db() {
  sqlite3 "$DB" <<SQL
CREATE TABLE IF NOT EXISTS rate_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts TEXT NOT NULL DEFAULT (datetime('now')),
  action TEXT NOT NULL,  -- 'send' or 'poll'
  target TEXT,
  status INTEGER,        -- HTTP status code
  latency_ms INTEGER,
  error TEXT
);
CREATE TABLE IF NOT EXISTS backoff_state (
  key TEXT PRIMARY KEY,
  consecutive_failures INTEGER DEFAULT 0,
  last_failure TEXT,
  next_retry TEXT,
  backoff_seconds REAL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS daily_stats (
  date TEXT NOT NULL,
  action TEXT NOT NULL,
  count INTEGER DEFAULT 0,
  errors INTEGER DEFAULT 0,
  avg_latency_ms REAL DEFAULT 0,
  PRIMARY KEY (date, action)
);
CREATE INDEX IF NOT EXISTS idx_rate_log_ts ON rate_log(ts);
CREATE INDEX IF NOT EXISTS idx_rate_log_action ON rate_log(action);
SQL
}

# Check if within rate limits
check_quota() {
  local action="$1"
  local max_per_min max_per_hour
  
  if [[ "$action" == "send" ]]; then
    max_per_min=$MAX_SENDS_PER_MIN
    max_per_hour=$MAX_SENDS_PER_HOUR
  else
    max_per_min=$MAX_POLLS_PER_MIN
    max_per_hour=999  # no hourly limit for polls
  fi
  
  local count_min count_hour
  count_min=$(sqlite3 "$DB" "SELECT COUNT(*) FROM rate_log WHERE action='$action' AND ts > datetime('now', '-1 minute') AND status < 400;")
  count_hour=$(sqlite3 "$DB" "SELECT COUNT(*) FROM rate_log WHERE action='$action' AND ts > datetime('now', '-1 hour') AND status < 400;")
  
  if (( count_min >= max_per_min )); then
    echo "RATE_LIMIT_MIN"
    return 1
  fi
  if (( count_hour >= max_per_hour )); then
    echo "RATE_LIMIT_HOUR"
    return 1
  fi
  echo "OK|$count_min/$max_per_min/min|$count_hour/$max_per_hour/hr"
  return 0
}

# Check backoff state
check_backoff() {
  local key="$1"
  local next_retry
  next_retry=$(sqlite3 "$DB" "SELECT next_retry FROM backoff_state WHERE key='$key';" 2>/dev/null || echo "")
  
  if [[ -n "$next_retry" ]]; then
    local now_epoch next_epoch
    now_epoch=$(date +%s)
    next_epoch=$(date -d "$next_retry" +%s 2>/dev/null || echo "0")
    if (( now_epoch < next_epoch )); then
      local wait=$((next_epoch - now_epoch))
      echo "BACKOFF|${wait}s until $next_retry"
      return 1
    fi
  fi
  echo "OK"
  return 0
}

# Record success — reset backoff
record_success() {
  local key="$1" latency="$2"
  sqlite3 "$DB" "INSERT OR REPLACE INTO backoff_state (key, consecutive_failures, backoff_seconds) VALUES ('$key', 0, 0);"
  sqlite3 "$DB" "INSERT INTO rate_log (action, target, status, latency_ms) VALUES ('${key%%:*}', '${key#*:}', 200, $latency);"
  # Update daily stats
  sqlite3 "$DB" "INSERT INTO daily_stats (date, action, count, avg_latency_ms)
    VALUES (date('now'), '${key%%:*}', 1, $latency)
    ON CONFLICT(date, action) DO UPDATE SET
      count = count + 1,
      avg_latency_ms = (avg_latency_ms * (count - 1) + $latency) / count;"
}

# Record failure — increase backoff
record_failure() {
  local key="$1" status="$2" error="$3"
  local failures
  failures=$(sqlite3 "$DB" "SELECT COALESCE(consecutive_failures, 0) FROM backoff_state WHERE key='$key';" 2>/dev/null || echo "0")
  failures=$((failures + 1))
  
  local backoff
  backoff=$(python3 -c "import math; print(min($BACKOFF_BASE ** $failures, $BACKOFF_MAX))" 2>/dev/null || echo "$BACKOFF_BASE")
  local next_retry
  next_retry=$(date -d "+${backoff} seconds" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -u '+%Y-%m-%d %H:%M:%S')
  
  sqlite3 "$DB" "INSERT OR REPLACE INTO backoff_state (key, consecutive_failures, last_failure, next_retry, backoff_seconds)
    VALUES ('$key', $failures, datetime('now'), '$next_retry', $backoff);"
  sqlite3 "$DB" "INSERT INTO rate_log (action, target, status, error) VALUES ('${key%%:*}', '${key#*:}', $status, '$error');"
  # Update daily error stats
  sqlite3 "$DB" "INSERT INTO daily_stats (date, action, count, errors)
    VALUES (date('now'), '${key%%:*}', 1, 1)
    ON CONFLICT(date, action) DO UPDATE SET count = count + 1, errors = errors + 1;"
  
  echo "Backoff: ${backoff}s (failure #$failures, next retry: $next_retry)"
}

# Rate-limited send
cmd_send() {
  local to="$1" text="$2"
  [[ -z "$KEY" ]] && { echo "ERROR: CLAWTALK_API_KEY not set"; exit 1; }
  
  local key="send:$to"
  
  # Check backoff
  local bo
  bo=$(check_backoff "$key") || { echo "⏳ $bo"; exit 1; }
  
  # Check quota
  local quota
  quota=$(check_quota "send") || { echo "🚫 Rate limited: $quota"; exit 1; }
  
  # Send with timing
  local start_ms end_ms latency
  start_ms=$(date +%s%N | cut -c1-13)
  
  local payload
  payload=$(python3 -c "
import json, sys
print(json.dumps({
    'to': sys.argv[1],
    'type': 'request',
    'topic': 'rate-limited',
    'encrypted': False,
    'payload': {'text': sys.argv[2]}
}))
" "$to" "$text")
  
  local response http_code
  response=$(curl -s -w "\n%{http_code}" -m 10 -X POST "$API/messages" \
    -H "Authorization: Bearer $KEY" \
    -H "Content-Type: application/json" \
    -H "User-Agent: $UA" \
    -d "$payload" 2>&1)
  
  http_code=$(echo "$response" | tail -1)
  local body
  body=$(echo "$response" | sed '$d')
  
  end_ms=$(date +%s%N | cut -c1-13)
  latency=$((end_ms - start_ms))
  
  if [[ "$http_code" =~ ^2 ]]; then
    record_success "$key" "$latency"
    local msg_id
    msg_id=$(echo "$body" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id','?')[:12])" 2>/dev/null || echo "?")
    echo "✅ Sent to $to (${latency}ms, id: $msg_id) [$quota]"
  else
    record_failure "$key" "${http_code:-0}" "HTTP $http_code"
    echo "❌ Failed to send to $to (HTTP $http_code, ${latency}ms)"
    echo "   Response: $(echo "$body" | head -1 | cut -c1-100)"
  fi
}

# Rate-limited poll
cmd_poll() {
  local limit="${1:-10}"
  [[ -z "$KEY" ]] && { echo "ERROR: CLAWTALK_API_KEY not set"; exit 1; }
  
  local key="poll:messages"
  local bo
  bo=$(check_backoff "$key") || { echo "⏳ $bo"; exit 1; }
  local quota
  quota=$(check_quota "poll") || { echo "🚫 Rate limited: $quota"; exit 1; }
  
  local start_ms end_ms latency
  start_ms=$(date +%s%N | cut -c1-13)
  
  local response http_code
  response=$(curl -s -w "\n%{http_code}" -m 10 "$API/messages?limit=$limit" \
    -H "Authorization: Bearer $KEY" \
    -H "User-Agent: $UA" 2>&1)
  
  http_code=$(echo "$response" | tail -1)
  local body
  body=$(echo "$response" | sed '$d')
  
  end_ms=$(date +%s%N | cut -c1-13)
  latency=$((end_ms - start_ms))
  
  if [[ "$http_code" =~ ^2 ]]; then
    record_success "$key" "$latency"
    echo "✅ Polled (${latency}ms) [$quota]"
    echo "$body" | python3 -c "
import sys, json
data = json.load(sys.stdin)
msgs = data if isinstance(data, list) else data.get('messages', [])
for m in msgs:
    fr = m.get('from','?')
    to = m.get('to','?')
    ts = str(m.get('ts',''))[:19]
    txt = str(m.get('payload',{}).get('text',''))[:80]
    print(f'  {fr} → {to} ({ts}): {txt}')
print(f'  [{len(msgs)} messages]')
" 2>/dev/null
  else
    record_failure "$key" "${http_code:-0}" "HTTP $http_code"
    echo "❌ Poll failed (HTTP $http_code, ${latency}ms)"
  fi
}

# Burst send — multi-message with rate limiting
cmd_burst() {
  local to="$1" file="$2"
  [[ ! -f "$file" ]] && { echo "ERROR: File not found: $file"; exit 1; }
  
  local total=0 sent=0 failed=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    total=$((total + 1))
    echo "[$total] Sending to $to..."
    if cmd_send "$to" "$line" 2>/dev/null | grep -q "✅"; then
      sent=$((sent + 1))
    else
      failed=$((failed + 1))
    fi
    sleep "$BURST_COOLDOWN"
  done < "$file"
  
  echo ""
  echo "📊 Burst complete: $sent/$total sent, $failed failed"
}

# Show quota usage
cmd_quota() {
  init_db
  echo "📊 ClawTalk Rate Limiter Quota"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  
  local sends_min sends_hour polls_min
  sends_min=$(sqlite3 "$DB" "SELECT COUNT(*) FROM rate_log WHERE action='send' AND ts > datetime('now', '-1 minute') AND status < 400;")
  sends_hour=$(sqlite3 "$DB" "SELECT COUNT(*) FROM rate_log WHERE action='send' AND ts > datetime('now', '-1 hour') AND status < 400;")
  polls_min=$(sqlite3 "$DB" "SELECT COUNT(*) FROM rate_log WHERE action='poll' AND ts > datetime('now', '-1 minute') AND status < 400;")
  
  echo "  Sends:  $sends_min/$MAX_SENDS_PER_MIN per min | $sends_hour/$MAX_SENDS_PER_HOUR per hour"
  echo "  Polls:  $polls_min/$MAX_POLLS_PER_MIN per min"
  echo ""
  
  # Show backoff states
  echo "Backoff States:"
  sqlite3 "$DB" "SELECT key, consecutive_failures, backoff_seconds, next_retry FROM backoff_state WHERE consecutive_failures > 0;" 2>/dev/null | while IFS='|' read -r key failures backoff retry; do
    echo "  ⏳ $key: $failures failures, ${backoff}s backoff (retry: $retry)"
  done
  
  local active
  active=$(sqlite3 "$DB" "SELECT COUNT(*) FROM backoff_state WHERE consecutive_failures > 0;" 2>/dev/null || echo "0")
  [[ "$active" == "0" ]] && echo "  ✅ No active backoffs"
  echo ""
  
  # Daily stats
  echo "Today's Stats:"
  sqlite3 "$DB" "SELECT action, count, errors, ROUND(avg_latency_ms) FROM daily_stats WHERE date=date('now');" 2>/dev/null | while IFS='|' read -r action count errors latency; do
    echo "  $action: $count requests, $errors errors, ${latency}ms avg latency"
  done
  
  local today_total
  today_total=$(sqlite3 "$DB" "SELECT COALESCE(SUM(count),0) FROM daily_stats WHERE date=date('now');" 2>/dev/null || echo "0")
  [[ "$today_total" == "0" ]] && echo "  (no requests today)"
}

# Show history
cmd_history() {
  local hours="${1:-24}"
  echo "📜 Rate Limiter History (last ${hours}h)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  
  sqlite3 -column -header "$DB" "
    SELECT ts, action, target, status, latency_ms, error
    FROM rate_log
    WHERE ts > datetime('now', '-$hours hours')
    ORDER BY ts DESC
    LIMIT 30;
  " 2>/dev/null
  
  echo ""
  echo "Summary:"
  sqlite3 "$DB" "
    SELECT action, COUNT(*) as total,
           SUM(CASE WHEN status < 400 THEN 1 ELSE 0 END) as success,
           SUM(CASE WHEN status >= 400 THEN 1 ELSE 0 END) as errors,
           ROUND(AVG(latency_ms)) as avg_ms
    FROM rate_log
    WHERE ts > datetime('now', '-$hours hours')
    GROUP BY action;
  " 2>/dev/null
}

# Show backoff state
cmd_backoff() {
  echo "⏳ Backoff State"
  echo "━━━━━━━━━━━━━━━"
  sqlite3 -column -header "$DB" "SELECT * FROM backoff_state;" 2>/dev/null
}

# Show config
cmd_config() {
  echo "⚙️  Rate Limiter Configuration"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  API:              $API"
  echo "  DB:               $DB"
  echo "  Max sends/min:    $MAX_SENDS_PER_MIN"
  echo "  Max sends/hour:   $MAX_SENDS_PER_HOUR"
  echo "  Max polls/min:    $MAX_POLLS_PER_MIN"
  echo "  Backoff base:     ${BACKOFF_BASE}s"
  echo "  Backoff max:      ${BACKOFF_MAX}s"
  echo "  Burst cooldown:   ${BURST_COOLDOWN}s"
  echo "  Agent:            RealAaron"
}

# Reset counters
cmd_reset() {
  sqlite3 "$DB" "DELETE FROM rate_log; DELETE FROM backoff_state; DELETE FROM daily_stats;"
  echo "✅ All rate limit counters reset"
}

# Main
[[ "${1:-}" == "" || "${1:-}" == "--help" || "${1:-}" == "-h" ]] && usage

init_db

case "${1:-}" in
  send)
    [[ -z "${2:-}" || -z "${3:-}" ]] && { echo "Usage: $0 send <to> <text>"; exit 1; }
    cmd_send "$2" "$3"
    ;;
  poll)
    local_limit="${2:-10}"
    [[ "${2:-}" == "--limit" ]] && local_limit="${3:-10}"
    cmd_poll "$local_limit"
    ;;
  burst)
    [[ -z "${2:-}" || -z "${3:-}" ]] && { echo "Usage: $0 burst <to> <file>"; exit 1; }
    cmd_burst "$2" "$3"
    ;;
  quota) cmd_quota ;;
  history)
    hours="${2:-24}"
    [[ "${2:-}" == "--hours" ]] && hours="${3:-24}"
    cmd_history "$hours"
    ;;
  backoff) cmd_backoff ;;
  config) cmd_config ;;
  reset) cmd_reset ;;
  *) echo "Unknown command: $1"; usage ;;
esac
