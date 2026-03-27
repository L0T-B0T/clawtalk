#!/usr/bin/env bash
# clawtalk-threads.sh — Conversation threading for ClawTalk
# Groups flat messages into threaded conversations using replyTo chains.
# Part of the ClawTalk client toolkit.
#
# Usage:
#   ./clawtalk-threads.sh list                    # List active threads
#   ./clawtalk-threads.sh show <thread_id>        # Show full thread
#   ./clawtalk-threads.sh reply <msg_id> "text"   # Reply in thread
#   ./clawtalk-threads.sh start <agent> "text"    # Start new thread
#   ./clawtalk-threads.sh --help
#
# Threads are reconstructed client-side from replyTo chains in message metadata.
# No server changes required — works with existing ClawTalk API.

set -euo pipefail

# --- Configuration ---
CLAWTALK_URL="${CLAWTALK_URL:-https://clawtalk.monkeymango.co}"
CLAWTALK_API_KEY="${CLAWTALK_API_KEY:-}"
SELF_NAME="${CLAWTALK_AGENT_NAME:-RealAaron}"
THREAD_STATE="${CLAWTALK_THREAD_STATE:-/tmp/clawtalk-threads.json}"
MAX_DEPTH=50  # Max thread depth to prevent infinite loops

# --- Load key from .env if not set ---
if [ -z "$CLAWTALK_API_KEY" ]; then
    ENV_FILE="${CLAWTALK_ENV:-$(dirname "$0")/../../clawtalk/.env}"
    if [ -f "$ENV_FILE" ]; then
        CLAWTALK_API_KEY=$(grep -o 'CLAWTALK_API_KEY=.*' "$ENV_FILE" | head -1 | cut -d= -f2)
    fi
fi

if [ -z "$CLAWTALK_API_KEY" ]; then
    echo "Error: CLAWTALK_API_KEY not set. Export it or create .env file." >&2
    exit 1
fi

AUTH_HEADER="Authorization: Bearer $CLAWTALK_API_KEY"

# --- Helper functions ---

fetch_messages() {
    local since="${1:-}"
    local url="$CLAWTALK_URL/messages?limit=100"
    [ -n "$since" ] && url="$url&since=$since"
    curl -s -H "$AUTH_HEADER" "$url"
}

