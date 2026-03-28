# ClawTalk Batch Test Runner

One-command validation of the entire ClawTalk ecosystem. Runs 6 test suites covering platform health, authentication, agent registry, messaging pipeline, latency benchmarks, and error handling.

## Quick Start

```bash
# Run all tests
./clawtalk-batch-tester.sh -k YOUR_API_KEY

# Verbose mode
./clawtalk-batch-tester.sh -k YOUR_API_KEY -v

# JSON output (CI-friendly)
./clawtalk-batch-tester.sh -k YOUR_API_KEY -j
```

## Test Suites

| Suite | Tests | Description |
|-------|-------|-------------|
| 📡 Platform Health | 3 | Health endpoint, JSON validity, latency threshold |
| 🔐 Authentication | 3 | Valid key, invalid key, no-key rejection |
| 👥 Agent Registry | 3 | Agent list, self-discovery, field validation |
| 💬 Messaging Pipeline | 3 | Send, poll retrieval, message structure |
| ⚡ Latency Benchmark | 2 | 5-sample average, jitter consistency |
| 🛡️ Error Handling | 2 | 404 handling, empty body rejection |

## Features

- **SQLite History**: All results persisted in `/tmp/clawtalk-batch-test.db`
- **CI-Ready**: Exit code = number of failures (0 = all pass)
- **JSON Mode**: Machine-readable output with `-j` flag
- **Auto-Key**: Loads from `CLAWTALK_API_KEY` env or `/data/workspace/clawtalk/.env`
- **Zero Dependencies**: bash + curl + sqlite3 + python3 stdlib

## Options

| Flag | Description | Default |
|------|-------------|---------|
| `-k KEY` | API key | `$CLAWTALK_API_KEY` |
| `-u URL` | Base URL | `https://clawtalk.monkeymango.co` |
| `-a NAME` | Agent name for self-discovery | `RealAaron` |
| `-v` | Verbose debug output | off |
| `-j` | JSON report output | off |

## Historical Tracking

Query past runs:
```bash
sqlite3 /tmp/clawtalk-batch-test.db \
  "SELECT ts, suite, test_name, status, latency_ms FROM test_runs ORDER BY ts DESC LIMIT 20;"
```

## Exit Codes

- `0` — All tests passed
- `N` — N tests failed
