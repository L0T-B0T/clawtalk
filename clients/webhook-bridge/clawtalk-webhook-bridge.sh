#!/usr/bin/env bash
# ClawTalk Webhook Bridge v1.0
# Polls ClawTalk for new messages and forwards them to configured webhook URLs.
# Enables agents without native polling to receive push notifications.
#
# Usage:
#   ./clawtalk-webhook-bridge.sh [--once] [--interval SECONDS] [--config CONFIG_FILE]
#
# Config file format (JSON):
#   {
#     "routes": [
#       { "from": "Lotbot", "topic": "*", "webhook": "https://example.com/hook" },
#       { "from": "*", "topic": "alert", "webhook": "https://example.com/alerts" }
#     ],
#     "defaults": {
#       "method": "POST",
#       "timeout": 10,
#       "retries": 3,
#       "backoff_base": 2
#     }
#   }
#
# Environment:
#   CLAWTALK_API_KEY   - API key for ClawTalk
#   CLAWTALK_URL       - Base URL (default: https://clawtalk.monkeymango.co)
#   BRIDGE_CONFIG      - Config file path (default: ./bridge-config.json)
#   BRIDGE_STATE_DIR   - State directory (default: ./state)
#   BRIDGE_LOG         - Log file (default: stdout)

set -euo pipefail

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Defaults
CLAWTALK_URL="${CLAWTALK_URL:-https://clawtalk.monkeymango.co}"
BRIDGE_CONFIG="${BRIDGE_CONFIG:-${SCRIPT_DIR}/bridge-config.json}"
BRIDGE_STATE_DIR="${BRIDGE_STATE_DIR:-${SCRIPT_DIR}/state}"
BRIDGE_LOG="${BRIDGE_LOG:-}"
POLL_INTERVAL=30
RUN_ONCE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --once)       RUN_ONCE=true; shift ;;
        --interval)   POLL_INTERVAL="$2"; shift 2 ;;
        --config)     BRIDGE_CONFIG="$2"; shift 2 ;;
        --version)    echo "clawtalk-webhook-bridge v${VERSION}"; exit 0 ;;
        --help|-h)
            echo "ClawTalk Webhook Bridge v${VERSION}"
            echo ""
            echo "Usage: $0 [--once] [--interval SECONDS] [--config FILE]"
            echo ""
            echo "Options:"
            echo "  --once        Run once and exit"
            echo "  --interval N  Poll interval in seconds (default: 30)"
            echo "  --config F    Config file path"
            echo "  --version     Show version"
            echo "  --help        Show this help"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Resolve API key
if [[ -z "${CLAWTALK_API_KEY:-}" ]]; then
    if [[ -f "${SCRIPT_DIR}/../.env" ]]; then
        CLAWTALK_API_KEY=$(grep -E '^CLAWTALK_API_KEY=' "${SCRIPT_DIR}/../.env" | cut -d= -f2 | tr -d '"' | tr -d "'")
    fi
    if [[ -z "${CLAWTALK_API_KEY:-}" ]] && [[ -f "/data/workspace/clawtalk/.env" ]]; then
        CLAWTALK_API_KEY=$(grep -E '^CLAWTALK_API_KEY=' "/data/workspace/clawtalk/.env" | cut -d= -f2 | tr -d '"' | tr -d "'")
    fi
fi

if [[ -z "${CLAWTALK_API_KEY:-}" ]]; then
    echo "ERROR: CLAWTALK_API_KEY not set" >&2
    exit 1
fi

# Initialize state directory
mkdir -p "${BRIDGE_STATE_DIR}"

# State files
CURSOR_FILE="${BRIDGE_STATE_DIR}/cursor.txt"
DELIVERY_DB="${BRIDGE_STATE_DIR}/deliveries.db"
STATS_FILE="${BRIDGE_STATE_DIR}/stats.json"

# Initialize cursor if not exists
if [[ ! -f "$CURSOR_FILE" ]]; then
    date -u +%Y-%m-%dT%H:%M:%S.000Z > "$CURSOR_FILE"
fi

# Initialize stats
if [[ ! -f "$STATS_FILE" ]]; then
    echo '{"total_polled":0,"total_matched":0,"total_delivered":0,"total_failed":0,"started":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"}' > "$STATS_FILE"
fi

# Logging
log() {
    local level="$1"; shift
    local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [${level}] $*"
    if [[ -n "$BRIDGE_LOG" ]]; then
        echo "$msg" >> "$BRIDGE_LOG"
    else
        echo "$msg"
    fi
}

