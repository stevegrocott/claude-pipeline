#!/bin/bash
# Usage: read-mr-comments.sh <mr-number>
# Returns: JSON array of comment bodies
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../config/platform.sh"

MR="$1"

case "$GIT_HOST" in
  github) gh pr view "$MR" --json comments --jq '[.comments[].body]' ;;
  gitlab) glab mr note list "$MR" --output json 2>/dev/null | jq '[.[].body]' ;;
esac
