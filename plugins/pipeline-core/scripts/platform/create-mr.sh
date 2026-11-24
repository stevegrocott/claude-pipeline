#!/bin/bash
# Usage: create-mr.sh --source "branch" --target "main" --title "Title" \
#   (--body "Body" | --body-file path)
# Returns: MR/PR number on stdout
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

SOURCE="" TARGET="" TITLE="" BODY="" BODY_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --source) SOURCE="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --title) TITLE="$2"; shift 2 ;;
    --body) BODY="$2"; shift 2 ;;
    --body-file) BODY_FILE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# --body-file takes precedence over --body; content still gets redacted.
if [[ -n "$BODY_FILE" ]]; then
  if [[ ! -f "$BODY_FILE" || ! -r "$BODY_FILE" ]]; then
    echo "ERROR: body file not readable: $BODY_FILE" >&2
    exit 1
  fi
  BODY="$(cat "$BODY_FILE"; printf x)"
  BODY="${BODY%x}"
fi

# Never publish machine-local absolute paths.
BODY="$(redact_local_paths "$BODY"; printf x)"
BODY="${BODY%x}"

case "$GIT_HOST" in
  github)
    gh pr create --head "$SOURCE" --base "$TARGET" --title "$TITLE" --body "$BODY" \
      2>/dev/null | grep -oE '[0-9]+$'
    ;;
  gitlab)
    glab mr create --source-branch "$SOURCE" --target-branch "$TARGET" \
      --title "$TITLE" --description "$BODY" --squash-on-merge --no-editor \
      2>/dev/null | grep -oE '![0-9]+' | tr -d '!'
    ;;
  *)
    echo "ERROR: unrecognised GIT_HOST '$GIT_HOST'" \
      "(accepted: github, gitlab)" >&2
    exit 1
    ;;
esac
