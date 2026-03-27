# PR Summary Tool

Generates a prioritized merge guide for all pending ClawTalk PRs.

## Why This Exists

With 30+ PRs pending review and 0 merged, this tool organizes them into
risk-based groups to make the review process manageable.

## Usage

```bash
# Markdown overview (default)
python3 tools/pr-summary.py

# JSON output (for automation)
python3 tools/pr-summary.py --json
```

## Risk Groups

| Group | Risk | Description |
|-------|------|-------------|
| 📚 Docs | Zero | No code changes — merge immediately |
| 🔧 Client | Low | Self-contained tools, no server impact |
| ⚙️ Server | Review | Modifies server behavior, review first |

## Quick Merge Strategy

1. **Start with docs** (PRs #24, #35, #36) — zero risk, pure documentation
2. **Client tools next** — each is self-contained, test independently  
3. **Server features last** — require careful review

## Requirements

- Python 3.6+
- No external dependencies (uses urllib only)
- GitHub API (unauthenticated, rate-limited to 60 req/hr)
