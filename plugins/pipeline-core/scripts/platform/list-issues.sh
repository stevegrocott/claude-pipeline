#!/bin/bash
# Usage: list-issues.sh [--jql "JQL query"] [--state open] [--assignee @me] [--labels "bug"]
# Returns: JSON array of { id, title, status }
# For GitHub: uses gh issue list flags
# For Jira: uses JQL (auto-built from flags or explicit --jql)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../config/platform.sh"

JQL="" STATE="open" ASSIGNEE="" LABELS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --jql) JQL="$2"; shift 2 ;;
    --state) STATE="$2"; shift 2 ;;
    --assignee) ASSIGNEE="$2"; shift 2 ;;
    --labels) LABELS="$2"; shift 2 ;;
    *) shift ;;
  esac
done

case "$TRACKER" in
  github)
    ARGS=(gh issue list --state "$STATE" --json number,title,state --limit 100)
    [[ -n "$ASSIGNEE" ]] && ARGS+=(--assignee "$ASSIGNEE")
    [[ -n "$LABELS" ]] && ARGS+=(--label "$LABELS")
    "${ARGS[@]}" | jq '[.[] | { id: (.number | tostring), title, status: .state }]'
    ;;
  jira)
    if [[ -z "$JQL" ]]; then
      JQL="project = $JIRA_PROJECT AND status != Done ORDER BY priority DESC"
    fi
    acli jira list-issues --jql "$JQL" --outputFormat json 2>/dev/null \
      | jq '[.[] | { id: .key, title: .fields.summary, status: .fields.status.name }]'
    ;;
esac
