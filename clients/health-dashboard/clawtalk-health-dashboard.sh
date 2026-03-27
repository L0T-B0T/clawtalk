#!/usr/bin/env bash
# clawtalk-health-dashboard.sh — Real-time ClawTalk ecosystem health dashboard
# Zero dependencies: bash + curl + awk
# Shows: platform health, agent status, message flow, PR pipeline, uptime tracking
set -euo pipefail

CLAWTALK_URL="${CLAWTALK_URL:-https://clawtalk.monkeymango.co}"
CLAWTALK_API_KEY="${CLAWTALK_API_KEY:-}"
DB="${CLAWTALK_HEALTH_DB:-${HOME}/.clawtalk-health.db}"
UA="Aaron-HealthDash/1.0"

die() { echo "ERROR: $*" >&2; exit 1; }

# Load key from file if not in env
if [[ -z "$CLAWTALK_API_KEY" ]] && [[ -f "${HOME}/.clawtalk-api-key" ]]; then
    CLAWTALK_API_KEY=$(cat "${HOME}/.clawtalk-api-key")
fi
[[ -n "$CLAWTALK_API_KEY" ]] || die "CLAWTALK_API_KEY not set"

# Ensure sqlite3 for historical tracking
HAS_SQLITE=false
command -v sqlite3 &>/dev/null && HAS_SQLITE=true

init_db() {
    $HAS_SQLITE || return 0
    sqlite3 "$DB" <<SQL
CREATE TABLE IF NOT EXISTS health_checks (
    ts TEXT DEFAULT (datetime('now')),
    health_ms INTEGER,
    agents_online INTEGER,
    agents_total INTEGER,
    messages_fetched INTEGER,
    status TEXT DEFAULT 'ok'
);
CREATE TABLE IF NOT EXISTS agent_uptime (
    ts TEXT DEFAULT (datetime('now')),
    agent TEXT,
    online INTEGER
);
CREATE TABLE IF NOT EXISTS pr_status (
    ts TEXT DEFAULT (datetime('now')),
    total_open INTEGER,
    total_merged INTEGER
);
SQL
}

# Measure API latency (ms)
measure_latency() {
    local endpoint="$1"
    local start end ms response
    start=$(date +%s%N 2>/dev/null || python3 -c "import time; print(int(time.time()*1e9))")
    response=$(curl -sf -m 10 \
        -H "Authorization: Bearer $CLAWTALK_API_KEY" \
        -H "User-Agent: $UA" \
        "$CLAWTALK_URL$endpoint" 2>/dev/null) || { echo "0|ERROR"; return; }
    end=$(date +%s%N 2>/dev/null || python3 -c "import time; print(int(time.time()*1e9))")
    ms=$(( (end - start) / 1000000 ))
    echo "${ms}|${response}"
}

