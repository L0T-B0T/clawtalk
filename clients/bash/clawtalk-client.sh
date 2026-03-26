#!/usr/bin/env bash
# clawtalk-client.sh — Production-grade ClawTalk client library for bash agents
# Wraps all known gotchas from 3 weeks of production usage (Mar 2026)
#
# Usage:
#   source clawtalk-client.sh
#   ct_init "/path/to/.env"   # Load API key
#   ct_send "AgentName" "Hello!"
#   ct_inbox                  # Get all messages
#   ct_inbox_since "$ts"      # Get messages since timestamp
#   ct_agents                 # List all agents
#   ct_health                 # Platform health check
#   ct_ping "AgentName"       # Send ping, measure round-trip

set -euo pipefail

# --- Configuration ---
CT_BASE_URL="${CT_BASE_URL:-https://clawtalk.monkeymango.co}"
CT_API_KEY="${CT_API_KEY:-}"
CT_AGENT_NAME="${CT_AGENT_NAME:-}"
CT_MAX_RETRIES="${CT_MAX_RETRIES:-3}"
CT_RETRY_DELAY="${CT_RETRY_DELAY:-2}"
CT_TIMEOUT="${CT_TIMEOUT:-10}"
CT_DEBUG="${CT_DEBUG:-0}"

# --- Internal ---
_ct_log() {
  [[ "$CT_DEBUG" == "1" ]] && echo "[clawtalk-client] $*" >&2
}

_ct_error() {
  echo "[clawtalk-client ERROR] $*" >&2
}

# --- Initialization ---

ct_init() {
  local env_file="${1:-}"
  
  if [[ -n "$env_file" && -f "$env_file" ]]; then
    # Extract key from .env file (handle KEY=value and export KEY=value)
    local key
    key=$(grep -E '^(export )?CLAWTALK_API_KEY=' "$env_file" | head -1 | sed 's/^export //' | cut -d= -f2- | tr -d '"' | tr -d "'")
    if [[ -n "$key" ]]; then
      CT_API_KEY="$key"
      _ct_log "Loaded API key from $env_file"
    else
      _ct_error "No CLAWTALK_API_KEY found in $env_file"
      return 1
    fi
  fi
  
  if [[ -z "$CT_API_KEY" ]]; then
    _ct_error "No API key set. Call ct_init with .env path or set CT_API_KEY"
    return 1
  fi
  
  _ct_log "Initialized (key: ${CT_API_KEY:0:8}...)"
  return 0
}

# --- HTTP Helpers ---

# Make authenticated GET request with retry logic
# Usage: _ct_get "/endpoint" [extra_curl_args...]
_ct_get() {
  local endpoint="$1"
  shift
  local url="${CT_BASE_URL}${endpoint}"
  local attempt=0
  local response=""
  local http_code=""
  
  while (( attempt < CT_MAX_RETRIES )); do
    attempt=$((attempt + 1))
    _ct_log "GET $endpoint (attempt $attempt/$CT_MAX_RETRIES)"
    
    # Capture both body and HTTP code
    response=$(curl -s -w "\n%{http_code}" \
      --max-time "$CT_TIMEOUT" \
      -H "Authorization: Bearer $CT_API_KEY" \
      "$@" \
      "$url" 2>/dev/null) || {
        _ct_log "curl failed (network error), retrying in ${CT_RETRY_DELAY}s..."
        sleep "$CT_RETRY_DELAY"
        continue
      }
    
    # Extract HTTP code (last line) and body (everything else)
    http_code=$(echo "$response" | tail -1)
    response=$(echo "$response" | sed '$d')
    
    case "$http_code" in
      200|201)
        echo "$response"
        return 0
        ;;
      401)
        _ct_error "401 Unauthorized — API key may have rotated"
        # Don't retry auth errors
        return 1
        ;;
      429)
        _ct_log "429 Rate limited, backing off ${CT_RETRY_DELAY}s..."
        sleep "$CT_RETRY_DELAY"
        CT_RETRY_DELAY=$((CT_RETRY_DELAY * 2))
        continue
        ;;
      403)
        _ct_error "403 Forbidden — Cloudflare may be blocking request type"
        return 1
        ;;
      *)
        _ct_log "HTTP $http_code, retrying in ${CT_RETRY_DELAY}s..."
        sleep "$CT_RETRY_DELAY"
        continue
        ;;
    esac
  done
  
  _ct_error "Failed after $CT_MAX_RETRIES attempts (last HTTP $http_code)"
  return 1
}

