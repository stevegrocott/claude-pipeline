#!/usr/bin/env bash
#
# issue-body-lib.sh - Validation helpers for pipeline issue bodies
#
# Sourceable library (no main()).  Exposes two public functions:
#
#   valid_agents
#       Prints the set of known agent names — one per line, sorted and
#       unique — derived from the .claude/agents/*.md definitions.
#
#   assert_issue_valid <body>
#       Validates an issue body string against six structural criteria:
#         1. at least one parseable (open) task line
#         2. every task agent resolves to a known agent (or "default")
#         3. every file path referenced in a task resolves (file exists or
#            its parent directory exists)
#         4. an "## Acceptance Criteria" section is present
#         5. a "## Deploy Verification" section exists if and only if
#            DEPLOY_VERIFY_CMD is set
#       Returns 0 when valid; prints one diagnostic per failure to stderr
#       and returns 1 otherwise.
#
# Configuration (environment overrides, mainly for testing):
#   ISSUE_BODY_AGENTS_DIR   agents directory (default: <lib>/../agents)
#   ISSUE_BODY_REPO_ROOT    repo root for path resolution (default: .)
#   DEPLOY_VERIFY_CMD       deploy verification gate (see criterion 5)
#
# Task-parsing, agent-normalization, and path-extraction logic is extracted
# from implement-issue-orchestrator.sh:
#   _normalize_agent_name          (legacy remap + .md resolution)
#   _extract_task_files_from_desc  (path token extraction)
#

# Idempotent source guard — re-sourcing is a no-op so readonly constants and
# repeated `source` calls never error.
[[ -n "${_ISSUE_BODY_LIB_SOURCED:-}" ]] && return 0
_ISSUE_BODY_LIB_SOURCED=1

# Known file extensions used to qualify bare filename tokens — mirrors
# KNOWN_FILE_EXTENSIONS in the orchestrator (version strings, domains, etc.
# are excluded).
readonly ISSUE_BODY_KNOWN_EXTS='sh|bats|bash|ts|tsx|js|jsx|mjs|cjs|py|go|rb|rs|java|kt|swift|json|yaml|yml|toml|sql|md|css|html|tf'

# Resolve this library's own directory so the default agents dir can be
# located relative to it.
_issue_body_lib_dir() {
	local src="${BASH_SOURCE[0]}"
	local dir="${src%/*}"
	(cd "$dir" 2>/dev/null && pwd)
}

#
# Maps a file path to the specialist agent best suited for that file type.
# Validates the candidate against ISSUE_BODY_AGENTS_DIR and degrades to
# "default" when no .md definition exists.
#
# Arguments:
#   $1 - file path (empty string → returns "default")
# Outputs:
#   Validated agent name on stdout (always a defined agent or "default")
#
_infer_agent_from_path() {
	local file_path="${1:-}"

	if [[ -z "$file_path" ]]; then
		printf '%s' "default"
		return
	fi

	# Strip :line/:function suffix (e.g. "file.sh:330-334" → "file.sh") before
	# extracting the extension — callers commonly pass File:Line references.
	local bare_path="${file_path%%:*}"
	local ext="${bare_path##*.}"
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

#
# Prints the known agent names — one per line, sorted-unique — derived from
# the .claude/agents/*.md definitions.
#
valid_agents() {
	local agents_dir="${ISSUE_BODY_AGENTS_DIR:-$(_issue_body_lib_dir)/../agents}"
	local file name

	for file in "$agents_dir"/*.md; do
		[[ -f "$file" ]] || continue
		name="${file##*/}"
		name="${name%.md}"
		printf '%s\n' "$name"
	done | sort -u
}

#
# Applies legacy→current agent-name remapping (mirrors the orchestrator's
# _normalize_agent_name allowlist).  Never deletes old entries so historical
# issue bodies keep parsing cleanly.
#
# Arguments:
#   $1 - raw agent name
# Outputs:
#   Remapped agent name on stdout
#
_issue_body_remap_agent() {
	local name="$1"
	case "$name" in
		test-engineer) name="playwright-test-developer" ;;
	esac
	printf '%s' "$name"
}

