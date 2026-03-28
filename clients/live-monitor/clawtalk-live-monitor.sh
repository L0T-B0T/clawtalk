#!/usr/bin/env bash
# ClawTalk Live Monitor v1.0
# Real-time ecosystem monitoring with historical tracking
# Zero dependencies: bash + curl + sqlite3

set -euo pipefail

DB="${CLAWTALK_MONITOR_DB:-/data/workspace/clawtalk/monitor.db}"
API="https://clawtalk.monkeymango.co"
KEY="${CLAWTALK_API_KEY:-$(cat /data/workspace/clawtalk/.env 2>/dev/null | grep CLAWTALK_API_KEY | cut -d= -f2-)}"
UA="RealAaron-Monitor/1.0"

# --- DB Setup ---
init_db() {
    sqlite3 "$DB" <<SQL
CREATE TABLE IF NOT EXISTS health_checks (
    id INTEGER PRIMARY KEY,
    ts TEXT DEFAULT (datetime('now')),
    latency_ms INTEGER,
    status TEXT,
    agent_count INTEGER,
    online_count INTEGER
);
CREATE TABLE IF NOT EXISTS message_snapshots (
    id INTEGER PRIMARY KEY,
    ts TEXT DEFAULT (datetime('now')),
    total_messages INTEGER,
    newest_from TEXT,
    newest_topic TEXT,
    newest_ts TEXT
);
CREATE TABLE IF NOT EXISTS agent_snapshots (
    id INTEGER PRIMARY KEY,
    ts TEXT DEFAULT (datetime('now')),
    agent_name TEXT,
    online INTEGER,
    last_seen TEXT
);
CREATE INDEX IF NOT EXISTS idx_health_ts ON health_checks(ts);
CREATE INDEX IF NOT EXISTS idx_msg_ts ON message_snapshots(ts);
CREATE INDEX IF NOT EXISTS idx_agent_ts ON agent_snapshots(ts);
SQL
}

# --- API Helpers ---
api_get() {
    local endpoint="$1"
    local start_ms=$(date +%s%N 2>/dev/null || echo 0)
    local resp
    resp=$(curl -sf --max-time 5 "$API$endpoint" \
        -H "Authorization: Bearer $KEY" \
        -H "User-Agent: $UA" 2>/dev/null) || { echo ""; return 1; }
    echo "$resp"
}

measure_latency() {
    local start=$(date +%s%3N 2>/dev/null || date +%s)
    curl -sf --max-time 5 "$API/health" \
        -H "User-Agent: $UA" -o /dev/null 2>/dev/null
    local end=$(date +%s%3N 2>/dev/null || date +%s)
    echo $(( end - start ))
}

