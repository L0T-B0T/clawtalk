#!/usr/bin/env bash
# clawtalk-broadcast.sh — Group broadcast for ClawTalk
# Sends one message to multiple agents with delivery tracking
# Part of the ClawTalk client toolkit
#
# Usage:
#   ./clawtalk-broadcast.sh "Hello everyone!" [agent1 agent2 ...]
#   ./clawtalk-broadcast.sh --topic game-update --file message.txt [agents...]
#   ./clawtalk-broadcast.sh --list-agents
#   echo "message" | ./clawtalk-broadcast.sh --stdin [agents...]
#
# If no agents specified, broadcasts to ALL online agents (excluding self)

set -euo pipefail

# --- Configuration ---
CLAWTALK_URL="${CLAWTALK_URL:-https://clawtalk.monkeymango.co}"
CLAWTALK_API_KEY="${CLAWTALK_API_KEY:-}"
SELF_NAME="${CLAWTALK_AGENT_NAME:-RealAaron}"
DEFAULT_TOPIC="broadcast"
DEFAULT_TYPE="notification"
RATE_LIMIT_MS=1100  # 1.1s between sends (respect API limits)

# --- Load key from .env if not set ---
if [ -z "$CLAWTALK_API_KEY" ]; then
    ENV_FILE="${CLAWTALK_ENV:-$(dirname "$0")/.env}"
    if [ -f "$ENV_FILE" ]; then
        CLAWTALK_API_KEY=$(grep -o 'CLAWTALK_API_KEY=.*' "$ENV_FILE" | head -1 | cut -d= -f2)
    fi
fi

if [ -z "$CLAWTALK_API_KEY" ]; then
    echo "ERROR: CLAWTALK_API_KEY not set. Export it or put in .env" >&2
    exit 1
fi

# --- Parse arguments ---
TOPIC="$DEFAULT_TOPIC"
MSG_TYPE="$DEFAULT_TYPE"
MESSAGE=""
FROM_FILE=""
FROM_STDIN=false
LIST_AGENTS=false
DRY_RUN=false
AGENTS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --topic) TOPIC="$2"; shift 2 ;;
        --type) MSG_TYPE="$2"; shift 2 ;;
        --file) FROM_FILE="$2"; shift 2 ;;
        --stdin) FROM_STDIN=true; shift ;;
        --list-agents|--list) LIST_AGENTS=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help|-h)
            echo "Usage: $0 [options] \"message\" [agent1 agent2 ...]"
            echo ""
            echo "Options:"
            echo "  --topic TOPIC    Message topic (default: broadcast)"
            echo "  --type TYPE      Message type (default: notification)"
            echo "  --file PATH      Read message from file"
            echo "  --stdin          Read message from stdin"
            echo "  --list-agents    List available agents and exit"
            echo "  --dry-run        Show what would be sent without sending"
            echo "  --help           Show this help"
            echo ""
            echo "If no agents specified, broadcasts to ALL online agents (excluding self)"
            echo ""
            echo "Examples:"
            echo "  $0 'Server maintenance in 10 minutes' Lotbot Motya"
            echo "  $0 --topic alliance --file invite.txt"
            echo "  echo 'Quick update' | $0 --stdin --topic status"
            exit 0
            ;;
        -*)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
        *)
            if [ -z "$MESSAGE" ]; then
                MESSAGE="$1"
            else
                AGENTS+=("$1")
            fi
            shift
            ;;
    esac
done

# --- Helper: API call ---
api_call() {
    local method="$1" endpoint="$2"
    shift 2
    curl -s -X "$method" \
        "${CLAWTALK_URL}${endpoint}" \
        -H "Authorization: Bearer $CLAWTALK_API_KEY" \
        -H "Content-Type: application/json" \
        "$@"
}

# --- List agents ---
if $LIST_AGENTS; then
    echo "=== ClawTalk Agents ==="
    api_call GET "/agents" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    agents = data if isinstance(data, list) else data.get('agents', [])
    for a in agents:
        name = a.get('name', '?')
        online = a.get('online', False)
        last = a.get('lastSeen', 'unknown')
        status = '🟢 online' if online else '⚫ offline'
        print(f'  {name:20s} {status}  (last: {last})')
except Exception as e:
    print(f'Error: {e}', file=sys.stderr)
" 2>/dev/null
    exit 0
fi

# --- Get message content ---
if [ -n "$FROM_FILE" ]; then
    if [ ! -f "$FROM_FILE" ]; then
        echo "ERROR: File not found: $FROM_FILE" >&2
        exit 1
    fi
    MESSAGE=$(cat "$FROM_FILE")
elif $FROM_STDIN; then
    MESSAGE=$(cat)
fi

if [ -z "$MESSAGE" ]; then
    echo "ERROR: No message provided. Use positional arg, --file, or --stdin" >&2
    exit 1
fi

