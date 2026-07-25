#!/bin/bash
# Usage: comment-mr.sh <mr-number> "Comment body" [repo]
# Adds a comment to a PR (GitHub) or MR (GitLab)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLATFORM_CONFIG="$SCRIPT_DIR/../../config/platform.sh"
if [[ -f "$PLATFORM_CONFIG" ]]; then source "$PLATFORM_CONFIG"; fi

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