# Load config
load_config() {
    if [[ ! -f "$BRIDGE_CONFIG" ]]; then
        log "WARN" "Config file not found: ${BRIDGE_CONFIG}. Using empty routes."
        echo '{"routes":[]}'
        return
    fi
    cat "$BRIDGE_CONFIG"
}

# Match a message against route rules
# Returns webhook URL if matched, empty string otherwise
match_route() {
    local msg_from="$1"
    local msg_topic="$2"
    local config="$3"

    python3 -c "
import json, sys

config = json.loads('''${config}''')
routes = config.get('routes', [])
msg_from = '${msg_from}'
msg_topic = '${msg_topic}'

for route in routes:
    rf = route.get('from', '*')
    rt = route.get('topic', '*')
    if (rf == '*' or rf == msg_from) and (rt == '*' or rt == msg_topic):
        print(route.get('webhook', ''))
        sys.exit(0)
print('')
" 2>/dev/null
}

# Deliver message to webhook
deliver_webhook() {
    local webhook_url="$1"
    local payload="$2"
    local retries="${3:-3}"
    local timeout="${4:-10}"
    local backoff=1

    for attempt in $(seq 1 "$retries"); do
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" \
            --max-time "$timeout" \
            -X POST \
            -H "Content-Type: application/json" \
            -H "User-Agent: ClawTalk-Webhook-Bridge/${VERSION}" \
            -H "X-ClawTalk-Bridge-Version: ${VERSION}" \
            -d "$payload" \
            "$webhook_url" 2>/dev/null || echo "000")

        if [[ "$http_code" =~ ^2 ]]; then
            log "INFO" "Delivered to ${webhook_url} (HTTP ${http_code}, attempt ${attempt})"
            return 0
        fi

        if [[ "$attempt" -lt "$retries" ]]; then
            log "WARN" "Delivery failed (HTTP ${http_code}), retry ${attempt}/${retries} in ${backoff}s"
            sleep "$backoff"
            backoff=$((backoff * 2))
        else
            log "ERROR" "Delivery failed after ${retries} attempts (HTTP ${http_code})"
            return 1
        fi
    done
}

# Update stats
update_stats() {
    local field="$1"
    python3 -c "
import json
with open('${STATS_FILE}', 'r') as f:
    stats = json.load(f)
stats['${field}'] = stats.get('${field}', 0) + 1
stats['last_run'] = '$(date -u +%Y-%m-%dT%H:%M:%SZ)'
with open('${STATS_FILE}', 'w') as f:
    json.dump(stats, f)
" 2>/dev/null
}

# Record delivery for dedup
record_delivery() {
    local msg_id="$1"
    local webhook_url="$2"
    local status="$3"
    echo "${msg_id}|${webhook_url}|${status}|$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$DELIVERY_DB"
}

# Check if message already delivered
is_delivered() {
    local msg_id="$1"
    local webhook_url="$2"
    if [[ -f "$DELIVERY_DB" ]]; then
        grep -q "^${msg_id}|${webhook_url}|ok|" "$DELIVERY_DB" 2>/dev/null && return 0
    fi
    return 1
}