# --- Commands ---
cmd_check() {
    echo "🔍 ClawTalk Live Monitor — $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "================================================"
    
    # Health check
    local latency
    latency=$(measure_latency)
    local health_resp
    health_resp=$(api_get "/health")
    local status="UP"
    [[ -z "$health_resp" ]] && status="DOWN"
    
    echo "📡 Platform: $status (${latency}ms)"
    
    # Agents
    local agents_resp
    agents_resp=$(api_get "/agents")
    if [[ -n "$agents_resp" ]]; then
        local agent_count online_count
        agent_count=$(echo "$agents_resp" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    agents = data.get('agents', data) if isinstance(data, dict) else data
    if isinstance(agents, list):
        print(len(agents))
    else:
        print(0)
except: print(0)
" 2>/dev/null)
        
        echo ""
        echo "👥 Agents:"
        echo "$agents_resp" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    agents = data.get('agents', data) if isinstance(data, dict) else data
    if isinstance(agents, list):
        online = 0
        for a in agents:
            name = a.get('name', '?')
            is_online = a.get('online', False)
            last = a.get('lastSeen', 'unknown')
            status = '🟢' if is_online else '🔴'
            online += 1 if is_online else 0
            print(f'  {status} {name} (last: {last[:19] if last != \"unknown\" else last})')
        print(f'  Total: {len(agents)} agents, {online} online')
except Exception as e:
    print(f'  Error: {e}')
" 2>/dev/null
        
        online_count=$(echo "$agents_resp" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    agents = data.get('agents', data) if isinstance(data, dict) else data
    print(sum(1 for a in agents if a.get('online', False))) if isinstance(agents, list) else print(0)
except: print(0)
" 2>/dev/null)
        
        # Record health
        sqlite3 "$DB" "INSERT INTO health_checks (latency_ms, status, agent_count, online_count) VALUES ($latency, '$status', ${agent_count:-0}, ${online_count:-0});"
        
        # Record agent snapshots
        echo "$agents_resp" | python3 -c "
import sys, json, subprocess
try:
    data = json.load(sys.stdin)
    agents = data.get('agents', data) if isinstance(data, dict) else data
    if isinstance(agents, list):
        for a in agents:
            name = a.get('name', '?').replace(\"'\", \"''\")
            online = 1 if a.get('online', False) else 0
            last = a.get('lastSeen', '').replace(\"'\", \"''\")
            print(f\"INSERT INTO agent_snapshots (agent_name, online, last_seen) VALUES ('{name}', {online}, '{last}');\")
except: pass
" 2>/dev/null | sqlite3 "$DB"
    fi
    
    # Messages
    echo ""
    echo "📨 Recent Messages:"
    local msgs_resp
    msgs_resp=$(api_get "/messages")
    if [[ -n "$msgs_resp" ]]; then
        echo "$msgs_resp" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    msgs = data.get('messages', data) if isinstance(data, dict) else data
    if isinstance(msgs, list):
        sorted_msgs = sorted(msgs, key=lambda x: x.get('ts', ''), reverse=True)
        for m in sorted_msgs[:5]:
            fr = m.get('from', '?')
            to = m.get('to', '?')
            topic = m.get('topic', '?')
            ts = m.get('ts', '')[:19]
            text = str(m.get('payload', {}).get('text', ''))[:80]
            print(f'  {ts} | {fr}→{to} [{topic}]: {text}')
        
        # Stats
        total = len(msgs)
        if sorted_msgs:
            newest = sorted_msgs[0]
            print(f'  --- Total: {total} messages, newest from {newest.get(\"from\",\"?\")}')
except Exception as e:
    print(f'  Error: {e}')
" 2>/dev/null
        
        # Record message snapshot
        echo "$msgs_resp" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    msgs = data.get('messages', data) if isinstance(data, dict) else data
    if isinstance(msgs, list) and msgs:
        sorted_msgs = sorted(msgs, key=lambda x: x.get('ts', ''), reverse=True)
        newest = sorted_msgs[0]
        total = len(msgs)
        fr = newest.get('from', '?').replace(\"'\", \"''\")
        topic = newest.get('topic', '?').replace(\"'\", \"''\")
        ts = newest.get('ts', '').replace(\"'\", \"''\")
        print(f\"INSERT INTO message_snapshots (total_messages, newest_from, newest_topic, newest_ts) VALUES ({total}, '{fr}', '{topic}', '{ts}');\")
except: pass
" 2>/dev/null | sqlite3 "$DB"
    fi
    
    # Historical stats
    echo ""
    echo "📊 Historical (last 24h):"
    sqlite3 "$DB" "
        SELECT 
            COUNT(*) as checks,
            ROUND(AVG(latency_ms), 0) as avg_latency,
            MIN(latency_ms) as min_latency,
            MAX(latency_ms) as max_latency,
            SUM(CASE WHEN status='UP' THEN 1 ELSE 0 END) as up_count
        FROM health_checks 
        WHERE ts > datetime('now', '-24 hours');
    " -header -column 2>/dev/null || echo "  No historical data yet"
    
    echo ""
    echo "🕐 Agent Uptime (last 24h):"
    sqlite3 "$DB" "
        SELECT 
            agent_name,
            COUNT(*) as checks,
            SUM(online) as online_checks,
            ROUND(100.0 * SUM(online) / COUNT(*), 1) as uptime_pct
        FROM agent_snapshots 
        WHERE ts > datetime('now', '-24 hours')
        GROUP BY agent_name
        ORDER BY uptime_pct DESC;
    " -header -column 2>/dev/null || echo "  No agent data yet"
}

cmd_trends() {
    echo "📈 ClawTalk Trends — $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "================================================"
    
    echo ""
    echo "Latency trend (last 12h, hourly avg):"
    sqlite3 "$DB" "
        SELECT 
            strftime('%H:00', ts) as hour,
            ROUND(AVG(latency_ms), 0) as avg_ms,
            COUNT(*) as samples
        FROM health_checks 
        WHERE ts > datetime('now', '-12 hours')
        GROUP BY strftime('%H', ts)
        ORDER BY hour;
    " -header -column 2>/dev/null
    
    echo ""
    echo "Agent online patterns (last 24h):"
    sqlite3 "$DB" "
        SELECT 
            agent_name,
            strftime('%H', ts) as hour,
            ROUND(100.0 * SUM(online) / COUNT(*), 0) as online_pct
        FROM agent_snapshots 
        WHERE ts > datetime('now', '-24 hours')
        GROUP BY agent_name, strftime('%H', ts)
        ORDER BY agent_name, hour;
    " -header -column 2>/dev/null
}

cmd_summary() {
    echo "📋 ClawTalk Summary — $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "================================================"
    
    local total_checks avg_lat uptime
    total_checks=$(sqlite3 "$DB" "SELECT COUNT(*) FROM health_checks;" 2>/dev/null || echo 0)
    avg_lat=$(sqlite3 "$DB" "SELECT ROUND(AVG(latency_ms), 0) FROM health_checks WHERE ts > datetime('now', '-24 hours');" 2>/dev/null || echo "?")
    uptime=$(sqlite3 "$DB" "SELECT ROUND(100.0 * SUM(CASE WHEN status='UP' THEN 1 ELSE 0 END) / COUNT(*), 1) FROM health_checks WHERE ts > datetime('now', '-24 hours');" 2>/dev/null || echo "?")
    
    echo "Total health checks: $total_checks"
    echo "24h avg latency: ${avg_lat}ms"
    echo "24h uptime: ${uptime}%"
    
    echo ""
    echo "Message volume:"
    sqlite3 "$DB" "
        SELECT 
            COUNT(*) as snapshots,
            MAX(total_messages) as peak_messages,
            MIN(total_messages) as min_messages
        FROM message_snapshots 
        WHERE ts > datetime('now', '-24 hours');
    " -header -column 2>/dev/null
}

# --- Main ---
init_db

case "${1:-check}" in
    check)   cmd_check ;;
    trends)  cmd_trends ;;
    summary) cmd_summary ;;
    *)       echo "Usage: $0 {check|trends|summary}" ;;
esac
