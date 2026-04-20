#!/usr/bin/env bash
# =============================================================================
# file_issue.sh — Post a GitHub issue when validate_api.sh fails
# Called by GitHub Actions validate.yml on any job failure.
#
# Features:
#   - Reads the structured report from validate_api.sh (REPORT_FILE)
#   - Deduplicates: skips filing if an identical open issue already exists
#     (matches on title prefix to avoid flooding on repeat failures)
#   - Labels the issue: "regression", "sftpgo", "automated"
#   - Adds a run link and commit SHA to the issue body
#   - Closes any previously auto-filed issue when re-run passes (called with --resolve)
#
# Usage:
#   file_issue.sh              — file a failure issue
#   file_issue.sh --resolve    — close any open auto-filed issues (called on success)
#
# Required env:
#   GH_TOKEN       — GitHub token with issues:write (auto-set in Actions as GITHUB_TOKEN)
#   GITHUB_REPOSITORY — e.g. JoftheV/sftpgo-neoncovenant (auto-set in Actions)
#   REPORT_FILE    — path to the markdown report from validate_api.sh
# =============================================================================

set -euo pipefail

REPORT_FILE="${REPORT_FILE:-/tmp/sftpgo_failure_report.md}"
REPO="${GITHUB_REPOSITORY:-JoftheV/sftpgo-neoncovenant}"
RUN_ID="${GITHUB_RUN_ID:-0}"
RUN_NUMBER="${GITHUB_RUN_NUMBER:-0}"
SERVER_URL="${GITHUB_SERVER_URL:-https://github.com}"
SHA="${GITHUB_SHA:-unknown}"
SHORT_SHA="${SHA:0:7}"

ISSUE_TITLE_PREFIX="[CI] SFTPGo regression failure"
ISSUE_TITLE="${ISSUE_TITLE_PREFIX} — run #${RUN_NUMBER} (${SHORT_SHA})"
LABELS="regression,sftpgo,automated"
RUN_URL="${SERVER_URL}/${REPO}/actions/runs/${RUN_ID}"

# ---------------------------------------------------------------------------
# --resolve mode: close any open auto-filed issues when CI passes again
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--resolve" ]]; then
  echo "Checking for open auto-filed regression issues to close..."

  OPEN_ISSUES=$(gh issue list \
    --repo "${REPO}" \
    --label "automated,regression" \
    --state open \
    --json number,title \
    --jq '.[] | select(.title | startswith("'"${ISSUE_TITLE_PREFIX}"'")) | .number')

  if [[ -z "${OPEN_ISSUES}" ]]; then
    echo "No open regression issues to close."
    exit 0
  fi

  while IFS= read -r ISSUE_NUM; do
    echo "Closing issue #${ISSUE_NUM} (CI is green again)..."
    gh issue close "${ISSUE_NUM}" \
      --repo "${REPO}" \
      --comment "**CI passed on [run #${RUN_NUMBER}](${RUN_URL})** (commit \`${SHORT_SHA}\`). Closing automatically — regression resolved."
    echo "  Closed #${ISSUE_NUM}"
  done <<< "${OPEN_ISSUES}"

  exit 0
fi

# ---------------------------------------------------------------------------
# Failure mode: file an issue
# ---------------------------------------------------------------------------

# Check report file exists and is non-empty
if [[ ! -s "${REPORT_FILE}" ]]; then
  echo "WARNING: Report file '${REPORT_FILE}' is missing or empty."
  echo "Filing a generic failure issue instead."
  BODY="CI run [#${RUN_NUMBER}](${RUN_URL}) failed but no structured report was generated. Check the Actions log directly."
else
  BODY=$(cat "${REPORT_FILE}")
fi

# ---------------------------------------------------------------------------
# Deduplication: search for an open issue with the same title prefix
# ---------------------------------------------------------------------------
echo "Checking for existing open regression issue..."

EXISTING=$(gh issue list \
  --repo "${REPO}" \
  --label "automated,regression" \
  --state open \
  --json number,title \
  --jq '.[] | select(.title | startswith("'"${ISSUE_TITLE_PREFIX}"'")) | .number' \
  | head -1)

if [[ -n "${EXISTING}" ]]; then
  echo "Open regression issue #${EXISTING} already exists — adding a comment instead of filing a duplicate."
  gh issue comment "${EXISTING}" \
    --repo "${REPO}" \
    --body "**Still failing** on [run #${RUN_NUMBER}](${RUN_URL}) (commit \`${SHORT_SHA}\`).

${BODY}"
  echo "Commented on #${EXISTING}"
  exit 0
fi

# ---------------------------------------------------------------------------
# Ensure required labels exist (creates them if missing)
# ---------------------------------------------------------------------------
ensure_label() {
  local label="$1" color="$2" desc="$3"
  gh label create "${label}" \
    --repo "${REPO}" \
    --color "${color}" \
    --description "${desc}" \
    --force 2>/dev/null || true
}

ensure_label "regression"  "d73a4a" "Config or API regression detected by CI"
ensure_label "sftpgo"      "0075ca" "SFTPGo configuration issue"
ensure_label "automated"   "e4e669" "Filed automatically by CI"

# ---------------------------------------------------------------------------
# File the issue
# ---------------------------------------------------------------------------
echo "Filing new regression issue..."

ISSUE_URL=$(gh issue create \
  --repo "${REPO}" \
  --title "${ISSUE_TITLE}" \
  --body "${BODY}" \
  --label "${LABELS}")

echo "Issue filed: ${ISSUE_URL}"
