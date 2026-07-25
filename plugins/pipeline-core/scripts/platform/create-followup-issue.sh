#!/bin/bash
# Usage: create-followup-issue.sh --title TITLE --description DESC
#          --task-description TASK_DESC --file-path FILE_PATH
#          --pr-number PR_NUM --issue-number ISSUE_NUM --reviewer REVIEWER
#          [--labels LABELS] [--type precise|vague]
#
# Delegates body construction (agent inference + fail-closed validation) to the
# shared generator at ../create-followup-issue.sh — the single source of truth
# for agent inference and assert_issue_valid — then deduplicates and creates the
# issue via create-issue.sh (which establishes the parent link through the
# GitHub sub-issues REST API).
#
# Returns: created issue number on stdout.
# Exits 1 on duplicate found or on a body that fails validation; 3 on a missing
# required argument or an unknown option.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

TITLE="" DESCRIPTION="" TASK_DESCRIPTION="" FILE_PATH=""
PR_NUMBER="" ISSUE_NUMBER="" REVIEWER="" LABELS="" TYPE="precise"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title)            TITLE="$2"; shift 2 ;;
    --description)      DESCRIPTION="$2"; shift 2 ;;
    --task-description) TASK_DESCRIPTION="$2"; shift 2 ;;
    --file-path)        FILE_PATH="$2"; shift 2 ;;
    --pr-number)        PR_NUMBER="$2"; shift 2 ;;
    --issue-number)     ISSUE_NUMBER="$2"; shift 2 ;;
    --reviewer)         REVIEWER="$2"; shift 2 ;;
    --labels)           LABELS="$2"; shift 2 ;;
    --type)             TYPE="$2"; shift 2 ;;
    --) shift; break ;;
    # Reject mistyped flags loudly instead of swallowing them (and their
    # value) — a swallowed flag surfaces later as a confusing "required" error.
    -*) echo "ERROR: unknown option: $1" >&2; exit 3 ;;
    *) shift ;;
  esac
done

for required in TITLE DESCRIPTION FILE_PATH PR_NUMBER ISSUE_NUMBER REVIEWER; do
  [[ -z "${!required}" ]] && { echo "ERROR: --$(echo "$required" | tr '[:upper:]' '[:lower:]' | tr '_' '-') is required" >&2; exit 3; }
done

# Deduplication check — skip if a similar open issue already exists
TITLE_LOWER=$(echo "$TITLE" | tr '[:upper:]' '[:lower:]')
EXISTING=$(gh issue list --search "$TITLE" --state open \
  --json number,title \
  | jq -r --arg t "$TITLE_LOWER" '.[] | select(.title | ascii_downcase | contains($t)) | .number' \
  | head -1)
if [[ -n "$EXISTING" ]]; then
  echo "Skipping duplicate: similar open issue already exists (#$EXISTING for \"$TITLE\")" >&2
  exit 1
fi

# Delegate body construction to the shared generator — the single source of
# agent inference and the home of assert_issue_valid.  It exits non-zero
# (printing nothing) when the body fails validation, so a bad body never
# reaches issue creation.
GENERATOR="$SCRIPT_DIR/../create-followup-issue.sh"
GEN_ARGS=(
  --title "$TITLE"
  --description "$DESCRIPTION"
  --file-path "$FILE_PATH"
  --pr-number "$PR_NUMBER"
  --issue-number "$ISSUE_NUMBER"
  --reviewer "$REVIEWER"
  --type "$TYPE"
)
[[ -n "$TASK_DESCRIPTION" ]] && GEN_ARGS+=(--task-description "$TASK_DESCRIPTION")

if ! BODY=$("$GENERATOR" "${GEN_ARGS[@]}"); then
  echo "ERROR: follow-up body failed validation; issue not created" >&2
  exit 1
fi

# Labels are applied at creation time, not in the body — vague items get the
# needs-explore label so an explore sweep picks them up.
if [[ "$TYPE" == "vague" ]]; then
  FINAL_LABELS="${LABELS:+$LABELS,}needs-explore"
else
  FINAL_LABELS="$LABELS"
fi

ARGS=(--title "$TITLE" --body "$BODY" --parent "#${ISSUE_NUMBER}")
[[ -n "$FINAL_LABELS" ]] && ARGS+=(--labels "$FINAL_LABELS")

"$SCRIPT_DIR/create-issue.sh" "${ARGS[@]}"
