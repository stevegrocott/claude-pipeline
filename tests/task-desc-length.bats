#!/usr/bin/env bats
#
# tests/task-desc-length.bats
# Coverage for the prose-only task-description length measurement (issue #823).
#
# Background: the turn-budget promotion check and the plan-validation
# "consider splitting" warning both measured the *entire* parsed task
# line — complexity hint (`**(S)**`), prose, and the mandatory trailing
# ` — \`path\`` file-path suffix — against TASK_DESC_PROMOTE_CHARS
# (default 120). The explore/enrich-issue skills' "~120 characters"
# guidance is about the prose alone, so a task with short prose and a
# couple of real repo paths could never satisfy the check: dropping the
# paths is not an option (assert_issue_valid hard-rejects pathless
# tasks). Nearly every (S) task was silently promoted to the larger
# 40-turn budget as a result.
#
# Fix: a single helper, `_task_desc_prose_len`, strips the leading
# complexity hint and the trailing file-path suffix before measuring
# length, and is used at both call sites (the turn-budget check and the
# plan-validation warning) so they cannot drift apart again.
#
# This suite extracts `_task_desc_prose_len` from the orchestrator
# in-process via an awk range extraction (the same pattern used by
# agent-name-normalization.bats, event-emission.bats and
# timeout-budget.bats). If the function does not exist yet — the
# corresponding implementation task on this issue not yet merged — the
# awk range matches nothing, the function stays undefined, and these
# tests fail as expected (RED) until the implementation lands.
#

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
ORCHESTRATOR="$REPO_ROOT/.claude/scripts/implement-issue-orchestrator.sh"

# ---------------------------------------------------------------------------
# Per-test setup / teardown
# ---------------------------------------------------------------------------

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
}

teardown() {
	if [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Extract _task_desc_prose_len from the orchestrator and source it in-process.
_source_prose_len_function() {
	local func_file="$TEST_TMP/prose_len_funcs.bash"
	awk '
		/^readonly /                                 { next }
		/^set -o /                                   { next }
		/^_task_desc_prose_len\(\) \{$/,/^\}$/       { print; next }
	' "$ORCHESTRATOR" > "$func_file"
	# shellcheck disable=SC1090
	source "$func_file"
}

# ---------------------------------------------------------------------------
# AC1 / AC4 — hint and path-suffix stripping
# ---------------------------------------------------------------------------

@test "_task_desc_prose_len strips the complexity hint and a single-path suffix" {
	_source_prose_len_function

	local prose="Fix bug in parser"
	local desc="**(S)** ${prose} — \`src/foo.sh:L10\`"

	run _task_desc_prose_len "$desc"
	[ "$status" -eq 0 ]
	[ "$output" -eq "${#prose}" ]
}

@test "_task_desc_prose_len strips the complexity hint and a multi-path suffix" {
	_source_prose_len_function

	# Real example from the issue's Research Findings: full line is 144
	# chars, prose alone is 50.
	local prose='Replace two bare `((x++))` with the assignment form'
	local desc="**(S)** ${prose} — \`.claude/scripts/issue-body-lib.sh:L165\`, \`.claude/scripts/issue-body-lib.sh:L381\`"

	run _task_desc_prose_len "$desc"
	[ "$status" -eq 0 ]
	[ "$output" -eq "${#prose}" ]
}

@test "_task_desc_prose_len handles a task line with no complexity hint" {
	_source_prose_len_function

	local prose="Fix null pointer check"
	local desc="${prose} — \`src/a.ts:L1\`"

	run _task_desc_prose_len "$desc"
	[ "$status" -eq 0 ]
	[ "$output" -eq "${#prose}" ]
}

@test "_task_desc_prose_len does not strip an em dash embedded in prose (AC4)" {
	_source_prose_len_function

	# Two em dashes: the first is prose punctuation, the second precedes
	# the real path suffix. Only the trailing " — \`path\`" tail — the
	# one that is entirely backtick-quoted path tokens — is a suffix.
	local prose="Improve the cache-miss path — reduces P99 latency"
	local desc="**(S)** ${prose} — \`src/cache.ts:L44\`"

	run _task_desc_prose_len "$desc"
	[ "$status" -eq 0 ]
	[ "$output" -eq "${#prose}" ]
}

@test "_task_desc_prose_len leaves prose-only em dash untouched when no path suffix follows" {
	_source_prose_len_function

	# The tail after the (only) em dash is plain prose, not backtick
	# paths, so nothing should be stripped except the hint.
	local prose="Improve the cache-miss path — reduces P99 latency"
	local desc="**(S)** ${prose}"

	run _task_desc_prose_len "$desc"
	[ "$status" -eq 0 ]
	[ "$output" -eq "${#prose}" ]
}

# ---------------------------------------------------------------------------
# AC1 — short prose + long path suffix must NOT promote
# ---------------------------------------------------------------------------

@test "_task_desc_prose_len stays under threshold when only the path suffix is long" {
	_source_prose_len_function

	local prose="Add prose-only length helper"
	local desc="**(S)** ${prose} — \`.claude/scripts/implement-issue-orchestrator.sh:L2975-3025\`, \`.claude/scripts/implement-issue-orchestrator.sh:L10571-10580\`"

	# Full line is well over 120 chars; prose alone is short.
	[ "${#desc}" -gt 120 ]

	run _task_desc_prose_len "$desc"
	[ "$status" -eq 0 ]
	[ "$output" -eq "${#prose}" ]
	[ "$output" -lt 120 ]
}

# ---------------------------------------------------------------------------
# AC2 — long prose must still exceed the threshold (stripping must not
# accidentally remove prose content)
# ---------------------------------------------------------------------------

@test "_task_desc_prose_len still exceeds the threshold when prose alone is long" {
	_source_prose_len_function

	local prose="This task description is deliberately verbose so that the prose portion alone exceeds the one hundred twenty character promotion threshold on its own merits"
	local desc="**(S)** ${prose} — \`src/a.ts:L1\`"

	[ "${#prose}" -gt 120 ]

	run _task_desc_prose_len "$desc"
	[ "$status" -eq 0 ]
	[ "$output" -eq "${#prose}" ]
	[ "$output" -gt 120 ]
}

# ---------------------------------------------------------------------------
# AC3 — both call sites use the same helper (no divergence possible)
# ---------------------------------------------------------------------------

@test "the turn-budget check and the plan-validation warning both call _task_desc_prose_len" {
	# Guards against the helper being introduced but only wired into one
	# of the two call sites, which would let the checks drift apart again
	# exactly as issue #823 describes.
	local call_count
	call_count=$(grep -c '_task_desc_prose_len' "$ORCHESTRATOR")
	# 1 for the function definition line + at least 2 call sites.
	[ "$call_count" -ge 3 ]
}

@test "the plan-validation warning measures prose length via the helper, not raw \${#desc}" {
	# Line 10604 (pre-fix) computed desc_len from the raw parsed
	# description. After the fix it must route through the helper
	# instead of re-implementing the strip inline.
	local warning_block
	warning_block=$(awk '
		/large task descriptions/,/^        done$/
	' "$ORCHESTRATOR")
	[[ -n "$warning_block" ]] || fail "could not locate the plan-validation warning block in $ORCHESTRATOR"
	[[ "$warning_block" == *"_task_desc_prose_len"* ]] || \
		fail "plan-validation warning does not call _task_desc_prose_len. Block: $warning_block"
}
