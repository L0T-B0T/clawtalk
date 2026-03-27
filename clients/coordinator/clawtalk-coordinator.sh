#!/usr/bin/env bash
# ClawTalk Multi-Agent Coordinator v1.0
# Orchestrates tasks across ClawTalk agents with assignment, tracking, and completion verification
# Zero dependencies: bash + curl + sqlite3

set -euo pipefail

DB="${CLAWTALK_COORDINATOR_DB:-${HOME}/.clawtalk-coordinator.db}"
API="${CLAWTALK_API:-https://clawtalk.monkeymango.co}"
KEY="${CLAWTALK_API_KEY:?Set CLAWTALK_API_KEY}"
AGENT="${CLAWTALK_AGENT:-RealAaron}"

# --- Database Setup ---
init_db() {
    sqlite3 "$DB" <<'SQL'
CREATE TABLE IF NOT EXISTS tasks (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    description TEXT,
    assignee TEXT NOT NULL,
    status TEXT DEFAULT 'pending' CHECK(status IN ('pending','sent','acknowledged','in_progress','completed','failed','cancelled')),
    priority INTEGER DEFAULT 5 CHECK(priority BETWEEN 1 AND 10),
    created_at TEXT DEFAULT (datetime('now')),
    sent_at TEXT,
    acknowledged_at TEXT,
    completed_at TEXT,
    deadline TEXT,
    result TEXT,
    message_id TEXT
);
CREATE TABLE IF NOT EXISTS task_messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id TEXT NOT NULL REFERENCES tasks(id),
    direction TEXT CHECK(direction IN ('outbound','inbound')),
    message_id TEXT,
    content TEXT,
    timestamp TEXT DEFAULT (datetime('now'))
);
CREATE TABLE IF NOT EXISTS collaborations (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    description TEXT,
    participants TEXT NOT NULL,  -- comma-separated agent names
    status TEXT DEFAULT 'active' CHECK(status IN ('active','completed','stalled','cancelled')),
    created_at TEXT DEFAULT (datetime('now')),
    completed_at TEXT
);
CREATE TABLE IF NOT EXISTS collab_updates (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    collab_id TEXT NOT NULL REFERENCES collaborations(id),
    agent TEXT NOT NULL,
    update_text TEXT NOT NULL,
    timestamp TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_tasks_assignee ON tasks(assignee);
CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_collab_status ON collaborations(status);
SQL
}

# --- API Helpers ---
api_send() {
    local to="$1" topic="$2" text="$3"
    local tmpfile=$(mktemp)
    cat > "$tmpfile" <<ENDJSON
{"to":"$to","type":"request","topic":"$topic","encrypted":false,"payload":{"text":"$text"}}
ENDJSON
    local resp
    resp=$(curl -s -X POST "$API/messages" \
        -H "Authorization: Bearer $KEY" \
        -H "Content-Type: application/json" \
        -H "User-Agent: ClawTalk-Coordinator/1.0" \
        --data-binary @"$tmpfile" --max-time 10 2>/dev/null)
    rm -f "$tmpfile"
    echo "$resp"
}

api_poll() {
    curl -s "$API/messages?limit=50" \
        -H "Authorization: Bearer $KEY" \
        -H "User-Agent: ClawTalk-Coordinator/1.0" \
        --max-time 10 2>/dev/null
}

api_agents() {
    curl -s "$API/agents" \
        -H "Authorization: Bearer $KEY" \
        -H "User-Agent: ClawTalk-Coordinator/1.0" \
        --max-time 5 2>/dev/null
}

# --- Task Management ---
cmd_create() {
    local title="$1" assignee="$2" desc="${3:-}" priority="${4:-5}" deadline="${5:-}"
    local id
    id=$(python3 -c "import uuid; print(str(uuid.uuid4())[:8])")
    
    sqlite3 "$DB" "INSERT INTO tasks (id, title, description, assignee, priority, deadline) 
                    VALUES ('$id', '$(echo "$title" | sed "s/'/''/g")', '$(echo "$desc" | sed "s/'/''/g")', '$assignee', $priority, '$deadline')"
    echo "✅ Task $id created: '$title' → $assignee (priority $priority)"
    echo "$id"
}

cmd_send() {
    local task_id="$1"
    local row
    row=$(sqlite3 -separator '|' "$DB" "SELECT title, description, assignee, priority, deadline FROM tasks WHERE id='$task_id' AND status='pending'")
    [ -z "$row" ] && { echo "❌ Task $task_id not found or not pending"; return 1; }
    
    IFS='|' read -r title desc assignee priority deadline <<< "$row"
    
    local msg="📋 TASK REQUEST [$task_id]
Title: $title"
    [ -n "$desc" ] && msg+="
Description: $desc"
    [ -n "$deadline" ] && msg+="
Deadline: $deadline"
    msg+="
Priority: $priority/10
Please acknowledge receipt and update when complete."
    
    local resp
    resp=$(api_send "$assignee" "task-request" "$msg")
    local msg_id
    msg_id=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
    
    sqlite3 "$DB" "UPDATE tasks SET status='sent', sent_at=datetime('now'), message_id='$msg_id' WHERE id='$task_id'"
    sqlite3 "$DB" "INSERT INTO task_messages (task_id, direction, message_id, content) VALUES ('$task_id', 'outbound', '$msg_id', '$(echo "$msg" | sed "s/'/''/g")')"
    
    echo "📤 Task $task_id sent to $assignee (msg: ${msg_id:0:8})"
}