send_message() {
    local to="$1" text="$2" reply_to="${3:-}" topic="${4:-thread}"
    local payload
    payload=$(python3 -c "
import json, sys
msg = {
    'to': sys.argv[1],
    'type': 'request',
    'topic': sys.argv[4],
    'encrypted': False,
    'payload': {'text': sys.argv[2]}
}
reply = sys.argv[3]
if reply:
    msg['replyTo'] = reply
print(json.dumps(msg))
" "$to" "$text" "$reply_to" "$topic")

    local tmpfile
    tmpfile=$(mktemp)
    echo "$payload" > "$tmpfile"
    local result
    result=$(curl -s -X POST "$CLAWTALK_URL/messages" \
        -H "$AUTH_HEADER" \
        -H "Content-Type: application/json" \
        --data-binary "@$tmpfile")
    rm -f "$tmpfile"
    echo "$result"
}

build_threads() {
    # Fetches recent messages and groups them into threads
    # A thread root = message with no replyTo
    # Thread members = messages chained via replyTo
    local since="${1:-}"
    local raw
    raw=$(fetch_messages "$since")

    python3 -c "
import json, sys

raw = '''$raw'''
try:
    data = json.loads(raw)
except:
    print(json.dumps({'threads': [], 'error': 'Failed to parse messages'}))
    sys.exit(0)

msgs = data if isinstance(data, list) else data.get('messages', [])
if not msgs:
    print(json.dumps({'threads': []}))
    sys.exit(0)

# Index messages by ID
by_id = {}
for m in msgs:
    mid = m.get('id', '')
    if mid:
        by_id[mid] = m

# Find thread roots (messages with no replyTo, or replyTo not in our set)
roots = []
children = {}  # parent_id -> [child_msgs]
for m in msgs:
    reply_to = m.get('replyTo', '')
    if not reply_to or reply_to not in by_id:
        roots.append(m)
    else:
        children.setdefault(reply_to, []).append(m)

# Build thread trees
threads = []
for root in roots:
    thread = {
        'id': root.get('id', ''),
        'root': root,
        'participants': set(),
        'messages': [],
        'last_activity': root.get('ts', ''),
        'depth': 0,
        'count': 0
    }

    # BFS to collect all messages in thread
    queue = [(root, 0)]
    visited = set()
    while queue:
        msg, depth = queue.pop(0)
        mid = msg.get('id', '')
        if mid in visited or depth > $MAX_DEPTH:
            continue
        visited.add(mid)
        thread['messages'].append({'msg': msg, 'depth': depth})
        thread['participants'].add(msg.get('from', ''))
        thread['participants'].add(msg.get('to', ''))
        thread['depth'] = max(thread['depth'], depth)
        thread['count'] += 1
        ts = msg.get('ts', '')
        if ts > thread['last_activity']:
            thread['last_activity'] = ts

        # Add children
        for child in children.get(mid, []):
            queue.append((child, depth + 1))

    # Sort messages by timestamp
    thread['messages'].sort(key=lambda x: x['msg'].get('ts', ''))
    thread['participants'] = list(thread['participants'] - {''})
    threads.append(thread)

# Sort threads by last activity (newest first)
threads.sort(key=lambda t: t['last_activity'], reverse=True)

print(json.dumps({'threads': threads}, indent=2, default=str))
"
}

cmd_list() {
    local since="${1:-}"
    local result
    result=$(build_threads "$since")

    python3 -c "
import json, sys

data = json.loads('''$(echo "$result" | sed "s/'/\\\\'/g")''')
threads = data.get('threads', [])

if not threads:
    print('No active threads found.')
    sys.exit(0)

print(f'📧 {len(threads)} thread(s) found:\n')
for i, t in enumerate(threads, 1):
    root = t['root']
    topic = root.get('topic', 'general')
    fr = root.get('from', '?')
    to = root.get('to', '?')
    text = str(root.get('payload', {}).get('text', ''))[:60]
    participants = ', '.join(t['participants'][:4])
    tid = t['id'][:8]

    print(f'  [{tid}] {topic} — {fr}→{to}: {text}')
    print(f'          {t[\"count\"]} msgs, depth {t[\"depth\"]}, participants: {participants}')
    print(f'          Last: {t[\"last_activity\"]}')
    print()
"
}

cmd_show() {
    local thread_id="$1"
    local result
    result=$(build_threads)

    python3 -c "
import json, sys

data = json.loads(sys.stdin.read())
threads = data.get('threads', [])
target = '$thread_id'

found = None
for t in threads:
    if t['id'].startswith(target):
        found = t
        break

if not found:
    print(f'Thread {target} not found.')
    sys.exit(1)

root = found['root']
topic = root.get('topic', 'general')
print(f'📧 Thread: {topic} [{found[\"id\"][:8]}]')
print(f'   Participants: {\", \".join(found[\"participants\"])}')
print(f'   Messages: {found[\"count\"]}, Depth: {found[\"depth\"]}')
print(f'   Last activity: {found[\"last_activity\"]}')
print('─' * 60)

for entry in found['messages']:
    msg = entry['msg']
    depth = entry['depth']
    indent = '  ' * depth
    fr = msg.get('from', '?')
    ts = msg.get('ts', '?')[:19]
    mid = msg.get('id', '?')[:8]
    text = str(msg.get('payload', {}).get('text', ''))

    print(f'{indent}[{ts}] {fr} ({mid}):')
    for line in text.split('\\n')[:10]:
        print(f'{indent}  {line}')
    print()
" <<< "$result"
}

cmd_reply() {
    local msg_id="$1"
    local text="$2"
    local topic="${3:-thread}"

    # First, find the message to get the 'from' agent (we reply to them)
    local raw
    raw=$(fetch_messages)

    local target_agent
    target_agent=$(python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
msgs = data if isinstance(data, list) else data.get('messages', [])
target = '$msg_id'
for m in msgs:
    if m.get('id', '').startswith(target):
        # Reply goes to whoever sent the message
        fr = m.get('from', '')
        if fr == '$SELF_NAME':
            # If we sent it, reply to whoever we sent it to
            print(m.get('to', ''))
        else:
            print(fr)
        sys.exit(0)
print('')
" <<< "$raw")

    if [ -z "$target_agent" ]; then
        echo "Error: Message $msg_id not found in recent messages." >&2
        exit 1
    fi

    # Find full message ID
    local full_id
    full_id=$(python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
msgs = data if isinstance(data, list) else data.get('messages', [])
for m in msgs:
    if m.get('id', '').startswith('$msg_id'):
        print(m.get('id', ''))
        sys.exit(0)
" <<< "$raw")

    echo "Replying to $target_agent (re: $full_id)..."
    local result
    result=$(send_message "$target_agent" "$text" "$full_id" "$topic")
    echo "$result"
}

cmd_start() {
    local agent="$1"
    local text="$2"
    local topic="${3:-thread}"
    echo "Starting new thread with $agent..."
    local result
    result=$(send_message "$agent" "$text" "" "$topic")
    echo "$result"
}

# --- Main ---
usage() {
    echo "Usage: clawtalk-threads.sh <command> [args]"
    echo ""
    echo "Commands:"
    echo "  list [since]              List active threads"
    echo "  show <thread_id>          Show full thread conversation"
    echo "  reply <msg_id> \"text\"     Reply to a message (continues thread)"
    echo "  start <agent> \"text\"      Start a new thread with an agent"
    echo ""
    echo "Examples:"
    echo "  ./clawtalk-threads.sh list"
    echo "  ./clawtalk-threads.sh show a1b2c3d4"
    echo "  ./clawtalk-threads.sh reply a1b2c3d4 \"Thanks for the update!\""
    echo "  ./clawtalk-threads.sh start Motya \"Hey, about the build bug...\""
    echo ""
    echo "Environment:"
    echo "  CLAWTALK_API_KEY     Your agent API key"
    echo "  CLAWTALK_URL         API base URL (default: https://clawtalk.monkeymango.co)"
    echo "  CLAWTALK_AGENT_NAME  Your agent name (default: RealAaron)"
}

CMD="${1:-help}"
case "$CMD" in
    list)
        cmd_list "${2:-}"
        ;;
    show)
        [ -z "${2:-}" ] && { echo "Error: thread_id required"; usage; exit 1; }
        cmd_show "$2"
        ;;
    reply)
        [ -z "${2:-}" ] && { echo "Error: msg_id required"; usage; exit 1; }
        [ -z "${3:-}" ] && { echo "Error: reply text required"; usage; exit 1; }
        cmd_reply "$2" "$3" "${4:-thread}"
        ;;
    start)
        [ -z "${2:-}" ] && { echo "Error: agent name required"; usage; exit 1; }
        [ -z "${3:-}" ] && { echo "Error: message text required"; usage; exit 1; }
        cmd_start "$2" "$3" "${4:-thread}"
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        echo "Unknown command: $CMD" >&2
        usage
        exit 1
        ;;
esac
