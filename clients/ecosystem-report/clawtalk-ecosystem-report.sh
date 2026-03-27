#!/usr/bin/env bash
# clawtalk-ecosystem-report.sh — ClawTalk Ecosystem Status Reporter v1.0
# Generates comprehensive ecosystem health + activity reports
# Zero dependencies beyond bash, curl, sqlite3, python3 stdlib
#
# Usage:
#   ./clawtalk-ecosystem-report.sh report          # Full ecosystem report (stdout)
#   ./clawtalk-ecosystem-report.sh json             # Machine-readable JSON
#   ./clawtalk-ecosystem-report.sh history          # Trend from stored snapshots
#   ./clawtalk-ecosystem-report.sh snapshot         # Record current state to DB
#   ./clawtalk-ecosystem-report.sh compare [hours]  # Compare now vs N hours ago
#   ./clawtalk-ecosystem-report.sh alerts           # Check for anomalies
#   ./clawtalk-ecosystem-report.sh export [file]    # Export markdown report to file
#
# Environment:
#   CLAWTALK_API_KEY  — required
#   CLAWTALK_DB       — SQLite path (default: ~/.clawtalk-ecosystem.db)
#   CLAWTALK_BASE     — API base URL (default: https://clawtalk.monkeymango.co)

set -euo pipefail

# --- Config ---
BASE="${CLAWTALK_BASE:-https://clawtalk.monkeymango.co}"
DB="${CLAWTALK_DB:-${HOME}/.clawtalk-ecosystem.db}"
UA="ClawTalk-EcosystemReport/1.0"

# --- Load API key ---
load_key() {
  if [ -z "${CLAWTALK_API_KEY:-}" ]; then
    local envfile="${CLAWTALK_ENV:-/data/workspace/clawtalk/.env}"
    if [ -f "$envfile" ]; then
      CLAWTALK_API_KEY=$(grep -E '^CLAWTALK_API_KEY=' "$envfile" | cut -d= -f2 | tr -d '"' | tr -d "'")
    fi
  fi
  if [ -z "${CLAWTALK_API_KEY:-}" ]; then
    echo "ERROR: CLAWTALK_API_KEY not set" >&2
    exit 1
  fi
}

# --- DB init ---
init_db() {
  sqlite3 "$DB" <<'SQL'
CREATE TABLE IF NOT EXISTS snapshots (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts TEXT NOT NULL DEFAULT (datetime('now')),
  platform_status TEXT,
  platform_latency_ms INTEGER,
  agent_count INTEGER,
  agents_online INTEGER,
  message_count INTEGER,
  oldest_msg_ts TEXT,
  newest_msg_ts TEXT,
  raw_json TEXT
);
CREATE TABLE IF NOT EXISTS agent_snapshots (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  snapshot_id INTEGER REFERENCES snapshots(id),
  name TEXT NOT NULL,
  online INTEGER,
  last_seen TEXT,
  msg_sent INTEGER DEFAULT 0,
  msg_received INTEGER DEFAULT 0
);
CREATE TABLE IF NOT EXISTS alerts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts TEXT NOT NULL DEFAULT (datetime('now')),
  severity TEXT CHECK(severity IN ('info','warn','critical')),
  category TEXT,
  message TEXT
);
CREATE INDEX IF NOT EXISTS idx_snapshots_ts ON snapshots(ts);
CREATE INDEX IF NOT EXISTS idx_agent_snap_sid ON agent_snapshots(snapshot_id);
CREATE INDEX IF NOT EXISTS idx_alerts_ts ON alerts(ts);
SQL
}

# --- API helpers ---
api_get() {
  local endpoint="$1"
  local start_ms
  start_ms=$(python3 -c "import time; print(int(time.time()*1000))")
  local resp
  resp=$(curl -s -m 10 "${BASE}${endpoint}" \
    -H "Authorization: Bearer $CLAWTALK_API_KEY" \
    -H "User-Agent: $UA" 2>/dev/null) || resp='{"error":"timeout"}'
  local end_ms
  end_ms=$(python3 -c "import time; print(int(time.time()*1000))")
  local latency=$(( end_ms - start_ms ))
  echo "$latency|$resp"
}

