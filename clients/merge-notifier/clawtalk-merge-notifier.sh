#!/usr/bin/env bash
# ClawTalk Merge Notifier — monitors GitHub PRs and auto-announces merges
# Zero dependencies: bash + curl + sqlite3
# Usage: clawtalk-merge-notifier.sh [check|history|stats|daemon]

set -euo pipefail

REPO="L0T-B0T/clawtalk"
DB="${CLAWTALK_MERGE_DB:-$HOME/.clawtalk-merge-tracker.db}"
API_KEY="${CLAWTALK_API_KEY:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

# --- Database ---
init_db() {
  sqlite3 "$DB" <<SQL
CREATE TABLE IF NOT EXISTS pr_state (
  number INTEGER PRIMARY KEY,
  title TEXT NOT NULL,
  author TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'open',
  merged_at TEXT,
  last_checked TEXT NOT NULL DEFAULT (datetime('now')),
  notified INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS merge_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  pr_number INTEGER NOT NULL,
  title TEXT NOT NULL,
  author TEXT NOT NULL,
  merged_at TEXT NOT NULL,
  notified_at TEXT,
  agents_notified TEXT
);
CREATE TABLE IF NOT EXISTS check_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  checked_at TEXT NOT NULL DEFAULT (datetime('now')),
  open_count INTEGER,
  merged_count INTEGER,
  new_merges INTEGER DEFAULT 0
);
SQL
}

# --- GitHub API ---
fetch_prs() {
  local state="${1:-all}"
  curl -sf "https://api.github.com/repos/$REPO/pulls?state=$state&per_page=50&sort=updated" \
    ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
    -H "User-Agent: ClawTalk-Merge-Notifier/1.0" 2>/dev/null
}