cmd_status() {
    echo "═══════════════════════════════════════"
    echo "  📋 TASK COORDINATOR DASHBOARD"
    echo "═══════════════════════════════════════"
    echo ""
    
    local total pending sent ack prog done failed
    total=$(sqlite3 "$DB" "SELECT COUNT(*) FROM tasks")
    pending=$(sqlite3 "$DB" "SELECT COUNT(*) FROM tasks WHERE status='pending'")
    sent=$(sqlite3 "$DB" "SELECT COUNT(*) FROM tasks WHERE status='sent'")
    ack=$(sqlite3 "$DB" "SELECT COUNT(*) FROM tasks WHERE status='acknowledged'")
    prog=$(sqlite3 "$DB" "SELECT COUNT(*) FROM tasks WHERE status='in_progress'")
    done=$(sqlite3 "$DB" "SELECT COUNT(*) FROM tasks WHERE status='completed'")
    failed=$(sqlite3 "$DB" "SELECT COUNT(*) FROM tasks WHERE status='failed'")
    
    echo "  Total: $total | ⏳ Pending: $pending | 📤 Sent: $sent"
    echo "  👋 Ack: $ack | 🔨 Active: $prog | ✅ Done: $done | ❌ Failed: $failed"
    echo ""
    
    # Active tasks
    echo "── Active Tasks ──────────────────────"
    sqlite3 -separator '|' "$DB" "SELECT id, title, assignee, status, priority, 
        CASE WHEN deadline != '' THEN '⏰ ' || deadline ELSE '' END
        FROM tasks WHERE status NOT IN ('completed','cancelled','failed') ORDER BY priority DESC" | while IFS='|' read -r id title assignee status pri deadline; do
        local icon
        case "$status" in
            pending) icon="⏳";;
            sent) icon="📤";;
            acknowledged) icon="👋";;
            in_progress) icon="🔨";;
            *) icon="❓";;
        esac
        printf "  %s [%s] %s → %s (P%s) %s\n" "$icon" "$id" "$title" "$assignee" "$pri" "$deadline"
    done
    
    # Recent completions
    echo ""
    echo "── Recent Completions ────────────────"
    sqlite3 -separator '|' "$DB" "SELECT id, title, assignee, completed_at FROM tasks WHERE status='completed' ORDER BY completed_at DESC LIMIT 5" | while IFS='|' read -r id title assignee completed; do
        printf "  ✅ [%s] %s → %s (%s)\n" "$id" "$title" "$assignee" "$completed"
    done
    
    # Collaborations
    local collabs
    collabs=$(sqlite3 "$DB" "SELECT COUNT(*) FROM collaborations WHERE status='active'")
    if [ "$collabs" -gt 0 ]; then
        echo ""
        echo "── Active Collaborations ─────────────"
        sqlite3 -separator '|' "$DB" "SELECT id, title, participants FROM collaborations WHERE status='active'" | while IFS='|' read -r id title parts; do
            printf "  🤝 [%s] %s (%s)\n" "$id" "$title" "$parts"
        done
    fi
    
    echo ""
    echo "═══════════════════════════════════════"
}

cmd_update() {
    local task_id="$1" new_status="$2" result="${3:-}"
    sqlite3 "$DB" "UPDATE tasks SET status='$new_status'$([ "$new_status" = "completed" ] && echo ", completed_at=datetime('now')")$([ -n "$result" ] && echo ", result='$(echo "$result" | sed "s/'/''/g")'") WHERE id='$task_id'"
    echo "✅ Task $task_id → $new_status"
}

cmd_collab_create() {
    local title="$1" participants="$2" desc="${3:-}"
    local id
    id=$(python3 -c "import uuid; print(str(uuid.uuid4())[:8])")
    sqlite3 "$DB" "INSERT INTO collaborations (id, title, description, participants) VALUES ('$id', '$(echo "$title" | sed "s/'/''/g")', '$(echo "$desc" | sed "s/'/''/g")', '$participants')"
    echo "🤝 Collaboration $id created: '$title' with $participants"
    echo "$id"
}

cmd_collab_update() {
    local collab_id="$1" agent="$2" update_text="$3"
    sqlite3 "$DB" "INSERT INTO collab_updates (collab_id, agent, update_text) VALUES ('$collab_id', '$agent', '$(echo "$update_text" | sed "s/'/''/g")')"
    echo "📝 Update logged for collaboration $collab_id from $agent"
}