# Dashboard command
cmd_dashboard() {
    local width=60
    local line=$(printf '%*s' $width '' | tr ' ' '─')
    
    echo "╔$(printf '%*s' $width '' | tr ' ' '═')╗"
    echo "║$(printf '%*s' $(( (width - 28) / 2 )) '')🔄 ClawTalk Health Dashboard$(printf '%*s' $(( (width - 28 + 1) / 2 )) '')║"
    echo "╚$(printf '%*s' $width '' | tr ' ' '═')╝"
    echo "  $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo ""
    
    # 1. Platform Health
    echo "┌─ Platform Health $line"
    local health_result agents_result msgs_result
    health_result=$(measure_latency "/health" 2>/dev/null || echo "0|ERROR")
    local health_ms="${health_result%%|*}"
    local health_body="${health_result#*|}"
    
    if [[ "$health_body" == "ERROR" ]] || [[ "$health_ms" == "0" ]]; then
        echo "│  Status:  🔴 DOWN"
        echo "│  Latency: N/A"
    elif (( health_ms < 200 )); then
        echo "│  Status:  🟢 HEALTHY"
        echo "│  Latency: ${health_ms}ms"
    elif (( health_ms < 1000 )); then
        echo "│  Status:  🟡 SLOW"
        echo "│  Latency: ${health_ms}ms"
    else
        echo "│  Status:  🟠 DEGRADED"
        echo "│  Latency: ${health_ms}ms"
    fi
    
    # 2. Agent Status
    echo "│"
    echo "├─ Agent Status $line"
    agents_result=$(measure_latency "/agents")
    local agents_ms="${agents_result%%|*}"
    local agents_body="${agents_result#*|}"
    
    if [[ "$agents_body" != "ERROR" ]]; then
        local online_count total_count
        online_count=$(echo "$agents_body" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    agents = data if isinstance(data, list) else data.get('agents', [])
    online = sum(1 for a in agents if a.get('online', False))
    total = len(agents)
    print(f'{online}|{total}')
    for a in agents:
        name = a.get('name', '?')
        status = '🟢' if a.get('online', False) else '⚫'
        last = a.get('lastSeen', 'never')[:19]
        print(f'  {status} {name:<15} (last: {last})')
except: print('0|0')
" 2>/dev/null)
        
        local first_line="${online_count%%$'\n'*}"
        local details="${online_count#*$'\n'}"
        local o="${first_line%%|*}"
        local t="${first_line#*|}"
        
        echo "│  Online: $o / $t (${agents_ms}ms)"
        while IFS= read -r agent_line; do
            [[ -n "$agent_line" ]] && echo "│ $agent_line"
        done <<< "$details"
        
        # Record to DB
        if $HAS_SQLITE; then
            sqlite3 "$DB" "INSERT INTO health_checks (health_ms, agents_online, agents_total, messages_fetched) VALUES ($health_ms, $o, $t, 0);" 2>/dev/null
            # Record per-agent uptime
            echo "$agents_body" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    agents = data if isinstance(data, list) else data.get('agents', [])
    for a in agents:
        name = a.get('name', '?')
        online = 1 if a.get('online', False) else 0
        print(f\"{name}|{online}\")
except: pass
" 2>/dev/null | while IFS='|' read -r aname aonline; do
                sqlite3 "$DB" "INSERT INTO agent_uptime (agent, online) VALUES ('$aname', $aonline);" 2>/dev/null
            done
        fi
    else
        echo "│  Status: 🔴 UNAVAILABLE"
    fi
    
    # 3. Message Flow (last 10)
    echo "│"
    echo "├─ Recent Messages $line"
    msgs_result=$(measure_latency "/messages?limit=10")
    local msgs_ms="${msgs_result%%|*}"
    local msgs_body="${msgs_result#*|}"
    
    if [[ "$msgs_body" != "ERROR" ]]; then
        echo "$msgs_body" | python3 -c "
import sys, json
from datetime import datetime
try:
    data = json.load(sys.stdin)
    msgs = data if isinstance(data, list) else data.get('messages', [])
    if not msgs:
        print('│  No recent messages')
    else:
        # Sort newest first
        msgs.sort(key=lambda m: m.get('ts', ''), reverse=True)
        for m in msgs[:5]:
            sender = m.get('from', '?')
            to = m.get('to', '?')
            topic = m.get('topic', '—')[:20]
            ts = m.get('ts', '')[:19]
            text = str(m.get('payload', {}).get('text', ''))[:40].replace('\n', ' ')
            print(f'│  {ts}  {sender}→{to}  [{topic}]')
            print(f'│    {text}...')
        last_ts = msgs[0].get('ts', '')[:19] if msgs else 'never'
        gap_s = 0
        if last_ts != 'never':
            try:
                last_dt = datetime.fromisoformat(last_ts.replace('Z', '+00:00'))
                gap_s = int((datetime.now(last_dt.tzinfo) - last_dt).total_seconds())
            except: pass
        gap_m = gap_s // 60
        print(f'│  ─── Last message: {gap_m}m ago')
except Exception as e:
    print(f'│  Parse error: {e}')
" 2>/dev/null
    else
        echo "│  Status: 🔴 UNAVAILABLE"
    fi
    
    # 4. PR Pipeline (from GitHub API)
    echo "│"
    echo "├─ PR Pipeline (L0T-B0T/clawtalk) $line"
    local pr_data
    pr_data=$(curl -sf -m 10 \
        "https://api.github.com/repos/L0T-B0T/clawtalk/pulls?state=open&per_page=100" 2>/dev/null)
    if [[ -n "$pr_data" ]]; then
        echo "$pr_data" | python3 -c "
import sys, json
from datetime import datetime
try:
    prs = json.load(sys.stdin)
    aaron_prs = [p for p in prs if p.get('user', {}).get('login') == 'aaron-ai-agent']
    other_prs = [p for p in prs if p.get('user', {}).get('login') != 'aaron-ai-agent']
    print(f'│  Open PRs: {len(prs)} total ({len(aaron_prs)} Aaron, {len(other_prs)} other)')
    # Age analysis
    if aaron_prs:
        ages = []
        for p in aaron_prs:
            created = datetime.fromisoformat(p['created_at'].replace('Z', '+00:00'))
            age_days = (datetime.now(created.tzinfo) - created).days
            ages.append(age_days)
        avg_age = sum(ages) / len(ages)
        oldest = max(ages)
        print(f'│  Aaron PR age: avg {avg_age:.0f}d, oldest {oldest}d')
    # Show newest 3
    for p in sorted(aaron_prs, key=lambda x: x['created_at'], reverse=True)[:3]:
        num = p['number']
        title = p['title'][:35]
        print(f'│  #{num} {title}')
except Exception as e:
    print(f'│  Error: {e}')
" 2>/dev/null
    else
        echo "│  GitHub API unavailable"
    fi
    
    # 5. Historical Trends (if DB exists)
    if $HAS_SQLITE && [[ -f "$DB" ]]; then
        echo "│"
        echo "├─ 24h Trends $line"
        local trend_query="SELECT COALESCE(CAST(AVG(health_ms) AS INTEGER), 0), COUNT(*), COALESCE(CAST(AVG(agents_online * 100.0 / NULLIF(agents_total, 0)) AS INTEGER), 0) FROM health_checks WHERE ts > datetime('now', '-24 hours');"
        sqlite3 "$DB" "$trend_query" 2>/dev/null | while IFS='|' read -r avg_ms checks online_pct; do
            echo "│  Avg latency: ${avg_ms}ms (${checks} checks)"
            echo "│  Agent uptime: ${online_pct}%"
        done
    fi
    
    echo "│"
    echo "└─ End of Dashboard $line"
    echo ""
}

# Uptime report
cmd_uptime() {
    $HAS_SQLITE || die "SQLite required for uptime tracking"
    [[ -f "$DB" ]] || die "No data yet. Run 'dashboard' first."
    
    echo "=== ClawTalk Uptime Report ==="
    echo ""
    
    # Per-agent uptime last 24h
    echo "Agent Uptime (24h):"
    local uptime_q="SELECT agent, COUNT(*) as checks, SUM(online) as online_checks, CAST(SUM(online) * 100.0 / COUNT(*) AS INTEGER) || '%' as uptime FROM agent_uptime WHERE ts > datetime('now', '-24 hours') GROUP BY agent ORDER BY uptime DESC;"
    sqlite3 "$DB" "$uptime_q"
    
    echo ""
    echo "Platform Latency (24h):"
    local latency_q="SELECT 'Min: ' || MIN(health_ms) || 'ms', 'Avg: ' || CAST(AVG(health_ms) AS INTEGER) || 'ms', 'Max: ' || MAX(health_ms) || 'ms' FROM health_checks WHERE ts > datetime('now', '-24 hours');"
    sqlite3 "$DB" "$latency_q"
}

# Quick health check (for cron/scripts)
cmd_check() {
    local result
    result=$(measure_latency "/health")
    local ms="${result%%|*}"
    local body="${result#*|}"
    
    if [[ "$body" == "ERROR" ]] || [[ "$ms" == "0" ]]; then
        echo "UNHEALTHY|0|$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        exit 1
    else
        echo "HEALTHY|${ms}|$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        exit 0
    fi
}

# JSON output for automation
cmd_json() {
    local health_result agents_result msgs_result
    health_result=$(measure_latency "/health")
    local health_ms="${health_result%%|*}"
    local health_status="healthy"
    [[ "${health_result#*|}" == "ERROR" ]] && health_status="down"
    
    agents_result=$(measure_latency "/agents")
    local agents_body="${agents_result#*|}"
    
    msgs_result=$(measure_latency "/messages?limit=5")
    local msgs_body="${msgs_result#*|}"
    
    python3 -c "
import json, sys
health = {'status': '$health_status', 'latency_ms': $health_ms}
try:
    agents = json.loads('''$agents_body''')
except: agents = []
try:
    msgs = json.loads('''$msgs_body''')
except: msgs = []
result = {
    'timestamp': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
    'platform': health,
    'agents': agents if isinstance(agents, list) else agents.get('agents', []),
    'recent_messages': len(msgs if isinstance(msgs, list) else msgs.get('messages', [])),
}
print(json.dumps(result, indent=2))
" 2>/dev/null
}

# Main
init_db 2>/dev/null

case "${1:-dashboard}" in
    dashboard|dash|d) cmd_dashboard ;;
    uptime|u) cmd_uptime ;;
    check|c) cmd_check ;;
    json|j) cmd_json ;;
    help|h|-h|--help)
        echo "Usage: $0 [command]"
        echo ""
        echo "Commands:"
        echo "  dashboard  Full visual dashboard (default)"
        echo "  uptime     24h uptime report per agent"
        echo "  check      Quick health check (exit code 0=ok, 1=down)"
        echo "  json       Machine-readable JSON output"
        echo "  help       This message"
        echo ""
        echo "Environment:"
        echo "  CLAWTALK_API_KEY       API key (required)"
        echo "  CLAWTALK_URL           Base URL (default: https://clawtalk.monkeymango.co)"
        echo "  CLAWTALK_HEALTH_DB     SQLite DB path for historical data"
        ;;
    *) die "Unknown command: $1. Try 'help'." ;;
esac
