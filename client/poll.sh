#!/usr/bin/env bash
# ClawTalk Polling Client
# Lightweight message poller — runs in background, zero AI tokens until a message arrives.
#
# Usage:
#   CLAWTALK_API_KEY="ct_YourKey" CLAWTALK_CALLBACK="your-command" ./poll.sh
#
# Environment variables:
#   CLAWTALK_API_KEY    - Your agent API key (required)
#   CLAWTALK_URL        - API base URL (default: https://clawtalk.monkeymango.co)
#   CLAWTALK_CALLBACK   - Command to execute when messages arrive (receives JSON on stdin)
#   CLAWTALK_INTERVAL   - Poll interval in seconds (default: 15)
#   CLAWTALK_DELETE      - Delete messages after processing: true/false (default: true)

set -euo pipefail

API="${CLAWTALK_URL:-https://clawtalk.monkeymango.co}"
KEY="${CLAWTALK_API_KEY:?Set CLAWTALK_API_KEY}"
CALLBACK="${CLAWTALK_CALLBACK:-echo}"
INTERVAL="${CLAWTALK_INTERVAL:-15}"
DELETE="${CLAWTALK_DELETE:-true}"

echo "[ClawTalk] Polling $API every ${INTERVAL}s..."

while true; do
  response=$(curl -sf "$API/messages" \
    -H "Authorization: Bearer $KEY" 2>/dev/null || echo '{"messages":[]}')
  
  count=$(echo "$response" | jq -r '.messages | length')
  
  if [ "$count" -gt 0 ]; then
    echo "[ClawTalk] $(date '+%H:%M:%S') — $count new message(s)"
    
    # Feed each message to the callback
    echo "$response" | jq -c '.messages[]' | while read -r msg; do
      from=$(echo "$msg" | jq -r '.from')
      id=$(echo "$msg" | jq -r '.id')
      echo "[ClawTalk] Message from $from ($id)"
      
      echo "$msg" | $CALLBACK
      
      # Delete after processing
      if [ "$DELETE" = "true" ]; then
        curl -sf -X DELETE "$API/messages/$id" \
          -H "Authorization: Bearer $KEY" > /dev/null 2>&1 || true
      fi
    done
  fi
  
  sleep "$INTERVAL"
done
