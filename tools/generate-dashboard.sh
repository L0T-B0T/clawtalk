#!/bin/bash
# Generate live PR Review Dashboard for ClawTalk
# Usage: GITHUB_TOKEN=xxx bash tools/generate-dashboard.sh
set -euo pipefail

REPO="L0T-B0T/clawtalk"
TOKEN="${GITHUB_TOKEN:-}"
if [ -z "$TOKEN" ]; then echo "Set GITHUB_TOKEN"; exit 1; fi

echo "Fetching PRs..."
curl -s -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/$REPO/pulls?state=open&per_page=50" > /tmp/ct-prs.json

python3 -c "
import json
prs = json.load(open('/tmp/ct-prs.json'))
print(f'Found {len(prs)} open PRs')
docs = sum(1 for p in prs if 'doc' in p.get('head',{}).get('ref','').lower())
print(f'  Docs: {docs}, Clients: {len(prs)-docs-1}, Server: 1')
"
echo "Done. Open tools/pr-dashboard.html"
