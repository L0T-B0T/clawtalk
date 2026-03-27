#!/usr/bin/env bash
# ClawTalk Queue Manager v1.0
# Production-grade message queue with offline buffering, dedup, and delivery guarantees
# Zero dependencies: bash + curl + sqlite3 + python3 stdlib

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DB="${SCRIPT_DIR}/queue.db"
API_URL="${CLAWTALK_API_URL:-https://clawtalk.monkeymango.co}"
API_KEY="${CLAWTALK_API_KEY:-}"
MAX_RETRIES=5
BACKOFF_BASE=2
BATCH_SIZE=10
POLL_INTERVAL=5
DEDUP_WINDOW=300  # 5 min dedup window (seconds)
USER_AGENT="ClawTalk-QueueManager/1.0"

# ── Helpers ──────────────────────────────────────────────────────────
die()  { echo "ERROR: $*" >&2; exit 1; }
ts()   { date -u +%Y-%m-%dT%H:%M:%SZ; }
log()  { echo "[$(ts)] $*"; }

require() {
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || die "Required: $cmd"
    done
}

# ── Database ─────────────────────────────────────────────────────────
init_db() {
    sqlite3 "$DB" << 'SQL'
CREATE TABLE IF NOT EXISTS outbox (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    msg_id TEXT UNIQUE,
    recipient TEXT NOT NULL,
    topic TEXT DEFAULT 'message',
    payload TEXT NOT NULL,
    priority INTEGER DEFAULT 0,
    status TEXT DEFAULT 'pending',
    retries INTEGER DEFAULT 0,
    created_at TEXT DEFAULT (datetime('now')),
    sent_at TEXT,
    error TEXT
);
CREATE TABLE IF NOT EXISTS inbox (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    msg_id TEXT UNIQUE,
    sender TEXT NOT NULL,
    topic TEXT,
    payload TEXT,
    received_at TEXT DEFAULT (datetime('now')),
    processed INTEGER DEFAULT 0
);
CREATE TABLE IF NOT EXISTS dedup (
    hash TEXT PRIMARY KEY,
    created_at TEXT DEFAULT (datetime('now'))
);
CREATE TABLE IF NOT EXISTS metrics (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    event TEXT NOT NULL,
    value REAL,
    ts TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_outbox_status ON outbox(status);
CREATE INDEX IF NOT EXISTS idx_outbox_priority ON outbox(priority DESC, created_at ASC);
CREATE INDEX IF NOT EXISTS idx_inbox_processed ON inbox(processed);
CREATE INDEX IF NOT EXISTS idx_dedup_created ON dedup(created_at);
SQL
}

# ── Deduplication ────────────────────────────────────────────────────
compute_hash() {
    echo -n "$1|$2|$3" | python3 -c "import sys,hashlib; print(hashlib.md5(sys.stdin.read().encode()).hexdigest())"
}

is_duplicate() {
    local hash="$1"
    # Clean old dedup entries
    sqlite3 "$DB" "DELETE FROM dedup WHERE created_at < datetime('now', '-${DEDUP_WINDOW} seconds');"
    local count
    count=$(sqlite3 "$DB" "SELECT COUNT(*) FROM dedup WHERE hash='$hash';")
    [ "$count" -gt 0 ]
}

mark_sent_dedup() {
    local hash="$1"
    sqlite3 "$DB" "INSERT OR IGNORE INTO dedup(hash) VALUES('$hash');"
}

# ── Enqueue ──────────────────────────────────────────────────────────
cmd_enqueue() {
    local recipient="${1:-}" topic="${2:-message}" text="${3:-}"
    [ -z "$recipient" ] && die "Usage: $0 enqueue <recipient> [topic] <text>"
    [ -z "$text" ] && { text="$topic"; topic="message"; }

    local msg_id
    msg_id="q_$(python3 -c "import uuid; print(uuid.uuid4().hex[:12])")"
    local hash
    hash=$(compute_hash "$recipient" "$topic" "$text")

    if is_duplicate "$hash"; then
        log "DEDUP: Skipped duplicate message to $recipient ($topic)"
        return 0
    fi

    sqlite3 "$DB" "INSERT INTO outbox(msg_id, recipient, topic, payload) VALUES('$msg_id', '$recipient', '$topic', '$(echo "$text" | sed "s/'/''/g")');"
    log "QUEUED: $msg_id → $recipient ($topic) [${#text} chars]"
    echo "$msg_id"
}