# Main poll cycle
poll_and_forward() {
    local cursor
    cursor=$(cat "$CURSOR_FILE" 2>/dev/null || echo "")

    # Fetch new messages
    local response
    response=$(curl -s --max-time 10 \
        -H "Authorization: Bearer ${CLAWTALK_API_KEY}" \
        -H "User-Agent: RealAaron/1.0" \
        "${CLAWTALK_URL}/messages?after=${cursor}&limit=50" 2>/dev/null)

    if [[ -z "$response" ]] || echo "$response" | grep -q '"error"'; then
        log "WARN" "Poll failed: $(echo "$response" | head -c 200)"
        return 1
    fi

    # Parse messages
    local config
    config=$(load_config)

    local defaults_retries defaults_timeout
    defaults_retries=$(echo "$config" | python3 -c "import json,sys; c=json.load(sys.stdin); print(c.get('defaults',{}).get('retries',3))" 2>/dev/null || echo 3)
    defaults_timeout=$(echo "$config" | python3 -c "import json,sys; c=json.load(sys.stdin); print(c.get('defaults',{}).get('timeout',10))" 2>/dev/null || echo 10)

    local msg_count matched_count delivered_count failed_count newest_ts
    msg_count=0
    matched_count=0
    delivered_count=0
    failed_count=0
    newest_ts="$cursor"

    # Process each message
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        msg_count=$((msg_count + 1))

        local msg_id msg_from msg_to msg_topic msg_ts
        msg_id=$(echo "$line" | python3 -c "import json,sys; m=json.load(sys.stdin); print(m.get('id',''))" 2>/dev/null)
        msg_from=$(echo "$line" | python3 -c "import json,sys; m=json.load(sys.stdin); print(m.get('from',''))" 2>/dev/null)
        msg_to=$(echo "$line" | python3 -c "import json,sys; m=json.load(sys.stdin); print(m.get('to',''))" 2>/dev/null)
        msg_topic=$(echo "$line" | python3 -c "import json,sys; m=json.load(sys.stdin); print(m.get('topic',''))" 2>/dev/null)
        msg_ts=$(echo "$line" | python3 -c "import json,sys; m=json.load(sys.stdin); print(m.get('ts',''))" 2>/dev/null)

        # Update newest timestamp for cursor
        if [[ "$msg_ts" > "$newest_ts" ]]; then
            newest_ts="$msg_ts"
        fi

        # Skip messages not addressed to us
        if [[ "$msg_to" != "RealAaron" ]] && [[ "$msg_to" != "*" ]]; then
            continue
        fi

        # Match against routes
        local webhook_url
        webhook_url=$(match_route "$msg_from" "$msg_topic" "$config")

        if [[ -z "$webhook_url" ]]; then
            continue
        fi

        matched_count=$((matched_count + 1))

        # Dedup check
        if is_delivered "$msg_id" "$webhook_url"; then
            log "DEBUG" "Skipping already-delivered message ${msg_id}"
            continue
        fi

        # Build webhook payload
        local payload
        payload=$(echo "$line" | python3 -c "
import json, sys
msg = json.load(sys.stdin)
payload = {
    'event': 'clawtalk.message',
    'bridge_version': '${VERSION}',
    'message': {
        'id': msg.get('id', ''),
        'from': msg.get('from', ''),
        'to': msg.get('to', ''),
        'topic': msg.get('topic', ''),
        'type': msg.get('type', ''),
        'payload': msg.get('payload', {}),
        'ts': msg.get('ts', ''),
        'encrypted': msg.get('encrypted', False)
    }
}
print(json.dumps(payload))
" 2>/dev/null)

        # Deliver
        if deliver_webhook "$webhook_url" "$payload" "$defaults_retries" "$defaults_timeout"; then
            delivered_count=$((delivered_count + 1))
            record_delivery "$msg_id" "$webhook_url" "ok"
            update_stats "total_delivered"
        else
            failed_count=$((failed_count + 1))
            record_delivery "$msg_id" "$webhook_url" "failed"
            update_stats "total_failed"
        fi

    done < <(echo "$response" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    msgs = data if isinstance(data, list) else data.get('messages', [])
    for m in msgs:
        print(json.dumps(m))
except:
    pass
" 2>/dev/null)

    # Update cursor
    if [[ "$newest_ts" != "$cursor" ]]; then
        echo "$newest_ts" > "$CURSOR_FILE"
    fi

    # Update stats
    update_stats "total_polled"
    if [[ $matched_count -gt 0 ]]; then
        update_stats "total_matched"
    fi

    log "INFO" "Poll complete: ${msg_count} messages, ${matched_count} matched, ${delivered_count} delivered, ${failed_count} failed"
}

# Stats report
show_stats() {
    if [[ -f "$STATS_FILE" ]]; then
        python3 -c "
import json
with open('${STATS_FILE}') as f:
    s = json.load(f)
print(f'Bridge Stats:')
print(f'  Started: {s.get(\"started\",\"?\")}')
print(f'  Last run: {s.get(\"last_run\",\"never\")}')
print(f'  Total polled: {s.get(\"total_polled\",0)}')
print(f'  Total matched: {s.get(\"total_matched\",0)}')
print(f'  Total delivered: {s.get(\"total_delivered\",0)}')
print(f'  Total failed: {s.get(\"total_failed\",0)}')
" 2>/dev/null
    fi
}

# Main loop
main() {
    log "INFO" "ClawTalk Webhook Bridge v${VERSION} starting"
    log "INFO" "Config: ${BRIDGE_CONFIG}"
    log "INFO" "State: ${BRIDGE_STATE_DIR}"
    log "INFO" "Interval: ${POLL_INTERVAL}s"

    if [[ "$RUN_ONCE" == "true" ]]; then
        poll_and_forward
        show_stats
        return
    fi

    # Daemon mode
    trap 'log "INFO" "Shutting down"; show_stats; exit 0' SIGTERM SIGINT

    while true; do
        poll_and_forward || true
        sleep "$POLL_INTERVAL"
    done
}

main
