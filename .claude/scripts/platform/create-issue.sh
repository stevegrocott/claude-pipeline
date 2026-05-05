#!/bin/bash
# Usage: create-issue.sh --title "Title" --body "Body" [--labels "bug,critical"] [--parent "EPIC-KEY"]
# Returns: issue number or key on stdout (e.g., "42" or "KIN-123")
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../config/platform.sh"

TITLE="" BODY="" LABELS="" PARENT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --title) TITLE="$2"; shift 2 ;;
    --body) BODY="$2"; shift 2 ;;
    --labels) LABELS="$2"; shift 2 ;;
    --parent) PARENT="$2"; shift 2 ;;
    *) shift ;;
  esac
done

[[ -z "$TITLE" ]] && { echo "ERROR: --title is required" >&2; exit 3; }

case "$TRACKER" in
  github)
    ARGS=(gh issue create --title "$TITLE" --body "$BODY")
    [[ -n "$LABELS" ]] && ARGS+=(--label "$LABELS")
    "${ARGS[@]}" 2>&1 | grep -oE '[0-9]+$'
    ;;
  jira)
    ARGS=(acli jira workitem create
      --project "$JIRA_PROJECT"
      --type "$JIRA_DEFAULT_ISSUE_TYPE"
      --summary "$TITLE")

    # Convert markdown body to ADF and write to temp file (avoids arg length limits)
    if [[ -n "$BODY" ]]; then
      TMPFILE="$(mktemp)"
      trap 'rm -f "$TMPFILE"' EXIT
      printf '%s' "$BODY" | python3 "$SCRIPT_DIR/markdown-to-adf.py" > "$TMPFILE"
      ARGS+=(--description-file "$TMPFILE")
    fi

    [[ -n "$PARENT" ]] && ARGS+=(--parent "$PARENT")
    [[ -n "$LABELS" ]] && ARGS+=(--label "$LABELS")

    OUTPUT=$("${ARGS[@]}" 2>&1) || {
      echo "ERROR: acli failed: $OUTPUT" >&2
      if [[ "$OUTPUT" == *"unauthorized"* ]] || [[ "$OUTPUT" == *"auth"* ]]; then
        echo "HINT: Run 'acli jira auth login' to authenticate" >&2
      fi
      exit 1
    }
    echo "$OUTPUT" | grep -oE '[A-Z]+-[0-9]+'
    ;;
esac