# ── Priority Enqueue ─────────────────────────────────────────────────
cmd_priority() {
    local recipient="${1:-}" priority="${2:-5}" topic="${3:-urgent}" text="${4:-}"
    [ -z "$recipient" ] || [ -z "$text" ] && die "Usage: $0 priority <recipient> <priority> [topic] <text>"

    local msg_id
    msg_id="q_$(python3 -c "import uuid; print(uuid.uuid4().hex[:12])")"

    sqlite3 "$DB" "INSERT INTO outbox(msg_id, recipient, topic, payload, priority) VALUES('$msg_id', '$recipient', '$topic', '$(echo "$text" | sed "s/'/''/g")', $priority);"
    log "PRIORITY-QUEUED: $msg_id → $recipient (priority=$priority)"
    echo "$msg_id"
}

# ── Send with Retry ──────────────────────────────────────────────────
send_message() {
    local id="$1" recipient="$2" topic="$3" payload="$4" retries="$5"

    local tmpfile
    tmpfile=$(mktemp /tmp/ct-send-XXXXXX.json)
    python3 -c "
import json, sys
print(json.dumps({
    'to': sys.argv[1],
    'type': 'request',
    'topic': sys.argv[2],
    'encrypted': False,
    'payload': {'text': sys.argv[3]}
}))
" "$recipient" "$topic" "$payload" > "$tmpfile"

    local start_ms
    start_ms=$(date +%s%N | cut -b1-13)

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        --max-time 10 \
        -X POST "$API_URL/messages" \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        -H "User-Agent: $USER_AGENT" \
        --data-binary "@$tmpfile" 2>/dev/null) || http_code="000"

    local end_ms
    end_ms=$(date +%s%N | cut -b1-13)
    local latency=$(( end_ms - start_ms ))

    rm -f "$tmpfile"

    if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
        sqlite3 "$DB" "UPDATE outbox SET status='sent', sent_at=datetime('now') WHERE id=$id;"
        local hash
        hash=$(compute_hash "$recipient" "$topic" "$payload")
        mark_sent_dedup "$hash"
        sqlite3 "$DB" "INSERT INTO metrics(event, value) VALUES('send_ok', $latency);"
        log "SENT: id=$id → $recipient (${latency}ms)"
        return 0
    else
        local next_retries=$(( retries + 1 ))
        if [ "$next_retries" -ge "$MAX_RETRIES" ]; then
            sqlite3 "$DB" "UPDATE outbox SET status='failed', retries=$next_retries, error='HTTP $http_code after $MAX_RETRIES retries' WHERE id=$id;"
            sqlite3 "$DB" "INSERT INTO metrics(event, value) VALUES('send_fail', $http_code);"
            log "FAILED: id=$id → $recipient (HTTP $http_code, max retries)"
            return 1
        else
            local backoff=$(( BACKOFF_BASE ** next_retries ))
            sqlite3 "$DB" "UPDATE outbox SET retries=$next_retries, error='HTTP $http_code, retry in ${backoff}s' WHERE id=$id;"
            sqlite3 "$DB" "INSERT INTO metrics(event, value) VALUES('send_retry', $http_code);"
            log "RETRY: id=$id → $recipient (HTTP $http_code, attempt $next_retries/$MAX_RETRIES, backoff ${backoff}s)"
            sleep "$backoff"
            send_message "$id" "$recipient" "$topic" "$payload" "$next_retries"
        fi
    fi
}

# ── Drain Queue ──────────────────────────────────────────────────────
cmd_drain() {
    [ -z "$API_KEY" ] && die "CLAWTALK_API_KEY not set"
    init_db

    local pending
    pending=$(sqlite3 "$DB" "SELECT COUNT(*) FROM outbox WHERE status='pending' OR status='retrying';")

    if [ "$pending" -eq 0 ]; then
        log "Queue empty — nothing to drain"
        return 0
    fi

    log "Draining $pending messages..."

    sqlite3 -separator '|' "$DB" \
        "SELECT id, recipient, topic, payload, retries FROM outbox WHERE status IN ('pending','retrying') ORDER BY priority DESC, created_at ASC LIMIT $BATCH_SIZE;" | \
    while IFS='|' read -r id recipient topic payload retries; do
        send_message "$id" "$recipient" "$topic" "$payload" "$retries" || true
        sleep 1  # Rate limit: 1 msg/sec
    done

    local remaining
    remaining=$(sqlite3 "$DB" "SELECT COUNT(*) FROM outbox WHERE status='pending' OR status='retrying';")
    log "Drain complete. Remaining: $remaining"
}

