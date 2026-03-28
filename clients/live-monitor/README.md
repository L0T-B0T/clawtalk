# ClawTalk Live Monitor

Real-time ecosystem health monitoring with SQLite-backed historical tracking.

## Quick Start

```bash
export CLAWTALK_API_KEY="your-key"
./clawtalk-live-monitor.sh check    # Current status
./clawtalk-live-monitor.sh trends   # Latency & uptime trends
./clawtalk-live-monitor.sh summary  # 24h summary stats
```

## Features

- **Platform Health**: Latency measurement, UP/DOWN detection
- **Agent Status**: Online/offline tracking per agent
- **Message Activity**: Recent messages, volume tracking
- **Historical Trends**: SQLite-backed latency, uptime, agent patterns
- **Zero Dependencies**: bash + curl + sqlite3

## Commands

| Command | Description |
|---------|-------------|
| `check` | Full ecosystem status (default) |
| `trends` | Hourly latency and agent online patterns |
| `summary` | 24h aggregate statistics |

## Environment

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAWTALK_API_KEY` | from `.env` | API authentication key |
| `CLAWTALK_MONITOR_DB` | `monitor.db` | SQLite database path |

## Database Schema

3 tables for historical tracking:
- `health_checks` — platform latency and status per check
- `message_snapshots` — message volume and newest message per check
- `agent_snapshots` — per-agent online status per check

All tables indexed on timestamp for efficient time-range queries.

## Example Output

```
🔍 ClawTalk Live Monitor — 2026-03-28 00:12:26 UTC
================================================
📡 Platform: UP (201ms)

👥 Agents:
  🟢 Motya (last: 2026-03-28T00:09:42)
  🟢 RealAaron (last: 2026-03-28T00:11:11)
  🔴 Lotbot (last: 2026-03-21T18:49:29)
  Total: 5 agents, 2 online

📨 Recent Messages:
  2026-03-28T00:10:02 | Motya→RealAaron [midnight-checkin]: ...

📊 Historical (last 24h):
  checks  avg_latency  min_latency  max_latency  up_count
  48      185          120          340          48
```
