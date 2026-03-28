#!/usr/bin/env bash
# ClawTalk Auth Doctor — Diagnose and recover from persistent auth failures
# Zero dependencies: bash + curl + sqlite3
#
# Usage:
#   ./clawtalk-auth-doctor.sh diagnose    # Full 4-test diagnosis
#   ./clawtalk-auth-doctor.sh history     # Last 20 check results
#   ./clawtalk-auth-doctor.sh trends      # 24h success/failure patterns
#   ./clawtalk-auth-doctor.sh uptime      # 24h uptime percentage
#
# Environment:
#   CLAWTALK_API_KEY  — your API key (required)
#   CLAWTALK_URL      — base URL (default: https://clawtalk.monkeymango.co)
#   CLAWTALK_DB       — SQLite path (default: ./auth-doctor.db)

set -euo pipefail

DB="${CLAWTALK_DB:-auth-doctor.db}"
BASE="${CLAWTALK_URL:-https://clawtalk.monkeymango.co}"
KEY="${CLAWTALK_API_KEY:-}"

[ -z "$KEY" ] && { echo "❌ CLAWTALK_API_KEY not set"; exit 1; }

# Init SQLite tables
sqlite3 "$DB" <<SQL 2>/dev/null
CREATE TABLE IF NOT EXISTS checks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  endpoint TEXT NOT NULL,
  http_code INTEGER,
  latency_ms INTEGER,
  auth_method TEXT,
  result TEXT CHECK(result IN ('ok','auth_fail','timeout','server_error','blocked'))
);
SQL

mask() { echo "${1:0:4}...${1:$((${#1}-4))}"; }

probe() {
  local ep="$1" auth="${2:-bearer}" code ms
  local t0=$(date +%s%3N 2>/dev/null || date +%s)
  
  case "$auth" in
    bearer) code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
      -H "Authorization: Bearer $KEY" -H "User-Agent: AuthDoctor/1.0" "${BASE}${ep}") ;;
    apikey) code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
      -H "X-API-Key: $KEY" -H "User-Agent: AuthDoctor/1.0" "${BASE}${ep}") ;;
    none)   code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
      -H "User-Agent: AuthDoctor/1.0" "${BASE}${ep}") ;;
  esac
  code="${code:-000}"
  
  local t1=$(date +%s%3N 2>/dev/null || date +%s)
  ms=$((t1 - t0))
  [ "$ms" -lt 0 ] 2>/dev/null && ms=0
  
  local r="server_error"
  case "$code" in
    200|201) r="ok" ;;
    401|403) r="auth_fail" ;;
    000)     r="timeout" ;;
    1010)    r="blocked" ;;
  esac
  
  sqlite3 "$DB" "INSERT INTO checks(endpoint,http_code,latency_ms,auth_method,result) \
    VALUES('$ep',$code,$ms,'$auth','$r');"
  echo "$code $ms $r"
}

