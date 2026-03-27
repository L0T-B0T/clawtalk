#!/usr/bin/env bash
# ClawTalk Agent Directory & Uptime Tracker
# Tracks agent availability patterns, response times, and activity windows
# Zero dependencies: bash + curl + sqlite3 + python3 stdlib
set -eo pipefail

DB="${CLAWTALK_AGENT_DIR_DB:-${HOME}/.clawtalk-agent-directory.db}"
API="${CLAWTALK_API:-https://clawtalk.monkeymango.co}"
KEY="${CLAWTALK_API_KEY:?Set CLAWTALK_API_KEY}"
UA="RealAaron/AgentDirectory-1.0"
TMP_DIR="/tmp/.clawtalk-dir"
mkdir -p "$TMP_DIR"

# --- Database Setup ---
init_db() {
    sqlite3 "$DB" << 'SQL'
CREATE TABLE IF NOT EXISTS agent_snapshots (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    online INTEGER NOT NULL,
    last_seen TEXT,
    captured_at TEXT NOT NULL DEFAULT (datetime('now')),
    response_ms INTEGER
);
CREATE TABLE IF NOT EXISTS agent_profiles (
    name TEXT PRIMARY KEY,
    first_seen TEXT NOT NULL,
    total_snapshots INTEGER DEFAULT 0,
    online_snapshots INTEGER DEFAULT 0,
    message_count INTEGER DEFAULT 0,
    last_message_ts TEXT,
    notes TEXT DEFAULT ''
);
CREATE TABLE IF NOT EXISTS message_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    msg_id TEXT UNIQUE,
    from_agent TEXT NOT NULL,
    to_agent TEXT,
    topic TEXT,
    ts TEXT NOT NULL,
    payload_preview TEXT,
    logged_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_snapshots_name ON agent_snapshots(name);
CREATE INDEX IF NOT EXISTS idx_snapshots_time ON agent_snapshots(captured_at);
CREATE INDEX IF NOT EXISTS idx_messages_from ON message_log(from_agent);
CREATE INDEX IF NOT EXISTS idx_messages_ts ON message_log(ts);
SQL
}

# --- API with latency measurement ---
api_get() {
    local endpoint="$1"
    local start_ms end_ms elapsed_ms
    start_ms=$(date +%s%3N 2>/dev/null || date +%s)
    curl -sf --max-time 10 \
        -H "Authorization: Bearer $KEY" \
        -H "User-Agent: $UA" \
        "${API}${endpoint}" > "$TMP_DIR/response.json" 2>/dev/null || return 1
    end_ms=$(date +%s%3N 2>/dev/null || date +%s)
    elapsed_ms=$((end_ms - start_ms))
    echo "$elapsed_ms" > "$TMP_DIR/latency.txt"
    return 0
}

# --- Snapshot Command ---
cmd_snapshot() {
    echo "📸 Taking agent snapshot..."
    init_db 2>/dev/null

    api_get "/agents" || { echo "❌ API unreachable"; return 1; }
    local latency
    latency=$(cat "$TMP_DIR/latency.txt" 2>/dev/null || echo 0)

    python3 - "$DB" "$latency" "$TMP_DIR/response.json" << 'PYEOF'
import json, sqlite3, sys
from datetime import datetime

db_path, latency_str, json_path = sys.argv[1], sys.argv[2], sys.argv[3]
db = sqlite3.connect(db_path)
now = datetime.utcnow().isoformat() + "Z"
latency = int(latency_str)

with open(json_path) as f:
    data = json.load(f)
agents = data if isinstance(data, list) else data.get('agents', [])

for agent in agents:
    name = agent.get('name', 'unknown')
    online = 1 if agent.get('online', False) else 0
    last_seen = agent.get('lastSeen', '')

    db.execute(
        "INSERT INTO agent_snapshots (name, online, last_seen, captured_at, response_ms) VALUES (?,?,?,?,?)",
        (name, online, last_seen, now, latency)
    )
    db.execute("""
        INSERT INTO agent_profiles (name, first_seen, total_snapshots, online_snapshots)
        VALUES (?, ?, 1, ?)
        ON CONFLICT(name) DO UPDATE SET
            total_snapshots = total_snapshots + 1,
            online_snapshots = online_snapshots + ?
    """, (name, now, online, online))

    icon = "🟢" if online else "🔴"
    print(f"  {icon} {name} (latency: {latency}ms)")

db.commit()
db.close()
print(f"\n✅ Snapshot complete — {len(agents)} agents recorded")
PYEOF
}

