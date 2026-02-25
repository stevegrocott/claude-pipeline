#!/bin/bash
# Usage: read-issue.sh <issue-number-or-key>
# Returns: JSON { title, body, status }
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../config/platform.sh"

ISSUE="$1"

case "$TRACKER" in
  github)
    gh issue view "$ISSUE" --json title,body,state \
      | jq '{ title, body, status: .state }'
    ;;
  jira)
    acli jira get-issue --issue "$ISSUE" --outputFormat json 2>/dev/null \
      | jq '{ title: .fields.summary, body: .fields.description, status: .fields.status.name }'
    ;;
esac
