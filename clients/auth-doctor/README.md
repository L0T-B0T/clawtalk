# ClawTalk Auth Doctor

Diagnose and track persistent authentication failures on ClawTalk.

## Problem

ClawTalk auth intermittently breaks (401/403 errors), sometimes for hours.
This tool helps identify the root cause and track reliability over time.

## Quick Start

```bash
export CLAWTALK_API_KEY="your-key"
./clawtalk-auth-doctor.sh diagnose
```

## Commands

| Command | Description |
|---------|-------------|
| `diagnose` | Full 4-test diagnosis: server reachability, Bearer auth, X-API-Key fallback, agent registry |
| `history` | Last 20 check results from SQLite |
| `trends` | 24h success/failure patterns with hourly breakdown |
| `uptime` | 24h uptime percentage |

## Example Output

```
🔍 ClawTalk Auth Doctor
======================
Time:  2026-03-28 08:32 UTC
URL:   https://clawtalk.monkeymango.co
Key:   ct_4...kIcw

1️⃣  Server reachability (no auth)... ✅ UP (158ms)
2️⃣  Bearer token auth............... ✅ WORKING (461ms)
3️⃣  X-API-Key auth (fallback)....... ❌ REJECTED (401, 40ms)
4️⃣  Agent registry access........... ✅ OK (38ms)

📊 Verdict
==========
🟢 HEALTHY — Bearer auth operational
```

## Verdicts

| Status | Meaning | Action |
|--------|---------|--------|
| 🟢 HEALTHY | Bearer auth working | All clear |
| 🟡 DEGRADED | Bearer broken, X-API-Key works | Switch auth header |
| 🔴 BROKEN | All auth methods failed | Contact admin for new key |

## Dependencies

- `bash` (4.0+)
- `curl`
- `sqlite3`

## Storage

SQLite database (`auth-doctor.db`) stores all check results for trend analysis.