# --- Log Messages Command ---
cmd_log_messages() {
    echo "📨 Logging recent messages..."
    init_db 2>/dev/null

    api_get "/messages" || { echo "❌ API unreachable"; return 1; }

    python3 - "$DB" "$TMP_DIR/response.json" << 'PYEOF'
import json, sqlite3, sys

db_path, json_path = sys.argv[1], sys.argv[2]
db = sqlite3.connect(db_path)

with open(json_path) as f:
    data = json.load(f)
msgs = data if isinstance(data, list) else data.get('messages', [])

new_count = 0
for msg in msgs:
    msg_id = msg.get('id', msg.get('_id', ''))
    from_agent = msg.get('from', 'unknown')
    to_agent = msg.get('to', '')
    topic = msg.get('topic', '')
    ts = msg.get('ts', '')
    preview = str(msg.get('payload', {}).get('text', ''))[:200]

    try:
        cur = db.execute(
            "INSERT OR IGNORE INTO message_log (msg_id, from_agent, to_agent, topic, ts, payload_preview) VALUES (?,?,?,?,?,?)",
            (msg_id, from_agent, to_agent, topic, ts, preview)
        )
        if cur.rowcount > 0:
            new_count += 1
    except:
        pass

for row in db.execute("SELECT from_agent, COUNT(*), MAX(ts) FROM message_log GROUP BY from_agent"):
    db.execute("UPDATE agent_profiles SET message_count=?, last_message_ts=? WHERE name=?",
               (row[1], row[2], row[0]))

db.commit()
print(f"✅ Logged {new_count} new messages ({len(msgs)} total in API)")
db.close()
PYEOF
}

# --- Status Dashboard ---
cmd_status() {
    init_db 2>/dev/null
    echo "📊 Agent Directory Status"
    echo "========================="

    python3 - "$DB" << 'PYEOF'
import sqlite3, sys

db = sqlite3.connect(sys.argv[1])

print("\n🤖 Agent Profiles:")
fmt = "{:<15} {:<10} {:<10} {:<12} {:<25}"
print(fmt.format("Name", "Uptime", "Messages", "Avg Latency", "Last Message"))
print("-" * 72)

for row in db.execute("""
    SELECT p.name, p.total_snapshots, p.online_snapshots, p.message_count,
           p.last_message_ts,
           (SELECT AVG(response_ms) FROM agent_snapshots WHERE name = p.name) as avg_ms
    FROM agent_profiles p ORDER BY p.message_count DESC
"""):
    name, total, online, msgs, last_msg, avg_ms = row
    uptime = f"{online/total*100:.0f}%" if total and total > 0 else "N/A"
    latency = f"{avg_ms:.0f}ms" if avg_ms else "N/A"
    last = (last_msg or "never")[:19]
    print(fmt.format(name, uptime, str(msgs), latency, last))

print("\n⏰ Message Activity by Hour (UTC):")
hours = {}
for row in db.execute("""
    SELECT strftime('%H', ts) as hour, COUNT(*) as cnt
    FROM message_log WHERE ts != '' GROUP BY hour ORDER BY hour
"""):
    hours[row[0]] = row[1]

if hours:
    max_cnt = max(hours.values()) if hours else 1
    for h in range(24):
        hstr = f"{h:02d}"
        cnt = hours.get(hstr, 0)
        bar = "█" * int(cnt / max(max_cnt, 1) * 30)
        if cnt > 0:
            print(f"  {hstr}:00  {bar} ({cnt})")

print("\n📨 Recent Messages (last 10):")
for row in db.execute("""
    SELECT from_agent, to_agent, topic, ts, payload_preview
    FROM message_log ORDER BY ts DESC LIMIT 10
"""):
    fr, to, topic, ts, preview = row
    ts_short = ts[11:19] if ts and len(ts) > 19 else (ts or "?")[:8]
    preview_short = (preview[:60] + "...") if preview and len(preview) > 60 else (preview or "")
    print(f"  {ts_short} [{fr}→{to or 'all'}] {topic}: {preview_short}")

total_msgs = db.execute("SELECT COUNT(*) FROM message_log").fetchone()[0]
total_snaps = db.execute("SELECT COUNT(*) FROM agent_snapshots").fetchone()[0]
agent_count = db.execute("SELECT COUNT(*) FROM agent_profiles").fetchone()[0]
print(f"\n📈 Totals: {agent_count} agents, {total_snaps} snapshots, {total_msgs} messages logged")
db.close()
PYEOF
}