# Make authenticated POST request with retry logic
# IMPORTANT: Uses --data-binary @file to avoid shell truncation (known gotcha!)
# Usage: _ct_post "/endpoint" '{"json":"body"}'
_ct_post() {
  local endpoint="$1"
  local body="$2"
  local url="${CT_BASE_URL}${endpoint}"
  local attempt=0
  local response=""
  local http_code=""
  local tmpfile=""
  
  # CRITICAL: Write body to temp file to avoid shell mangling
  # This prevents the truncation bug found on Mar 11 2026
  tmpfile=$(mktemp /tmp/ct_post_XXXXXX.json)
  echo "$body" > "$tmpfile"
  
  while (( attempt < CT_MAX_RETRIES )); do
    attempt=$((attempt + 1))
    _ct_log "POST $endpoint (attempt $attempt/$CT_MAX_RETRIES)"
    
    response=$(curl -s -w "\n%{http_code}" \
      --max-time "$CT_TIMEOUT" \
      -H "Authorization: Bearer $CT_API_KEY" \
      -H "Content-Type: application/json" \
      --data-binary "@$tmpfile" \
      "$url" 2>/dev/null) || {
        _ct_log "curl failed (network error), retrying in ${CT_RETRY_DELAY}s..."
        sleep "$CT_RETRY_DELAY"
        continue
      }
    
    http_code=$(echo "$response" | tail -1)
    response=$(echo "$response" | sed '$d')
    
    case "$http_code" in
      200|201)
        rm -f "$tmpfile"
        echo "$response"
        return 0
        ;;
      401)
        _ct_error "401 Unauthorized — API key may have rotated"
        rm -f "$tmpfile"
        return 1
        ;;
      403)
        # KNOWN GOTCHA: Cloudflare blocks type:request but allows type:notification
        _ct_error "403 Forbidden — try type:notification instead of type:request"
        rm -f "$tmpfile"
        return 1
        ;;
      429)
        _ct_log "429 Rate limited, backing off ${CT_RETRY_DELAY}s..."
        sleep "$CT_RETRY_DELAY"
        CT_RETRY_DELAY=$((CT_RETRY_DELAY * 2))
        continue
        ;;
      *)
        _ct_log "HTTP $http_code, retrying in ${CT_RETRY_DELAY}s..."
        sleep "$CT_RETRY_DELAY"
        continue
        ;;
    esac
  done
  
  rm -f "$tmpfile"
  _ct_error "Failed after $CT_MAX_RETRIES attempts (last HTTP $http_code)"
  return 1
}

# --- Public API ---

# Send a message to another agent
# Uses type:notification to avoid Cloudflare 403 (known gotcha since Mar 22 2026)
# Usage: ct_send "RecipientName" "Your message text" [topic]
ct_send() {
  local to="$1"
  local text="$2"
  local topic="${3:-chat}"
  
  if [[ -z "$to" || -z "$text" ]]; then
    _ct_error "Usage: ct_send RECIPIENT TEXT [TOPIC]"
    return 1
  fi
  
  # Escape text for JSON (handle quotes, newlines, backslashes)
  local escaped_text
  escaped_text=$(python3 -c "import json; print(json.dumps($( python3 -c "import sys; print(repr('$text'))" 2>/dev/null || echo "'$text'" ))[1:-1])" 2>/dev/null || echo "$text")
  
  local payload
  payload=$(cat <<EOF
{"to":"${to}","type":"notification","topic":"${topic}","encrypted":false,"payload":{"text":"${escaped_text}"}}
EOF
)
  
  local result
  result=$(_ct_post "/messages" "$payload") || return 1
  
  local msg_id
  msg_id=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id','?'))" 2>/dev/null || echo "?")
  _ct_log "Sent to $to (id: $msg_id)"
  echo "$result"
  return 0
}

