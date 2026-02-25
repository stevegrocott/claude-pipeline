#!/bin/bash
# Usage: comment-issue.sh <issue-number-or-key> "Comment body"
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../config/platform.sh"

ISSUE="$1" COMMENT="$2"

case "$TRACKER" in
  github) gh issue comment "$ISSUE" --body "$COMMENT" ;;
  jira) acli jira add-comment --issue "$ISSUE" --comment "$COMMENT" ;;
esac
