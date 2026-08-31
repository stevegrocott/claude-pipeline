#!/bin/bash
# Usage: read-issue.sh <issue-number-or-key>
# Returns: JSON { title, body, status }
# Body is always returned as plain markdown text.
#
# On GitHub the payload additionally carries the staleness fields consumed by
# the orchestrator's parse-issue guard (issue #846):
#   bodyUpdatedAt             when the BODY was last edited
#   latestHumanCommentAt      newest non-pipeline comment, or null
#   latestHumanCommentAuthor  its author's login, or null
#   latestHumanCommentUrl     a link to it, or null
# Comment PROSE is deliberately never returned: the guard only reports that a
# discrepancy exists, and nothing in the pipeline may parse comment content as
# tasks or acceptance criteria.
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

ISSUE="$1"

# -----------------------------------------------------------------------------
# Pipeline-comment classifier (issue #846)
#
# Authorship cannot separate generated comments from human ones: the pipeline
# posts under the operator's own `gh` credentials, so every comment on an issue
# shares one author. Two structural markers do work, and a comment matching
# EITHER is treated as pipeline-generated:
#
#   1. The attribution line comment_issue() stamps on every comment it posts
#      ("###### *Written by `<agent>`*" / "###### *Posted by
#      `implement-issue-orchestrator`*"). This covers every stage comment
#      regardless of its heading, including the ones whose headings carry
#      run-time suffixes ("Test Loop: Results (1/2)", "Task 3 Complete").
#   2. A known "## <Stage>" heading at the start of a line. This is the only
#      thing that classifies comments posted outside comment_issue() — notably
#      the process-pr skill's "## Completed", which has no attribution line.
#
# Both patterns are line-anchored via (^|\n) rather than a bare ^: jq's regex
# engine anchors ^ to the START OF THE STRING only (neither the "m" nor "s"
# flag changes that), so a bare ^ would only ever match a comment's first line
# and would miss the attribution on line 2. Anchoring also keeps a human
# comment that QUOTES a heading mid-sentence from being misread as generated.
#
# Anything matching neither marker is treated as human discussion. A false
# "human" reading costs a spurious warning; a false "pipeline" reading loses
# the signal entirely — so the heading list stays specific rather than broad.
# -----------------------------------------------------------------------------
PIPELINE_ATTRIBUTION_RE='(^|\n)###### *\*(Written|Posted) by '
PIPELINE_HEADING_RE='(^|\n)## +('
PIPELINE_HEADING_RE+='Acceptance Test'
PIPELINE_HEADING_RE+='|Already Implemented'
PIPELINE_HEADING_RE+='|Completed'
PIPELINE_HEADING_RE+='|Config-Only Changes Detected'
PIPELINE_HEADING_RE+='|Deploy Verify'
PIPELINE_HEADING_RE+='|Docs Stage'
PIPELINE_HEADING_RE+='|E2E '
PIPELINE_HEADING_RE+='|Full-Suite '
PIPELINE_HEADING_RE+='|Implementation Complete'
PIPELINE_HEADING_RE+='|Implementation Failed'
PIPELINE_HEADING_RE+='|Implementation Plan Confirmed'
PIPELINE_HEADING_RE+='|Implementation:'
PIPELINE_HEADING_RE+='|Merge:'
PIPELINE_HEADING_RE+='|NAS Pre-Merge Build'
PIPELINE_HEADING_RE+='|PR Review'
PIPELINE_HEADING_RE+='|Quality Loop'
PIPELINE_HEADING_RE+='|Resuming Automated Processing'
PIPELINE_HEADING_RE+='|Starting Automated Processing'
PIPELINE_HEADING_RE+='|Task [0-9]+ Complete'
PIPELINE_HEADING_RE+='|Test Loop'
PIPELINE_HEADING_RE+=')'

# The GraphQL projection. `lastEditedAt` is the reason this path exists at all:
# an issue's REST/`gh issue view` `updatedAt` is bumped by every COMMENT, so it
# cannot tell "the body was edited last" from "someone commented last" and a
# guard built on it would never fire. `lastEditedAt` is the body's own edit
# timestamp, and is null until the body is first edited (hence the createdAt
# fallback below). comments(last:100) takes the NEWEST hundred, which is the
# window a "newest human comment" question actually needs.
read -r -d '' ISSUE_GRAPHQL_QUERY <<'GRAPHQL' || true
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    issue(number: $number) {
      title
      body
      state
      createdAt
      lastEditedAt
      comments(last: 100) {
        nodes {
          createdAt
          url
          body
          author { login }
        }
      }
    }
  }
}
GRAPHQL

read -r -d '' ISSUE_GRAPHQL_JQ <<'JQ' || true
def is_pipeline_comment:
	(.body // "")
	| test($attribution) or test($heading);

.data.repository.issue
| select(. != null)
| . as $issue
| ($issue.comments.nodes // []
	| map(select(is_pipeline_comment | not))
	| sort_by(.createdAt)
	| last) as $human
| {
	title: $issue.title,
	body: $issue.body,
	status: $issue.state,
	bodyUpdatedAt: ($issue.lastEditedAt // $issue.createdAt),
	latestHumanCommentAt: ($human.createdAt // null),
	latestHumanCommentAuthor: ($human.author.login // null),
	latestHumanCommentUrl: ($human.url // null)
}
JQ

# Emits the enriched GitHub payload, or nothing when the staleness fetch is
# unavailable. Callers fall back to the plain `gh issue view` read.
#
# Only a bare issue NUMBER is eligible: `gh issue view` also accepts URLs and
# cross-repo references, whereas the GraphQL query is pinned to the current
# repository via gh's {owner}/{repo} placeholders. Anything else takes the
# fallback rather than silently querying the wrong repository.
read_github_issue_with_staleness() {
    local issue="$1"

    [[ "$issue" =~ ^[0-9]+$ ]] || return 1

    local response
    response=$(gh api graphql \
        -F owner='{owner}' -F name='{repo}' -F number="$issue" \
        -f query="$ISSUE_GRAPHQL_QUERY" 2>/dev/null) || return 1
    [[ -n "$response" ]] || return 1

    local payload
    payload=$(printf '%s' "$response" | jq \
        --arg attribution "$PIPELINE_ATTRIBUTION_RE" \
        --arg heading "$PIPELINE_HEADING_RE" \
        "$ISSUE_GRAPHQL_JQ" 2>/dev/null) || return 1
    [[ -n "$payload" ]] || return 1

    printf '%s\n' "$payload"
}

case "$TRACKER" in
  github)
    # ONE tracker fetch either way (issue #846 AC4): the staleness read
    # REPLACES the legacy `gh issue view` call rather than adding to it. The
    # fallback only runs when the enriched read produced nothing at all — a
    # non-numeric reference, an older GitHub Enterprise without the field, or
    # a transient API failure — and yields the original { title, body, status }
    # shape, which simply carries no timestamps and so never warns.
    read_github_issue_with_staleness "$ISSUE" \
      || gh issue view "$ISSUE" --json title,body,state \
        | jq '{ title, body, status: .state }'
    ;;
  jira)
    # acli returns description as ADF (Atlassian Document Format) JSON.
    # Pipe through adf-to-markdown.py to convert to { title, body, status }.
    # No staleness fields: the guard stays silent for Jira rather than
    # guessing (issue #846).
    acli jira workitem view "$ISSUE" --fields summary,description,status --json 2>/dev/null \
      | python3 "$SCRIPT_DIR/adf-to-markdown.py"
    ;;
esac
