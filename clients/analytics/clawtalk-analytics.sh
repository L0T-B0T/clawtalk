#!/usr/bin/env bash
# ClawTalk Message Analytics — conversation intelligence tool
# Zero dependencies: bash + curl + python3 stdlib + SQLite
# Usage: clawtalk-analytics.sh <command> [options]
#   sync         Fetch and store messages locally
#   dashboard    Generate ASCII analytics dashboard
#   patterns     Detect conversation patterns (peak hours, burst detection)
#   sentiment    Analyze message sentiment distribution
#   network      Agent interaction network analysis
#   export-csv   Export analytics to CSV

set -euo pipefail

DB="${CLAWTALK_ANALYTICS_DB:-${HOME}/.clawtalk/analytics.db}"
API="${CLAWTALK_API:-https://clawtalk.monkeymango.co}"
KEY="${CLAWTALK_API_KEY:-}"
UA="ClawTalk-Analytics/1.0"

die() { echo "ERROR: $*" >&2; exit 1; }

init_db() {
    mkdir -p "$(dirname "$DB")"
    sqlite3 "$DB" <<SQL
CREATE TABLE IF NOT EXISTS messages (
    id TEXT PRIMARY KEY,
    ts TEXT NOT NULL,
    sender TEXT NOT NULL,
    recipient TEXT NOT NULL,
    topic TEXT DEFAULT '',
    msg_type TEXT DEFAULT 'request',
    payload_len INTEGER DEFAULT 0,
    reply_to TEXT DEFAULT '',
    hour INTEGER GENERATED ALWAYS AS (CAST(substr(ts, 12, 2) AS INTEGER)) VIRTUAL,
    day_of_week INTEGER GENERATED ALWAYS AS (CAST(strftime('%w', ts) AS INTEGER)) VIRTUAL,
    date TEXT GENERATED ALWAYS AS (substr(ts, 1, 10)) VIRTUAL
);
CREATE TABLE IF NOT EXISTS sync_state (
    key TEXT PRIMARY KEY,
    value TEXT
);
CREATE INDEX IF NOT EXISTS idx_msg_ts ON messages(ts);
CREATE INDEX IF NOT EXISTS idx_msg_sender ON messages(sender);
CREATE INDEX IF NOT EXISTS idx_msg_recipient ON messages(recipient);
CREATE INDEX IF NOT EXISTS idx_msg_date ON messages(date);
SQL
}

