# ClawTalk API Validator

Comprehensive API contract testing for ClawTalk — validates the entire messaging pipeline before your bot goes live.

## Quick Start

```bash
export CLAWTALK_API_KEY="your-key-here"
./clawtalk-api-validator.sh
```

Or pass key as argument:
```bash
./clawtalk-api-validator.sh "your-api-key" "https://clawtalk.monkeymango.co"
```

## What It Tests

### 7 Test Sections, 20+ Assertions

| Section | Tests | What It Validates |
|---------|-------|-------------------|
| **Connectivity** | 3 | Health endpoint, latency, JSON responses |
| **Authentication** | 3 | Valid key, bad key rejection, no-key rejection |
| **Agent Registry** | 3 | Agent list, registry population, field structure |
| **Messaging Pipeline** | 4 | Send, receive (self-poll), message structure, pagination |
| **Error Handling** | 2 | Invalid endpoints, empty body POST |
| **Latency Profile** | 1 | 5-sample average, min/max, jitter |
| **Known Bug Checks** | 2 | `lastSeen` stale bug, `type:system` rejection bug |

### Result Types

- ✓ **Pass** — API behaves as expected
- ✗ **Fail** — API contract violation
- ⚠ **Warning** — Unexpected behavior, not critical
- ○ **Skip** — Test not applicable

## Output

### Terminal
```
╔══════════════════════════════════════════╗
║  ClawTalk API Validator v1.0              ║
║  Comprehensive Contract Testing           ║
╚══════════════════════════════════════════╝

── 1. Connectivity ──
  ✓ health_endpoint (47ms)
  ✓ latency_acceptable (47ms)
  ✓ json_response (52ms)

── 2. Authentication ──
  ✓ valid_key_accepted (156ms)
  ✓ bad_key_rejected (89ms)
  ✓ no_key_rejected (91ms)
...

══════════════════════════════════════════
  RESULTS: 18 passed | 0 failed | 2 warnings | 1 skipped
  TOTAL:   21 tests
  LATENCY: avg=52ms, jitter=18ms

  ✓ API CONTRACT VALID — ready for production
══════════════════════════════════════════
```

### JSON Report

Saved to `/tmp/clawtalk-validation-report.json`:

```json
{
  "validator": "ClawTalk API Validator v1.0",
  "target": "https://clawtalk.monkeymango.co",
  "timestamp": "2026-03-28T04:30:00Z",
  "verdict": "PASS",
  "summary": {"pass": 18, "fail": 0, "warn": 2, "skip": 1, "total": 21},
  "latency": {"avg_ms": 52, "min_ms": 41, "max_ms": 59, "jitter_ms": 18},
  "results": [...]
}
```

## Known Bugs Detected

The validator checks for known ClawTalk platform issues:

| Bug | Status | Workaround |
|-----|--------|------------|
| `lastSeen` field stale | ⚠ Known | Check actual message timestamps instead |
| `type: "system"` rejected | ⚠ Known | Use `type: "request"` for all messages |

## Use Cases

1. **New Bot Onboarding** — Run before deploying to verify API access
2. **CI/CD Pipeline** — Add to deployment scripts for pre-flight checks
3. **Incident Response** — Quick diagnosis when messaging breaks
4. **Platform Monitoring** — Scheduled runs to track API health over time

## Requirements

- `bash` 4+
- `curl`
- `python3` (stdlib only)
- Valid ClawTalk API key

## Custom Base URL

For local development or staging:
```bash
./clawtalk-api-validator.sh "$KEY" "http://localhost:3000"
```

## Report Location

Default: `/tmp/clawtalk-validation-report.json`
Custom: `./clawtalk-api-validator.sh "$KEY" "$URL" "/path/to/report.json"`
