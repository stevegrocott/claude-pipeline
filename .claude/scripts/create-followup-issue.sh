#!/usr/bin/env bash
#
# create-followup-issue.sh — deterministic follow-up issue body generator
#
# Emits a complete, validated issue body on stdout.
# Calls assert_issue_valid fail-closed: exits non-zero without printing
# anything when the generated body fails validation.
#
# Usage:
#   create-followup-issue.sh --title TITLE --description DESC
#       --file-path FILE_PATH --pr-number PR_NUM
#       --issue-number ISSUE_NUM --reviewer REVIEWER
#       [--task-description TASK_DESC] [--labels LABELS]
#       [--type precise|vague]
#
# Environment:
#   DEPLOY_VERIFY_CMD       When set, appends a ## Deploy Verification section.
#   FRONTEND_PATH_PATTERNS  Pipe-separated glob patterns (from platform.sh)
#                           used to disambiguate TS/JS frontend vs backend.
#   ISSUE_BODY_AGENTS_DIR   Override agents directory (testing/portability).
#   ISSUE_BODY_REPO_ROOT    Override repo root for path resolution (default: .).
#
# Exit codes:
#   0 — valid body written to stdout
#   1 — body failed assert_issue_valid (diagnostics on stderr; nothing on stdout)
#   3 — missing required argument
#

set -o pipefail

readonly SCRIPT_NAME="${0##*/}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly SCRIPT_DIR

# Source the shared validator — exposes assert_issue_valid + valid_agents.
# shellcheck source=issue-body-lib.sh
source "${SCRIPT_DIR}/issue-body-lib.sh"

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

die() {
	printf '%s: error: %s\n' "$SCRIPT_NAME" "$*" >&2
	exit 3
}

# Mirrors implement-issue-orchestrator.sh:_infer_agent_from_path (L3422).
# Maps common file extensions to specialist agents; validates the candidate
# against ISSUE_BODY_AGENTS_DIR and degrades to "default" when no .md
# definition exists — guaranteeing graceful degradation on any consumer project.
#
# Arguments:
#   $1 - file path (empty string → returns "default")
# Outputs:
#   Validated agent name on stdout (always a defined agent or "default")
_infer_agent_from_path() {
	local file_path="${1:-}"

	if [[ -z "$file_path" ]]; then
		printf '%s' "default"
		return
	fi

	local ext="${file_path##*.}"
	local candidate

	case "$ext" in
		sh|bats|bash)
			candidate="bash-script-craftsman"
			;;
		ts|tsx|js|jsx|mjs|cjs)
			# Disambiguate frontend vs backend via FRONTEND_PATH_PATTERNS
			# (pipe-separated globs from platform.sh).
			#   Patterns set + path matches → react-frontend-developer
			#   Patterns set + no match     → fastify-backend-developer
			#   Patterns unset              → ambiguous → default
			if [[ -n "${FRONTEND_PATH_PATTERNS:-}" ]]; then
				local pattern
				local IFS='|'
				for pattern in ${FRONTEND_PATH_PATTERNS}; do
					# shellcheck disable=SC2254
					case "$file_path" in
						$pattern)
							candidate="react-frontend-developer"
							break
							;;
					esac
				done
				candidate="${candidate:-fastify-backend-developer}"
			else
				candidate="default"
			fi
			;;
		*)
			candidate="default"
			;;
	esac

	# "default" is always valid — no .md definition required.
	if [[ "$candidate" == "default" ]]; then
		printf '%s' "default"
		return
	fi

	# Degrade to "default" when the inferred agent has no local .md definition.
	local agents_dir
	agents_dir="${ISSUE_BODY_AGENTS_DIR:-$(_issue_body_lib_dir)/../agents}"
	if [[ ! -f "${agents_dir}/${candidate}.md" ]]; then
		candidate="default"
	fi

	printf '%s' "$candidate"
}

# Appends the ## References block to the body being assembled.
# Writes to stdout.
_references_block() {
	local pr_num="$1"
	local issue_num="$2"
	local rev="$3"

	printf '\n## References\n'
	printf '%s\n' "- Parent Issue: #${issue_num}"
	printf '%s\n' "- PR/MR: #${pr_num}"
	printf '%s\n' "- Reviewer: @${rev}"
}

