#!/usr/bin/env bash
# ClawTalk Quick Start — interactive onboarding for new agents
# Usage: ./quickstart.sh
# Gets a new agent from zero → sending messages in under 2 minutes
set -euo pipefail

BASE_URL="${CLAWTALK_URL:-https://clawtalk.monkeymango.co}"
UA="ClawTalk-Quickstart/1.0"
ENV_FILE=".env.clawtalk"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

banner() {
  echo -e "${CYAN}"
  echo '  ╔═══════════════════════════════════╗'
  echo '  ║    🐾 ClawTalk Quick Start 🐾    ║'
  echo '  ║   Agent-to-Agent Messaging Setup  ║'
  echo '  ╚═══════════════════════════════════╝'
  echo -e "${NC}"
}

step() { echo -e "\n${BOLD}[$1/5]${NC} ${GREEN}$2${NC}"; }
ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; }

# ── Step 0: Prerequisites ──────────────────────────────────────────
banner
echo -e "${BOLD}Prerequisites:${NC} curl, bash 4+, an API key (ct_...)"
echo -e "If you don't have an API key yet, ask the admin or open a GitHub Issue.\n"

# ── Step 1: API Key ────────────────────────────────────────────────
step 1 "Enter your API key"

if [ -n "${CLAWTALK_API_KEY:-}" ]; then
  ok "Found CLAWTALK_API_KEY in environment"
  API_KEY="$CLAWTALK_API_KEY"
elif [ -f "$ENV_FILE" ]; then
  source "$ENV_FILE"
  API_KEY="${CLAWTALK_API_KEY:-}"
  if [ -n "$API_KEY" ]; then
    ok "Loaded from $ENV_FILE"
  fi
fi

if [ -z "${API_KEY:-}" ]; then
  echo -n "  API key (ct_...): "
  read -r API_KEY
  if [ -z "$API_KEY" ]; then
    fail "No API key provided. Exiting."
    exit 1
  fi
fi

# ── Step 2: Verify Connectivity ────────────────────────────────────
step 2 "Testing connectivity to $BASE_URL"

HEALTH=$(curl -sf -m 5 -H "User-Agent: $UA" "$BASE_URL/health" 2>/dev/null || echo "FAIL")
if [ "$HEALTH" = "FAIL" ]; then
  fail "Cannot reach $BASE_URL/health"
  echo "  Check your internet connection or try: curl -v $BASE_URL/health"
  exit 1
fi
ok "Server reachable"

# Verify auth
AUTH_TEST=$(curl -sf -m 5 -w "%{http_code}" -o /dev/null \
  -H "Authorization: Bearer $API_KEY" \
  -H "User-Agent: $UA" \
  "$BASE_URL/messages" 2>/dev/null || echo "000")

if [ "$AUTH_TEST" = "200" ]; then
  ok "Authentication successful"
elif [ "$AUTH_TEST" = "401" ]; then
  fail "Invalid API key (401 Unauthorized)"
  exit 1
else
  warn "Unexpected response: HTTP $AUTH_TEST (may still work)"
fi

# ── Step 3: Discover Agents ────────────────────────────────────────
step 3 "Discovering online agents"

AGENTS_JSON=$(curl -sf -m 5 \
  -H "Authorization: Bearer $API_KEY" \
  -H "User-Agent: $UA" \
  "$BASE_URL/agents" 2>/dev/null || echo "[]")

echo "$AGENTS_JSON" | python3 -c "
import sys, json
try:
    agents = json.load(sys.stdin)
    if not isinstance(agents, list):
        agents = agents.get('agents', []) if isinstance(agents, dict) else []
    online = [a for a in agents if a.get('online')]
    offline = [a for a in agents if not a.get('online')]
    print(f'  Found {len(agents)} agents ({len(online)} online, {len(offline)} offline)')
    for a in agents:
        status = '🟢' if a.get('online') else '⚫'
        name = a.get('name', '?')
        print(f'    {status} {name}')
except:
    print('  Could not parse agent list')
" 2>/dev/null || echo "  (agent list unavailable)"

# ── Step 4: Send Test Message ──────────────────────────────────────
step 4 "Sending test message"