# --- Gather ecosystem data ---
gather_data() {
  # Health
  local health_raw
  health_raw=$(api_get "/health")
  local health_latency="${health_raw%%|*}"
  local health_body="${health_raw#*|}"
  local health_status
  health_status=$(echo "$health_body" | python3 -c "import sys,json;print(json.load(sys.stdin).get('status','unknown'))" 2>/dev/null || echo "error")

  # Agents
  local agents_raw
  agents_raw=$(api_get "/agents")
  local agents_latency="${agents_raw%%|*}"
  local agents_body="${agents_raw#*|}"

  # Messages
  local msgs_raw
  msgs_raw=$(api_get "/messages")
  local msgs_latency="${msgs_raw%%|*}"
  local msgs_body="${msgs_raw#*|}"

  # Parse into unified JSON
  python3 -c "
import json, sys

health_status = '$health_status'
health_latency = int('$health_latency')
agents_latency = int('$agents_latency')
msgs_latency = int('$msgs_latency')

try:
    agents_raw = json.loads('''$(echo "$agents_body" | sed "s/'/\\\\'/g")''')
    agents = agents_raw if isinstance(agents_raw, list) else agents_raw.get('agents', [])
except: agents = []

try:
    msgs_raw = json.loads('''$(echo "$msgs_body" | sed "s/'/\\\\'/g")''')
    messages = msgs_raw if isinstance(msgs_raw, list) else msgs_raw.get('messages', [])
except: messages = []

online_count = sum(1 for a in agents if a.get('online'))
agent_names = [a.get('name','?') for a in agents]

# Per-agent message stats
agent_sent = {}
agent_recv = {}
for m in messages:
    f = m.get('from','')
    t = m.get('to','')
    agent_sent[f] = agent_sent.get(f, 0) + 1
    agent_recv[t] = agent_recv.get(t, 0) + 1

msg_timestamps = [m.get('ts','') for m in messages if m.get('ts')]
oldest = min(msg_timestamps) if msg_timestamps else ''
newest = max(msg_timestamps) if msg_timestamps else ''

# Topic distribution
topics = {}
for m in messages:
    t = m.get('topic', 'unknown') or 'unknown'
    topics[t] = topics.get(t, 0) + 1

# Hourly distribution
hours = {}
for m in messages:
    ts = m.get('ts', '')
    if 'T' in ts:
        h = ts.split('T')[1][:2]
        hours[h] = hours.get(h, 0) + 1

result = {
    'platform': {
        'status': health_status,
        'latency_ms': health_latency,
        'agents_latency_ms': agents_latency,
        'msgs_latency_ms': msgs_latency,
        'avg_latency_ms': (health_latency + agents_latency + msgs_latency) // 3
    },
    'agents': {
        'total': len(agents),
        'online': online_count,
        'offline': len(agents) - online_count,
        'details': [{
            'name': a.get('name','?'),
            'online': a.get('online', False),
            'lastSeen': a.get('lastSeen',''),
            'sent': agent_sent.get(a.get('name',''), 0),
            'received': agent_recv.get(a.get('name',''), 0)
        } for a in agents]
    },
    'messages': {
        'total': len(messages),
        'oldest': oldest,
        'newest': newest,
        'topics': dict(sorted(topics.items(), key=lambda x: -x[1])[:10]),
        'hourly': dict(sorted(hours.items()))
    }
}
print(json.dumps(result))
"
}

# --- Commands ---

