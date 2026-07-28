#!/usr/bin/env bash
#
# issue-body-lib.sh - Validation helpers for pipeline issue bodies
#
# Sourceable library (no main()).  Exposes three public functions:
#
#   valid_agents
#       Prints the set of known agent names — one per line, sorted and
#       unique — derived from the .claude/agents/*.md definitions.
#
#   lint_task_lines <body>
#       Preflight lint for the "Implementation Tasks" section — emits one
#       "<cause>\t<line>" record (cause: format / agent-unresolved /
#       path-unresolved) per in-section line a parse would silently drop or
#       degrade.  Makes 0-task / mis-extracted parses loud and actionable.
#
#   assert_issue_valid <body>
#       Validates an issue body string against seven structural criteria:
#         1. at least one parseable (open) task line
#         2. every task agent resolves to a known agent (or "default")
#         3. every file path referenced in a task resolves (file exists or
#            its parent directory exists)
#         4. an "Acceptance Criteria" section is present (any heading depth)
#         5. a "Deploy Verification" section exists if and only if (any heading depth)
#            DEPLOY_VERIFY_CMD is set
#         6. task granularity — no M/L task references more than two distinct
#            file paths (decomposable tasks must be split into S sub-tasks)
#         7. every open task references at least one file path (a task with
#            zero path tokens is rejected — the #1 explore-stage token sink)
#       Additionally emits a non-failing stderr WARNING reporting the
#       M/L-vs-S task count whenever the body has any non-S task.
#       Returns 0 when valid; prints one diagnostic per failure to stderr
#       and returns 1 otherwise.
#
# Configuration (environment overrides, mainly for testing):
#   ISSUE_BODY_AGENTS_DIR   agents directory (default: resolve_consumer_dir
#                           agents — see resolve-pipeline-root.sh)
#   ISSUE_BODY_REPO_ROOT    repo root for path resolution (default: .)
#   DEPLOY_VERIFY_CMD       deploy verification gate (see criterion 5)
#
# Task-parsing, agent-normalization, and path-extraction logic is extracted
# from implement-issue-orchestrator.sh:
#   _normalize_agent_name          (legacy remap + .md resolution)
#   _extract_task_files_from_desc  (path token extraction)
#

# Bash-host guard (issue #601) — this library uses bash-only builtins (shopt,
# [[ =~ ]], BASH_SOURCE).  When sourced under a non-bash shell (e.g. zsh, the
# macOS default) it would otherwise emit spurious validation verdicts instead
# of erroring.  Fail fast with a clear message.  Kept POSIX-portable ([ ], not
# [[ ]]) so a non-bash shell parses it.
if [ -z "${BASH_VERSION:-}" ]; then
    printf '%s\n' "issue-body-lib.sh: requires bash (sourced under a non-bash shell)." >&2
    return 1 2>/dev/null || exit 1
fi

# Idempotent source guard — re-sourcing is a no-op so readonly constants and
# repeated `source` calls never error.
[[ -n "${_ISSUE_BODY_LIB_SOURCED:-}" ]] && return 0
_ISSUE_BODY_LIB_SOURCED=1

# Known file extensions used to qualify bare filename tokens — mirrors
# KNOWN_FILE_EXTENSIONS in the orchestrator (version strings, domains, etc.
# are excluded).
readonly ISSUE_BODY_KNOWN_EXTS='sh|bats|bash|ts|tsx|js|jsx|mjs|cjs|py|go|rb|rs|java|kt|swift|json|yaml|yml|toml|sql|md|css|html|tf'

# Canonical "Implementation Tasks" heading matcher (issue #584 parity) — the
# SINGLE source of truth for both library parsers, which both route section
# slicing through _issue_body_tasks_section.  Behaviour, applied IDENTICALLY at
# every mirror site:
#   * ERE, UNANCHORED at the tail — annotated headings such as
#     "## Implementation Tasks (draft)" are recognised (do NOT re-add a `$`).
#   * Case-insensitive — folded at the call site (bash: nocasematch; awk:
#     tolower($0); grep: -i).
#   * CRLF-tolerant — the caller strips carriage returns before matching.
# The orchestrator mirrors this exact behaviour via ISSUE_TASKS_HEADING_ERE in
# implement-issue-orchestrator.sh; a parity test (test-parser-parity.bats)
# guards the two against drift.
readonly ISSUE_BODY_TASKS_HEADING_RE='^##+[[:space:]]+Implementation Tasks'