#
# Extracts candidate file paths from a task description (mirrors the
# orchestrator's _extract_task_files_from_desc).
#
# Arguments:
#   $1 - task description string
# Outputs:
#   Newline-separated, sorted-unique file paths (empty if none found)
#
_issue_body_extract_paths() {
	local desc="$1"
	local grep_pat
	# Only backtick-quoted tokens are treated as paths.  Bare tokens are
	# deliberately NOT matched: free-text like "fix input/output handling"
	# would otherwise be read as the path "input/output", fail validation,
	# and silently drop a legitimate follow-up.  Real follow-up bodies always
	# wrap file paths in backticks, so this loses no genuine paths.
	# Qualify only when path-like ('/') or extension-bearing.
	# Literal backticks below are markdown delimiters, not substitution.
	# shellcheck disable=SC2016
	grep_pat='`[a-zA-Z0-9_.-]*/[a-zA-Z0-9_./-]+`'
	grep_pat+='|`[a-zA-Z0-9_.-]+\.'"($ISSUE_BODY_KNOWN_EXTS)"'`'
	printf '%s' "$desc" \
		| grep -oE "$grep_pat" \
		| sed 's/`//g' \
		| sort -u
}

#
# Parses open task lines from an issue body, emitting one
# "agent<TAB>description" record per task (mirrors the canonical and
# fallback patterns of the orchestrator's _parse_task_lines).  Checked [x]
# tasks are treated as complete and skipped.
#
# Only lines inside the "## Implementation Tasks" section are matched —
# see the in-function section-extraction loop below.
#
# Caller audit (confirmed no dependency on whole-body parsing):
#   assert_issue_valid() [issue-body-lib.sh:292]
#       Passes the full issue body but consumes only the section-scoped
#       output.  It never relied on task lines from other sections.
#   BATS tests [implement-issue-test/test-issue-body-lib.bats]
#       All invocations either supply a body that contains an
#       "## Implementation Tasks" heading, or explicitly assert that
#       section-less / out-of-section lines yield no output.  None
#       depend on the pre-scoping, whole-body-parsing behaviour.
#
# Arguments:
#   $1 - issue body text
# Outputs:
#   Tab-separated agent/description records on stdout
#
_issue_body_parse_tasks() {
	local body="$1"
	# Normalize gh API's backslash-escaped backticks.
	body="${body//\\\`/\`}"

	# Extract only the lines under "## Implementation Tasks", stopping at
	# the next "##" heading (or end of body).  Lines from other sections
	# (Acceptance Criteria, Notes, Deploy Verification, etc.) are never
	# matched as tasks, preventing false positives from prose that happens
	# to resemble a task line.
	local in_section=false
	local section=""
	local line
	while IFS= read -r line; do
		if [[ "$line" == "## Implementation Tasks" ]]; then
			in_section=true
			continue
		fi
		if $in_section; then
			# Any new level-2 heading ends the section.
			if [[ "$line" =~ ^##([[:space:]]|$) ]]; then
				break
			fi
			section+="${line}"$'\n'
		fi
	done <<< "$body"

	# No "## Implementation Tasks" heading found — emit nothing.
	$in_section || return 0

	# Backtick-bearing regex must live in a variable — bash cannot escape a
	# backtick inside an inline [[ =~ ]] pattern reliably.
	local bt='`'
	local re_bare_agent="^- (\[ \] )?${bt}([^${bt}]+)${bt} (.+)\$"

	local agent desc
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		[[ "$line" =~ \[x\] ]] && continue

		agent=""
		desc=""

		# Canonical:  - [ ] `[agent]` desc   OR   - `[agent]` desc
		if [[ "$line" =~ ^-\ (\[\ \]\ )?\`\[([^\]]+)\]\`\ (.+)$ ]]; then
			agent="${BASH_REMATCH[2]}"
			desc="${BASH_REMATCH[3]}"

		# Fallback 1: missing backticks — - [ ] [agent] desc
		elif [[ "$line" =~ ^-\ (\[\ \]\ )?\[([^\]\ ]+)\]\ (.+)$ ]]; then
			agent="${BASH_REMATCH[2]}"
			desc="${BASH_REMATCH[3]}"

		# Fallback 2: asterisk bullet — * [ ] `[agent]` desc
		elif [[ "$line" =~ ^\*\ (\[\ \]\ )?\`\[([^\]]+)\]\`\ (.+)$ ]]; then
			agent="${BASH_REMATCH[2]}"
			desc="${BASH_REMATCH[3]}"

		# Fallback 3: leading whitespace — <ws>- [ ] `[agent]` desc
		elif [[ "$line" =~ ^[[:space:]]+-\ (\[\ \]\ )?\`\[([^\]]+)\]\`\ (.+)$ ]]; then
			agent="${BASH_REMATCH[2]}"
			desc="${BASH_REMATCH[3]}"

		# Fallback 4: missing square brackets — - [ ] `agent` desc
		elif [[ "$line" =~ $re_bare_agent ]]; then
			agent="${BASH_REMATCH[2]}"
			desc="${BASH_REMATCH[3]}"

		else
			continue
		fi

		printf '%s\t%s\n' "$agent" "$desc"
	done <<< "$section"
}

#
# Validates an issue body against the six structural criteria.
#
# Arguments:
#   $1 - issue body text
# Outputs:
#   One diagnostic per failure on stderr
# Returns:
#   0 when valid, 1 otherwise
#
assert_issue_valid() {
	local body="$1"
	local repo_root="${ISSUE_BODY_REPO_ROOT:-.}"
	local -a errors=()

	local valid_set
	valid_set=$(valid_agents)

	local tasks
	tasks=$(_issue_body_parse_tasks "$body")

	# Criterion 1: at least one parseable open task.
	if [[ -z "$tasks" ]]; then
		errors+=("no parseable task lines found")
	fi

	# Criteria 2 & 3: agents resolve and path suffixes resolve.
	local agent desc remapped path parent
	while IFS=$'\t' read -r agent desc; do
		[[ -z "$agent" ]] && continue

		# Criterion 2: agent resolves to a known agent or "default".
		remapped=$(_issue_body_remap_agent "$agent")
		if [[ "$remapped" != "default" ]] \
			&& ! grep -qxF "$remapped" <<< "$valid_set"; then
			errors+=("unknown agent: $agent")
		fi

		# Criterion 3: every referenced path resolves.
		while IFS= read -r path; do
			[[ -z "$path" ]] && continue
			if [[ "$path" == */* ]]; then
				parent="${path%/*}"
			else
				parent="."
			fi
			if [[ ! -e "$repo_root/$path" \
				&& ! -d "$repo_root/$parent" ]]; then
				errors+=("unresolved path: $path")
			fi
		done < <(_issue_body_extract_paths "$desc")
	done <<< "$tasks"

	# Criterion 4: Acceptance Criteria section present.
	if ! grep -q '^## Acceptance Criteria' <<< "$body"; then
		errors+=("missing '## Acceptance Criteria' section")
	fi

	# Criterion 5: Deploy Verification iff DEPLOY_VERIFY_CMD set.
	local has_deploy=false
	if grep -q '^## Deploy Verification' <<< "$body"; then
		has_deploy=true
	fi
	if [[ -n "${DEPLOY_VERIFY_CMD:-}" ]]; then
		if [[ "$has_deploy" == false ]]; then
			errors+=("DEPLOY_VERIFY_CMD set but no '## Deploy Verification' section")
		fi
	elif [[ "$has_deploy" == true ]]; then
		errors+=("'## Deploy Verification' section present but DEPLOY_VERIFY_CMD unset")
	fi

	if ((${#errors[@]} > 0)); then
		local err
		for err in "${errors[@]}"; do
			printf 'assert_issue_valid: %s\n' "$err" >&2
		done
		return 1
	fi

	return 0
}
