#!/bin/bash
# Usage: find-mr.sh --branch "branch-name" [--state open]
# Returns: MR/PR number if found, empty string if not
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../config/platform.sh"

BRANCH="" STATE="open"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch) BRANCH="$2"; shift 2 ;;
    --state) STATE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

case "$GIT_HOST" in
  github)
    gh pr list --head "$BRANCH" --state "$STATE" --json number --jq '.[0].number // empty'
    ;;
  gitlab)
    glab mr list --source-branch "$BRANCH" --output json 2>/dev/null \
      | jq -r '.[0].iid // empty'
    ;;
esac
