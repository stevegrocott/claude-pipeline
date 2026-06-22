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

# Validate pipeline-autocreated bodies before creation.
if [[ "$BODY" == *"<!-- pipeline-autocreated -->"* ]]; then
  # shellcheck source=../issue-body-lib.sh
  source "$SCRIPT_DIR/../issue-body-lib.sh"
  if ! assert_issue_valid "$BODY"; then
    echo "ERROR: pipeline-autocreated body failed validation — issue not created" >&2
    exit 1
  fi
fi

case "$TRACKER" in
  github)
    ARGS=(gh issue create --title "$TITLE" --body "$BODY")
    [[ -n "$LABELS" ]] && ARGS+=(--label "$LABELS")
    if ! issue_url=$("${ARGS[@]}" 2>/dev/null); then
      exit 1
    fi
    if [[ ! "$issue_url" =~ ^https://github\.com/.+/issues/[0-9]+$ ]]; then
      exit 1
    fi
    issue_num="${issue_url##*/}"
    printf '%s\n' "$issue_num"
    if [[ -n "$PARENT" ]]; then
      parent_num="${PARENT#\#}"
      if [[ ! "$parent_num" =~ ^[0-9]+$ ]]; then
        printf 'WARNING: --parent %s is not numeric; skipping sub-issue link\n' \
          "$PARENT" >&2
      elif [[ ! "$issue_num" =~ ^[0-9]+$ ]]; then
        printf 'WARNING: issue_num %s is not numeric; skipping link\n' \
          "$issue_num" >&2
      elif [[ "$issue_url" != https://github.com/* ]]; then
        printf \
          'WARNING: issue_url %s lacks required https://github.com/ prefix; skipping link\n' \
          "$issue_url" >&2
      else
        repo_part="${issue_url#https://github.com/}"
        repo="${repo_part%/issues/*}"
        child_id=$(gh api "repos/$repo/issues/$issue_num" \
          --jq '.id' 2>/dev/null) || true
        if [[ -n "$child_id" ]]; then
          gh api -X POST "repos/$repo/issues/$parent_num/sub_issues" \
            -F "sub_issue_id=$child_id" >/dev/null 2>&1 || \
            printf 'WARNING: failed to link #%s as sub-issue of #%s\n' \
              "$issue_num" "$parent_num" >&2
        else
          printf 'WARNING: could not fetch ID for issue #%s; skipping link\n' \
            "$issue_num" >&2
        fi
      fi
    fi
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
