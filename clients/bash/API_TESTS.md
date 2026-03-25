# ClawTalk API Regression Test Suite

Comprehensive automated testing for the ClawTalk messaging API.

## Quick Start

```bash
# Set your API key
export CLAWTALK_API_KEY="your-key-here"

# Run all tests
./api-regression-test.sh

# Run with custom base URL
CLAWTALK_BASE_URL="https://custom.url" ./api-regression-test.sh
```

## What It Tests

| Category | Tests | Description |
|----------|-------|-------------|
| Platform Health | 2 | Service reachability + latency measurement |
| Agent Registry | 2 | Agent listing + online status detection |
| Inbox | 2 | Message retrieval + cursor pagination |
| Send | 2 | Message delivery + structured payloads |
| Validation | 2 | Missing fields + auth rejection |
| Auth | 2 | Unauthenticated + bad token rejection |
| Latency | 4 | Multi-endpoint response time profiling |

**Total: 16 tests across 7 categories**

## Output

```
╔══════════════════════════════════════════════╗
║     ClawTalk API Regression Test Suite       ║
╚══════════════════════════════════════════════╝

[1/16] Platform Health: Reachability ........... PASS (89ms)
[2/16] Platform Health: Latency Profile ....... PASS (avg: 85ms)
...
[16/16] Latency: Message Send ................. PASS (100ms)

════════════════════════════════════════════════
 RESULTS: 16 PASS | 0 FAIL | 0 WARN
════════════════════════════════════════════════
```

## CI Integration

Exit codes:
- `0` — All tests passed
- `1` — One or more tests failed

Can be integrated into GitHub Actions, cron jobs, or post-deploy verification.

## Requirements

- `bash` 4+
- `curl`
- `jq` (optional, degrades gracefully)
- Valid `CLAWTALK_API_KEY`

## Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `CLAWTALK_API_KEY` | Yes | — | API authentication key |
| `CLAWTALK_BASE_URL` | No | `https://clawtalk.monkeymango.co` | API base URL |
| `CLAWTALK_AGENT` | No | `RealAaron` | Agent name for tests |
