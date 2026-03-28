#!/usr/bin/env bash
# ClawTalk PR Batch Merge Tool
# Safely merges groups of PRs in L0T-B0T/clawtalk by risk tier
# Usage: ./pr-batch-merge.sh [--dry-run] [--tier docs|client|server|all]
#
# Tier classification:
#   docs   — zero risk (README, API.md, TROUBLESHOOTING.md)
#   client — low risk (standalone bash/python tools in clients/)
#   server — needs review (changes to server code)
#
# Requires: GITHUB_TOKEN with repo scope for L0T-B0T/clawtalk

set -euo pipefail

REPO="L0T-B0T/clawtalk"
API="https://api.github.com/repos/${REPO}"
DRY_RUN=false
TIER="all"
MERGED=0
SKIPPED=0
FAILED=0

usage() {
    echo "Usage: $0 [--dry-run] [--tier docs|client|server|all]"
    echo ""
    echo "Options:"
    echo "  --dry-run   Show what would be merged without actually merging"
    echo "  --tier T    Only merge PRs in specified tier (default: all)"
    echo ""
    echo "Tiers (merged in order):"
    echo "  docs    — Documentation PRs (zero risk)"
    echo "  client  — Client tool PRs (no server changes)"
    echo "  server  — Server feature PRs (review carefully)"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --tier) TIER="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    echo "ERROR: GITHUB_TOKEN not set"
    echo "Export a GitHub PAT with repo scope for L0T-B0T/clawtalk"
    exit 1
fi

AUTH=(-H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github.v3+json")

echo "╔══════════════════════════════════════════╗"
echo "║   ClawTalk PR Batch Merge Tool           ║"
echo "║   Repo: ${REPO}                    ║"
echo "║   Tier: ${TIER}                              ║"
echo "║   Dry-run: ${DRY_RUN}                        ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# Fetch all open PRs
echo "→ Fetching open PRs..."
PRS=$(curl -s "${AUTH[@]}" "${API}/pulls?state=open&per_page=100&sort=created&direction=asc")
PR_COUNT=$(echo "$PRS" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
echo "  Found ${PR_COUNT} open PRs"
echo ""

if [[ "$PR_COUNT" == "0" ]]; then
    echo "✅ No open PRs to merge"
    exit 0
fi

# Classify PRs into tiers
classify_pr() {
    local title="$1"
    local files_url="$2"
    local branch="$3"

    # Docs tier: documentation-only PRs
    if echo "$branch" | grep -qiE '^(docs/|feat/quickstart|feat/api-reference)'; then
        echo "docs"
        return
    fi
    if echo "$title" | grep -qiE '(readme|documentation|api.md|troubleshoot|merge.roadmap|quickstart)'; then
        echo "docs"
        return
    fi

    # Server tier: changes to server-side code
    if echo "$branch" | grep -qiE '(server|webhook|auth|middleware)'; then
        echo "server"
        return
    fi
    if echo "$title" | grep -qiE '(server|webhook|auth|middleware|database)'; then
        echo "server"
        return
    fi

    # Default: client tier (standalone tools)
    echo "client"
}

# Process PRs
echo "═══════════════════════════════════════════"
echo " CLASSIFICATION"
echo "═══════════════════════════════════════════"

DOCS_PRS=""
CLIENT_PRS=""
SERVER_PRS=""

while IFS= read -r line; do
    pr_num=$(echo "$line" | cut -d'|' -f1)
    pr_title=$(echo "$line" | cut -d'|' -f2)
    pr_branch=$(echo "$line" | cut -d'|' -f3)
    pr_mergeable=$(echo "$line" | cut -d'|' -f4)

    tier=$(classify_pr "$pr_title" "" "$pr_branch")

    case "$tier" in
        docs)   DOCS_PRS="${DOCS_PRS}${pr_num}|${pr_title}|${pr_mergeable}\n" ;;
        client) CLIENT_PRS="${CLIENT_PRS}${pr_num}|${pr_title}|${pr_mergeable}\n" ;;
        server) SERVER_PRS="${SERVER_PRS}${pr_num}|${pr_title}|${pr_mergeable}\n" ;;
    esac

    printf "  #%-4s [%-6s] %s\n" "$pr_num" "$tier" "$pr_title"

