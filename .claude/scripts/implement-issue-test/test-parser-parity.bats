#!/usr/bin/env bats
#
# test-parser-parity.bats
# Parity guard (issue #584) — proves the orchestrator's task extraction and the
# issue-body-lib.sh parsers stay behaviourally identical.  A SHARED set of
# fixtures is run through BOTH real code paths and asserted to agree:
#
#   Orchestrator path : _extract_tasks_section  ->  _parse_task_lines
#                       (implement-issue-orchestrator.sh, sourced via
#                        source_orchestrator_functions)
#   Library path      : _issue_body_tasks_section -> _issue_body_parse_tasks
#                       and lint_task_lines (issue-body-lib.sh)
#
# The two parsers intentionally differ in POST-processing (the orchestrator
# normalises agent names and injects a default **(M)** complexity hint), so
# parity is asserted on the behaviour that MUST match:
#   (A) section extraction is byte-identical
#   (B) the recognised task COUNT is identical
#   (C) the recognised task DESCRIPTIONS are identical
#       (fixtures carry explicit **(S)** hints so no **(M)** injection occurs)
#
# Fixtures cover: canonical heading, lowercase heading, CRLF line endings, an
# ANNOTATED heading ("## Implementation Tasks (draft)"), and a prose "Task N:"
# line in an otherwise-empty section.  The annotated-heading fixture is the
# regression: before the heading matcher was unified it diverged (the
# orchestrator's UNANCHORED awk found the section while the library's
# $-anchored regex did not), which silently disabled the per-line lint report.
#

bats_require_minimum_version 1.5.0

load 'helpers/test-helper.bash'

LIB_PATH="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)/issue-body-lib.sh"

setup() {
	setup_test_env

	# Required by log / log_error helpers sourced with the orchestrator.
	export ISSUE_NUMBER=99
	export BASE_BRANCH=main
	export LOG_BASE="$TEST_TMP/logs/test"
	export LOG_FILE="$LOG_BASE/orchestrator.log"
	export STAGE_COUNTER=0
	mkdir -p "$LOG_BASE"

	# Sandbox agents dir consulted by the library's valid_agents() (used by
	# lint_task_lines).  Keep it minimal — parity compares descriptions, not
	# agent resolution.
	export ISSUE_BODY_AGENTS_DIR="$TEST_TMP/agents"
	mkdir -p "$ISSUE_BODY_AGENTS_DIR"
	: > "$ISSUE_BODY_AGENTS_DIR/bash-script-craftsman.md"
	export ISSUE_BODY_REPO_ROOT="$TEST_TMP/repo"
	mkdir -p "$ISSUE_BODY_REPO_ROOT"

	source_orchestrator_functions
}

teardown() {
	teardown_test_env
}

# ---------------------------------------------------------------------------
# Real code-path shims (no hand-copied logic — every call reaches production).
# ---------------------------------------------------------------------------

# Orchestrator: exact PARSE ISSUE stage sequence.
_orch_section() { _extract_tasks_section "$1"; }
_orch_count()   { _parse_task_lines "$(_extract_tasks_section "$1")" 2>/dev/null | jq 'length'; }
_orch_descs()   { _parse_task_lines "$(_extract_tasks_section "$1")" 2>/dev/null | jq -r '.[].description'; }

# Library: run in a subshell so its helper defs never collide with the
# orchestrator's identically-named internals.
_lib_section() { ( source "$LIB_PATH"; _issue_body_tasks_section "$1" ); }
_lib_count()   { ( source "$LIB_PATH"; _issue_body_parse_tasks "$1" ) | grep -c . ; }
_lib_descs()   { ( source "$LIB_PATH"; _issue_body_parse_tasks "$1" ) | cut -f2- ; }
_lib_lint()    { ( source "$LIB_PATH"; lint_task_lines "$1" ); }

# Assert both parsers agree on section, count, and descriptions for one body.
assert_full_parity() {
	local label="$1" body="$2"
	local o_sec l_sec o_cnt l_cnt o_desc l_desc

	o_sec=$(_orch_section "$body"); l_sec=$(_lib_section "$body")
	[ "$o_sec" = "$l_sec" ] || \
		fail "[$label] section extraction diverged:
--- orchestrator ---
$o_sec
--- library ---
$l_sec"

	o_cnt=$(_orch_count "$body"); l_cnt=$(_lib_count "$body")
	[ "$o_cnt" = "$l_cnt" ] || \
		fail "[$label] task count diverged: orchestrator=$o_cnt library=$l_cnt"

	o_desc=$(_orch_descs "$body"); l_desc=$(_lib_descs "$body")
	[ "$o_desc" = "$l_desc" ] || \
		fail "[$label] task descriptions diverged:
--- orchestrator ---
$o_desc
--- library ---
$l_desc"
}

# ---------------------------------------------------------------------------
# Well-formed fixtures — both parsers must agree end to end.
# ---------------------------------------------------------------------------

@test "parity: canonical '## Implementation Tasks' heading" {
	local body
	body=$(printf '%s\n' \
		'## Implementation Tasks' \
		'' \
		'- [ ] `[bash-script-craftsman]` **(S)** Task one — `a.sh`' \
		'- [ ] `[bash-script-craftsman]` **(S)** Task two — `b.sh`' \
		'' \
		'## Acceptance Criteria' \
		'' \
		'- [ ] Something else')
	assert_full_parity "canonical" "$body"
	[ "$(_orch_count "$body")" -eq 2 ]
}

