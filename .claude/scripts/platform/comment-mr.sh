#!/bin/bash
# Usage: comment-mr.sh <mr-number> "Comment body"
# Adds a comment to a PR (GitHub) or MR (GitLab)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../config/platform.sh"

MR="$1" COMMENT="$2"

case "$GIT_HOST" in
  github) gh pr comment "$MR" --body "$COMMENT" ;;
  gitlab) glab mr note "$MR" --message "$COMMENT" ;;
esac
