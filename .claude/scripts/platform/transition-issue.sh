#!/bin/bash
# Usage: transition-issue.sh <issue-number-or-key> [transition-name]
# GitHub: closes the issue
# Jira: transitions to the named state (defaults to JIRA_DONE_TRANSITION)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../config/platform.sh"

ISSUE="$1"
TRANSITION="${2:-$JIRA_DONE_TRANSITION}"

case "$TRACKER" in
  github) gh issue close "$ISSUE" ;;
  jira) acli jira transition-issue --issue "$ISSUE" --transition "$TRANSITION" ;;
esac