@test "parity: lowercase '## implementation tasks' heading" {
	local body
	body=$(printf '%s\n' \
		'## implementation tasks' \
		'' \
		'- [ ] `[bash-script-craftsman]` **(S)** Lowercase-heading task — `a.sh`')
	assert_full_parity "lowercase" "$body"
	[ "$(_orch_count "$body")" -eq 1 ]
}

@test "parity: CRLF line endings" {
	# Real Windows/gh CRLF body — carriage returns must not leak or defeat
	# either parser.
	local body
	body=$(printf '## Implementation Tasks\r\n\r\n- [ ] `[bash-script-craftsman]` **(S)** CRLF task — `a.sh`\r\n')
	assert_full_parity "crlf" "$body"
	[ "$(_orch_count "$body")" -eq 1 ]
	# The parsed description must be CR-free in both parsers.
	printf '%s' "$(_orch_descs "$body")" | grep -q $'\r' && \
		fail "orchestrator leaked CR into description"
	printf '%s' "$(_lib_descs "$body")" | grep -q $'\r' && \
		fail "library leaked CR into description"
	return 0
}

# ---------------------------------------------------------------------------
# Regression fixtures — the divergence issue #584's fix closes.
# ---------------------------------------------------------------------------

@test "parity: ANNOTATED heading '## Implementation Tasks (draft)' is recognised by BOTH parsers" {
	# Pre-fix RED: the orchestrator's unanchored awk matched this heading while
	# the library's $-anchored regex did not, so section extraction diverged and
	# lint_task_lines saw no section.  Post-fix GREEN: both find it.
	local body
	body=$(printf '%s\n' \
		'## Implementation Tasks (draft)' \
		'' \
		'- [ ] `[bash-script-craftsman]` **(S)** Annotated-heading task — `a.sh`')

	# Both must actually find a (non-empty) section — proves neither silently
	# missed the annotated heading.
	[ -n "$(_orch_section "$body")" ] || fail "orchestrator missed annotated heading"
	[ -n "$(_lib_section "$body")" ]  || fail "library missed annotated heading"

	assert_full_parity "annotated" "$body"
	[ "$(_orch_count "$body")" -eq 1 ]
}

@test "parity: annotated heading + prose 'Task N:' — sections agree and lint fires" {
	# The deliverable of issue #584: with a non-canonical heading and a
	# prose-only section, both parsers must agree (0 tasks, identical section)
	# AND the shared lint must report the un-parseable prose line.  Pre-fix the
	# library returned no section, lint was empty, and the run fell back to the
	# unhelpful raw-excerpt message.
	local body
	body=$(printf '%s\n' \
		'## Implementation Tasks (draft)' \
		'' \
		'Task 1: do a thing but this is prose, not a task line')

	# Sections identical and non-empty.
	local o_sec l_sec
	o_sec=$(_orch_section "$body"); l_sec=$(_lib_section "$body")
	[ -n "$o_sec" ] || fail "orchestrator missed annotated heading (prose case)"
	[ "$o_sec" = "$l_sec" ] || fail "section extraction diverged on prose case"

	# Neither parser recognises the prose line as a task.
	[ "$(_orch_count "$body")" -eq 0 ]
	[ "$(_lib_count "$body")" -eq 0 ]

	# The shared lint fires with an actionable per-line 'format' rejection.
	local lint
	lint=$(_lib_lint "$body")
	[ -n "$lint" ] || fail "lint_task_lines produced no report (regression: silent fallback)"
	printf '%s' "$lint" | grep -q $'^format\t' || \
		fail "lint did not classify the prose line as 'format': $lint"
	printf '%s' "$lint" | grep -q 'do a thing' || \
		fail "lint report missing the offending prose line: $lint"
}

# ---------------------------------------------------------------------------
# Direct heading-matcher parity — the single divergence issue #584 unifies.
# ---------------------------------------------------------------------------

@test "parity: section slicers agree byte-for-byte across all headings" {
	local h
	for h in '## Implementation Tasks' '### Implementation Tasks' \
		'## implementation tasks' '## Implementation Tasks (draft)' \
		'## IMPLEMENTATION TASKS'; do
		local body
		body=$(printf '%s\n\n- [ ] `[bash-script-craftsman]` **(S)** Task — `a.sh`\n' "$h")
		[ "$(_orch_section "$body")" = "$(_lib_section "$body")" ] || \
			fail "section slicers diverged for heading: $h"
	done
}

@test "parity: a body with NO Implementation Tasks heading yields empty in both" {
	local body
	body=$(printf '%s\n' \
		'## Acceptance Criteria' \
		'' \
		'- [ ] `[bash-script-craftsman]` **(S)** Not under a tasks heading')
	[ -z "$(_orch_section "$body")" ]
	[ -z "$(_lib_section "$body")" ]
	[ "$(_orch_count "$body")" -eq 0 ]
	[ "$(_lib_count "$body")" -eq 0 ]
}
