#!/bin/bash
# Usage: comment-mr.sh <mr-number> "Comment body" [repo]
# Adds a comment to a PR (GitHub) or MR (GitLab)
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

MR="$1" COMMENT="$2" REPO_ARG="${3:-}"

case "${GIT_HOST:-github}" in
  github)
    if [[ -n "$REPO_ARG" ]]; then
      gh pr comment "$MR" -R "$REPO_ARG" --body "$COMMENT"
    else
      gh pr comment "$MR" --body "$COMMENT"
    fi
    ;;
  gitlab) glab mr note "$MR" --message "$COMMENT" ;;
esac