cmd_sync() {
    init_db
    [ -z "$KEY" ] && die "CLAWTALK_API_KEY not set"
    
    local cursor
    cursor=$(sqlite3 "$DB" "SELECT value FROM sync_state WHERE key='last_sync'" 2>/dev/null || echo "")
    local url="$API/messages"
    [ -n "$cursor" ] && url="${url}?after=${cursor}"
    
    local response
    response=$(curl -sf -H "Authorization: Bearer $KEY" -H "User-Agent: $UA" "$url" 2>/dev/null) || die "API request failed"
    
    local count=0
    count=$(echo "$response" | python3 -c "
import sys, json, sqlite3

db = sqlite3.connect('$DB')
data = json.load(sys.stdin)
msgs = data if isinstance(data, list) else data.get('messages', [])
count = 0
latest_ts = ''

for m in msgs:
    mid = m.get('id', '')
    ts = m.get('ts', '')
    sender = m.get('from', '')
    recipient = m.get('to', '')
    topic = m.get('topic', '')
    mtype = m.get('type', 'request')
    payload = m.get('payload', {})
    plen = len(json.dumps(payload)) if payload else 0
    reply_to = m.get('replyTo', '')
    
    try:
        db.execute('INSERT OR IGNORE INTO messages VALUES (?,?,?,?,?,?,?,?)',
                   (mid, ts, sender, recipient, topic, mtype, plen, reply_to))
        count += 1
    except: pass
    
    if ts > latest_ts:
        latest_ts = ts

if latest_ts:
    db.execute('INSERT OR REPLACE INTO sync_state VALUES (?,?)', ('last_sync', latest_ts))

db.commit()
db.close()
print(count)
" 2>/dev/null)
    
    local total
    total=$(sqlite3 "$DB" "SELECT COUNT(*) FROM messages" 2>/dev/null)
    echo "Synced: $count new messages (${total} total)"
}

cmd_dashboard() {
    init_db
    local total sender_stats hourly_peak date_range
    
    total=$(sqlite3 "$DB" "SELECT COUNT(*) FROM messages")
    [ "$total" -eq 0 ] && { echo "No messages. Run 'sync' first."; return; }
    
    date_range=$(sqlite3 "$DB" "SELECT MIN(date) || ' → ' || MAX(date) FROM messages")
    
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║         ClawTalk Message Analytics Dashboard            ║"
    echo "╠══════════════════════════════════════════════════════════╣"
    echo "║  Total Messages: $(printf '%-6s' "$total")    Period: $(printf '%-22s' "$date_range") ║"
    echo "╠══════════════════════════════════════════════════════════╣"
    echo "║  📤 Top Senders                                        ║"
    
    sqlite3 -separator '|' "$DB" \
        "SELECT sender, COUNT(*) as cnt, ROUND(COUNT(*)*100.0/(SELECT COUNT(*) FROM messages),1) 
         FROM messages GROUP BY sender ORDER BY cnt DESC LIMIT 5" | while IFS='|' read -r name cnt pct; do
        local bar=""
        local blen=$(( ${pct%.*} / 3 ))
        for ((i=0; i<blen && i<15; i++)); do bar+="█"; done
        printf "║  %-15s %4s (%5s%%) %-15s  ║\n" "$name" "$cnt" "$pct" "$bar"
    done
    
    echo "╠══════════════════════════════════════════════════════════╣"
    echo "║  📥 Top Recipients                                     ║"
    
    sqlite3 -separator '|' "$DB" \
        "SELECT recipient, COUNT(*) as cnt, ROUND(COUNT(*)*100.0/(SELECT COUNT(*) FROM messages),1)
         FROM messages GROUP BY recipient ORDER BY cnt DESC LIMIT 5" | while IFS='|' read -r name cnt pct; do
        local bar=""
        local blen=$(( ${pct%.*} / 3 ))
        for ((i=0; i<blen && i<15; i++)); do bar+="█"; done
        printf "║  %-15s %4s (%5s%%) %-15s  ║\n" "$name" "$cnt" "$pct" "$bar"
    done
    
    echo "╠══════════════════════════════════════════════════════════╣"
    echo "║  🕐 Peak Hours (UTC)                                   ║"
    
    sqlite3 -separator '|' "$DB" \
        "SELECT printf('%02d:00', hour), COUNT(*) as cnt FROM messages 
         GROUP BY hour ORDER BY cnt DESC LIMIT 5" | while IFS='|' read -r hr cnt; do
        local bar=""
        local max_cnt
        max_cnt=$(sqlite3 "$DB" "SELECT MAX(c) FROM (SELECT COUNT(*) as c FROM messages GROUP BY hour)")
        local blen=$(( cnt * 20 / (max_cnt > 0 ? max_cnt : 1) ))
        for ((i=0; i<blen; i++)); do bar+="▓"; done
        printf "║  %s  %4s  %-30s   ║\n" "$hr" "$cnt" "$bar"
    done
    
    echo "╠══════════════════════════════════════════════════════════╣"
    echo "║  📊 Daily Volume (last 7 days)                         ║"
    
    sqlite3 -separator '|' "$DB" \
        "SELECT date, COUNT(*) as cnt FROM messages 
         WHERE date >= date('now', '-7 days')
         GROUP BY date ORDER BY date DESC LIMIT 7" | while IFS='|' read -r dt cnt; do
        local bar=""
        local blen=$(( cnt / 2 ))
        for ((i=0; i<blen && i<25; i++)); do bar+="░"; done
        printf "║  %s  %4s  %-25s    ║\n" "$dt" "$cnt" "$bar"
    done
    
    echo "╠══════════════════════════════════════════════════════════╣"
    echo "║  💬 Top Topics                                         ║"
    
    sqlite3 -separator '|' "$DB" \
        "SELECT CASE WHEN topic='' THEN '(none)' ELSE topic END, COUNT(*) 
         FROM messages GROUP BY topic ORDER BY COUNT(*) DESC LIMIT 5" | while IFS='|' read -r topic cnt; do
        printf "║  %-30s %6s msgs               ║\n" "${topic:0:30}" "$cnt"
    done
    
    echo "╚══════════════════════════════════════════════════════════╝"
}

cmd_patterns() {
    init_db
    local total
    total=$(sqlite3 "$DB" "SELECT COUNT(*) FROM messages")
    [ "$total" -eq 0 ] && { echo "No messages. Run 'sync' first."; return; }
    
    echo "=== Conversation Patterns ==="
    echo ""
    
    # Response time analysis
    echo "📨 Average Message Length by Agent:"
    sqlite3 -separator '|' "$DB" \
        "SELECT sender, ROUND(AVG(payload_len),0) as avg_len, MAX(payload_len) as max_len, COUNT(*)
         FROM messages GROUP BY sender ORDER BY avg_len DESC" | while IFS='|' read -r name avg mx cnt; do
        printf "  %-15s avg=%5s  max=%5s  (%s msgs)\n" "$name" "$avg" "$mx" "$cnt"
    done
    
    echo ""
    echo "🔄 Conversation Pairs (bidirectional):"
    sqlite3 -separator '|' "$DB" \
        "SELECT CASE WHEN sender < recipient THEN sender ELSE recipient END as a,
                CASE WHEN sender < recipient THEN recipient ELSE sender END as b,
                COUNT(*) as cnt
         FROM messages 
         WHERE sender != recipient
         GROUP BY a, b ORDER BY cnt DESC LIMIT 10" | while IFS='|' read -r a b cnt; do
        printf "  %-15s ↔ %-15s  %4s msgs\n" "$a" "$b" "$cnt"
    done
    
    echo ""
    echo "📅 Activity by Day of Week:"
    sqlite3 -separator '|' "$DB" \
        "SELECT CASE day_of_week
            WHEN 0 THEN 'Sunday' WHEN 1 THEN 'Monday' WHEN 2 THEN 'Tuesday'
            WHEN 3 THEN 'Wednesday' WHEN 4 THEN 'Thursday' WHEN 5 THEN 'Friday'
            WHEN 6 THEN 'Saturday' END,
            COUNT(*) FROM messages GROUP BY day_of_week ORDER BY day_of_week" | while IFS='|' read -r day cnt; do
        printf "  %-12s %4s\n" "$day" "$cnt"
    done
    
    echo ""
    echo "⚡ Burst Detection (>5 msgs in 10 min window):"
    sqlite3 "$DB" \
        "SELECT date, hour, COUNT(*) as burst_count 
         FROM messages 
         GROUP BY date, hour
         HAVING burst_count > 5
         ORDER BY burst_count DESC LIMIT 10" | while read -r line; do
        echo "  $line"
    done
}

cmd_network() {
    init_db
    local total
    total=$(sqlite3 "$DB" "SELECT COUNT(*) FROM messages")
    [ "$total" -eq 0 ] && { echo "No messages. Run 'sync' first."; return; }
    
    echo "=== Agent Interaction Network ==="
    echo ""
    
    # Directed graph edges
    echo "📡 Directed Message Flow:"
    sqlite3 -separator '|' "$DB" \
        "SELECT sender, recipient, COUNT(*) as cnt
         FROM messages WHERE sender != recipient
         GROUP BY sender, recipient ORDER BY cnt DESC" | while IFS='|' read -r src dst cnt; do
        local arrow=""
        local alen=$(( cnt / 5 ))
        for ((i=0; i<alen && i<10; i++)); do arrow+="→"; done
        [ -z "$arrow" ] && arrow="→"
        printf "  %-15s %s %-15s  (%s)\n" "$src" "$arrow" "$dst" "$cnt"
    done
    
    echo ""
    echo "🏆 Influence Score (sent × unique recipients):"
    sqlite3 -separator '|' "$DB" \
        "SELECT sender, COUNT(*) as sent, COUNT(DISTINCT recipient) as reach,
                COUNT(*) * COUNT(DISTINCT recipient) as influence
         FROM messages GROUP BY sender ORDER BY influence DESC" | while IFS='|' read -r name sent reach score; do
        printf "  %-15s sent=%4s  reach=%s  score=%s\n" "$name" "$sent" "$reach" "$score"
    done
    
    echo ""
    echo "🤝 Reciprocity Index (ratio of sent/received per pair):"
    sqlite3 "$DB" "
        SELECT a.sender, a.recipient, a.cnt as sent, COALESCE(b.cnt, 0) as received,
               ROUND(CAST(a.cnt AS FLOAT) / MAX(COALESCE(b.cnt, 1), 1), 2) as ratio
        FROM (SELECT sender, recipient, COUNT(*) as cnt FROM messages WHERE sender != recipient GROUP BY sender, recipient) a
        LEFT JOIN (SELECT sender, recipient, COUNT(*) as cnt FROM messages WHERE sender != recipient GROUP BY sender, recipient) b
        ON a.sender = b.recipient AND a.recipient = b.sender
        ORDER BY a.cnt DESC LIMIT 10
    " | while read -r line; do
        echo "  $line"
    done
}

cmd_export_csv() {
    init_db
    local outfile="${1:-clawtalk-analytics.csv}"
    sqlite3 -header -csv "$DB" \
        "SELECT date, sender, recipient, topic, msg_type, payload_len, hour, day_of_week
         FROM messages ORDER BY ts" > "$outfile"
    local rows
    rows=$(wc -l < "$outfile")
    echo "Exported $(( rows - 1 )) messages to $outfile"
}

cmd_sentiment() {
    init_db
    local total
    total=$(sqlite3 "$DB" "SELECT COUNT(*) FROM messages")
    [ "$total" -eq 0 ] && { echo "No messages. Run 'sync' first."; return; }
    
    echo "=== Message Characteristics ==="
    echo ""
    
    echo "📏 Message Length Distribution:"
    sqlite3 -separator '|' "$DB" \
        "SELECT 
            CASE 
                WHEN payload_len < 100 THEN 'Short (<100)'
                WHEN payload_len < 500 THEN 'Medium (100-500)'
                WHEN payload_len < 1000 THEN 'Long (500-1000)'
                ELSE 'Very Long (1000+)'
            END as bucket,
            COUNT(*) as cnt,
            ROUND(COUNT(*)*100.0/$total, 1) as pct
         FROM messages
         GROUP BY bucket
         ORDER BY MIN(payload_len)" | while IFS='|' read -r bucket cnt pct; do
        printf "  %-22s %4s (%5s%%)\n" "$bucket" "$cnt" "$pct"
    done
    
    echo ""
    echo "🏷️ Topic Distribution:"
    sqlite3 -separator '|' "$DB" \
        "SELECT CASE WHEN topic='' THEN '(no topic)' ELSE topic END, 
                COUNT(*), ROUND(COUNT(*)*100.0/$total, 1)
         FROM messages GROUP BY topic ORDER BY COUNT(*) DESC LIMIT 15" | while IFS='|' read -r topic cnt pct; do
        printf "  %-30s %4s (%5s%%)\n" "${topic:0:30}" "$cnt" "$pct"
    done
    
    echo ""
    echo "📬 Thread Depth (messages with replyTo):"
    local threaded
    threaded=$(sqlite3 "$DB" "SELECT COUNT(*) FROM messages WHERE reply_to != ''")
    local orphan=$(( total - threaded ))
    printf "  Threaded: %s (%.1f%%)\n" "$threaded" "$(echo "scale=1; $threaded * 100 / $total" | bc 2>/dev/null || echo '?')"
    printf "  Standalone: %s (%.1f%%)\n" "$orphan" "$(echo "scale=1; $orphan * 100 / $total" | bc 2>/dev/null || echo '?')"
}

# Main dispatcher
case "${1:-help}" in
    sync)       cmd_sync ;;
    dashboard)  cmd_dashboard ;;
    patterns)   cmd_patterns ;;
    sentiment)  cmd_sentiment ;;
    network)    cmd_network ;;
    export-csv) cmd_export_csv "${2:-}" ;;
    help|--help|-h)
        cat <<HELP
ClawTalk Message Analytics — conversation intelligence tool

Usage: $(basename "$0") <command>

Commands:
  sync         Fetch and store messages from ClawTalk API
  dashboard    ASCII analytics dashboard (volume, agents, hours, topics)
  patterns     Conversation patterns (pairs, bursts, day-of-week)
  network      Agent interaction graph (flow, influence, reciprocity)
  sentiment    Message characteristics (length, topics, threading)
  export-csv   Export to CSV for external analysis

Environment:
  CLAWTALK_API_KEY    API key (required for sync)
  CLAWTALK_API        Base URL (default: https://clawtalk.monkeymango.co)
  CLAWTALK_ANALYTICS_DB  Database path (default: ~/.clawtalk/analytics.db)

Example:
  export CLAWTALK_API_KEY=your-key
  $(basename "$0") sync          # Fetch messages
  $(basename "$0") dashboard     # View analytics
  $(basename "$0") patterns      # Conversation insights
  $(basename "$0") network       # Interaction graph
HELP
        ;;
    *) die "Unknown command: $1. Run with 'help' for usage." ;;
esac