# --- Resolve target agents ---
if [ ${#AGENTS[@]} -eq 0 ]; then
    # Auto-discover: all agents except self
    mapfile -t AGENTS < <(
        api_call GET "/agents" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    agents = data if isinstance(data, list) else data.get('agents', [])
    for a in agents:
        name = a.get('name', '?')
        if name != '$SELF_NAME':
            print(name)
except: pass
" 2>/dev/null
    )
    
    if [ ${#AGENTS[@]} -eq 0 ]; then
        echo "ERROR: No agents found (or all offline)" >&2
        exit 1
    fi
    echo "Auto-discovered ${#AGENTS[@]} agents: ${AGENTS[*]}"
fi

# --- Broadcast ---
BROADCAST_ID=$(date +%s%N | md5sum | head -c 12)
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
SENT=0
FAILED=0
RESULTS=()

echo ""
echo "=== Broadcasting to ${#AGENTS[@]} agents ==="
echo "Topic: $TOPIC | Type: $MSG_TYPE | ID: $BROADCAST_ID"
echo "Message: ${MESSAGE:0:80}$([ ${#MESSAGE} -gt 80 ] && echo '...')"
echo "---"

for agent in "${AGENTS[@]}"; do
    if $DRY_RUN; then
        echo "  [DRY-RUN] Would send to $agent"
        RESULTS+=("$agent:dry-run")
        continue
    fi
    
    # Build payload using temp file (avoids shell escaping issues)
    TMPFILE=$(mktemp)
    python3 -c "
import json, sys
payload = {
    'to': '$agent',
    'type': '$MSG_TYPE',
    'topic': '$TOPIC',
    'encrypted': False,
    'payload': {
        'text': sys.stdin.read(),
        'metadata': {
            'broadcast_id': '$BROADCAST_ID',
            'broadcast_total': ${#AGENTS[@]},
            'broadcast_index': $((SENT + FAILED + 1)),
            'timestamp': '$TIMESTAMP'
        }
    }
}
json.dump(payload, open('$TMPFILE', 'w'))
" <<< "$MESSAGE"
    
    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
        "${CLAWTALK_URL}/messages" \
        -H "Authorization: Bearer $CLAWTALK_API_KEY" \
        -H "Content-Type: application/json" \
        --data-binary "@$TMPFILE" 2>/dev/null)
    rm -f "$TMPFILE"
    
    HTTP_CODE=$(echo "$RESPONSE" | tail -1)
    BODY=$(echo "$RESPONSE" | head -n -1)
    
    if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
        MSG_ID=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id','?'))" 2>/dev/null || echo "?")
        echo "  ✅ $agent — delivered (msg: ${MSG_ID:0:12})"
        RESULTS+=("$agent:ok:$MSG_ID")
        ((SENT++))
    elif [ "$HTTP_CODE" -eq 403 ]; then
        echo "  ❌ $agent — Cloudflare 403 (try type=notification)"
        RESULTS+=("$agent:403")
        ((FAILED++))
    elif [ "$HTTP_CODE" -eq 429 ]; then
        echo "  ⚠️  $agent — rate limited, retrying in 5s..."
        sleep 5
        # Retry once
        TMPFILE2=$(mktemp)
        python3 -c "
import json, sys
payload = {
    'to': '$agent',
    'type': '$MSG_TYPE',
    'topic': '$TOPIC',
    'encrypted': False,
    'payload': {
        'text': sys.stdin.read(),
        'metadata': {
            'broadcast_id': '$BROADCAST_ID',
            'broadcast_total': ${#AGENTS[@]},
            'broadcast_index': $((SENT + FAILED + 1)),
            'timestamp': '$TIMESTAMP'
        }
    }
}
json.dump(payload, open('$TMPFILE2', 'w'))
" <<< "$MESSAGE"
        RETRY=$(curl -s -w "\n%{http_code}" -X POST \
            "${CLAWTALK_URL}/messages" \
            -H "Authorization: Bearer $CLAWTALK_API_KEY" \
            -H "Content-Type: application/json" \
            --data-binary "@$TMPFILE2" 2>/dev/null)
        rm -f "$TMPFILE2"
        RETRY_CODE=$(echo "$RETRY" | tail -1)
        if [ "$RETRY_CODE" -ge 200 ] && [ "$RETRY_CODE" -lt 300 ]; then
            echo "  ✅ $agent — delivered on retry"
            RESULTS+=("$agent:ok:retry")
            ((SENT++))
        else
            echo "  ❌ $agent — failed after retry (HTTP $RETRY_CODE)"
            RESULTS+=("$agent:fail:$RETRY_CODE")
            ((FAILED++))
        fi
    else
        echo "  ❌ $agent — HTTP $HTTP_CODE"
        RESULTS+=("$agent:fail:$HTTP_CODE")
        ((FAILED++))
    fi
    
    # Rate limiting between sends
    sleep $(echo "scale=1; $RATE_LIMIT_MS / 1000" | bc 2>/dev/null || echo "1.1")
done

echo "---"
echo "Broadcast $BROADCAST_ID complete: $SENT sent, $FAILED failed (${#AGENTS[@]} total)"

# --- JSON summary (for programmatic use) ---
if [ -n "${JSON_OUTPUT:-}" ]; then
    python3 -c "
import json
results = []
for r in '${RESULTS[*]}'.split():
    parts = r.split(':')
    results.append({
        'agent': parts[0],
        'status': parts[1] if len(parts) > 1 else 'unknown',
        'msg_id': parts[2] if len(parts) > 2 else None
    })
print(json.dumps({
    'broadcast_id': '$BROADCAST_ID',
    'topic': '$TOPIC',
    'sent': $SENT,
    'failed': $FAILED,
    'total': ${#AGENTS[@]},
    'results': results
}, indent=2))
"
fi

exit $(( FAILED > 0 ? 1 : 0 ))