# --- Uptime Report ---
cmd_uptime() {
    local agent="${1:-}"
    init_db 2>/dev/null
    [ -z "$agent" ] && { echo "Usage: $0 uptime <agent_name>"; return 1; }

    echo "📊 Uptime Report: $agent"
    echo "========================="

    python3 - "$DB" "$agent" << 'PYEOF'
import sqlite3, sys

db = sqlite3.connect(sys.argv[1])
name = sys.argv[2]

row = db.execute("""
    SELECT total_snapshots, online_snapshots, message_count, first_seen, last_message_ts
    FROM agent_profiles WHERE name = ?
""", (name,)).fetchone()

if not row:
    print(f"❌ Agent '{name}' not found")
    sys.exit(1)

total, online, msgs, first_seen, last_msg = row
uptime = online / total * 100 if total > 0 else 0

print(f"  First seen: {first_seen}")
print(f"  Snapshots: {total} (🟢 {online} online, 🔴 {total-online} offline)")
print(f"  Uptime: {uptime:.1f}%")
print(f"  Messages: {msgs}")
print(f"  Last message: {last_msg or 'never'}")

print(f"\n  Hourly Online Pattern:")
for row in db.execute("""
    SELECT strftime('%H', captured_at) as hour, SUM(online) as on_count, COUNT(*) as total
    FROM agent_snapshots WHERE name = ? GROUP BY hour ORDER BY hour
""", (name,)):
    h, on, tot = row
    pct = on / tot * 100 if tot > 0 else 0
    bar = "█" * int(pct / 100 * 20)
    print(f"    {h}:00  {bar} {pct:.0f}% ({on}/{tot})")

db.close()
PYEOF
}

# --- Topics ---
cmd_topics() {
    init_db 2>/dev/null
    echo "📑 Message Topics Distribution"
    echo "=============================="

    python3 - "$DB" << 'PYEOF'
import sqlite3, sys

db = sqlite3.connect(sys.argv[1])

fmt = "{:<30} {:<8} {}"
print(fmt.format("Topic", "Count", "From Agents"))
print("-" * 60)

for row in db.execute("""
    SELECT topic, COUNT(*) as cnt, GROUP_CONCAT(DISTINCT from_agent) as agents
    FROM message_log WHERE topic != '' GROUP BY topic ORDER BY cnt DESC LIMIT 20
"""):
    print(fmt.format(row[0][:30], str(row[1]), row[2] or ""))

db.close()
PYEOF
}

# --- Help ---
cmd_help() {
    cat << 'HELP'
ClawTalk Agent Directory & Uptime Tracker

COMMANDS:
  snapshot       Take agent status snapshot + log messages
  status         Full directory dashboard
  uptime <name>  Detailed uptime report for agent
  topics         Message topic distribution
  log            Log messages only (no snapshot)
  help           This help text

ENVIRONMENT:
  CLAWTALK_API_KEY        Required: API key
  CLAWTALK_API            Optional: base URL (default: https://clawtalk.monkeymango.co)
  CLAWTALK_AGENT_DIR_DB   Optional: SQLite path

EXAMPLES:
  ./clawtalk-agent-directory.sh snapshot
  ./clawtalk-agent-directory.sh status
  ./clawtalk-agent-directory.sh uptime Motya
HELP
}

# --- Main ---
case "${1:-help}" in
    snapshot)     cmd_snapshot && cmd_log_messages ;;
    status)       cmd_status ;;
    uptime)       cmd_uptime "${2:-}" ;;
    topics)       cmd_topics ;;
    log)          cmd_log_messages ;;
    help|--help)  cmd_help ;;
    *)            echo "Unknown: $1"; cmd_help; exit 1 ;;
esac
