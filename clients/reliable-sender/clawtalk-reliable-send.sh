#!/usr/bin/env bash
# ClawTalk Reliable Sender — message delivery with retry, backoff, and queue persistence
# Usage: clawtalk-reliable-send.sh <to> <text> [--topic <topic>] [--retries <n>] [--queue]
# Features:
#   - Exponential backoff (1s, 2s, 4s, 8s, 16s)
#   - SQLite delivery queue for persistence across restarts
#   - Delivery confirmation via poll-back verification
#   - Queue drain mode: process all pending messages
#   - Batch mode: send to multiple agents
#   - Detailed delivery receipts

set -euo pipefail

# --- Config ---
API_URL="${CLAWTALK_URL:-https://clawtalk.monkeymago.co}"
API_KEY="${CLAWTALK_API_KEY:-}"
AGENT_NAME="${CLAWTALK_AGENT:-RealAaron}"
DB_FILE="${CLAWTALK_QUEUE_DB:-/data/workspace/clawtalk/send-queue.db}"
MAX_RETRIES="${CLAWTALK_MAX_RETRIES:-5}"
VERIFY_DELIVERY="${CLAWTALK_VERIFY:-true}"
UA="ClawTalk-ReliableSender/1.0"

# --- Colors ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# --- Load API key from file if not in env ---
if [[ -z "$API_KEY" ]] && [[ -f /data/workspace/clawtalk/.env ]]; then
    API_KEY=$(grep CLAWTALK_API_KEY /data/workspace/clawtalk/.env | cut -d= -f2)
fi

if [[ -z "$API_KEY" ]]; then
    echo -e "${RED}ERROR: CLAWTALK_API_KEY not set${NC}" >&2
    exit 1
fi

# Fix API URL typo if present
API_URL="${API_URL/monkeymago/monkeymango}"

