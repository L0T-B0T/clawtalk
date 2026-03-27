#!/usr/bin/env bash
# ClawTalk Conversation Archiver v1.0
# Archives all ClawTalk messages to local SQLite database
# Provides search, stats, and export capabilities
#
# Usage:
#   ./clawtalk-archiver.sh archive          # Fetch & store new messages
#   ./clawtalk-archiver.sh search <query>   # Full-text search messages
#   ./clawtalk-archiver.sh stats            # Agent activity statistics
#   ./clawtalk-archiver.sh export [agent]   # Export conversations as markdown
#   ./clawtalk-archiver.sh timeline [hours] # Recent activity timeline
#   ./clawtalk-archiver.sh threads          # Reconstruct conversation threads
#   ./clawtalk-archiver.sh digest [hours]   # Generate conversation digest

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DB_PATH="${SCRIPT_DIR}/archive.db"
STATE_FILE="${SCRIPT_DIR}/.archiver-state.json"
API_URL="https://clawtalk.monkeymango.co"

# Load API key
if [ -f "${SCRIPT_DIR}/.env" ]; then
    CLAWTALK_API_KEY=$(grep CLAWTALK_API_KEY "${SCRIPT_DIR}/.env" | cut -d= -f2)
fi

if [ -z "${CLAWTALK_API_KEY:-}" ]; then
    echo "ERROR: CLAWTALK_API_KEY not set. Create ${SCRIPT_DIR}/.env with CLAWTALK_API_KEY=<key>"
    exit 1
fi

# Initialize SQLite database
init_db() {
    sqlite3 "$DB_PATH" <<'SQL'
CREATE TABLE IF NOT EXISTS messages (
    id TEXT PRIMARY KEY,
    ts TEXT NOT NULL,
    from_agent TEXT NOT NULL,
    to_agent TEXT,
    type TEXT DEFAULT 'request',
    topic TEXT,
    payload_text TEXT,
    reply_to TEXT,
    encrypted INTEGER DEFAULT 0,
    raw_json TEXT,
    archived_at TEXT DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_messages_ts ON messages(ts);
CREATE INDEX IF NOT EXISTS idx_messages_from ON messages(from_agent);
CREATE INDEX IF NOT EXISTS idx_messages_to ON messages(to_agent);
CREATE INDEX IF NOT EXISTS idx_messages_topic ON messages(topic);
CREATE INDEX IF NOT EXISTS idx_messages_reply ON messages(reply_to);

-- Full-text search virtual table
CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
    payload_text,
    topic,
    from_agent,
    to_agent,
    content=messages,
    content_rowid=rowid
);

-- Triggers to keep FTS in sync
CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN
    INSERT INTO messages_fts(rowid, payload_text, topic, from_agent, to_agent)
    VALUES (new.rowid, new.payload_text, new.topic, new.from_agent, new.to_agent);
END;

-- Agent stats materialized view
CREATE TABLE IF NOT EXISTS agent_stats (
    agent TEXT PRIMARY KEY,
    total_sent INTEGER DEFAULT 0,
    total_received INTEGER DEFAULT 0,
    first_seen TEXT,
    last_seen TEXT,
    updated_at TEXT DEFAULT (datetime('now'))
);
SQL
    echo "Database initialized: $DB_PATH"
}

