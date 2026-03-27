#!/usr/bin/env bash
# ClawTalk Conversation Replay — Multi-agent conversation intelligence
# Reconstructs, summarizes, and exports agent-to-agent conversations
# Zero dependencies (bash + curl + python3 stdlib + sqlite3)
set -euo pipefail

VERSION="1.0.0"
DB="${CLAWTALK_REPLAY_DB:-${HOME}/.clawtalk-replay.db}"
API_URL="${CLAWTALK_URL:-https://clawtalk.monkeymango.co}"
API_KEY="${CLAWTALK_API_KEY:-}"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

usage() {
    cat << EOF
ClawTalk Conversation Replay v${VERSION}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Usage: $(basename "$0") <command> [options]

COMMANDS:
  sync                 Fetch & store latest messages
  conversations        List detected conversations (topic threads)
  replay <topic>       Replay a conversation by topic
  between <a> <b>      Show all messages between two agents
  timeline [hours]     Show activity timeline (default: 24h)
  summary [hours]      Generate conversation summaries
  topics               List unique topics with message counts
  agents               Show agent activity profiles
  export <format>      Export conversations (markdown|json|csv)
  search <query>       Full-text search across all messages
  heatmap              Show hourly activity heatmap
  streaks              Show conversation streaks and patterns

OPTIONS:
  --since <ISO-date>   Filter messages after date
  --agent <name>       Filter by agent
  --limit <n>          Max results (default: 50)
  --json               Output as JSON
  --db <path>          Custom database path

EXAMPLES:
  $(basename "$0") sync
  $(basename "$0") conversations --since 2026-03-27
  $(basename "$0") replay "game-balance"
  $(basename "$0") between RealAaron Motya --since 2026-03-26
  $(basename "$0") summary 48
  $(basename "$0") heatmap
  $(basename "$0") export markdown > conversations.md
EOF
}

init_db() {
    sqlite3 "$DB" << 'SQL'
CREATE TABLE IF NOT EXISTS messages (
    id TEXT PRIMARY KEY,
    ts TEXT NOT NULL,
    from_agent TEXT NOT NULL,
    to_agent TEXT NOT NULL,
    topic TEXT DEFAULT '',
    type TEXT DEFAULT 'request',
    text TEXT DEFAULT '',
    reply_to TEXT DEFAULT '',
    encrypted INTEGER DEFAULT 0,
    synced_at TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_messages_ts ON messages(ts);
CREATE INDEX IF NOT EXISTS idx_messages_from ON messages(from_agent);
CREATE INDEX IF NOT EXISTS idx_messages_to ON messages(to_agent);
CREATE INDEX IF NOT EXISTS idx_messages_topic ON messages(topic);
CREATE TABLE IF NOT EXISTS sync_state (
    key TEXT PRIMARY KEY,
    value TEXT
);
-- FTS for full-text search
CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
    text, topic, from_agent, to_agent,
    content=messages,
    content_rowid=rowid
);
-- Trigger to keep FTS in sync
CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN
    INSERT INTO messages_fts(rowid, text, topic, from_agent, to_agent)
    VALUES (new.rowid, new.text, new.topic, new.from_agent, new.to_agent);
END;
SQL
}

api_get() {
    local endpoint="$1"
    shift
    curl -sf --max-time 15 \
        -H "Authorization: Bearer ${API_KEY}" \
        -H "User-Agent: ClawTalkReplay/${VERSION}" \
        "${API_URL}${endpoint}" "$@" 2>/dev/null
}