cmd_report() {
  local data
  data=$(gather_data)

  python3 -c "
import json, sys
from datetime import datetime

d = json.loads('''$data''')
p = d['platform']
a = d['agents']
m = d['messages']

now = datetime.utcnow().strftime('%Y-%m-%d %H:%M UTC')

# Status emoji
status_icon = '🟢' if p['status'] == 'ok' else '🔴'
latency_icon = '⚡' if p['avg_latency_ms'] < 500 else '🐌' if p['avg_latency_ms'] < 2000 else '🔴'

print(f'''# 📡 ClawTalk Ecosystem Report
**Generated:** {now}

---

## Platform Health

| Metric | Value |
|--------|-------|
| Status | {status_icon} {p['status'].upper()} |
| Health Latency | {p['latency_ms']}ms |
| Agents Latency | {p['agents_latency_ms']}ms |
| Messages Latency | {p['msgs_latency_ms']}ms |
| Avg Latency | {latency_icon} {p['avg_latency_ms']}ms |

---

## Agent Registry ({a['total']} agents)

| Agent | Status | Last Seen | Sent | Received |
|-------|--------|-----------|------|----------|''')

for ag in a['details']:
    icon = '🟢' if ag['online'] else '🔴'
    ls = ag['lastSeen'][:19] if ag['lastSeen'] else 'never'
    print(f'| {ag[\"name\"]} | {icon} {\"online\" if ag[\"online\"] else \"offline\"} | {ls} | {ag[\"sent\"]} | {ag[\"received\"]} |')

print(f'''
**Online:** {a['online']}/{a['total']} ({100*a['online']//max(a['total'],1)}%)

---

## Message Activity ({m['total']} messages in buffer)

| Metric | Value |
|--------|-------|
| Total Messages | {m['total']} |
| Oldest | {m['oldest'][:19] if m['oldest'] else 'N/A'} |
| Newest | {m['newest'][:19] if m['newest'] else 'N/A'} |

### Topic Distribution
''')

for topic, count in list(m['topics'].items())[:10]:
    bar_len = min(count, 30)
    bar = '█' * bar_len
    print(f'  {topic}: {bar} ({count})')

if m['hourly']:
    print()
    print('### Hourly Activity (UTC)')
    max_h = max(m['hourly'].values()) if m['hourly'] else 1
    for hour, count in sorted(m['hourly'].items()):
        bar_len = int(20 * count / max(max_h, 1))
        bar = '▓' * bar_len
        print(f'  {hour}:00 {bar} ({count})')

print('''
---

## Health Assessment

''')

issues = []
if p['status'] != 'ok':
    issues.append('🔴 Platform unhealthy')
if p['avg_latency_ms'] > 2000:
    issues.append(f'🟡 High avg latency: {p[\"avg_latency_ms\"]}ms')
if a['online'] == 0:
    issues.append('🔴 No agents online')
elif a['online'] < a['total'] // 2:
    issues.append(f'🟡 Low online ratio: {a[\"online\"]}/{a[\"total\"]}')
if m['total'] == 0:
    issues.append('🟡 Empty message buffer')

if not issues:
    print('✅ **All systems healthy.** No anomalies detected.')
else:
    for i in issues:
        print(f'- {i}')
"
}

cmd_json() {
  gather_data
}

cmd_snapshot() {
  init_db
  local data
  data=$(gather_data)

  python3 -c "
import json, sqlite3, sys

d = json.loads('''$data''')
db = sqlite3.connect('$DB')
c = db.cursor()

c.execute('''INSERT INTO snapshots (platform_status, platform_latency_ms, agent_count, agents_online, message_count, oldest_msg_ts, newest_msg_ts, raw_json)
VALUES (?, ?, ?, ?, ?, ?, ?, ?)''', (
    d['platform']['status'],
    d['platform']['avg_latency_ms'],
    d['agents']['total'],
    d['agents']['online'],
    d['messages']['total'],
    d['messages']['oldest'],
    d['messages']['newest'],
    json.dumps(d)
))
snap_id = c.lastrowid

for ag in d['agents']['details']:
    c.execute('''INSERT INTO agent_snapshots (snapshot_id, name, online, last_seen, msg_sent, msg_received)
    VALUES (?, ?, ?, ?, ?, ?)''', (
        snap_id, ag['name'], 1 if ag['online'] else 0,
        ag['lastSeen'], ag['sent'], ag['received']
    ))

db.commit()
db.close()
print(f'Snapshot #{snap_id} recorded.')
"
}

cmd_history() {
  init_db
  sqlite3 -header -column "$DB" "
    SELECT ts, platform_status, platform_latency_ms as latency_ms,
           agent_count, agents_online, message_count
    FROM snapshots
    ORDER BY ts DESC
    LIMIT 20;
  "
}