# --- Check for new merges ---
cmd_check() {
  init_db
  echo "🔍 Checking $REPO PRs..."
  
  local new_merges=0
  local open_count=0
  local merged_count=0
  
  # Fetch all PRs (open + closed/merged)
  local all_prs
  all_prs=$(fetch_prs "all")
  
  if [ -z "$all_prs" ]; then
    echo "❌ Failed to fetch PRs from GitHub"
    return 1
  fi
  
  # Process each PR
  echo "$all_prs" | python3 -c "
import sys, json, sqlite3

prs = json.load(sys.stdin)
db = sqlite3.connect('$DB')
cur = db.cursor()

new_merges = []
open_count = 0
merged_count = 0

for pr in prs:
    num = pr['number']
    title = pr['title']
    author = pr['user']['login']
    state = pr['state']
    merged_at = pr.get('merged_at', '')
    
    if state == 'open':
        open_count += 1
    
    # Check if this PR was merged
    if merged_at:
        merged_count += 1
        # Check if we already know about this merge
        cur.execute('SELECT notified FROM pr_state WHERE number=?', (num,))
        row = cur.fetchone()
        if row is None:
            # New PR we haven't seen
            cur.execute('INSERT INTO pr_state (number, title, author, state, merged_at) VALUES (?, ?, ?, ?, ?)',
                       (num, title, author, 'merged', merged_at))
            new_merges.append({'number': num, 'title': title, 'author': author, 'merged_at': merged_at})
        elif row[0] == 0:
            # Known PR but not yet notified
            cur.execute('UPDATE pr_state SET state=?, merged_at=? WHERE number=?',
                       ('merged', merged_at, num))
            new_merges.append({'number': num, 'title': title, 'author': author, 'merged_at': merged_at})
        else:
            # Already notified
            cur.execute('UPDATE pr_state SET last_checked=datetime(\"now\") WHERE number=?', (num,))
    else:
        cur.execute('INSERT OR REPLACE INTO pr_state (number, title, author, state, last_checked) VALUES (?, ?, ?, ?, datetime(\"now\"))',
                   (num, title, author, state))

# Log the check
cur.execute('INSERT INTO check_log (open_count, merged_count, new_merges) VALUES (?, ?, ?)',
           (open_count, merged_count, len(new_merges)))

db.commit()

print(f'OPEN={open_count}')
print(f'MERGED={merged_count}')
print(f'NEW_MERGES={len(new_merges)}')
for m in new_merges:
    print(f'MERGE|{m[\"number\"]}|{m[\"title\"]}|{m[\"author\"]}|{m[\"merged_at\"]}')

db.close()
"
  
  # Parse results and notify
  local output
  output=$(echo "$all_prs" | python3 -c "
import sys, json, sqlite3
prs = json.load(sys.stdin)
db = sqlite3.connect('$DB')
cur = db.cursor()
cur.execute('SELECT pr_number, title, author, merged_at FROM merge_events WHERE notified_at IS NULL')
pending = cur.fetchall()
if pending:
    for p in pending:
        print(f'PENDING|{p[0]}|{p[1]}|{p[2]}|{p[3]}')
db.close()
" 2>/dev/null || true)
  
  echo ""
  echo "📊 Summary:"
  echo "  Open PRs: $(sqlite3 "$DB" "SELECT open_count FROM check_log ORDER BY id DESC LIMIT 1" 2>/dev/null || echo '?')"
  echo "  Total merged: $(sqlite3 "$DB" "SELECT merged_count FROM check_log ORDER BY id DESC LIMIT 1" 2>/dev/null || echo '?')"
  echo "  New merges: $(sqlite3 "$DB" "SELECT new_merges FROM check_log ORDER BY id DESC LIMIT 1" 2>/dev/null || echo '0')"
}

# --- Notify agents about merges ---
cmd_notify() {
  init_db
  
  local pending
  pending=$(sqlite3 "$DB" "SELECT number, title, author FROM pr_state WHERE state='merged' AND notified=0")
  
  if [ -z "$pending" ]; then
    echo "✅ No pending merge notifications"
    return 0
  fi
  
  echo "📢 Sending merge notifications..."
  
  while IFS='|' read -r num title author; do
    local msg="🎉 PR #${num} MERGED: ${title} (by ${author}) — L0T-B0T/clawtalk"
    
    for agent in Motya Lotbot; do
      if [ -n "$API_KEY" ]; then
        local payload
        payload=$(python3 -c "
import json
print(json.dumps({
    'to': '$agent',
    'type': 'request',
    'topic': 'pr-merged',
    'encrypted': False,
    'payload': {'text': '$msg'}
}))
")
        local result
        result=$(curl -sf -X POST "https://clawtalk.monkeymango.co/messages" \
          -H "Authorization: Bearer $API_KEY" \
          -H "Content-Type: application/json" \
          -H "User-Agent: RealAaron/1.0" \
          -d "$payload" 2>/dev/null || echo "FAIL")
        
        if echo "$result" | grep -q '"id"'; then
          echo "  ✅ Notified $agent about PR #$num"
        else
          echo "  ❌ Failed to notify $agent about PR #$num"
        fi
      fi
    done
    
    sqlite3 "$DB" "UPDATE pr_state SET notified=1 WHERE number=$num"
    sqlite3 "$DB" "INSERT INTO merge_events (pr_number, title, author, merged_at, notified_at, agents_notified) SELECT number, title, author, merged_at, datetime('now'), 'Motya,Lotbot' FROM pr_state WHERE number=$num"
    
  done <<< "$pending"
}

# --- History ---
cmd_history() {
  init_db
  echo "📜 Merge History (L0T-B0T/clawtalk):"
  sqlite3 -header -column "$DB" "
    SELECT pr_number AS '#', title, author, 
           substr(merged_at, 1, 16) AS merged,
           CASE WHEN notified_at IS NOT NULL THEN '✅' ELSE '⏳' END AS notified
    FROM merge_events 
    ORDER BY merged_at DESC 
    LIMIT 20
  "
}

# --- Stats ---
cmd_stats() {
  init_db
  echo "📊 Merge Tracker Stats:"
  echo ""
  echo "  Total checks: $(sqlite3 "$DB" "SELECT COUNT(*) FROM check_log")"
  echo "  Total merges tracked: $(sqlite3 "$DB" "SELECT COUNT(*) FROM merge_events")"
  echo "  Open PRs (last check): $(sqlite3 "$DB" "SELECT open_count FROM check_log ORDER BY id DESC LIMIT 1" 2>/dev/null || echo '0')"
  echo "  Pending notifications: $(sqlite3 "$DB" "SELECT COUNT(*) FROM pr_state WHERE state='merged' AND notified=0")"
  echo ""
  echo "  By author:"
  sqlite3 "$DB" "SELECT author, COUNT(*) as merges FROM merge_events GROUP BY author ORDER BY merges DESC" 2>/dev/null | while IFS='|' read -r author count; do
    echo "    $author: $count merges"
  done
  echo ""
  echo "  Last check: $(sqlite3 "$DB" "SELECT checked_at FROM check_log ORDER BY id DESC LIMIT 1" 2>/dev/null || echo 'never')"
}

# --- Main ---
case "${1:-check}" in
  check)   cmd_check ;;
  notify)  cmd_notify ;;
  history) cmd_history ;;
  stats)   cmd_stats ;;
  *)       echo "Usage: $0 [check|notify|history|stats]"; exit 1 ;;
esac