# Resolve this library's own directory so the default agents dir can be
# located relative to it.
_issue_body_lib_dir() {
	local src="${BASH_SOURCE[0]}"
	local dir="${src%/*}"
	(cd "$dir" 2>/dev/null && pwd)
}

# Source resolve-pipeline-root.sh for resolve_consumer_dir() (issue #631 —
# the consumer's .claude/agents/ dir, not a never-shipped bundle-relative
# path). Idempotent via that library's own source guard, so this is a no-op
# when a caller (e.g. batch-orchestrator.sh) already sourced it first.
# shellcheck source=resolve-pipeline-root.sh
source "$(_issue_body_lib_dir)/resolve-pipeline-root.sh"

#
# Resolves the agents directory used for agent-name validation.
# ISSUE_BODY_AGENTS_DIR remains an explicit override; otherwise resolution
# defers to resolve_consumer_dir() (override → consumer repo root →
# bundle-relative legacy fallback — see resolve-pipeline-root.sh).
#
# Outputs:
#   Resolved agents directory path on stdout (empty on a total miss)
# Returns:
#   0 if a directory was resolved, 1 if none could be located
#
_issue_body_agents_dir() {
	if [[ -n "${ISSUE_BODY_AGENTS_DIR:-}" ]]; then
		printf '%s' "$ISSUE_BODY_AGENTS_DIR"
		return 0
	fi
	resolve_consumer_dir agents
}

#
# Reports whether the agents directory used above actually resolved to an
# existing directory. Lets callers (batch-orchestrator.sh) distinguish "the
# agents dir itself is unresolvable" from "the body names a genuinely
# unknown agent" when assert_issue_valid fails (issue #631 AC3).
#
# Returns:
#   0 if the agents directory resolved to an existing directory, 1 otherwise
#
issue_body_agents_dir_resolved() {
	local agents_dir
	agents_dir="$(_issue_body_agents_dir)"
	[[ -n "$agents_dir" && -d "$agents_dir" ]]
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
	agents_dir="$(_issue_body_agents_dir)"
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
	local agents_dir
	agents_dir="$(_issue_body_agents_dir)"
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
	# Qualify only when path-like ('/') or extension-bearing.  The char
	# classes admit bracket/paren/brace segments so Next.js App Router paths
	# ( `foo/[step]/page.tsx`, `app/(public)/login/page.tsx` ) are matched.
	# In each class `]` is first and `-` last so both are literal.
	# Literal backticks below are markdown delimiters, not substitution.
	# shellcheck disable=SC2016
	grep_pat='`[]a-zA-Z0-9_.(){}[-]*/[]a-zA-Z0-9_./(){}[-]+`'
	grep_pat+='|`[]a-zA-Z0-9_.(){}[-]+\.'"($ISSUE_BODY_KNOWN_EXTS)"'`'
	printf '%s' "$desc" \
		| grep -oE "$grep_pat" \
		| sed 's/`//g' \
		| sort -u
}