# Appends ## Deploy Verification iff DEPLOY_VERIFY_CMD is set.
# Writes to stdout (nothing written when DEPLOY_VERIFY_CMD is unset).
_deploy_verification_block() {
	[[ -z "${DEPLOY_VERIFY_CMD:-}" ]] && return

	printf '\n## Deploy Verification\n'
	# Backticks below are markdown delimiters, not command substitution.
	# shellcheck disable=SC2016
	printf '\n**Verification command:** `%s`\n' "$DEPLOY_VERIFY_CMD"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

title=""
description=""
task_description=""
file_path=""
pr_number=""
issue_number=""
reviewer=""
labels=""
type="precise"

while [[ $# -gt 0 ]]; do
	case "$1" in
		--title)
			title="$2"
			shift 2
			;;
		--description)
			description="$2"
			shift 2
			;;
		--task-description)
			task_description="$2"
			shift 2
			;;
		--file-path)
			file_path="$2"
			shift 2
			;;
		--pr-number)
			pr_number="$2"
			shift 2
			;;
		--issue-number)
			issue_number="$2"
			shift 2
			;;
		--reviewer)
			reviewer="$2"
			shift 2
			;;
		--labels)
			# Accepted for CLI parity with the platform creator, but
			# labels are applied at issue-creation time — never in the
			# body — so this body generator deliberately ignores it.
			# shellcheck disable=SC2034
			labels="$2"
			shift 2
			;;
		--type)
			type="$2"
			shift 2
			;;
		--)
			shift
			break
			;;
		-*)
			printf '%s: unknown option: %s\n' "$SCRIPT_NAME" "$1" >&2
			exit 3
			;;
		*)
			break
			;;
	esac
done

[[ -n "$title" ]]        || die "--title is required"
[[ -n "$description" ]]  || die "--description is required"
[[ -n "$file_path" ]]    || die "--file-path is required"
[[ -n "$pr_number" ]]    || die "--pr-number is required"
[[ -n "$issue_number" ]] || die "--issue-number is required"
[[ -n "$reviewer" ]]     || die "--reviewer is required"

# ---------------------------------------------------------------------------
# Agent inference
# ---------------------------------------------------------------------------

agent=$(_infer_agent_from_path "$file_path")

# ---------------------------------------------------------------------------
# Body construction — mirrors _build_adj_body (orchestrator L3611-3681)
# ---------------------------------------------------------------------------

# task_description falls back to title when not explicitly provided.
task_desc="${task_description:-$title}"

body=""

if [[ "$type" == "vague" ]]; then
	body+="<!-- pipeline-autocreated -->"$'\n'
	body+="## Context"$'\n'
	body+="Created from code review of PR/MR #${pr_number}"
	body+=" (Issue #${issue_number})"$'\n'
	body+=$'\n'
	body+="## Description"$'\n'
	body+="${description}"$'\n'
	body+=$'\n'
	body+="> **Note:** This item was classified as vague and needs further"$'\n'
	body+="> research before implementation. A human or automated explore"$'\n'
	body+="> sweep should flesh out the implementation tasks."$'\n'
	body+=$'\n'
	body+="## Implementation Tasks"$'\n'
	body+=$'\n'
	body+="- [ ] \`[${agent}]\` **(S)**"
	body+=" Explore and implement: ${title} — \`${file_path}\`"$'\n'
	body+=$'\n'
	body+="## Acceptance Criteria"$'\n'
	body+=$'\n'
	body+="- [ ] The behaviour described in \"${title}\" is observable"
	body+=" and testable (to be made precise during the explore phase)"$'\n'
	body+="- [ ] Tests covering the implemented change pass"$'\n'
else
	body+="<!-- pipeline-autocreated -->"$'\n'
	body+="## Context"$'\n'
	body+="Created from code review of PR/MR #${pr_number}"
	body+=" (Issue #${issue_number})"$'\n'
	body+=$'\n'
	body+="## Description"$'\n'
	body+="${description}"$'\n'
	body+=$'\n'
	body+="## Implementation Tasks"$'\n'
	body+=$'\n'
	body+="- [ ] \`[${agent}]\` **(M)**"
	body+=" ${task_desc} — \`${file_path}\`"$'\n'
	body+=$'\n'
	body+="## Acceptance Criteria"$'\n'
	body+=$'\n'
	body+="- [ ] \`${file_path}\`: ${task_desc}"
	body+=" produces the expected behaviour"$'\n'
	body+="- [ ] Tests covering the change in \`${file_path}\` pass"$'\n'
fi

body+=$(_references_block "$pr_number" "$issue_number" "$reviewer")
body+=$(_deploy_verification_block)

# ---------------------------------------------------------------------------
# Fail-closed validation — nothing is emitted when the body is invalid.
# assert_issue_valid writes diagnostics to stderr; we add a summary line
# and exit 1 without touching stdout.
# ---------------------------------------------------------------------------

if ! assert_issue_valid "$body"; then
	printf '%s: generated body failed validation — body not emitted\n' \
		"$SCRIPT_NAME" >&2
	exit 1
fi

printf '%s\n' "$body"