done < <(echo "$PRS" | python3 -c "
import sys, json
prs = json.load(sys.stdin)
for pr in prs:
    num = pr['number']
    title = pr['title'][:60]
    branch = pr.get('head', {}).get('ref', '')
    mergeable = pr.get('mergeable_state', 'unknown')
    print(f'{num}|{title}|{branch}|{mergeable}')
" 2>/dev/null)

echo ""

# Merge function
merge_pr() {
    local pr_num="$1"
    local pr_title="$2"
    local tier_name="$3"

    if $DRY_RUN; then
        echo "  [DRY-RUN] Would merge #${pr_num}: ${pr_title}"
        ((MERGED++))
        return 0
    fi

    echo -n "  Merging #${pr_num}... "

    # Check if mergeable
    local pr_detail
    pr_detail=$(curl -s "${AUTH[@]}" "${API}/pulls/${pr_num}")
    local mergeable
    mergeable=$(echo "$pr_detail" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('mergeable', 'null'))" 2>/dev/null)

    if [[ "$mergeable" == "False" ]]; then
        echo "⚠️  CONFLICT (needs rebase)"
        ((SKIPPED++))
        return 1
    fi

    # Attempt merge
    local result
    result=$(curl -s -X PUT "${AUTH[@]}" \
        -d "{\"merge_method\":\"squash\",\"commit_title\":\"${pr_title} (#${pr_num})\"}" \
        "${API}/pulls/${pr_num}/merge")

    local merged
    merged=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('merged', False))" 2>/dev/null)

    if [[ "$merged" == "True" ]]; then
        echo "✅ MERGED"
        ((MERGED++))
        return 0
    else
        local msg
        msg=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('message', 'unknown error'))" 2>/dev/null)
        echo "❌ FAILED: ${msg}"
        ((FAILED++))
        return 1
    fi
}

# Process tiers in order
process_tier() {
    local tier_name="$1"
    local pr_list="$2"

    if [[ -z "$pr_list" ]]; then
        echo "  (no PRs in this tier)"
        return
    fi

    while IFS='|' read -r num title mergeable; do
        [[ -z "$num" ]] && continue
        merge_pr "$num" "$title" "$tier_name"
        # Rate limit: 1 second between merges
        sleep 1
    done < <(echo -e "$pr_list")
}

if [[ "$TIER" == "docs" || "$TIER" == "all" ]]; then
    echo "═══════════════════════════════════════════"
    echo " TIER 1: DOCUMENTATION (zero risk)"
    echo "═══════════════════════════════════════════"
    process_tier "docs" "$DOCS_PRS"
    echo ""
fi

if [[ "$TIER" == "client" || "$TIER" == "all" ]]; then
    echo "═══════════════════════════════════════════"
    echo " TIER 2: CLIENT TOOLS (no server changes)"
    echo "═══════════════════════════════════════════"
    process_tier "client" "$CLIENT_PRS"
    echo ""
fi

if [[ "$TIER" == "server" || "$TIER" == "all" ]]; then
    echo "═══════════════════════════════════════════"
    echo " TIER 3: SERVER FEATURES (review needed)"
    echo "═══════════════════════════════════════════"
    process_tier "server" "$SERVER_PRS"
    echo ""
fi

# Summary
echo "═══════════════════════════════════════════"
echo " SUMMARY"
echo "═══════════════════════════════════════════"
echo "  Merged:  ${MERGED}"
echo "  Skipped: ${SKIPPED}"
echo "  Failed:  ${FAILED}"
echo ""

if $DRY_RUN; then
    echo "💡 This was a dry run. Use without --dry-run to actually merge."
fi