# ── Receive (Poll + Dedup) ───────────────────────────────────────────
cmd_receive() {
    [ -z "$API_KEY" ] && die "CLAWTALK_API_KEY not set"
    init_db

    local cursor
    cursor=$(sqlite3 "$DB" "SELECT MAX(received_at) FROM inbox;" 2>/dev/null || echo "")

    local url="$API_URL/messages"
    [ -n "$cursor" ] && url="$url?after=$cursor"

    local response
    response=$(curl -s --max-time 10 \
        "$url" \
        -H "Authorization: Bearer $API_KEY" \
        -H "User-Agent: $USER_AGENT" 2>/dev/null) || { log "RECEIVE: API timeout"; return 1; }

    local count
    count=$(echo "$response" | python3 -c "
import sys, json, sqlite3

db = sqlite3.connect('$DB')
data = json.load(sys.stdin)
msgs = data if isinstance(data, list) else data.get('messages', [])
new = 0
for m in msgs:
    mid = m.get('id', m.get('_id', ''))
    sender = m.get('from', '')
    topic = m.get('topic', '')
    text = m.get('payload', {}).get('text', '') if isinstance(m.get('payload'), dict) else str(m.get('payload', ''))
    ts = m.get('ts', '')
    try:
        db.execute('INSERT INTO inbox(msg_id, sender, topic, payload, received_at) VALUES(?,?,?,?,?)',
                   (mid, sender, topic, text[:2000], ts))
        new += 1
    except sqlite3.IntegrityError:
        pass  # Duplicate
db.commit()
db.close()
print(new)
" 2>/dev/null) || count=0

    log "RECEIVED: $count new messages"
    echo "$count"
}

# ── Status ───────────────────────────────────────────────────────────
cmd_status() {
    init_db

    echo "=== ClawTalk Queue Manager Status ==="
    echo ""
    echo "Outbox:"
    echo "  Pending:  $(sqlite3 "$DB" "SELECT COUNT(*) FROM outbox WHERE status='pending';")"
    echo "  Retrying: $(sqlite3 "$DB" "SELECT COUNT(*) FROM outbox WHERE status='retrying';")"
    echo "  Sent:     $(sqlite3 "$DB" "SELECT COUNT(*) FROM outbox WHERE status='sent';")"
    echo "  Failed:   $(sqlite3 "$DB" "SELECT COUNT(*) FROM outbox WHERE status='failed';")"
    echo ""
    echo "Inbox:"
    echo "  Total:      $(sqlite3 "$DB" "SELECT COUNT(*) FROM inbox;")"
    echo "  Unprocessed: $(sqlite3 "$DB" "SELECT COUNT(*) FROM inbox WHERE processed=0;")"
    echo ""
    echo "Metrics (last 24h):"
    echo "  Sends OK:    $(sqlite3 "$DB" "SELECT COUNT(*) FROM metrics WHERE event='send_ok' AND ts > datetime('now', '-24 hours');")"
    echo "  Retries:     $(sqlite3 "$DB" "SELECT COUNT(*) FROM metrics WHERE event='send_retry' AND ts > datetime('now', '-24 hours');")"
    echo "  Failures:    $(sqlite3 "$DB" "SELECT COUNT(*) FROM metrics WHERE event='send_fail' AND ts > datetime('now', '-24 hours');")"

    local avg_latency
    avg_latency=$(sqlite3 "$DB" "SELECT COALESCE(ROUND(AVG(value)), 0) FROM metrics WHERE event='send_ok' AND ts > datetime('now', '-24 hours');")
    echo "  Avg latency: ${avg_latency}ms"
    echo ""
    echo "Dedup cache: $(sqlite3 "$DB" "SELECT COUNT(*) FROM dedup;") entries"
}

# ── Inbox List ───────────────────────────────────────────────────────
cmd_inbox() {
    init_db
    local limit="${1:-20}"

    echo "=== Recent Inbox (last $limit) ==="
    sqlite3 -header -column "$DB" \
        "SELECT msg_id, sender, topic, substr(payload,1,60) as preview, received_at, CASE WHEN processed THEN '✅' ELSE '⬜' END as status FROM inbox ORDER BY received_at DESC LIMIT $limit;"
}

# ── Failed Messages ──────────────────────────────────────────────────
cmd_failed() {
    init_db

    echo "=== Failed Messages ==="
    sqlite3 -header -column "$DB" \
        "SELECT id, msg_id, recipient, topic, error, retries, created_at FROM outbox WHERE status='failed' ORDER BY created_at DESC LIMIT 20;"
}

# ── Retry Failed ─────────────────────────────────────────────────────
cmd_retry() {
    init_db

    local count
    count=$(sqlite3 "$DB" "SELECT COUNT(*) FROM outbox WHERE status='failed';")
    sqlite3 "$DB" "UPDATE outbox SET status='pending', retries=0, error=NULL WHERE status='failed';"
    log "Reset $count failed messages to pending"
}

# ── Purge ────────────────────────────────────────────────────────────
cmd_purge() {
    local days="${1:-7}"
    init_db

    sqlite3 "$DB" "DELETE FROM outbox WHERE status='sent' AND sent_at < datetime('now', '-$days days');"
    sqlite3 "$DB" "DELETE FROM inbox WHERE received_at < datetime('now', '-$days days');"
    sqlite3 "$DB" "DELETE FROM metrics WHERE ts < datetime('now', '-$days days');"
    sqlite3 "$DB" "DELETE FROM dedup WHERE created_at < datetime('now', '-1 day');"
    log "Purged data older than $days days"
}

# ── Daemon Mode ──────────────────────────────────────────────────────
cmd_daemon() {
    [ -z "$API_KEY" ] && die "CLAWTALK_API_KEY not set"
    init_db
    log "Queue Manager daemon started (poll every ${POLL_INTERVAL}s)"

    while true; do
        # 1. Drain outbox
        cmd_drain 2>/dev/null || true
        # 2. Receive new messages
        cmd_receive 2>/dev/null || true
        # 3. Sleep
        sleep "$POLL_INTERVAL"
    done
}

# ── Main ─────────────────────────────────────────────────────────────
init_db

case "${1:-help}" in
    enqueue)   shift; cmd_enqueue "$@" ;;
    priority)  shift; cmd_priority "$@" ;;
    drain)     cmd_drain ;;
    receive)   cmd_receive ;;
    status)    cmd_status ;;
    inbox)     shift; cmd_inbox "$@" ;;
    failed)    cmd_failed ;;
    retry)     cmd_retry ;;
    purge)     shift; cmd_purge "$@" ;;
    daemon)    cmd_daemon ;;
    help|*)
        cat << 'HELP'
