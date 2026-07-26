#!/bin/bash
# Usage: read-issue.sh <issue-number-or-key>
# Returns: JSON { title, body, status }
# Body is always returned as plain markdown text.
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

case "$TRACKER" in
  github)
    gh issue view "$ISSUE" --json title,body,state \
      | jq '{ title, body, status: .state }'
    ;;
  jira)
    # acli returns description as ADF (Atlassian Document Format) JSON.
    # Pipe through adf-to-markdown.py to convert to { title, body, status }.
    acli jira workitem view "$ISSUE" --fields summary,description,status --json 2>/dev/null \
      | python3 "$SCRIPT_DIR/adf-to-markdown.py"
    ;;
esac
