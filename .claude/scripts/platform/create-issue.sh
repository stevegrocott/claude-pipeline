#!/bin/bash
# Usage: create-issue.sh --title "Title" --body "Body" [--labels "bug,critical"]
# Returns: issue number or key on stdout (e.g., "42" or "KIN-123")
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../config/platform.sh"

TITLE="" BODY="" LABELS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --title) TITLE="$2"; shift 2 ;;
    --body) BODY="$2"; shift 2 ;;
    --labels) LABELS="$2"; shift 2 ;;
    *) shift ;;
  esac
done

case "$TRACKER" in
  github)
    ARGS=(gh issue create --title "$TITLE" --body "$BODY")
    [[ -n "$LABELS" ]] && ARGS+=(--label "$LABELS")
    "${ARGS[@]}" 2>/dev/null | grep -oE '[0-9]+$'
    ;;
  jira)
    acli jira create-issue \
      --project "$JIRA_PROJECT" \
      --type "$JIRA_DEFAULT_ISSUE_TYPE" \
      --summary "$TITLE" \
      --description "$BODY" 2>/dev/null \
      | grep -oE '[A-Z]+-[0-9]+'
    ;;
esac