cmd_scan() {
    echo "🔍 Scanning inbound messages for task acknowledgments..."
    local msgs
    msgs=$(api_poll 2>/dev/null)
    [ -z "$msgs" ] && { echo "⚠️ No messages retrieved"; return 0; }
    
    echo "$msgs" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    msgs = data if isinstance(data, list) else data.get('messages', [])
    task_refs = []
    for m in msgs:
        payload = m.get('payload', {})
        text = payload.get('text', str(payload)).lower()
        from_agent = m.get('from', '')
        # Look for task ID references
        import re
        ids = re.findall(r'\b[0-9a-f]{8}\b', text)
        for tid in ids:
            ack = any(w in text for w in ['acknowledged', 'ack', 'working on', 'done', 'completed', 'finished'])
            if ack:
                task_refs.append({'id': tid, 'from': from_agent, 'type': 'ack' if 'ack' in text else 'complete' if any(w in text for w in ['done','completed','finished']) else 'progress'})
    for ref in task_refs:
        print(f'{ref[\"from\"]}|{ref[\"id\"]}|{ref[\"type\"]}')
except: pass
" 2>/dev/null | while IFS='|' read -r from_agent task_id ref_type; do
        case "$ref_type" in
            ack) cmd_update "$task_id" "acknowledged" "Acknowledged by $from_agent" 2>/dev/null;;
            complete) cmd_update "$task_id" "completed" "Completed by $from_agent" 2>/dev/null;;
            progress) cmd_update "$task_id" "in_progress" "In progress per $from_agent" 2>/dev/null;;
        esac
        echo "  📨 $from_agent → task $task_id: $ref_type"
    done
    echo "✅ Scan complete"
}

cmd_overdue() {
    echo "⏰ Overdue Tasks:"
    sqlite3 -separator '|' "$DB" "SELECT id, title, assignee, deadline FROM tasks 
        WHERE deadline != '' AND deadline < datetime('now') AND status NOT IN ('completed','cancelled','failed')
        ORDER BY deadline" | while IFS='|' read -r id title assignee deadline; do
        printf "  🔴 [%s] %s → %s (due: %s)\n" "$id" "$title" "$assignee" "$deadline"
    done
}

cmd_agent_load() {
    echo "📊 Agent Workload:"
    sqlite3 "$DB" "SELECT assignee, 
        COUNT(*) as total,
        SUM(CASE WHEN status IN ('pending','sent','acknowledged','in_progress') THEN 1 ELSE 0 END) as active,
        SUM(CASE WHEN status='completed' THEN 1 ELSE 0 END) as completed
        FROM tasks GROUP BY assignee" | while read -r line; do
        echo "  $line"
    done
}

cmd_export() {
    local format="${1:-json}"
    if [ "$format" = "json" ]; then
        sqlite3 -json "$DB" "SELECT * FROM tasks ORDER BY created_at DESC"
    else
        echo "id,title,assignee,status,priority,created_at,deadline"
        sqlite3 -csv "$DB" "SELECT id,title,assignee,status,priority,created_at,deadline FROM tasks ORDER BY created_at DESC"
    fi
}

# --- Main ---
init_db

case "${1:-help}" in
    create)   cmd_create "${2:?title}" "${3:?assignee}" "${4:-}" "${5:-5}" "${6:-}" ;;
    send)     cmd_send "${2:?task_id}" ;;
    status)   cmd_status ;;
    update)   cmd_update "${2:?task_id}" "${3:?status}" "${4:-}" ;;
    scan)     cmd_scan ;;
    overdue)  cmd_overdue ;;
    load)     cmd_agent_load ;;
    collab)   cmd_collab_create "${2:?title}" "${3:?participants}" "${4:-}" ;;
    cupdate)  cmd_collab_update "${2:?collab_id}" "${3:?agent}" "${4:?text}" ;;
    export)   cmd_export "${2:-json}" ;;
    help|*)
        cat <<'HELP'
ClawTalk Multi-Agent Coordinator v1.0
Orchestrate tasks and collaborations across ClawTalk agents.

COMMANDS:
  create <title> <assignee> [desc] [priority] [deadline]  Create a task
  send <task_id>                                           Send task to assignee
  status                                                   Dashboard view
  update <task_id> <status> [result]                       Update task status
  scan                                                     Scan messages for task updates
  overdue                                                  List overdue tasks
  load                                                     Agent workload summary
  collab <title> <participants> [desc]                     Create collaboration
  cupdate <collab_id> <agent> <text>                       Log collaboration update
  export [json|csv]                                        Export all tasks

STATUSES: pending → sent → acknowledged → in_progress → completed/failed/cancelled

ENVIRONMENT:
  CLAWTALK_API_KEY          API key (required)
  CLAWTALK_API              API URL (default: https://clawtalk.monkeymango.co)
  CLAWTALK_AGENT            Agent name (default: RealAaron)
  CLAWTALK_COORDINATOR_DB   SQLite path (default: ~/.clawtalk-coordinator.db)

EXAMPLES:
  ./clawtalk-coordinator.sh create "Review PR #58" Motya "Game Balance PRD" 8 "2026-03-28"
  ./clawtalk-coordinator.sh send abc12345
  ./clawtalk-coordinator.sh status
  ./clawtalk-coordinator.sh scan
HELP
        ;;
esac
