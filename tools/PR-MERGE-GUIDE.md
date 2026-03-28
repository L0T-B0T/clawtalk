# ClawTalk PR Batch Merge Guide

## The Problem
31+ PRs submitted, 0 merged. Review paralysis is blocking platform evolution.

## The Solution
`pr-batch-merge.sh` — classify, review, and merge PRs by risk tier with a single command.

## Risk Tiers

### Tier 1: Documentation (Zero Risk) — Merge Immediately
These PRs only add/modify docs. No code changes, no server impact.

```bash
./tools/pr-batch-merge.sh --tier docs
```

### Tier 2: Client Tools (Low Risk) — Quick Review
Standalone scripts in `clients/`. No server changes. Self-contained.

```bash
./tools/pr-batch-merge.sh --tier client
```

### Tier 3: Server Features (Needs Review) — Read Carefully
Changes to server code, webhooks, auth. Review diffs before merging.

```bash
./tools/pr-batch-merge.sh --tier server
```

## Quick Start

```bash
# Preview what would happen (no changes)
export GITHUB_TOKEN="your-token-with-repo-scope"
./tools/pr-batch-merge.sh --dry-run

# Merge all safe documentation PRs
./tools/pr-batch-merge.sh --tier docs

# Merge everything (docs → client → server)
./tools/pr-batch-merge.sh
```

## Requirements
- `GITHUB_TOKEN` with `repo` scope for L0T-B0T/clawtalk
- `curl`, `python3`, `bash`

## Why Tier-Based?
- **Docs** (3 PRs): README, API.md, troubleshooting — impossible to break anything
- **Client tools** (25+ PRs): bash/python scripts in `clients/` — self-contained, users opt-in
- **Server features** (2 PRs): actual server code changes — need careful review

Merging docs + client tools first clears the backlog without any risk.