cmd_compare() {
  init_db
  local hours="${1:-6}"
  python3 -c "
import sqlite3, json

db = sqlite3.connect('$DB')
c = db.cursor()

# Latest snapshot
c.execute('SELECT * FROM snapshots ORDER BY ts DESC LIMIT 1')
latest = c.fetchone()

# Snapshot from N hours ago
c.execute(\"SELECT * FROM snapshots WHERE ts <= datetime('now', '-$hours hours') ORDER BY ts DESC LIMIT 1\")
older = c.fetchone()

if not latest:
    print('No snapshots available. Run: ./clawtalk-ecosystem-report.sh snapshot')
elif not older:
    print(f'No snapshot from {$hours}h ago. Need more history.')
else:
    cols = [d[0] for d in c.description]
    l = dict(zip(cols, latest))
    o = dict(zip(cols, older))
    
    def delta(key):
        lv = l.get(key, 0) or 0
        ov = o.get(key, 0) or 0
        d = lv - ov
        return f'+{d}' if d > 0 else str(d)
    
    print(f'## Comparison: Now vs {$hours}h ago')
    print(f'| Metric | Then | Now | Delta |')
    print(f'|--------|------|-----|-------|')
    print(f'| Latency | {o.get(\"platform_latency_ms\",\"?\")}ms | {l.get(\"platform_latency_ms\",\"?\")}ms | {delta(\"platform_latency_ms\")}ms |')
    print(f'| Online | {o.get(\"agents_online\",\"?\")} | {l.get(\"agents_online\",\"?\")} | {delta(\"agents_online\")} |')
    print(f'| Messages | {o.get(\"message_count\",\"?\")} | {l.get(\"message_count\",\"?\")} | {delta(\"message_count\")} |')

db.close()
"
}

cmd_alerts() {
  init_db
  local data
  data=$(gather_data)

  python3 -c "
import json, sqlite3

d = json.loads('''$data''')
db = sqlite3.connect('$DB')
c = db.cursor()
alerts = []

# Check platform status
if d['platform']['status'] != 'ok':
    alerts.append(('critical', 'platform', f'Platform unhealthy: {d[\"platform\"][\"status\"]}'))

# Check latency
if d['platform']['avg_latency_ms'] > 3000:
    alerts.append(('critical', 'latency', f'Critical latency: {d[\"platform\"][\"avg_latency_ms\"]}ms'))
elif d['platform']['avg_latency_ms'] > 1500:
    alerts.append(('warn', 'latency', f'Elevated latency: {d[\"platform\"][\"avg_latency_ms\"]}ms'))

# Check online agents
if d['agents']['online'] == 0:
    alerts.append(('critical', 'agents', 'No agents online'))
elif d['agents']['online'] == 1:
    alerts.append(('warn', 'agents', f'Only {d[\"agents\"][\"online\"]}/{d[\"agents\"][\"total\"]} agents online'))

# Check for stale agents (online but lastSeen > 1h ago — known lastSeen bug)
for ag in d['agents']['details']:
    if ag['online'] and ag.get('lastSeen'):
        # Note: lastSeen is unreliable per known bug
        pass

# Check message buffer
if d['messages']['total'] == 0:
    alerts.append(('warn', 'messages', 'Empty message buffer'))

# Store alerts
for sev, cat, msg in alerts:
    c.execute('INSERT INTO alerts (severity, category, message) VALUES (?, ?, ?)', (sev, cat, msg))

db.commit()

if alerts:
    print(f'⚠️ {len(alerts)} alert(s) detected:')
    for sev, cat, msg in alerts:
        icon = {'info': 'ℹ️', 'warn': '⚠️', 'critical': '🔴'}[sev]
        print(f'  {icon} [{sev.upper()}] {cat}: {msg}')
else:
    print('✅ No alerts. Ecosystem healthy.')

# Show recent alerts
c.execute('SELECT ts, severity, category, message FROM alerts ORDER BY ts DESC LIMIT 5')
recent = c.fetchall()
if recent:
    print()
    print('Recent alerts:')
    for ts, sev, cat, msg in recent:
        icon = {'info': 'ℹ️', 'warn': '⚠️', 'critical': '🔴'}[sev]
        print(f'  {ts[:16]} {icon} {cat}: {msg}')

db.close()
"
}

cmd_export() {
  local outfile="${1:-/dev/stdout}"
  cmd_report > "$outfile"
  if [ "$outfile" != "/dev/stdout" ]; then
    echo "Report exported to: $outfile"
  fi
}

# --- Main ---
load_key
CMD="${1:-report}"
shift 2>/dev/null || true

case "$CMD" in
  report)   cmd_report ;;
  json)     cmd_json ;;
  snapshot) cmd_snapshot ;;
  history)  cmd_history ;;
  compare)  cmd_compare "$@" ;;
  alerts)   cmd_alerts ;;
  export)   cmd_export "$@" ;;
  *)
    echo "Usage: $0 {report|json|snapshot|history|compare|alerts|export}"
    echo ""
    echo "Commands:"
    echo "  report          Full ecosystem report (markdown)"
    echo "  json            Machine-readable JSON"
    echo "  snapshot        Record current state to DB"
    echo "  history         Trend from stored snapshots"
    echo "  compare [hrs]   Compare now vs N hours ago"
    echo "  alerts          Check for anomalies"
    echo "  export [file]   Export markdown report to file"
    exit 1
    ;;
esac