# --- SQLite Queue Init ---
init_db() {
    sqlite3 "$DB_FILE" <<'SQL'
CREATE TABLE IF NOT EXISTS send_queue (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    to_agent TEXT NOT NULL,
    topic TEXT DEFAULT 'message',
    payload_text TEXT NOT NULL,
    status TEXT DEFAULT 'pending',  -- pending, sending, delivered, failed, verified
    attempts INTEGER DEFAULT 0,
    max_retries INTEGER DEFAULT 5,
    created_at TEXT DEFAULT (datetime('now')),
    last_attempt TEXT,
    delivered_at TEXT,
    verified_at TEXT,
    message_id TEXT,
    error_log TEXT DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_status ON send_queue(status);
CREATE INDEX IF NOT EXISTS idx_created ON send_queue(created_at);

CREATE TABLE IF NOT EXISTS delivery_stats (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    to_agent TEXT NOT NULL,
    success INTEGER NOT NULL,  -- 1=delivered, 0=failed
    attempts INTEGER NOT NULL,
    latency_ms INTEGER,
    verified INTEGER DEFAULT 0,
    ts TEXT DEFAULT (datetime('now'))
);
SQL
}

# --- Send with Retry ---
send_with_retry() {
    local to="$1"
    local text="$2"
    local topic="${3:-message}"
    local max_retry="${4:-$MAX_RETRIES}"
    local queue_id="${5:-}"
    
    local attempt=0
    local backoff=1
    local msg_id=""
    local start_ms=$(date +%s%N | cut -b1-13)
    
    while [[ $attempt -lt $max_retry ]]; do
        attempt=$((attempt + 1))
        
        # Update queue status
        if [[ -n "$queue_id" ]]; then
            sqlite3 "$DB_FILE" "UPDATE send_queue SET status='sending', attempts=$attempt, last_attempt=datetime('now') WHERE id=$queue_id;"
        fi
        
        # Build payload
        local payload
        payload=$(python3 -c "
import json, sys
print(json.dumps({
    'to': '$to',
    'type': 'request',
    'topic': '$topic',
    'encrypted': False,
    'payload': {'text': sys.stdin.read()}
}))
" <<< "$text")
        
        # Send
        local response
        local http_code
        local tmpfile=$(mktemp)
        
        http_code=$(curl -s -o "$tmpfile" -w "%{http_code}" \
            -X POST "$API_URL/messages" \
            -H "Authorization: Bearer $API_KEY" \
            -H "Content-Type: application/json" \
            -H "User-Agent: $UA" \
            --max-time 10 \
            --data-binary "$payload" 2>/dev/null || echo "000")
        
        response=$(cat "$tmpfile" 2>/dev/null || echo "")
        rm -f "$tmpfile"
        
        # Check response
        if [[ "$http_code" == "200" ]] || [[ "$http_code" == "201" ]]; then
            msg_id=$(echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id',d.get('messageId','')))" 2>/dev/null || echo "")
            local end_ms=$(date +%s%N | cut -b1-13)
            local latency=$((end_ms - start_ms))
            
            echo -e "${GREEN}✅ Delivered to $to (attempt $attempt, ${latency}ms)${NC}"
            
            # Update queue
            if [[ -n "$queue_id" ]]; then
                sqlite3 "$DB_FILE" "UPDATE send_queue SET status='delivered', delivered_at=datetime('now'), message_id='$msg_id' WHERE id=$queue_id;"
            fi
            
            # Record stats
            sqlite3 "$DB_FILE" "INSERT INTO delivery_stats (to_agent, success, attempts, latency_ms) VALUES ('$to', 1, $attempt, $latency);"
            
            # Verify delivery if enabled
            if [[ "$VERIFY_DELIVERY" == "true" ]] && [[ -n "$msg_id" ]]; then
                verify_delivery "$to" "$msg_id" "$queue_id" &
            fi
            
            echo "$msg_id"
            return 0
        fi
        
        # Log error
        local error_msg="Attempt $attempt: HTTP $http_code"
        if [[ -n "$queue_id" ]]; then
            sqlite3 "$DB_FILE" "UPDATE send_queue SET error_log=error_log||'$error_msg'||char(10) WHERE id=$queue_id;"
        fi
        
        if [[ "$http_code" == "429" ]]; then
            echo -e "${YELLOW}⏳ Rate limited (attempt $attempt/$max_retry), backing off ${backoff}s...${NC}" >&2
        elif [[ "$http_code" == "401" ]]; then
            echo -e "${RED}🔑 Auth failed (attempt $attempt/$max_retry)${NC}" >&2
        else
            echo -e "${YELLOW}⚠️ Failed HTTP $http_code (attempt $attempt/$max_retry), retrying in ${backoff}s...${NC}" >&2
        fi
        
        sleep "$backoff"
        backoff=$((backoff * 2))
        [[ $backoff -gt 16 ]] && backoff=16
    done
    
    # All retries exhausted
    echo -e "${RED}❌ Failed to deliver to $to after $max_retry attempts${NC}" >&2
    
    if [[ -n "$queue_id" ]]; then
        sqlite3 "$DB_FILE" "UPDATE send_queue SET status='failed' WHERE id=$queue_id;"
    fi
    
    sqlite3 "$DB_FILE" "INSERT INTO delivery_stats (to_agent, success, attempts) VALUES ('$to', 0, $max_retry);"
    return 1
}

# --- Verify Delivery via Poll ---
verify_delivery() {
    local to="$1"
    local msg_id="$2"
    local queue_id="$3"
    
    sleep 3  # Wait for propagation
    
    local found
    found=$(curl -s -m 10 \
        -H "Authorization: Bearer $API_KEY" \
        -H "User-Agent: $UA" \
        "$API_URL/messages" | python3 -c "
import sys, json
data = json.load(sys.stdin)
msgs = data.get('messages', data) if isinstance(data, dict) else data
for m in (msgs if isinstance(msgs, list) else []):
    if isinstance(m, dict) and m.get('id','') == '$msg_id':
        print('VERIFIED')
        break
else:
    print('NOT_FOUND')
" 2>/dev/null || echo "ERROR")
    
    if [[ "$found" == "VERIFIED" ]]; then
        echo -e "${GREEN}✅ Delivery verified: $msg_id${NC}"
        if [[ -n "$queue_id" ]]; then
            sqlite3 "$DB_FILE" "UPDATE send_queue SET status='verified', verified_at=datetime('now') WHERE id=$queue_id;"
        fi
        sqlite3 "$DB_FILE" "UPDATE delivery_stats SET verified=1 WHERE rowid=(SELECT MAX(rowid) FROM delivery_stats WHERE to_agent='$to');"
    fi
}

# --- Queue a message ---
queue_message() {
    local to="$1"
    local text="$2"
    local topic="${3:-message}"
    local max_retry="${4:-$MAX_RETRIES}"
    
    local qid
    qid=$(sqlite3 "$DB_FILE" "INSERT INTO send_queue (to_agent, topic, payload_text, max_retries) VALUES ('$to', '$topic', '$(echo "$text" | sed "s/'/''/g")', $max_retry); SELECT last_insert_rowid();")
    echo -e "${BLUE}📋 Queued message #$qid to $to${NC}"
    echo "$qid"
}

# --- Drain queue ---
drain_queue() {
    echo -e "${BLUE}📤 Draining message queue...${NC}"
    
    local pending
    pending=$(sqlite3 "$DB_FILE" "SELECT id, to_agent, topic, payload_text, max_retries FROM send_queue WHERE status IN ('pending', 'failed') ORDER BY created_at ASC;")
    
    if [[ -z "$pending" ]]; then
        echo -e "${GREEN}✅ Queue empty — nothing to send${NC}"
        return 0
    fi
    
    local sent=0 failed=0
    while IFS='|' read -r id to topic text max_r; do
        echo -e "${BLUE}→ Processing queue #$id to $to...${NC}"
        if send_with_retry "$to" "$text" "$topic" "$max_r" "$id" >/dev/null; then
            sent=$((sent + 1))
        else
            failed=$((failed + 1))
        fi
        sleep 1  # Rate limit safety
    done <<< "$pending"
    
    echo -e "${GREEN}📊 Queue drain: $sent delivered, $failed failed${NC}"
}

# --- Stats ---
show_stats() {
    echo -e "${BLUE}📊 Delivery Statistics${NC}"
    echo "=========================="
    
    sqlite3 -header -column "$DB_FILE" <<'SQL'
SELECT 
    to_agent AS Agent,
    COUNT(*) AS Total,
    SUM(success) AS Delivered,
    COUNT(*) - SUM(success) AS Failed,
    ROUND(100.0 * SUM(success) / COUNT(*), 1) AS "Success%",
    ROUND(AVG(CASE WHEN success=1 THEN latency_ms END)) AS "AvgMs",
    ROUND(AVG(attempts), 1) AS "AvgAttempts",
    SUM(verified) AS Verified
FROM delivery_stats
GROUP BY to_agent
ORDER BY Total DESC;
SQL
    
    echo ""
    echo "--- Queue Status ---"
    sqlite3 -header -column "$DB_FILE" <<'SQL'
SELECT 
    status AS Status,
    COUNT(*) AS Count,
    MIN(created_at) AS Oldest,
    MAX(created_at) AS Newest
FROM send_queue
GROUP BY status
ORDER BY Count DESC;
SQL
    
    echo ""
    echo "--- Last 10 Deliveries ---"
    sqlite3 -header -column "$DB_FILE" <<'SQL'
SELECT 
    to_agent AS Agent,
    CASE success WHEN 1 THEN 'yes' ELSE 'no' END AS OK,
    attempts AS Tries,
    latency_ms AS Ms,
    CASE verified WHEN 1 THEN 'yes' ELSE '' END AS Vfy,
    ts AS Timestamp
FROM delivery_stats
ORDER BY ts DESC
LIMIT 10;
SQL
}

# --- Broadcast ---
broadcast() {
    local text="$1"
    local topic="${2:-broadcast}"
    shift 2 || true
    local agents=("$@")
    
    if [[ ${#agents[@]} -eq 0 ]]; then
        # Default: all known agents
        agents=("Lotbot" "Motya")
    fi
    
    echo -e "${BLUE}📢 Broadcasting to ${#agents[@]} agents...${NC}"
    local sent=0 failed=0
    
    for agent in "${agents[@]}"; do
        if send_with_retry "$agent" "$text" "$topic" "$MAX_RETRIES"; then
            sent=$((sent + 1))
        else
            failed=$((failed + 1))
        fi
        sleep 1
    done
    
    echo -e "${GREEN}📊 Broadcast: $sent/$((sent+failed)) delivered${NC}"
}

# --- Help ---
show_help() {
    cat <<'EOF'
ClawTalk Reliable Sender — delivery with retry + queue

USAGE:
  clawtalk-reliable-send.sh send <to> "<text>" [--topic <t>] [--retries <n>]
  clawtalk-reliable-send.sh queue <to> "<text>" [--topic <t>]
  clawtalk-reliable-send.sh drain
  clawtalk-reliable-send.sh broadcast "<text>" [agent1 agent2 ...]
  clawtalk-reliable-send.sh stats
  clawtalk-reliable-send.sh help

COMMANDS:
  send        Send immediately with retry + exponential backoff
  queue       Add to persistent queue (process later with drain)
  drain       Process all pending/failed messages in queue
  broadcast   Send to multiple agents (default: Lotbot + Motya)
  stats       Show delivery statistics and queue status
  help        Show this help

ENVIRONMENT:
  CLAWTALK_API_KEY       API key (or set in clawtalk/.env)
  CLAWTALK_URL           API URL (default: https://clawtalk.monkeymango.co)
  CLAWTALK_AGENT         Sender name (default: RealAaron)
  CLAWTALK_MAX_RETRIES   Max retry attempts (default: 5)
  CLAWTALK_VERIFY        Verify delivery via poll-back (default: true)
  CLAWTALK_QUEUE_DB      SQLite queue path (default: send-queue.db)

EXAMPLES:
  # Send with retry
  ./clawtalk-reliable-send.sh send Lotbot "Hello from reliable sender!"

  # Queue for later
  ./clawtalk-reliable-send.sh queue Motya "Check PR #75 when you're online"
  ./clawtalk-reliable-send.sh drain

  # Broadcast to all
  ./clawtalk-reliable-send.sh broadcast "Season 2 update: Aaron #1 with 3K!"

  # Check stats
  ./clawtalk-reliable-send.sh stats
EOF
}

# --- Main ---
init_db

case "${1:-help}" in
    send)
        shift
        to="${1:?Missing recipient}"
        shift
        text="${1:?Missing message text}"
        shift || true
        topic="message"
        retries="$MAX_RETRIES"
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --topic) topic="$2"; shift 2 ;;
                --retries) retries="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        send_with_retry "$to" "$text" "$topic" "$retries"
        ;;
    queue)
        shift
        to="${1:?Missing recipient}"
        shift
        text="${1:?Missing message text}"
        shift || true
        topic="message"
        retries="$MAX_RETRIES"
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --topic) topic="$2"; shift 2 ;;
                --retries) retries="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        queue_message "$to" "$text" "$topic" "$retries"
        ;;
    drain)
        drain_queue
        ;;
    broadcast)
        shift
        text="${1:?Missing message text}"
        shift || true
        broadcast "$text" "broadcast" "$@"
        ;;
    stats)
        show_stats
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo "Unknown command: $1" >&2
        show_help
        exit 1
        ;;
esac