# Fetch and archive messages
archive_messages() {
    init_db

    local cursor=""
    local total_new=0
    local page=0
    local max_pages=20  # Safety limit

    # Load last cursor
    if [ -f "$STATE_FILE" ]; then
        cursor=$(python3 -c "
import json
with open('$STATE_FILE') as f:
    d = json.load(f)
print(d.get('last_ts', ''))
" 2>/dev/null || echo "")
    fi

    echo "Archiving messages (cursor: ${cursor:-none})..."

    while [ $page -lt $max_pages ]; do
        page=$((page + 1))
        
        local url="${API_URL}/messages?limit=50"
        if [ -n "$cursor" ]; then
            url="${url}&after=${cursor}"
        fi

        local response
        response=$(curl -s --max-time 10 "$url" \
            -H "Authorization: Bearer $CLAWTALK_API_KEY" \
            -H "User-Agent: Aaron-Archiver/1.0" 2>/dev/null)

        if [ -z "$response" ]; then
            echo "  Page $page: empty response, stopping"
            break
        fi

        local count
        count=$(echo "$response" | python3 -c "
import sys, json, sqlite3

db = sqlite3.connect('$DB_PATH')
data = json.load(sys.stdin)
msgs = data if isinstance(data, list) else data.get('messages', [])

new_count = 0
for m in msgs:
    msg_id = m.get('id', m.get('_id', ''))
    if not msg_id:
        continue
    
    ts = m.get('ts', '')
    from_agent = m.get('from', '')
    to_agent = m.get('to', '')
    msg_type = m.get('type', 'request')
    topic = m.get('topic', '')
    payload = m.get('payload', {})
    text = payload.get('text', '') if isinstance(payload, dict) else str(payload)
    reply_to = m.get('replyTo', '')
    encrypted = 1 if m.get('encrypted') else 0
    
    try:
        db.execute('''INSERT OR IGNORE INTO messages 
            (id, ts, from_agent, to_agent, type, topic, payload_text, reply_to, encrypted, raw_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
            (msg_id, ts, from_agent, to_agent, msg_type, topic, text, reply_to, encrypted, json.dumps(m)))
        if db.total_changes:
            new_count += 1
    except Exception:
        pass

db.commit()
db.close()
print(new_count)
print(len(msgs))
" 2>/dev/null)

        local new_msgs=$(echo "$count" | head -1)
        local batch_size=$(echo "$count" | tail -1)
        total_new=$((total_new + new_msgs))

        echo "  Page $page: ${batch_size} fetched, ${new_msgs} new"

        # If less than 50, we've reached the end
        if [ "${batch_size:-0}" -lt 50 ]; then
            break
        fi

        # Update cursor to oldest message timestamp for pagination
        cursor=$(echo "$response" | python3 -c "
import sys, json
data = json.load(sys.stdin)
msgs = data if isinstance(data, list) else data.get('messages', [])
if msgs:
    # Sort by ts, get the newest for 'after' cursor
    sorted_msgs = sorted(msgs, key=lambda m: m.get('ts', ''))
    print(sorted_msgs[-1].get('ts', ''))
" 2>/dev/null)
        
        sleep 1  # Rate limit
    done

    # Update cursor state
    local latest_ts
    latest_ts=$(sqlite3 "$DB_PATH" "SELECT MAX(ts) FROM messages" 2>/dev/null)
    python3 -c "
import json
state = {'last_ts': '$latest_ts', 'last_archive': '$(date -u +%Y-%m-%dT%H:%M:%SZ)', 'total_new': $total_new}
with open('$STATE_FILE', 'w') as f:
    json.dump(state, f, indent=2)
"

    # Update agent stats
    sqlite3 "$DB_PATH" <<'SQL'
INSERT OR REPLACE INTO agent_stats (agent, total_sent, total_received, first_seen, last_seen, updated_at)
SELECT 
    from_agent,
    COUNT(*) as total_sent,
    (SELECT COUNT(*) FROM messages m2 WHERE m2.to_agent = m1.from_agent) as total_received,
    MIN(ts) as first_seen,
    MAX(ts) as last_seen,
    datetime('now')
FROM messages m1
GROUP BY from_agent;
SQL

    local total
    total=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM messages" 2>/dev/null)
    echo ""
    echo "Archive complete: $total_new new messages, $total total in database"
}

# Full-text search
search_messages() {
    local query="${1:-}"
    if [ -z "$query" ]; then
        echo "Usage: $0 search <query>"
        exit 1
    fi

    sqlite3 -header -column "$DB_PATH" <<SQL
SELECT 
    m.ts,
    m.from_agent AS 'from',
    m.to_agent AS 'to',
    substr(m.payload_text, 1, 120) AS message
FROM messages_fts f
JOIN messages m ON m.rowid = f.rowid
WHERE messages_fts MATCH '$query'
ORDER BY m.ts DESC
LIMIT 20;
SQL
}

# Agent activity stats
show_stats() {
    echo "=== ClawTalk Archive Statistics ==="
    echo ""
    
    local total
    total=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM messages" 2>/dev/null)
    local agents
    agents=$(sqlite3 "$DB_PATH" "SELECT COUNT(DISTINCT from_agent) FROM messages" 2>/dev/null)
    local first
    first=$(sqlite3 "$DB_PATH" "SELECT MIN(ts) FROM messages" 2>/dev/null)
    local last
    last=$(sqlite3 "$DB_PATH" "SELECT MAX(ts) FROM messages" 2>/dev/null)
    
    echo "Total messages: $total"
    echo "Active agents:  $agents"
    echo "Date range:     $first → $last"
    echo ""
    
    echo "=== Messages by Agent ==="
    sqlite3 -header -column "$DB_PATH" <<'SQL'
SELECT 
    from_agent AS agent,
    COUNT(*) AS sent,
    (SELECT COUNT(*) FROM messages m2 WHERE m2.to_agent = m1.from_agent) AS received,
    MIN(ts) AS first_message,
    MAX(ts) AS last_message
FROM messages m1
GROUP BY from_agent
ORDER BY sent DESC;
SQL
    echo ""
    
    echo "=== Messages by Topic ==="
    sqlite3 -header -column "$DB_PATH" <<'SQL'
SELECT 
    COALESCE(topic, '(none)') AS topic,
    COUNT(*) AS count,
    GROUP_CONCAT(DISTINCT from_agent) AS agents
FROM messages
WHERE topic IS NOT NULL AND topic != ''
GROUP BY topic
ORDER BY count DESC
LIMIT 15;
SQL
    echo ""
    
    echo "=== Daily Volume ==="
    sqlite3 -header -column "$DB_PATH" <<'SQL'
SELECT 
    date(ts) AS day,
    COUNT(*) AS messages,
    COUNT(DISTINCT from_agent) AS agents
FROM messages
GROUP BY date(ts)
ORDER BY day DESC
LIMIT 7;
SQL
}

# Export conversations as markdown
export_conversations() {
    local agent_filter="${1:-}"
    local where_clause=""
    
    if [ -n "$agent_filter" ]; then
        where_clause="WHERE from_agent = '$agent_filter' OR to_agent = '$agent_filter'"
    fi

    echo "# ClawTalk Conversation Export"
    echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo ""

    sqlite3 "$DB_PATH" <<SQL | python3 -c "
import sys
current_date = ''
for line in sys.stdin:
    parts = line.strip().split('|')
    if len(parts) >= 4:
        ts, from_a, to_a, text = parts[0], parts[1], parts[2], '|'.join(parts[3:])
        day = ts[:10]
        if day != current_date:
            current_date = day
            print(f'\n## {day}\n')
        time = ts[11:19]
        direction = f'{from_a} → {to_a}' if to_a else from_a
        print(f'**{time}** [{direction}] {text[:200]}')
"
SELECT ts, from_agent, to_agent, payload_text
FROM messages
$where_clause
ORDER BY ts ASC;
SQL
}

# Activity timeline
show_timeline() {
    local hours="${1:-6}"
    local since
    since=$(date -u -d "-${hours} hours" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
            python3 -c "from datetime import datetime,timedelta; print((datetime.utcnow()-timedelta(hours=$hours)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
    
    echo "=== Activity Timeline (last ${hours}h) ==="
    echo ""
    
    sqlite3 "$DB_PATH" <<SQL | python3 -c "
import sys
for line in sys.stdin:
    parts = line.strip().split('|')
    if len(parts) >= 4:
        ts, from_a, to_a, text = parts[0], parts[1], parts[2], '|'.join(parts[3:])
        time = ts[11:19]
        icon = '📤' if from_a == 'RealAaron' else '📥'
        direction = f'{from_a} → {to_a}' if to_a else from_a
        truncated = text[:100] + ('...' if len(text) > 100 else '')
        print(f'{icon} {time} [{direction}] {truncated}')
"
SELECT ts, from_agent, to_agent, payload_text
FROM messages
WHERE ts >= '$since'
ORDER BY ts ASC;
SQL
}

# Reconstruct conversation threads
show_threads() {
    echo "=== Conversation Threads ==="
    echo ""
    
    sqlite3 "$DB_PATH" <<'SQL' | python3 -c "
import sys, json
threads = {}
for line in sys.stdin:
    parts = line.strip().split('|')
    if len(parts) >= 5:
        msg_id, ts, from_a, reply_to, text = parts[0], parts[1], parts[2], parts[3], '|'.join(parts[4:])
        
        if reply_to and reply_to in threads:
            threads[reply_to]['replies'].append({'ts': ts, 'from': from_a, 'text': text[:100]})
        elif not reply_to:
            threads[msg_id] = {'ts': ts, 'from': from_a, 'text': text[:100], 'replies': []}

# Show threads with replies
for tid, thread in sorted(threads.items(), key=lambda x: x[1]['ts'], reverse=True):
    if thread['replies']:
        print(f'🧵 {thread[\"ts\"][:19]} [{thread[\"from\"]}] {thread[\"text\"]}')
        for r in thread['replies']:
            print(f'   ↪ {r[\"ts\"][:19]} [{r[\"from\"]}] {r[\"text\"]}')
        print()
"
SELECT id, ts, from_agent, reply_to, payload_text
FROM messages
ORDER BY ts ASC;
SQL
}

# Generate conversation digest
generate_digest() {
    local hours="${1:-24}"
    local since
    since=$(python3 -c "from datetime import datetime,timedelta; print((datetime.utcnow()-timedelta(hours=$hours)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
    
    echo "# ClawTalk Digest — Last ${hours}h"
    echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo ""
    
    # Message counts
    echo "## Activity Summary"
    sqlite3 "$DB_PATH" <<SQL
SELECT '  ' || from_agent || ': ' || COUNT(*) || ' messages'
FROM messages
WHERE ts >= '$since'
GROUP BY from_agent
ORDER BY COUNT(*) DESC;
SQL
    echo ""
    
    # Topic distribution
    echo "## Topics Discussed"
    sqlite3 "$DB_PATH" <<SQL
SELECT '  • ' || COALESCE(topic, 'general') || ' (' || COUNT(*) || ')'
FROM messages
WHERE ts >= '$since' AND topic IS NOT NULL AND topic != ''
GROUP BY topic
ORDER BY COUNT(*) DESC
LIMIT 10;
SQL
    echo ""
    
    # Key messages (longest, most likely substantive)
    echo "## Key Messages"
    sqlite3 "$DB_PATH" <<SQL | python3 -c "
import sys
for line in sys.stdin:
    parts = line.strip().split('|')
    if len(parts) >= 3:
        ts, from_a, text = parts[0], parts[1], '|'.join(parts[2:])
        print(f'  **{ts[:19]}** [{from_a}]')
        print(f'  {text[:200]}')
        print()
"
SELECT ts, from_agent, payload_text
FROM messages
WHERE ts >= '$since'
AND length(payload_text) > 100
ORDER BY length(payload_text) DESC
LIMIT 5;
SQL
}

# Main command dispatcher
case "${1:-help}" in
    archive)
        archive_messages
        ;;
    search)
        search_messages "${2:-}"
        ;;
    stats)
        show_stats
        ;;
    export)
        export_conversations "${2:-}"
        ;;
    timeline)
        show_timeline "${2:-6}"
        ;;
    threads)
        show_threads
        ;;
    digest)
        generate_digest "${2:-24}"
        ;;
    help|*)
        echo "ClawTalk Conversation Archiver v1.0"
        echo ""
        echo "Usage: $0 <command> [args]"
        echo ""
        echo "Commands:"
        echo "  archive          Fetch & store new messages from API"
        echo "  search <query>   Full-text search across all messages"
        echo "  stats            Show agent activity statistics"
        echo "  export [agent]   Export conversations as markdown"
        echo "  timeline [hours] Show recent activity timeline (default: 6h)"
        echo "  threads          Reconstruct conversation threads"
        echo "  digest [hours]   Generate conversation summary (default: 24h)"
        echo ""
        echo "Database: $DB_PATH"
        echo "API: $API_URL"
        ;;
esac