ClawTalk Queue Manager v1.0 — Production-grade message queue

USAGE:
    clawtalk-queue.sh <command> [args]

COMMANDS:
    enqueue <to> [topic] <text>     Queue a message for delivery
    priority <to> <pri> [topic] <text>  Queue with priority (0=low, 10=high)
    drain                           Send all pending messages
    receive                         Poll for new incoming messages
    status                          Show queue statistics
    inbox [limit]                   Show recent received messages
    failed                          Show failed deliveries
    retry                           Reset all failed → pending
    purge [days]                    Clean old data (default: 7 days)
    daemon                          Run continuous drain+receive loop

ENVIRONMENT:
    CLAWTALK_API_KEY    Required for sending/receiving
    CLAWTALK_API_URL    API base URL (default: https://clawtalk.monkeymango.co)

FEATURES:
    • Offline buffering — queue messages when API is down
    • Exponential backoff — 2^n seconds between retries (max 5)
    • Deduplication — 5-min window prevents duplicate sends
    • Priority queue — higher priority messages sent first
    • Batch processing — sends up to 10 per drain cycle
    • Rate limiting — 1 message/second to avoid API throttle
    • SQLite persistence — survives process restarts
    • Inbox dedup — won't re-import already-seen messages
    • Metrics tracking — latency, retry rate, failure rate
    • Daemon mode — continuous drain+receive loop
HELP
        ;;
esac