#
# Resolves an extracted token against the repo: true (0) if the token itself
# exists, or ANY ancestor directory exists.  Walking ancestors (not just the
# immediate parent) lets a new file in a not-yet-existing subdirectory validate
# so long as some ancestor is real (e.g. `app/api/register/route.ts` resolves
# when `app/api/` exists but `app/api/register/` does not yet).
#
# Arguments:
#   $1 - extracted path token
#   $2 - repo root
# Returns:
#   0 if the token or an ancestor directory exists, 1 otherwise
#
_issue_body_path_resolves() {
	local path="$1" repo_root="$2" parent
	[[ -e "$repo_root/$path" ]] && return 0
	parent="$path"
	while [[ "$parent" == */* ]]; do
		parent="${parent%/*}"
		[[ -z "$parent" ]] && break
		[[ -d "$repo_root/$parent" ]] && return 0
	done
	return 1
}

#
# Classifies an extracted token as a repo path (0) or prose (1).  A token
# counts as a repo path only if it bears a known file extension OR resolves on
# disk.  This demotes extension-less non-resolving tokens — HTTP routes like
# `/api/register` and bare `/word` tokens like `/login` — to prose, so they
# neither raise a false "unresolved path" error nor satisfy the ≥1-path
# requirement.  Extension-less real references (e.g. a `.claude/scripts/`
# directory) still count via the "resolves on disk" branch.
#
# Arguments:
#   $1 - extracted path token
#   $2 - repo root
# Returns:
#   0 if the token is a repo path, 1 if it is prose
#
_issue_body_is_repo_path() {
	local token="$1" repo_root="$2"
	[[ "$token" =~ \.(${ISSUE_BODY_KNOWN_EXTS})$ ]] && return 0
	_issue_body_path_resolves "$token" "$repo_root"
}

#
# Extracts the S/M/L complexity hint from a task description.  The hint is the
# first `**(S)**` / `**(M)**` / `**(L)**` marker (case-insensitive) in the
# description.  A description with no marker defaults to "M" — mirroring the
# orchestrator's hint-less default (implement-issue-orchestrator.sh:3834),
# which treats an unsized task as medium.
#
# Arguments:
#   $1 - task description string
# Outputs:
#   One of "S", "M", or "L" on stdout
#
_issue_body_task_complexity() {
	local desc="$1"
	local hint="M"
	if [[ "$desc" =~ \*\*\(([SsMmLl])\)\*\* ]]; then
		hint="${BASH_REMATCH[1]}"
	fi
	# Normalize to uppercase without relying on bash-4 case conversion.
	case "$hint" in
		s) hint="S" ;;
		m) hint="M" ;;
		l) hint="L" ;;
	esac
	printf '%s' "$hint"
}

#
# Counts the distinct file paths referenced in a task description for the
# granularity criterion.  The canonical Task Format appends an optional
# ":Lnn"/":nn-mm" line-range suffix to each backtick-quoted path
# (e.g. `src/app.ts:L45-80`).  `_issue_body_extract_paths` cannot match those
# tokens because its path char-class excludes ':', so the suffix is stripped
# here first — this also collapses `file.ts:L10` and `file.ts:L90` to a single
# distinct path, matching the "distinct file paths" intent.
#
# Arguments:
#   $1 - task description string
#   $2 - repo root (optional).  When given, only tokens that classify as repo
#        paths (known extension OR resolve on disk) are counted, so prose
#        tokens like `/api/register` or `/login` do not satisfy the ≥1-path
#        requirement.  When omitted, every extracted token is counted (legacy
#        behaviour for callers with no repo context).
# Outputs:
#   Distinct path count (integer) on stdout
#
_issue_body_task_path_count() {
	local desc="$1"
	local repo_root="${2:-}"
	local stripped path count=0
	stripped=$(printf '%s' "$desc" \
		| sed -E 's/(`[]A-Za-z0-9_./(){}[-]+):[A-Za-z0-9_.,-]*(`)/\1\2/g')
	while IFS= read -r path; do
		[[ -z "$path" ]] && continue
		if [[ -n "$repo_root" ]]; then
			_issue_body_is_repo_path "$path" "$repo_root" || continue
		fi
		count=$((count + 1))
	done < <(_issue_body_extract_paths "$stripped")
	printf '%s' "$count"
}

#
# Parses open task lines from an issue body, emitting one
# "agent<TAB>description" record per task (mirrors the canonical and
# fallback patterns of the orchestrator's _parse_task_lines).  Checked [x]
# tasks are treated as complete and skipped.
#
# Only lines inside an "Implementation Tasks" heading section are matched
# (any heading level: ##, ###, etc.) — see the in-function
# section-extraction loop below.  The section ends at the next heading of
# any level (## or deeper).
#
# Caller audit (confirmed no dependency on whole-body parsing):
#   assert_issue_valid() [issue-body-lib.sh:292]
#       Passes the full issue body but consumes only the section-scoped
#       output.  It never relied on task lines from other sections.
#   BATS tests [implement-issue-test/test-issue-body-lib.bats]
#       All invocations either supply a body that contains an
#       "Implementation Tasks" heading, or explicitly assert that
#       section-less / out-of-section lines yield no output.  None
#       depend on the pre-scoping, whole-body-parsing behaviour.
#
# Arguments:
#   $1 - issue body text
# Outputs:
#   Tab-separated agent/description records on stdout
#
#
# Extracts the raw text of the "Implementation Tasks" section from an issue
# body — the single source of truth for section slicing shared by
# _issue_body_parse_tasks and lint_task_lines so the two stay behaviourally
# identical.
#
# Hardening (issue #584):
#   * CRLF tolerance — strips carriage returns first so a Windows/gh CRLF
#     body cannot leak "\r" into descriptions or defeat the $-anchored
#     task regexes (the heading matcher is deliberately UNANCHORED — see
#     ISSUE_BODY_TASKS_HEADING_RE — so annotated headings still match).
#   * Case-insensitive heading — matches "## Implementation Tasks",
#     "## implementation tasks", etc. via a locally-scoped nocasematch
#     (bash-3.2-safe; ${x,,} is deliberately avoided elsewhere in this lib).
#
# The section spans from the "Implementation Tasks" heading (any depth:
# ##, ###, …) up to the next ## or deeper heading (or end of body).
#
# Arguments:
#   $1 - issue body text
# Outputs:
#   Section text on stdout (may be empty when the section has no lines)
# Returns:
#   0 when an "Implementation Tasks" heading was found, 1 otherwise
#
_issue_body_tasks_section() {
	local body="$1"
	# Strip carriage returns so CRLF bodies parse identically to LF bodies.
	body="${body//$'\r'/}"
	# Normalize gh API's backslash-escaped backticks.
	body="${body//\\\`/\`}"

	# Case-insensitive heading match — save/restore nocasematch so callers
	# are unaffected.  Only the heading detection needs it; the task-line
	# regexes below run case-sensitively (agent names, [x] markers).
	local _ci_saved
	_ci_saved=$(shopt -p nocasematch)
	shopt -s nocasematch

	local in_section=false
	local section=""
	local line
	while IFS= read -r line; do
		if [[ "$line" =~ $ISSUE_BODY_TASKS_HEADING_RE ]]; then
			in_section=true
			continue
		fi
		if $in_section; then
			# Any new ## or deeper heading ends the section.
			if [[ "$line" =~ ^##+[[:space:]] ]]; then
				break
			fi
			section+="${line}"$'\n'
		fi
	done <<< "$body"

	eval "$_ci_saved"

	$in_section || return 1
	printf '%s' "$section"
	return 0
}

_issue_body_parse_tasks() {
	local body="$1"

	# Extract only the lines under "Implementation Tasks" (any heading
	# level: ##, ###, etc.), stopping at the next ## or deeper heading (or
	# end of body).  Lines from other sections
	# (Acceptance Criteria, Notes, Deploy Verification, etc.) are never
	# matched as tasks, preventing false positives from prose that happens
	# to resemble a task line.  No "Implementation Tasks" heading (any
	# depth) — emit nothing.
	local section
	section=$(_issue_body_tasks_section "$body") || return 0

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
# Preflight lint for the "Implementation Tasks" section (issue #584).
#
# Emits one tab-separated rejection record — "<cause>\t<line>" — for every
# in-section candidate line that a downstream parse would silently drop or
# silently degrade.  This makes the failure classes the mirrored parsers hide
# LOUD and actionable:
#
#   format            the line matches no task pattern (canonical or any of
#                     the four fuzzy fallbacks) — e.g. a prose "Task 1: …"
#                     line or a bullet with neither backticks nor brackets.
#                     _parse_task_lines / _issue_body_parse_tasks would
#                     `continue` past it with no diagnostic.
#   agent-unresolved  the line parses, but its agent name resolves to neither
#                     a known agent nor "default" — the parser would silently
#                     degrade it to "default".
#   path-unresolved   the line parses, but a backtick-quoted file path it
#                     references neither exists nor has an existing parent
#                     directory (mirrors assert_issue_valid criterion 3).
#
# Well-formed tasks emit nothing.  Blank lines, checked [x] tasks, and
# "Affected files:" continuation lines are skipped (never candidates).  One
# record per line, cause priority: format > agent-unresolved > path-unresolved.
#
# Section slicing (CRLF tolerance + case-insensitive heading) is shared with
# _issue_body_parse_tasks via _issue_body_tasks_section, so the lint sees
# exactly the lines the parser would.
#
# Arguments:
#   $1 - issue body text
# Outputs:
#   Zero or more "<cause>\t<line>" records on stdout
# Returns:
#   0 always (a lint report is informational, not a failure signal)
#
lint_task_lines() {
	local body="$1"
	local repo_root="${ISSUE_BODY_REPO_ROOT:-.}"

	# No "Implementation Tasks" heading — nothing to lint.
	local section
	section=$(_issue_body_tasks_section "$body") || return 0

	local valid_set
	valid_set=$(valid_agents)

	local bt='`'
	local re_bare_agent="^- (\[ \] )?${bt}([^${bt}]+)${bt} (.+)\$"

	local line agent desc remapped path unresolved_path
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		# Checked [x] tasks are complete; the parser skips them, so does lint.
		[[ "$line" =~ \[x\] ]] && continue
		# "Affected files:" continuation lines are metadata, not candidates.
		[[ "$line" =~ ^[[:space:]]*[Aa]ffected[[:space:]][Ff]iles: ]] && continue

		agent=""
		desc=""

		# Same pattern ladder as _issue_body_parse_tasks — a line that matches
		# none of these is a format rejection.
		if [[ "$line" =~ ^-\ (\[\ \]\ )?\`\[([^\]]+)\]\`\ (.+)$ ]]; then
			agent="${BASH_REMATCH[2]}"
			desc="${BASH_REMATCH[3]}"
		elif [[ "$line" =~ ^-\ (\[\ \]\ )?\[([^\]\ ]+)\]\ (.+)$ ]]; then
			agent="${BASH_REMATCH[2]}"
			desc="${BASH_REMATCH[3]}"
		elif [[ "$line" =~ ^\*\ (\[\ \]\ )?\`\[([^\]]+)\]\`\ (.+)$ ]]; then
			agent="${BASH_REMATCH[2]}"
			desc="${BASH_REMATCH[3]}"
		elif [[ "$line" =~ ^[[:space:]]+-\ (\[\ \]\ )?\`\[([^\]]+)\]\`\ (.+)$ ]]; then
			agent="${BASH_REMATCH[2]}"
			desc="${BASH_REMATCH[3]}"
		elif [[ "$line" =~ $re_bare_agent ]]; then
			agent="${BASH_REMATCH[2]}"
			desc="${BASH_REMATCH[3]}"
		else
			printf 'format\t%s\n' "$line"
			continue
		fi

		# Criterion-2 mirror: agent must resolve to a known agent or "default".
		remapped=$(_issue_body_remap_agent "$agent")
		if [[ "$remapped" != "default" ]] \
			&& ! grep -qxF "$remapped" <<< "$valid_set"; then
			printf 'agent-unresolved\t%s\n' "$line"
			continue
		fi

		# Criterion-3 mirror: every referenced repo path must resolve.  Prose
		# tokens (extension-less and non-resolving, e.g. `/api/register`) are
		# skipped; resolution walks ancestor directories.
		unresolved_path=""
		while IFS= read -r path; do
			[[ -z "$path" ]] && continue
			_issue_body_is_repo_path "$path" "$repo_root" || continue
			if ! _issue_body_path_resolves "$path" "$repo_root"; then
				unresolved_path="$path"
				break
			fi
		done < <(_issue_body_extract_paths "$desc")

		if [[ -n "$unresolved_path" ]]; then
			printf 'path-unresolved\t%s\n' "$line"
			continue
		fi
	done <<< "$section"

	return 0
}

#
# Validates an issue body against the structural criteria.
#
# Hard criteria (any failure → stderr diagnostic + return 1):
#   1. at least one parseable open task line
#   2. every task agent resolves to a known agent (or "default")
#   3. every referenced file path resolves (file exists or parent dir exists)
#   4. an "Acceptance Criteria" section is present
#   5. a "Deploy Verification" section iff DEPLOY_VERIFY_CMD is set
#   6. task granularity — no M/L task references more than two distinct file
#      paths (a decomposable task that should be split into S sub-tasks)
#   7. every open task references at least one file path — a task whose
#      description yields zero path tokens is rejected (the diagnostic names
#      the offending task).  Checked [x] tasks are exempt (the parser skips
#      them, so only OPEN tasks reach this gate)
#
# Soft advisory (never fails the body):
#   * emits a stderr WARNING reporting the M/L-vs-S task count whenever the
#     body contains at least one non-S task
#
# Arguments:
#   $1 - issue body text
# Outputs:
#   One diagnostic per hard failure, plus the optional task-mix warning, on
#   stderr
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

	# Criteria 2, 3, 6 & 7: agents resolve, path suffixes resolve, granularity,
	# and every open task carries at least one file path.
	local agent desc remapped path complexity path_count
	local -i s_count=0 nons_count=0
	while IFS=$'\t' read -r agent desc; do
		[[ -z "$agent" ]] && continue

		# Criterion 2: agent resolves to a known agent or "default".
		remapped=$(_issue_body_remap_agent "$agent")
		if [[ "$remapped" != "default" ]] \
			&& ! grep -qxF "$remapped" <<< "$valid_set"; then
			errors+=("unknown agent: $agent")
		fi

		# Criterion 3: every referenced repo path resolves.  A token counts as
		# a repo path only if it bears a known extension or resolves on disk;
		# extension-less non-resolving tokens (HTTP routes like /api/register,
		# bare /word) are prose and are neither resolution-checked here nor
		# counted below.  Resolution walks ancestor directories, so a new file
		# in a new subdirectory validates when any ancestor exists.
		while IFS= read -r path; do
			[[ -z "$path" ]] && continue
			_issue_body_is_repo_path "$path" "$repo_root" || continue
			if ! _issue_body_path_resolves "$path" "$repo_root"; then
				errors+=("unresolved path: $path")
			fi
		done < <(_issue_body_extract_paths "$desc")

		# Distinct file-path count (":Lnn"-suffix aware — reuses #581's
		# _issue_body_task_path_count so a lone `file.ts:L10-40` still counts as
		# one path).  repo_root is passed so prose tokens do not satisfy the
		# ≥1-path requirement.  Computed once and shared by criteria 7 and 6.
		path_count=$(_issue_body_task_path_count "$desc" "$repo_root")

		# Criterion 7: every open task must reference at least one file path.
		# A task with zero path tokens forces the implement stage to scan the
		# codebase blind — the #1 token sink the explore skill warns about.
		# The parser already skips checked [x] tasks, so only OPEN tasks are
		# gated here; the diagnostic names the offending task.
		if (( path_count == 0 )); then
			errors+=("task has no file path: ${desc}")
		fi

		# Criterion 6: task granularity.  Tally the S/non-S mix for the
		# advisory warning, and hard-fail any M/L task that names more than
		# two distinct file paths — a decomposable task the explore step
		# should have split into S sub-tasks.
		complexity=$(_issue_body_task_complexity "$desc")
		if [[ "$complexity" == "S" ]]; then
			s_count=$((s_count + 1))
		else
			nons_count=$((nons_count + 1))
			if (( path_count > 2 )); then
				errors+=("task granularity: (${complexity}) task references ${path_count} distinct file paths (>2); split into S sub-tasks — ${desc}")
			fi
		fi
	done <<< "$tasks"

	# Advisory (never fails the body): report the non-S task mix so operators
	# see the M/L-vs-S balance and are nudged toward S-only decomposition.
	if (( nons_count > 0 )); then
		printf 'assert_issue_valid: WARNING: %d non-S task(s) (M/L) vs %d S task(s); prefer splitting M/L into S sub-tasks\n' \
			"$nons_count" "$s_count" >&2
	fi

	# Criterion 4: Acceptance Criteria section present.
	if ! grep -qE '^##+ Acceptance Criteria' <<< "$body"; then
		errors+=("missing 'Acceptance Criteria' section")
	fi

	# Criterion 5: Deploy Verification iff DEPLOY_VERIFY_CMD set.
	local has_deploy=false
	if grep -qE '^##+ Deploy Verification' <<< "$body"; then
		has_deploy=true
	fi
	if [[ -n "${DEPLOY_VERIFY_CMD:-}" ]]; then
		if [[ "$has_deploy" == false ]]; then
			errors+=("DEPLOY_VERIFY_CMD set but no 'Deploy Verification' section")
		fi
	elif [[ "$has_deploy" == true ]]; then
		errors+=("'Deploy Verification' section present but DEPLOY_VERIFY_CMD unset")
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