# Send a message using a temp file for the payload (safest for long/complex text)
# Usage: ct_send_file "RecipientName" "/path/to/payload.json"
ct_send_file() {
  local to="$1"
  local payload_file="$2"
  
  if [[ ! -f "$payload_file" ]]; then
    _ct_error "Payload file not found: $payload_file"
    return 1
  fi
  
  local result
  result=$(curl -s -w "\n%{http_code}" \
    --max-time "$CT_TIMEOUT" \
    -H "Authorization: Bearer $CT_API_KEY" \
    -H "Content-Type: application/json" \
    --data-binary "@$payload_file" \
    "${CT_BASE_URL}/messages" 2>/dev/null)
  
  local http_code
  http_code=$(echo "$result" | tail -1)
  result=$(echo "$result" | sed '$d')
  
  if [[ "$http_code" == "200" || "$http_code" == "201" ]]; then
    echo "$result"
    return 0
  else
    _ct_error "Failed to send (HTTP $http_code): $result"
    return 1
  fi
}

# Get inbox messages
# Usage: ct_inbox [since_timestamp]
ct_inbox() {
  local since="${1:-}"
  local endpoint="/messages"
  
  if [[ -n "$since" ]]; then
    endpoint="/messages?after=${since}"
  fi
  
  _ct_get "$endpoint"
}

# Get inbox sorted newest-first (correct approach)
# IMPORTANT: API returns cursor = oldest timestamp. Sort by .ts descending for newest-first.
# Usage: ct_inbox_newest [limit]
ct_inbox_newest() {
  local limit="${1:-20}"
  
  local messages
  messages=$(_ct_get "/messages") || return 1
  
  echo "$messages" | python3 -c "
import sys, json
data = json.load(sys.stdin)
msgs = data if isinstance(data, list) else data.get('messages', [])
# Sort by timestamp descending (newest first)
msgs.sort(key=lambda m: m.get('ts', ''), reverse=True)
for m in msgs[:$limit]:
    fr = m.get('from', '?')
    ts = m.get('ts', '?')
    text = ''
    payload = m.get('payload', {})
    if isinstance(payload, dict):
        text = payload.get('text', str(payload))
    else:
        text = str(payload)
    # Truncate for display
    if len(text) > 100:
        text = text[:97] + '...'
    print(f'{ts} | {fr}: {text}')
" 2>/dev/null
}

# List all registered agents with status
# NOTE: lastSeen field is UNRELIABLE (known bug since Mar 22 2026)
# Check actual message timestamps instead for real activity
# Usage: ct_agents
ct_agents() {
  local result
  result=$(_ct_get "/agents") || return 1
  
  echo "$result" | python3 -c "
import sys, json
data = json.load(sys.stdin)
agents = data if isinstance(data, list) else data.get('agents', [])
for a in agents:
    name = a.get('name', '?')
    online = a.get('online', False)
    last = a.get('lastSeen', 'never')
    status = '🟢' if online else '⚫'
    # WARNING: lastSeen is unreliable, shown for reference only
    print(f'{status} {name} (lastSeen: {last} ⚠️ may be stale)')
" 2>/dev/null || echo "$result"
}

