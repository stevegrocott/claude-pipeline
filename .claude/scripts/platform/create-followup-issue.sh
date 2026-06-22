#!/bin/bash
# Usage: create-followup-issue.sh --title TITLE --description DESC
#          --task-description TASK_DESC --file-path FILE_PATH
#          --pr-number PR_NUM --issue-number ISSUE_NUM --reviewer REVIEWER
#          [--labels LABELS] [--type precise|vague]
# Infers $AGENT from $FILE_PATH, deduplicates, builds body template, creates issue.
# Returns: created issue number on stdout; exits 1 on duplicate found.
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
    *) shift ;;
  esac
done

for required in TITLE DESCRIPTION FILE_PATH PR_NUMBER ISSUE_NUMBER REVIEWER; do
  [[ -z "${!required}" ]] && { echo "ERROR: --$(echo "$required" | tr '[:upper:]' '[:lower:]' | tr '_' '-') is required" >&2; exit 3; }
done

# Derive $AGENT from $FILE_PATH
# | File pattern                      | $AGENT                   |
# |-----------------------------------|--------------------------|
# | *.sh, *.bash, *.bats              | bash-script-craftsman    |
# | *.test.*, *.spec.*                | test-engineer            |
# | .claude/skills/**/*.md            | default                  |
# | src/routes/**, src/api/**         | api-design-specialist    |
# | Fallback                          | default                  |
if [[ "$FILE_PATH" == *.sh || "$FILE_PATH" == *.bash || "$FILE_PATH" == *.bats ]]; then
  AGENT="bash-script-craftsman"
elif [[ "$FILE_PATH" == *.test.* || "$FILE_PATH" == *.spec.* ]]; then
  AGENT="test-engineer"
elif [[ "$FILE_PATH" == .claude/skills/* && "$FILE_PATH" == *.md ]]; then
  AGENT="default"
elif [[ "$FILE_PATH" == src/routes/* || "$FILE_PATH" == src/api/* ]]; then
  AGENT="api-design-specialist"
else
  AGENT="default"
fi

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

# Build body and resolve labels based on type
if [[ "$TYPE" == "vague" ]]; then
  TASK_LINE="Explore and implement: ${TITLE} — \`${FILE_PATH}\`"
  BODY="<!-- pipeline-autocreated -->
## Context
Created from code review of PR/MR #${PR_NUMBER} (Issue #${ISSUE_NUMBER})

## Description
${DESCRIPTION}

> **Note:** This item was classified as vague and needs further research before implementation.
> A human or automated explore sweep should flesh out the implementation tasks.

## Implementation Tasks
- [ ] \`[${AGENT}]\` **(S)** ${TASK_LINE}

## Acceptance Criteria
- [ ] The behaviour described in \"${TITLE}\" is observable and testable (to be made precise during the explore phase)
- [ ] Tests covering the implemented change pass

## References
- Parent Issue: #${ISSUE_NUMBER}
- PR/MR: #${PR_NUMBER}
- Reviewer: @${REVIEWER}"
  FINAL_LABELS="${LABELS:+$LABELS,}needs-explore"
else
  TASK_DESC="${TASK_DESCRIPTION:-$TITLE}"
  BODY="<!-- pipeline-autocreated -->
## Context
Created from code review of PR/MR #${PR_NUMBER} (Issue #${ISSUE_NUMBER})

## Description
${DESCRIPTION}

## Implementation Tasks
- [ ] \`[${AGENT}]\` **(S)** ${TASK_DESC} — \`${FILE_PATH}\`

## Acceptance Criteria
- [ ] \`${FILE_PATH}\`: ${TASK_DESC} produces the expected behaviour (specify the exact output or observable state change)
- [ ] Tests covering the change in \`${FILE_PATH}\` pass

## References
- Parent Issue: #${ISSUE_NUMBER}
- PR/MR: #${PR_NUMBER}
- Reviewer: @${REVIEWER}"
  FINAL_LABELS="$LABELS"
fi

ARGS=(--title "$TITLE" --body "$BODY" --parent "#${ISSUE_NUMBER}")
[[ -n "$FINAL_LABELS" ]] && ARGS+=(--labels "$FINAL_LABELS")

"$SCRIPT_DIR/create-issue.sh" "${ARGS[@]}"
