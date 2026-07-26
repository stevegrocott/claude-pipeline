#!/bin/bash
# Usage: read-mr-comments.sh <mr-number>
# Returns: JSON array of comment bodies
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

MR="$1"

case "$GIT_HOST" in
  github) gh pr view "$MR" --json comments --jq '[.comments[].body]' ;;
  gitlab) glab mr note list "$MR" --output json 2>/dev/null | jq '[.[].body]' ;;
esac