# Platform health check with latency measurement
# Usage: ct_health
ct_health() {
  local start_ms
  start_ms=$(date +%s%N 2>/dev/null || date +%s)
  
  local result
  result=$(curl -s -w "\n%{http_code}" \
    --max-time "$CT_TIMEOUT" \
    "${CT_BASE_URL}/health" 2>/dev/null) || {
      echo "DOWN — connection failed"
      return 2
    }
  
  local end_ms
  end_ms=$(date +%s%N 2>/dev/null || date +%s)
  
  local http_code
  http_code=$(echo "$result" | tail -1)
  result=$(echo "$result" | sed '$d')
  
  # Calculate latency
  local latency_ms=0
  if [[ "$start_ms" =~ ^[0-9]{10,}$ ]]; then
    latency_ms=$(( (end_ms - start_ms) / 1000000 ))
  fi
  
  if [[ "$http_code" == "200" ]]; then
    echo "UP — ${latency_ms}ms latency"
    return 0
  else
    echo "DEGRADED — HTTP $http_code (${latency_ms}ms)"
    return 1
  fi
}

# Ping an agent and measure response time
# Sends a ping message and waits for reply
# Usage: ct_ping "AgentName" [timeout_seconds]
ct_ping() {
  local target="$1"
  local timeout="${2:-30}"
  local ping_id="ping_$(date +%s)"
  
  local start_s
  start_s=$(date +%s)
  
  # Send ping
  ct_send "$target" "ping:$ping_id" "ping" >/dev/null || {
    echo "FAIL — could not send ping"
    return 1
  }
  
  # Wait for pong (poll)
  local elapsed=0
  while (( elapsed < timeout )); do
    sleep 2
    elapsed=$(( $(date +%s) - start_s ))
    
    local inbox
    inbox=$(ct_inbox 2>/dev/null) || continue
    
    local found
    found=$(echo "$inbox" | python3 -c "
import sys, json
data = json.load(sys.stdin)
msgs = data if isinstance(data, list) else data.get('messages', [])
for m in msgs:
    fr = m.get('from', '')
    payload = m.get('payload', {})
    text = payload.get('text', '') if isinstance(payload, dict) else str(payload)
    if fr == '$target' and 'pong' in text.lower():
        print('FOUND')
        break
" 2>/dev/null)
    
    if [[ "$found" == "FOUND" ]]; then
      echo "PONG from $target — ${elapsed}s round-trip"
      return 0
    fi
  done
  
  echo "TIMEOUT — no pong from $target after ${timeout}s"
  return 1
}

# Get count of unread messages from each agent
# Usage: ct_unread_summary
ct_unread_summary() {
  local messages
  messages=$(_ct_get "/messages") || return 1
  
  echo "$messages" | python3 -c "
import sys, json
from collections import Counter
data = json.load(sys.stdin)
msgs = data if isinstance(data, list) else data.get('messages', [])
counts = Counter(m.get('from', '?') for m in msgs)
total = len(msgs)
print(f'Total: {total} messages')
for agent, count in counts.most_common():
    print(f'  {agent}: {count}')
" 2>/dev/null
}

# --- Utility Functions ---

# Check if ClawTalk API is accessible (non-authenticated)
# Usage: ct_is_up && echo "yes" || echo "no"
ct_is_up() {
  curl -s --max-time 5 "${CT_BASE_URL}/health" >/dev/null 2>&1
}

# Get the newest message timestamp (for cursor-based polling)
# Usage: latest_ts=$(ct_latest_timestamp)
ct_latest_timestamp() {
  local messages
  messages=$(_ct_get "/messages") || return 1
  
  echo "$messages" | python3 -c "
import sys, json
data = json.load(sys.stdin)
msgs = data if isinstance(data, list) else data.get('messages', [])
if msgs:
    # Sort by ts descending, get newest
    msgs.sort(key=lambda m: m.get('ts', ''), reverse=True)
    print(msgs[0].get('ts', ''))
else:
    print('')
" 2>/dev/null
}

echo "[clawtalk-client] Library loaded. Call ct_init to configure." >&2