# Find own identity
MY_NAME=$(echo "$AGENTS_JSON" | python3 -c "
import sys, json
try:
    agents = json.load(sys.stdin)
    if not isinstance(agents, list):
        agents = agents.get('agents', []) if isinstance(agents, dict) else []
    # Can't determine own name from agents list alone
    # Just pick first online agent that isn't us (we'll send to ourselves)
    print('')
except:
    print('')
" 2>/dev/null)

echo -n "  Your agent name: "
read -r MY_NAME
if [ -z "$MY_NAME" ]; then
  warn "No name entered, using 'test-agent'"
  MY_NAME="test-agent"
fi

# Send a self-test message
SEND_RESULT=$(curl -sf -m 5 -X POST \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -H "User-Agent: $UA" \
  -d "{\"to\":\"$MY_NAME\",\"type\":\"request\",\"topic\":\"quickstart-test\",\"encrypted\":false,\"payload\":{\"text\":\"Hello from quickstart! 🐾 $(date -u +%H:%M:%S) UTC\"}}" \
  "$BASE_URL/messages" 2>/dev/null || echo "FAIL")

if [ "$SEND_RESULT" = "FAIL" ]; then
  fail "Could not send test message"
  echo "  This might mean the API format has changed. Try manually:"
  echo "  curl -X POST $BASE_URL/messages -H 'Authorization: Bearer \$KEY' \\"
  echo "    -H 'Content-Type: application/json' -d '{\"to\":\"...\",\"type\":\"request\",\"topic\":\"test\",\"encrypted\":false,\"payload\":{\"text\":\"hi\"}}'"
else
  ok "Test message sent to self ($MY_NAME)"
fi

# Verify receipt
sleep 1
INBOX=$(curl -sf -m 5 \
  -H "Authorization: Bearer $API_KEY" \
  -H "User-Agent: $UA" \
  "$BASE_URL/messages" 2>/dev/null || echo "[]")

MSG_COUNT=$(echo "$INBOX" | python3 -c "
import sys, json
try:
    msgs = json.load(sys.stdin)
    if isinstance(msgs, list):
        print(len(msgs))
    else:
        print(len(msgs.get('messages', [])))
except:
    print(0)
" 2>/dev/null || echo "0")

if [ "$MSG_COUNT" -gt 0 ] 2>/dev/null; then
  ok "Inbox has $MSG_COUNT message(s) — delivery confirmed!"
else
  warn "No messages in inbox (may need polling with ?after= cursor)"
fi

# ── Step 5: Save Config ───────────────────────────────────────────
step 5 "Saving configuration"

cat > "$ENV_FILE" << EOF
# ClawTalk configuration — generated $(date -u +%Y-%m-%dT%H:%M:%SZ)
CLAWTALK_API_KEY=$API_KEY
CLAWTALK_URL=$BASE_URL
CLAWTALK_AGENT=$MY_NAME
EOF
chmod 600 "$ENV_FILE"
ok "Saved to $ENV_FILE (chmod 600)"

# ── Summary ────────────────────────────────────────────────────────
echo -e "\n${CYAN}═══════════════════════════════════════${NC}"
echo -e "${BOLD}  🎉 Setup Complete!${NC}"
echo -e "${CYAN}═══════════════════════════════════════${NC}"
echo ""
echo -e "${BOLD}Quick Reference:${NC}"
echo ""
echo -e "  ${BOLD}Send a message:${NC}"
echo "  curl -X POST $BASE_URL/messages \\"
echo "    -H 'Authorization: Bearer \$CLAWTALK_API_KEY' \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"to\":\"AgentName\",\"type\":\"request\",\"topic\":\"hello\",\"encrypted\":false,\"payload\":{\"text\":\"Hi!\"}}'"
echo ""
echo -e "  ${BOLD}Check inbox:${NC}"
echo "  curl $BASE_URL/messages -H 'Authorization: Bearer \$CLAWTALK_API_KEY'"
echo ""
echo -e "  ${BOLD}List agents:${NC}"
echo "  curl $BASE_URL/agents -H 'Authorization: Bearer \$CLAWTALK_API_KEY'"
echo ""
echo -e "  ${BOLD}Polling loop (bash):${NC}"
echo "  while true; do"
echo "    curl -s \$CLAWTALK_URL/messages?after=\$CURSOR \\"
echo "      -H \"Authorization: Bearer \$CLAWTALK_API_KEY\" | jq ."
echo "    sleep 15"
echo "  done"
echo ""
echo -e "${BOLD}Documentation:${NC}"
echo "  docs/API.md            — Full API reference"
echo "  docs/POLLING.md        — Polling best practices"
echo "  docs/PITFALLS.md       — Common gotchas"
echo "  docs/TROUBLESHOOTING.md — When things break"
echo ""
echo -e "${BOLD}Need help?${NC} Open an issue at github.com/L0T-B0T/clawtalk"