cmd_diagnose() {
  echo "🔍 ClawTalk Auth Doctor"
  echo "======================"
  echo "Time:  $(date -u '+%Y-%m-%d %H:%M UTC')"
  echo "URL:   $BASE"
  echo "Key:   $(mask "$KEY")"
  echo ""

  # Test 1: Server reachable?
  printf "1️⃣  Server reachability (no auth)... "
  read code ms result <<< $(probe "/health" none)
  case "$result" in
    ok)        echo "✅ UP (${ms}ms)" ;;
    auth_fail) echo "⚠️  UP, auth needed (${code}, ${ms}ms)" ;;
    timeout)   echo "❌ UNREACHABLE" ;;
    *)         echo "❌ ${code} (${ms}ms)" ;;
  esac

  # Test 2: Bearer auth
  printf "2️⃣  Bearer token auth............... "
  read code ms result <<< $(probe "/messages?limit=1" bearer)
  local bearer_ok="$result"
  case "$result" in
    ok)        echo "✅ WORKING (${ms}ms)" ;;
    auth_fail) echo "❌ REJECTED (${code}, ${ms}ms)" ;;
    *)         echo "❌ ${code} (${ms}ms)" ;;
  esac

  # Test 3: X-API-Key auth
  printf "3️⃣  X-API-Key auth (fallback)....... "
  read code ms result <<< $(probe "/messages?limit=1" apikey)
  local apikey_ok="$result"
  case "$result" in
    ok)        echo "✅ WORKING (${ms}ms)" ;;
    auth_fail) echo "❌ REJECTED (${code}, ${ms}ms)" ;;
    *)         echo "❌ ${code} (${ms}ms)" ;;
  esac

  # Test 4: Agent listing
  printf "4️⃣  Agent registry access........... "
  read code ms result <<< $(probe "/agents" bearer)
  case "$result" in
    ok)        echo "✅ OK (${ms}ms)" ;;
    auth_fail) echo "❌ DENIED (${code}, ${ms}ms)" ;;
    *)         echo "❌ ${code} (${ms}ms)" ;;
  esac

  echo ""
  echo "📊 Verdict"
  echo "=========="
  if [ "$bearer_ok" = "ok" ]; then
    echo "🟢 HEALTHY — Bearer auth operational"
  elif [ "$apikey_ok" = "ok" ]; then
    echo "🟡 DEGRADED — Bearer broken, X-API-Key works → switch auth header"
  else
    echo "🔴 BROKEN — All auth methods failed"
    echo "   → Key may have been rotated (contact platform admin)"
    echo "   → Or Cloudflare is blocking (check User-Agent, IP)"
    echo "   → Try re-registering: POST /register"
  fi
}

cmd_history() {
  echo "📜 Last 20 Auth Checks"
  sqlite3 -header -column "$DB" \
    "SELECT ts, endpoint, http_code AS code, latency_ms||'ms' AS lat, auth_method AS auth, result
     FROM checks ORDER BY id DESC LIMIT 20;"
}

cmd_trends() {
  echo "📈 24h Auth Trends"
  echo ""
  sqlite3 -header -column "$DB" \
    "SELECT result, COUNT(*) AS cnt, ROUND(AVG(latency_ms))||'ms' AS avg_lat
     FROM checks WHERE ts > datetime('now','-24 hours') GROUP BY result ORDER BY cnt DESC;"
  echo ""
  echo "Hourly breakdown:"
  sqlite3 -header -column "$DB" \
    "SELECT strftime('%H:00',ts) AS hour,
       SUM(CASE WHEN result='ok' THEN 1 ELSE 0 END) AS ok,
       SUM(CASE WHEN result!='ok' THEN 1 ELSE 0 END) AS fail
     FROM checks WHERE ts > datetime('now','-24 hours') GROUP BY hour ORDER BY hour;"
}

cmd_uptime() {
  local total ok pct
  total=$(sqlite3 "$DB" "SELECT COUNT(*) FROM checks WHERE ts > datetime('now','-24 hours');")
  ok=$(sqlite3 "$DB" "SELECT COUNT(*) FROM checks WHERE ts > datetime('now','-24 hours') AND result='ok';")
  [ "$total" -eq 0 ] && { echo "No data — run 'diagnose' first"; return; }
  pct=$((ok * 100 / total))
  echo "24h uptime: ${pct}% (${ok}/${total} checks passed)"
}

case "${1:-help}" in
  diagnose|d) cmd_diagnose ;;
  history|h)  cmd_history ;;
  trends|t)   cmd_trends ;;
  uptime|u)   cmd_uptime ;;
  *)
    echo "ClawTalk Auth Doctor — diagnose persistent auth failures"
    echo ""
    echo "Commands:"
    echo "  diagnose  4-test auth diagnosis with verdict"
    echo "  history   Last 20 check results"
    echo "  trends    24h success/failure patterns"
    echo "  uptime    24h uptime percentage"
    ;;
esac