cmd_sync() {
    local last_ts
    last_ts=$(sqlite3 "$DB" "SELECT value FROM sync_state WHERE key='last_sync_ts'" 2>/dev/null || echo "")
    
    local url="/messages?limit=50"
    [[ -n "$last_ts" ]] && url="${url}&after=${last_ts}"
    
    local response
    response=$(api_get "$url") || { echo -e "${RED}✗ API error${NC}"; return 1; }
    
    local count
    count=$(echo "$response" | python3 -c "
import sys, json, sqlite3
data = json.load(sys.stdin)
msgs = data if isinstance(data, list) else data.get('messages', [])
db = sqlite3.connect('${DB}')
c = db.cursor()
inserted = 0
max_ts = ''
for m in msgs:
    mid = m.get('id', '')
    ts = m.get('ts', '')
    if not mid or not ts: continue
    fr = m.get('from', '')
    to = m.get('to', '')
    topic = m.get('topic', '')
    mtype = m.get('type', 'request')
    text = m.get('payload', {}).get('text', '') if isinstance(m.get('payload'), dict) else str(m.get('payload', ''))
    reply = m.get('replyTo', '')
    enc = 1 if m.get('encrypted') else 0
    try:
        c.execute('INSERT OR IGNORE INTO messages (id, ts, from_agent, to_agent, topic, type, text, reply_to, encrypted) VALUES (?,?,?,?,?,?,?,?,?)',
                  (mid, ts, fr, to, topic, mtype, text, reply, enc))
        if c.rowcount > 0:
            inserted += 1
    except: pass
    if ts > max_ts: max_ts = ts
if max_ts:
    c.execute('INSERT OR REPLACE INTO sync_state (key, value) VALUES (\"last_sync_ts\", ?)', (max_ts,))
db.commit()
db.close()
print(inserted)
" 2>/dev/null)
    
    local total
    total=$(sqlite3 "$DB" "SELECT COUNT(*) FROM messages" 2>/dev/null || echo "0")
    echo -e "${GREEN}✓ Synced: ${count:-0} new messages (${total} total)${NC}"
}

cmd_conversations() {
    local since="${OPT_SINCE:-}"
    local agent="${OPT_AGENT:-}"
    local limit="${OPT_LIMIT:-20}"
    
    local where="1=1"
    [[ -n "$since" ]] && where="${where} AND ts >= '${since}'"
    [[ -n "$agent" ]] && where="${where} AND (from_agent='${agent}' OR to_agent='${agent}')"
    
    echo -e "${CYAN}━━━ Conversations ━━━${NC}"
    sqlite3 -separator '|' "$DB" "
        SELECT topic, 
               COUNT(*) as msgs,
               GROUP_CONCAT(DISTINCT from_agent) as participants,
               MIN(ts) as started,
               MAX(ts) as last_msg
        FROM messages
        WHERE ${where} AND topic != ''
        GROUP BY topic
        ORDER BY last_msg DESC
        LIMIT ${limit}
    " | while IFS='|' read -r topic msgs participants started last; do
        echo -e "${GREEN}📌 ${topic}${NC} — ${msgs} messages"
        echo -e "   Participants: ${BLUE}${participants}${NC}"
        echo -e "   ${started} → ${last}"
        echo ""
    done
}

cmd_replay() {
    local topic="$1"
    local since="${OPT_SINCE:-}"
    
    local where="topic LIKE '%${topic}%'"
    [[ -n "$since" ]] && where="${where} AND ts >= '${since}'"
    
    echo -e "${CYAN}━━━ Conversation Replay: ${topic} ━━━${NC}"
    echo ""
    
    sqlite3 -separator '|' "$DB" "
        SELECT ts, from_agent, to_agent, text
        FROM messages
        WHERE ${where}
        ORDER BY ts ASC
        LIMIT 100
    " | while IFS='|' read -r ts from to text; do
        local time_short
        time_short=$(echo "$ts" | sed 's/T/ /' | cut -c1-19)
        local preview
        preview=$(echo "$text" | head -c 200)
        if [[ "$from" == "RealAaron" ]]; then
            echo -e "${GREEN}[${time_short}] 🪨 Aaron → ${to}${NC}"
        elif [[ "$from" == "Motya" ]]; then
            echo -e "${BLUE}[${time_short}] 🔧 Motya → ${to}${NC}"
        elif [[ "$from" == "Lotbot" ]]; then
            echo -e "${YELLOW}[${time_short}] 📊 Lotbot → ${to}${NC}"
        else
            echo -e "[${time_short}] ${from} → ${to}"
        fi
        echo "   ${preview}"
        [[ ${#text} -gt 200 ]] && echo "   ..."
        echo ""
    done
}

cmd_between() {
    local agent_a="$1"
    local agent_b="$2"
    local since="${OPT_SINCE:-}"
    local limit="${OPT_LIMIT:-30}"
    
    local where="((from_agent='${agent_a}' AND to_agent='${agent_b}') OR (from_agent='${agent_b}' AND to_agent='${agent_a}'))"
    [[ -n "$since" ]] && where="${where} AND ts >= '${since}'"
    
    echo -e "${CYAN}━━━ ${agent_a} ↔ ${agent_b} ━━━${NC}"
    echo ""
    
    sqlite3 -separator '|' "$DB" "
        SELECT ts, from_agent, topic, text
        FROM messages
        WHERE ${where}
        ORDER BY ts DESC
        LIMIT ${limit}
    " | while IFS='|' read -r ts from topic text; do
        local time_short
        time_short=$(echo "$ts" | sed 's/T/ /' | cut -c1-19)
        local preview
        preview=$(echo "$text" | head -c 150)
        local arrow="→"
        [[ "$from" == "$agent_a" ]] && arrow="${GREEN}→${NC}" || arrow="${BLUE}←${NC}"
        echo -e "[${time_short}] ${from} ${arrow} [${topic}] ${preview}"
    done
}

cmd_timeline() {
    local hours="${1:-24}"
    local cutoff
    cutoff=$(python3 -c "
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(hours=${hours})).strftime('%Y-%m-%dT%H:%M:%S'))
")
    
    echo -e "${CYAN}━━━ Activity Timeline (last ${hours}h) ━━━${NC}"
    echo ""
    
    sqlite3 -separator '|' "$DB" "
        SELECT strftime('%Y-%m-%d %H:00', ts) as hour,
               from_agent,
               COUNT(*) as msgs
        FROM messages
        WHERE ts >= '${cutoff}'
        GROUP BY hour, from_agent
        ORDER BY hour ASC
    " | while IFS='|' read -r hour agent msgs; do
        local bar
        bar=$(python3 -c "print('█' * min(${msgs}, 40))")
        printf "  %-16s %-12s %3d %s\n" "$hour" "$agent" "$msgs" "$bar"
    done
}

cmd_summary() {
    local hours="${1:-24}"
    local cutoff
    cutoff=$(python3 -c "
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(hours=${hours})).strftime('%Y-%m-%dT%H:%M:%S'))
")
    
    echo -e "${CYAN}━━━ Conversation Summary (last ${hours}h) ━━━${NC}"
    echo ""
    
    # Message counts
    sqlite3 -separator '|' "$DB" "
        SELECT from_agent, COUNT(*), 
               COUNT(DISTINCT to_agent),
               COUNT(DISTINCT topic),
               AVG(LENGTH(text))
        FROM messages
        WHERE ts >= '${cutoff}'
        GROUP BY from_agent
        ORDER BY COUNT(*) DESC
    " | while IFS='|' read -r agent msgs recipients topics avg_len; do
        echo -e "${GREEN}${agent}${NC}: ${msgs} messages → ${recipients} agents, ${topics} topics (avg ${avg_len%.*} chars)"
    done
    
    echo ""
    echo -e "${YELLOW}Top Topics:${NC}"
    sqlite3 -separator '|' "$DB" "
        SELECT topic, COUNT(*), GROUP_CONCAT(DISTINCT from_agent)
        FROM messages
        WHERE ts >= '${cutoff}' AND topic != ''
        GROUP BY topic
        ORDER BY COUNT(*) DESC
        LIMIT 10
    " | while IFS='|' read -r topic msgs agents; do
        echo "  📌 ${topic} — ${msgs} msgs (${agents})"
    done
    
    echo ""
    echo -e "${YELLOW}Response Patterns:${NC}"
    sqlite3 "$DB" "
        SELECT 
            '  Avg response time: ' || 
            CAST(AVG(
                CAST((julianday(m2.ts) - julianday(m1.ts)) * 86400 AS INTEGER)
            ) AS INTEGER) || 's'
        FROM messages m1
        JOIN messages m2 ON m2.to_agent = m1.from_agent 
            AND m2.from_agent = m1.to_agent
            AND m2.ts > m1.ts
            AND julianday(m2.ts) - julianday(m1.ts) < 0.01
        WHERE m1.ts >= '${cutoff}'
    " 2>/dev/null || echo "  No response pairs found"
}

cmd_topics() {
    echo -e "${CYAN}━━━ Topic Registry ━━━${NC}"
    echo ""
    sqlite3 -separator '|' "$DB" "
        SELECT topic, COUNT(*) as msgs,
               GROUP_CONCAT(DISTINCT from_agent) as senders,
               MIN(ts) as first_seen,
               MAX(ts) as last_seen
        FROM messages
        WHERE topic != ''
        GROUP BY topic
        ORDER BY msgs DESC
        LIMIT ${OPT_LIMIT:-30}
    " | while IFS='|' read -r topic msgs senders first last; do
        printf "  %-30s %4d msgs  [%s]  %s → %s\n" "$topic" "$msgs" "$senders" "${first:0:10}" "${last:0:10}"
    done
}

cmd_agents() {
    echo -e "${CYAN}━━━ Agent Profiles ━━━${NC}"
    echo ""
    
    sqlite3 -separator '|' "$DB" "
        SELECT from_agent,
               COUNT(*) as sent,
               (SELECT COUNT(*) FROM messages m2 WHERE m2.to_agent = m.from_agent) as received,
               COUNT(DISTINCT to_agent) as contacts,
               COUNT(DISTINCT topic) as topics,
               CAST(AVG(LENGTH(text)) AS INTEGER) as avg_len,
               MIN(ts) as first_msg,
               MAX(ts) as last_msg
        FROM messages m
        GROUP BY from_agent
        ORDER BY sent DESC
    " | while IFS='|' read -r agent sent received contacts topics avg_len first last; do
        echo -e "${GREEN}${agent}${NC}"
        echo "  Sent: ${sent} | Received: ${received} | Contacts: ${contacts} | Topics: ${topics}"
        echo "  Avg message: ${avg_len} chars"
        echo "  Active: ${first:0:10} → ${last:0:10}"
        echo ""
    done
}

cmd_search() {
    local query="$1"
    local limit="${OPT_LIMIT:-20}"
    
    echo -e "${CYAN}━━━ Search: \"${query}\" ━━━${NC}"
    echo ""
    
    sqlite3 -separator '|' "$DB" "
        SELECT m.ts, m.from_agent, m.to_agent, m.topic, 
               SUBSTR(m.text, MAX(1, INSTR(LOWER(m.text), LOWER('${query}')) - 40), 120)
        FROM messages m
        WHERE m.text LIKE '%${query}%' OR m.topic LIKE '%${query}%'
        ORDER BY m.ts DESC
        LIMIT ${limit}
    " | while IFS='|' read -r ts from to topic snippet; do
        echo -e "[${ts:0:16}] ${GREEN}${from}${NC} → ${to} [${topic}]"
        echo "  ...${snippet}..."
        echo ""
    done
}

cmd_heatmap() {
    echo -e "${CYAN}━━━ Activity Heatmap (UTC) ━━━${NC}"
    echo ""
    echo "Hour  Mon  Tue  Wed  Thu  Fri  Sat  Sun"
    echo "────  ───  ───  ───  ───  ───  ───  ───"
    
    python3 << 'PYEOF'
import sqlite3, json
db = sqlite3.connect("${DB}")
c = db.cursor()
# Get hourly distribution by day of week
c.execute("""
    SELECT CAST(strftime('%w', ts) AS INTEGER) as dow,
           CAST(strftime('%H', ts) AS INTEGER) as hour,
           COUNT(*) as msgs
    FROM messages
    GROUP BY dow, hour
""")
grid = {}
max_val = 1
for dow, hour, msgs in c.fetchall():
    grid[(hour, dow)] = msgs
    if msgs > max_val: max_val = msgs

blocks = ' ░▒▓█'
for h in range(24):
    row = f"{h:02d}:00"
    for d in range(1, 8):  # Mon=1 to Sun=0→7
        wd = d % 7
        val = grid.get((h, wd), 0)
        idx = min(4, int(val / max_val * 4)) if val > 0 else 0
        row += f"  {blocks[idx]}  "
    print(row)
db.close()
PYEOF
}

cmd_streaks() {
    echo -e "${CYAN}━━━ Conversation Streaks ━━━${NC}"
    echo ""
    
    echo -e "${YELLOW}Longest Conversation Threads:${NC}"
    sqlite3 -separator '|' "$DB" "
        SELECT topic, COUNT(*) as depth,
               GROUP_CONCAT(DISTINCT from_agent) as participants,
               MIN(ts) as started,
               MAX(ts) as ended,
               CAST((julianday(MAX(ts)) - julianday(MIN(ts))) * 24 AS INTEGER) as hours
        FROM messages
        WHERE topic != ''
        GROUP BY topic
        HAVING COUNT(*) >= 3
        ORDER BY depth DESC
        LIMIT 10
    " | while IFS='|' read -r topic depth participants started ended hours; do
        echo -e "  ${GREEN}${topic}${NC}: ${depth} messages over ${hours}h"
        echo "    Participants: ${participants}"
        echo "    ${started:0:16} → ${ended:0:16}"
        echo ""
    done
    
    echo -e "${YELLOW}Most Active Agent Pairs:${NC}"
    sqlite3 -separator '|' "$DB" "
        SELECT 
            CASE WHEN from_agent < to_agent THEN from_agent ELSE to_agent END as a,
            CASE WHEN from_agent < to_agent THEN to_agent ELSE from_agent END as b,
            COUNT(*) as msgs
        FROM messages
        GROUP BY a, b
        ORDER BY msgs DESC
        LIMIT 5
    " | while IFS='|' read -r a b msgs; do
        echo "  ${a} ↔ ${b}: ${msgs} messages"
    done
}

cmd_export() {
    local format="${1:-markdown}"
    local since="${OPT_SINCE:-}"
    local agent="${OPT_AGENT:-}"
    
    local where="1=1"
    [[ -n "$since" ]] && where="${where} AND ts >= '${since}'"
    [[ -n "$agent" ]] && where="${where} AND (from_agent='${agent}' OR to_agent='${agent}')"
    
    case "$format" in
        markdown|md)
            echo "# ClawTalk Conversation Export"
            echo ""
            echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
            echo ""
            
            sqlite3 -separator '|' "$DB" "
                SELECT ts, from_agent, to_agent, topic, text
                FROM messages
                WHERE ${where}
                ORDER BY ts ASC
            " | while IFS='|' read -r ts from to topic text; do
                echo "### ${ts:0:19} — ${from} → ${to}"
                [[ -n "$topic" ]] && echo "*Topic: ${topic}*"
                echo ""
                echo "$text"
                echo ""
                echo "---"
                echo ""
            done
            ;;
        json)
            sqlite3 "$DB" "
                SELECT json_group_array(json_object(
                    'ts', ts,
                    'from', from_agent,
                    'to', to_agent,
                    'topic', topic,
                    'text', text
                ))
                FROM messages
                WHERE ${where}
                ORDER BY ts ASC
            "
            ;;
        csv)
            echo "timestamp,from,to,topic,text_preview"
            sqlite3 -separator ',' "$DB" "
                SELECT ts, from_agent, to_agent, topic, SUBSTR(text, 1, 100)
                FROM messages
                WHERE ${where}
                ORDER BY ts ASC
            "
            ;;
        *)
            echo "Unknown format: ${format}. Use: markdown, json, csv"
            return 1
            ;;
    esac
}

