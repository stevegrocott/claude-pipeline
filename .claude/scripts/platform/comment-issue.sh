#!/bin/bash
# Usage: comment-issue.sh <issue-number-or-key> "Comment body" [repo]
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

ISSUE="$1" COMMENT="$2" REPO_ARG="${3:-}"

case "${TRACKER:-github}" in
  github)
    if [[ -n "$REPO_ARG" ]]; then
      gh issue comment "$ISSUE" -R "$REPO_ARG" --body "$COMMENT"
    else
      gh issue comment "$ISSUE" --body "$COMMENT"
    fi
    ;;
  jira)
    # Convert markdown to Atlassian Document Format (ADF) JSON
    ADF_COMMENT=$(printf '%s' "$COMMENT" | python3 "$SCRIPT_DIR/markdown-to-adf.py")
    acli jira workitem comment create --key "$ISSUE" --body "$ADF_COMMENT"
    ;;
esac
