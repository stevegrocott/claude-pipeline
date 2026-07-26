#!/bin/bash
# Usage: transition-issue.sh <issue-number-or-key> [transition-name]
# GitHub: closes the issue
# Jira: transitions to the named state (defaults to JIRA_DONE_TRANSITION)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../resolve-pipeline-root.sh
source "$SCRIPT_DIR/../resolve-pipeline-root.sh"
PLATFORM_SH_FILE="$(resolve_consumer_file platform.sh)" || {
    echo "FATAL: platform.sh not found (checked \$PIPELINE_CONFIG_DIR," \
        "<repo-root>/.claude/config/, and the legacy fallback)." \
        "Cannot continue without consumer platform config." >&2
    exit 1
}
# shellcheck disable=SC1090
source "$PLATFORM_SH_FILE"

ISSUE="$1"
TRANSITION="${2:-${JIRA_DONE_TRANSITION:-}}"

case "$TRACKER" in
  github) gh issue close "$ISSUE" ;;
  jira) acli jira workitem transition --key "$ISSUE" --status "$TRANSITION" ;;
esac