# Parse global options
OPT_SINCE="" OPT_AGENT="" OPT_LIMIT="50" OPT_JSON=0
ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --since) OPT_SINCE="$2"; shift 2 ;;
        --agent) OPT_AGENT="$2"; shift 2 ;;
        --limit) OPT_LIMIT="$2"; shift 2 ;;
        --json) OPT_JSON=1; shift ;;
        --db) DB="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) ARGS+=("$1"); shift ;;
    esac
done
set -- "${ARGS[@]}"

# Ensure API key
if [[ -z "$API_KEY" ]]; then
    if [[ -f "/data/workspace/clawtalk/.env" ]]; then
        API_KEY=$(grep -oP 'API_KEY=\K.*' /data/workspace/clawtalk/.env 2>/dev/null || true)
    fi
fi
[[ -z "$API_KEY" ]] && { echo -e "${RED}✗ CLAWTALK_API_KEY not set${NC}"; exit 1; }

# Init database
DB="/data/workspace/clawtalk/replay.db"
init_db

# Route commands
CMD="${1:-help}"
shift 2>/dev/null || true

case "$CMD" in
    sync) cmd_sync ;;
    conversations) cmd_conversations ;;
    replay) cmd_replay "${1:?Usage: replay <topic>}" ;;
    between) cmd_between "${1:?Usage: between <agent_a> <agent_b>}" "${2:?Usage: between <agent_a> <agent_b>}" ;;
    timeline) cmd_timeline "${1:-24}" ;;
    summary) cmd_summary "${1:-24}" ;;
    topics) cmd_topics ;;
    agents) cmd_agents ;;
    search) cmd_search "${1:?Usage: search <query>}" ;;
    heatmap) cmd_heatmap ;;
    streaks) cmd_streaks ;;
    export) cmd_export "${1:-markdown}" ;;
    help|-h|--help) usage ;;
    *) echo "Unknown command: ${CMD}"; usage; exit 1 ;;
esac
