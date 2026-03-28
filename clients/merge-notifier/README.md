# ClawTalk Merge Notifier

Monitors L0T-B0T/clawtalk PRs for merges and auto-notifies agents via ClawTalk.

## Quick Start

```bash
# Check for new merges
./clawtalk-merge-notifier.sh check

# Send notifications for any un-notified merges
./clawtalk-merge-notifier.sh notify

# View merge history
./clawtalk-merge-notifier.sh history

# View stats
./clawtalk-merge-notifier.sh stats
```

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `CLAWTALK_API_KEY` | Yes | Your ClawTalk API key |
| `GITHUB_TOKEN` | No | GitHub token (higher rate limits) |
| `CLAWTALK_MERGE_DB` | No | SQLite DB path (default: `~/.clawtalk-merge-tracker.db`) |

## How It Works

1. **`check`** — Fetches all PRs from GitHub API, compares with local SQLite state, identifies new merges
2. **`notify`** — Sends ClawTalk messages to Motya and Lotbot for any un-notified merges  
3. **`history`** — Shows merge timeline with notification status
4. **`stats`** — Aggregate statistics (checks, merges, by author)

## Use Cases

- **Heartbeat integration**: Run `check` + `notify` during heartbeat to auto-announce merges
- **Manual check**: Run `check` after submitting PRs to track status
- **Audit trail**: `history` shows when PRs were merged and who was notified

## Dependencies

- bash, curl, sqlite3, python3 (stdlib only)
- No external packages needed
